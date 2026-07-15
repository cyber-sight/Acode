#import "Executor.h"
#import <Cordova/CDVPluginResult.h>
#import "IshBridge.h"
#import "IshWebSocketServer.h"
#import "AcodeIshTerminal.h"

static NSMutableDictionary<NSString *, NSString *> *sessionCallbacks;
static NSMutableDictionary<NSString *, NSString *> *execCallbacks;
static NSMutableDictionary<NSString *, NSMutableString *> *execOutputs;
static NSMutableDictionary<NSString *, NSString *> *execMarkers;
static NSMutableDictionary<NSString *, NSMutableArray<NSDictionary<NSString *, NSString *> *> *> *pendingEvents;
static NSMutableDictionary<NSString *, IshWebSocketServer *> *wsServers;
static __weak Executor *sharedExecutor;

static void HandleExecutorEvent(NSString *sessionId, NSString *type, NSString *payload) {
    if ([type isEqualToString:@"exit"] && wsServers[sessionId]) {
        IshWebSocketServer *server = wsServers[sessionId];
        [wsServers removeObjectForKey:sessionId];
        [server stop];
        [pendingEvents removeObjectForKey:sessionId];
        return;
    }
    NSString *execCallbackId = execCallbacks[sessionId];
    NSString *sessionCallbackId = sessionCallbacks[sessionId];
    if (!execCallbackId && !sessionCallbackId) {
        NSMutableArray *events = pendingEvents[sessionId];
        if (!events) {
            events = [NSMutableArray array];
            pendingEvents[sessionId] = events;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                if (!sessionCallbacks[sessionId] && !execCallbacks[sessionId]) {
                    [pendingEvents removeObjectForKey:sessionId];
                }
            });
        }
        [events addObject:@{ @"type": type ?: @"stdout", @"payload": payload ?: @"" }];
        if (events.count > 256) [events removeObjectAtIndex:0];
        return;
    }

    if (execCallbackId) {
        if ([type isEqualToString:@"exit"]) {
            [execCallbacks removeObjectForKey:sessionId];
            [execOutputs removeObjectForKey:sessionId];
            [execMarkers removeObjectForKey:sessionId];
            [pendingEvents removeObjectForKey:sessionId];
            if (sharedExecutor) {
                NSString *message = [NSString stringWithFormat:@"Command session exited before returning a result (status %@)", payload ?: @"unknown"];
                CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:message];
                [sharedExecutor.commandDelegate sendPluginResult:result callbackId:execCallbackId];
            }
            return;
        }
        NSMutableString *output = execOutputs[sessionId];
        if (!output) {
            output = [NSMutableString string];
            execOutputs[sessionId] = output;
        }
        [output appendString:payload ?: @""];

        NSString *marker = execMarkers[sessionId];
        if (!marker) return;
        NSRange markerRange = [output rangeOfString:marker];
        if (markerRange.location == NSNotFound) return;
        NSUInteger exitCodeStart = NSMaxRange(markerRange);
        NSRange newlineRange = [output rangeOfString:@"\n" options:0 range:NSMakeRange(exitCodeStart, output.length - exitCodeStart)];
        if (newlineRange.location == NSNotFound) return;

        NSString *exitCodeString = [output substringWithRange:NSMakeRange(exitCodeStart, newlineRange.location - exitCodeStart)];
        NSScanner *scanner = [NSScanner scannerWithString:exitCodeString];
        NSInteger exitCode = 0;
        if (![scanner scanInteger:&exitCode] || !scanner.isAtEnd) return;

        NSString *commandOutput = [output substringToIndex:markerRange.location];
        [execCallbacks removeObjectForKey:sessionId];
        [execOutputs removeObjectForKey:sessionId];
        [execMarkers removeObjectForKey:sessionId];
        [pendingEvents removeObjectForKey:sessionId];
        [[IshBridge shared] stopSession:sessionId completion:nil];
        if (!sharedExecutor) return;

        CDVPluginResult *result;
        if (exitCode == 0) {
            result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:commandOutput];
        } else {
            NSString *message = commandOutput.length > 0 ? commandOutput : [NSString stringWithFormat:@"Command exited with status %ld", (long)exitCode];
            result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:message];
        }
        [sharedExecutor.commandDelegate sendPluginResult:result callbackId:execCallbackId];
        return;
    }

    if (!sharedExecutor) return;
    NSString *message = [NSString stringWithFormat:@"%@:%@", type, payload ?: @""];
    CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:message];
    BOOL exited = [type isEqualToString:@"exit"];
    [result setKeepCallback:@(!exited)];
    if (exited) {
        [sessionCallbacks removeObjectForKey:sessionId];
        [pendingEvents removeObjectForKey:sessionId];
    }
    [sharedExecutor.commandDelegate sendPluginResult:result callbackId:sessionCallbackId];
}

