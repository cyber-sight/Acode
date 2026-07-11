#import "Executor.h"
#import <Cordova/CDVPluginResult.h>
#import "IshBridge.h"

static NSMutableDictionary<NSString *, NSString *> *sessionCallbacks;
static NSMutableDictionary<NSString *, NSString *> *execCallbacks;
static NSMutableDictionary<NSString *, NSMutableString *> *execOutputs;
static __weak Executor *sharedExecutor;

@implementation Executor

+ (void)initialize {
    if (self == [Executor class]) {
        sessionCallbacks = [NSMutableDictionary dictionary];
        execCallbacks = [NSMutableDictionary dictionary];
        execOutputs = [NSMutableDictionary dictionary];
        [[IshBridge shared] setEventHandler:^(NSString *sessionId, NSString *type, NSString *payload) {
            dispatch_async(dispatch_get_main_queue(), ^{
                NSString *execCallbackId = execCallbacks[sessionId];
                if (execCallbackId) {
                    NSMutableString *output = execOutputs[sessionId];
                    if (!output) {
                        output = [NSMutableString string];
                        execOutputs[sessionId] = output;
                    }
                    [output appendString:payload ?: @""];

                    NSRange markerRange = [output rangeOfString:@"\n__ACODE_EXEC_EXIT__:"];
                    if (markerRange.location == NSNotFound) {
                        return;
                    }

                    NSUInteger exitCodeStart = NSMaxRange(markerRange);
                    NSRange newlineRange = [output rangeOfString:@"\n" options:0 range:NSMakeRange(exitCodeStart, output.length - exitCodeStart)];
                    if (newlineRange.location == NSNotFound) {
                        return;
                    }

                    NSString *exitCodeString = [output substringWithRange:NSMakeRange(exitCodeStart, newlineRange.location - exitCodeStart)];
                    NSScanner *scanner = [NSScanner scannerWithString:exitCodeString];
                    NSInteger exitCode = 0;
                    BOOL hasExitCode = [scanner scanInteger:&exitCode] && scanner.isAtEnd;
                    if (!hasExitCode) {
                        return;
                    }

                    NSString *commandOutput = [output substringToIndex:markerRange.location];
                    [execCallbacks removeObjectForKey:sessionId];
                    [execOutputs removeObjectForKey:sessionId];
                    [[IshBridge shared] stopSession:sessionId completion:nil];

                    if (!sharedExecutor) {
                        return;
                    }
                    CDVPluginResult *result = nil;
                    if (exitCode == 0) {
                        result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:commandOutput];
                    } else {
                        NSString *message = commandOutput.length > 0 ? commandOutput : [NSString stringWithFormat:@"Command exited with status %ld", (long)exitCode];
                        result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:message];
                    }
                    [sharedExecutor.commandDelegate sendPluginResult:result callbackId:execCallbackId];
                    return;
                }

                NSString *callbackId = sessionCallbacks[sessionId];
                if (!callbackId || !sharedExecutor) {
                    return;
                }
                NSString *message = [NSString stringWithFormat:@"%@:%@", type, payload ?: @""];
                CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:message];
                BOOL exited = [type isEqualToString:@"exit"];
                [result setKeepCallback:@(!exited)];
                if (exited) {
                    [sessionCallbacks removeObjectForKey:sessionId];
                }
                [sharedExecutor.commandDelegate sendPluginResult:result callbackId:callbackId];
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

    [[IshBridge shared] stopSession:sessionId completion:^(NSError * _Nullable error) {
        if (error) {
            CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:error.localizedDescription];
            [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
            return;
        }
        [sessionCallbacks removeObjectForKey:sessionId];
        [execCallbacks removeObjectForKey:sessionId];
        [execOutputs removeObjectForKey:sessionId];
        CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
        [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
    }];
}

- (void)exec:(CDVInvokedUrlCommand *)command {
    NSString *cmd = command.arguments.count > 0 ? command.arguments[0] : @"";
    NSString *wrappedCommand = [NSString stringWithFormat:@"(\n%@\n)\n__acode_exec_status=$?\nprintf '\\n__ACODE_EXEC_EXIT__:%%s\\n' \"$__acode_exec_status\"", cmd];

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
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 120 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            NSString *callbackId = execCallbacks[sessionId];
            if (!callbackId) {
                return;
            }
            [execCallbacks removeObjectForKey:sessionId];
            [execOutputs removeObjectForKey:sessionId];
            [[IshBridge shared] stopSession:sessionId completion:nil];
            if (sharedExecutor) {
                CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"Command timed out after 120 seconds"];
                [sharedExecutor.commandDelegate sendPluginResult:result callbackId:callbackId];
            }
        });
    }];
}

- (void)stopService:(CDVInvokedUrlCommand *)command {
    NSArray<NSString *> *sessionIds = [sessionCallbacks.allKeys arrayByAddingObjectsFromArray:execCallbacks.allKeys];
    for (NSString *sessionId in sessionIds) {
        [[IshBridge shared] stopSession:sessionId completion:nil];
    }
    [sessionCallbacks removeAllObjects];
    [execCallbacks removeAllObjects];
    [execOutputs removeAllObjects];
    CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
    [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
}

- (void)isRunning:(CDVInvokedUrlCommand *)command {
    NSString *sessionId = command.arguments.count > 0 ? command.arguments[0] : @"";
    BOOL running = sessionCallbacks[sessionId] != nil || execCallbacks[sessionId] != nil;
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

@end