static void DrainPendingEvents(NSString *sessionId) {
    NSArray<NSDictionary<NSString *, NSString *> *> *events = [pendingEvents[sessionId] copy];
    [pendingEvents removeObjectForKey:sessionId];
    for (NSDictionary<NSString *, NSString *> *event in events) {
        HandleExecutorEvent(sessionId, event[@"type"], event[@"payload"]);
    }
}

static IshWebSocketServer *CreateWebSocketServer(NSString *sessionId,
                                                  AcodeIshTerminal *terminal,
                                                  NSError **error) {
    IshWebSocketServer *server = [[IshWebSocketServer alloc] initWithTerminal:terminal];
    server.sessionId = sessionId;
    if (![server startWithError:error]) return nil;
    server.disconnectHandler = ^{
        // A dropped browser socket must not destroy the PTY. The listener and
        // iSH session remain alive so the JavaScript side can reconnect.
        NSLog(@"[WS] awaiting reconnect for session %@", sessionId);
    };
    wsServers[sessionId] = server;
    return server;
}

@implementation Executor

+ (void)initialize {
    if (self == [Executor class]) {
        sessionCallbacks = [NSMutableDictionary dictionary];
        execCallbacks = [NSMutableDictionary dictionary];
        execOutputs = [NSMutableDictionary dictionary];
        execMarkers = [NSMutableDictionary dictionary];
        pendingEvents = [NSMutableDictionary dictionary];
        wsServers = [NSMutableDictionary dictionary];
        [[IshBridge shared] setEventHandler:^(NSString *sessionId, NSString *type, NSString *payload) {
            dispatch_async(dispatch_get_main_queue(), ^{
                HandleExecutorEvent(sessionId, type, payload);
            });
        }];
    }
}

- (void)pluginInitialize {
    sharedExecutor = self;
}

- (void)start:(CDVInvokedUrlCommand *)command {
    NSString *cmd = command.arguments.count > 0 ? command.arguments[0] : @"";
    NSString *callbackId = command.callbackId;

    [[IshBridge shared] startWithCommand:cmd completion:^(NSString *sessionId, NSError * _Nullable error) {
        if (error) {
            CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:error.localizedDescription];
            [self.commandDelegate sendPluginResult:result callbackId:callbackId];
            return;
        }
        if (sessionId.length == 0) {
            CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"Failed to start session"];
            [self.commandDelegate sendPluginResult:result callbackId:callbackId];
            return;
        }
        sessionCallbacks[sessionId] = callbackId;
        CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:sessionId];
        [result setKeepCallback:@YES];
        [self.commandDelegate sendPluginResult:result callbackId:callbackId];
        DrainPendingEvents(sessionId);
    }];
}

- (void)write:(CDVInvokedUrlCommand *)command {
    NSString *sessionId = command.arguments.count > 0 ? command.arguments[0] : @"";
    NSString *input = command.arguments.count > 1 ? command.arguments[1] : @"";

    [[IshBridge shared] writeToSession:sessionId input:input completion:^(NSError * _Nullable error) {
        if (error) {
            CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:error.localizedDescription];
            [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
            return;
        }
        CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
        [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
    }];
}

- (void)resize:(CDVInvokedUrlCommand *)command {
	NSString *sessionId = command.arguments.count > 0 ? command.arguments[0] : @"";
	NSInteger columns = command.arguments.count > 1 ? [command.arguments[1] integerValue] : 0;
	NSInteger rows = command.arguments.count > 2 ? [command.arguments[2] integerValue] : 0;

	[[IshBridge shared] resizeSession:sessionId columns:columns rows:rows completion:^(NSError * _Nullable error) {
		CDVPluginResult *result = error
			? [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:error.localizedDescription]
			: [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
		[self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
	}];
}

- (void)stop:(CDVInvokedUrlCommand *)command {
    NSString *sessionId = command.arguments.count > 0 ? command.arguments[0] : @"";

    IshWebSocketServer *server = wsServers[sessionId];
    if (server) {
        [wsServers removeObjectForKey:sessionId];
        [server stop];
    }

    [[IshBridge shared] stopSession:sessionId completion:^(NSError * _Nullable error) {
        if (error) {
            CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:error.localizedDescription];
            [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
            return;
        }
        [sessionCallbacks removeObjectForKey:sessionId];
        [execCallbacks removeObjectForKey:sessionId];
        [execOutputs removeObjectForKey:sessionId];
        [execMarkers removeObjectForKey:sessionId];
        [pendingEvents removeObjectForKey:sessionId];
        CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
        [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
    }];
}

- (void)exec:(CDVInvokedUrlCommand *)command {
    NSString *cmd = command.arguments.count > 0 ? command.arguments[0] : @"";
    NSString *token = NSUUID.UUID.UUIDString;
    NSString *marker = [NSString stringWithFormat:@"\n__ACODE_EXEC_EXIT_%@__:", token];
    NSString *wrappedCommand = [NSString stringWithFormat:@"(\n%@\n)\n__acode_exec_status=$?\nprintf '\\n__ACODE_EXEC_EXIT_%@__:%%s\\n' \"$__acode_exec_status\"", cmd, token];

    [[IshBridge shared] startWithCommand:wrappedCommand completion:^(NSString *sessionId, NSError * _Nullable error) {
        if (error) {
            CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:error.localizedDescription];
            [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
            return;
        }
        if (sessionId.length == 0) {
            CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"Failed to start session"];
            [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
            return;
        }
        execCallbacks[sessionId] = command.callbackId;
        execOutputs[sessionId] = [NSMutableString string];
        execMarkers[sessionId] = marker;
        DrainPendingEvents(sessionId);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 120 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            NSString *callbackId = execCallbacks[sessionId];
            if (!callbackId) {
                return;
            }
            [execCallbacks removeObjectForKey:sessionId];
            [execOutputs removeObjectForKey:sessionId];
            [execMarkers removeObjectForKey:sessionId];
            [pendingEvents removeObjectForKey:sessionId];
            [[IshBridge shared] stopSession:sessionId completion:nil];
            if (sharedExecutor) {
                CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"Command timed out after 120 seconds"];
                [sharedExecutor.commandDelegate sendPluginResult:result callbackId:callbackId];
            }
        });
    }];
}

- (void)stopService:(CDVInvokedUrlCommand *)command {
    // Stop WebSocket-served sessions
    for (NSString *sessionId in wsServers.allKeys) {
        [wsServers[sessionId] stop];
        [[IshBridge shared] stopSession:sessionId completion:nil];
    }
    [wsServers removeAllObjects];

    // Stop Cordova callback-served sessions
    NSArray<NSString *> *callbackSessionIds = [sessionCallbacks.allKeys arrayByAddingObjectsFromArray:execCallbacks.allKeys];
    for (NSString *sessionId in callbackSessionIds) {
        [[IshBridge shared] stopSession:sessionId completion:nil];
    }
    [sessionCallbacks removeAllObjects];
    [execCallbacks removeAllObjects];
    [execOutputs removeAllObjects];
    [execMarkers removeAllObjects];
    [pendingEvents removeAllObjects];
    CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
    [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
}

- (void)isRunning:(CDVInvokedUrlCommand *)command {
    NSString *sessionId = command.arguments.count > 0 ? command.arguments[0] : @"";
    BOOL running = sessionCallbacks[sessionId] != nil || execCallbacks[sessionId] != nil || wsServers[sessionId] != nil;
    CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:running ? @"running" : @"exited"];
    [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
}

- (void)moveToBackground:(CDVInvokedUrlCommand *)command {
    CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
    [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
}

- (void)moveToForeground:(CDVInvokedUrlCommand *)command {
    CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
    [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
}

- (void)loadLibrary:(CDVInvokedUrlCommand *)command {
    CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"Not supported on iOS."];
    [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
}

- (void)spawn:(CDVInvokedUrlCommand *)command {
    // Handle cmd as either a string or an array of strings (from Executor.js spawnStream)
    NSString *cmd = @"sh";
    if (command.arguments.count > 0) {
        id cmdArg = command.arguments[0];
        if ([cmdArg isKindOfClass:[NSString class]]) {
            cmd = cmdArg;
        } else if ([cmdArg isKindOfClass:[NSArray class]]) {
            cmd = [cmdArg componentsJoinedByString:@" "];
        }
    }
    NSInteger cols = command.arguments.count > 1 ? [command.arguments[1] integerValue] : 80;
    NSInteger rows = command.arguments.count > 2 ? [command.arguments[2] integerValue] : 24;

    [[IshBridge shared] startWithCommand:cmd completion:^(NSString *sessionId, NSError *error) {
        if (error) {
            CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR
                                                        messageAsString:error.localizedDescription];
            [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
            return;
        }
        if (sessionId.length == 0) {
            CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR
                                                        messageAsString:@"Failed to create terminal session"];
            [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
            return;
        }

        AcodeIshTerminal *terminal = [[IshBridge shared] terminalForSession:sessionId];
        if (!terminal) {
            CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR
                                                        messageAsString:@"Terminal session not found after creation"];
            [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
            return;
        }

        // Apply requested terminal size
        [terminal resizeToColumns:(int)cols rows:(int)rows];

        // Create WebSocket server for this session
        NSError *serverError = nil;
        IshWebSocketServer *server = CreateWebSocketServer(sessionId, terminal, &serverError);
        if (!server) {
            [[IshBridge shared] stopSession:sessionId completion:nil];
            NSString *msg = serverError.localizedDescription ?: @"Failed to start WebSocket server";
            CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR
                                                        messageAsString:msg];
            [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
            return;
        }

        NSDictionary *stream = @{
            @"port": @(server.port),
            @"sessionId": sessionId,
        };
        CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK
                                               messageAsDictionary:stream];
        [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
    }];
}

- (void)reconnect:(CDVInvokedUrlCommand *)command {
    NSString *sessionId = command.arguments.count > 0 ? command.arguments[0] : @"";
    if (sessionId.length == 0) {
        CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR
                                                    messageAsString:@"Missing terminal session ID"];
        [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
        return;
    }

    AcodeIshTerminal *terminal = [[IshBridge shared] terminalForSession:sessionId];
    if (!terminal) {
        CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR
                                                    messageAsString:@"Terminal session no longer exists"];
        [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
        return;
    }

    IshWebSocketServer *server = wsServers[sessionId];
    if (!server.isRunning) {
        [server stop];
        [wsServers removeObjectForKey:sessionId];
        NSError *serverError = nil;
        server = CreateWebSocketServer(sessionId, terminal, &serverError);
        if (!server) {
            NSString *message = serverError.localizedDescription ?: @"Failed to restart terminal WebSocket server";
            CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR
                                                        messageAsString:message];
            [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
            return;
        }
        NSLog(@"[WS] restarted listener for session %@ on port %u", sessionId, server.port);
    }

    NSDictionary *stream = @{ @"port": @(server.port), @"sessionId": sessionId };
    CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK
                                           messageAsDictionary:stream];
    [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
}

@end
