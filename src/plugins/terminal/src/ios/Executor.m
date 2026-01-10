#import "Executor.h"
#import <Cordova/CDVPluginResult.h>
#import "IshBridge.h"

static NSMutableDictionary<NSString *, NSString *> *sessionCallbacks;
static __weak Executor *sharedExecutor;

@implementation Executor

+ (void)initialize {
    if (self == [Executor class]) {
        sessionCallbacks = [NSMutableDictionary dictionary];
        [[IshBridge shared] setEventHandler:^(NSString *sessionId, NSString *type, NSString *payload) {
            NSString *callbackId = sessionCallbacks[sessionId];
            if (!callbackId) {
                return;
            }
            NSString *message = [NSString stringWithFormat:@"%@:%@", type, payload ?: @""];
            CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:message];
            [result setKeepCallback:@YES];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (sharedExecutor) {
                    [sharedExecutor.commandDelegate sendPluginResult:result callbackId:callbackId];
                }
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

- (void)stop:(CDVInvokedUrlCommand *)command {
    NSString *sessionId = command.arguments.count > 0 ? command.arguments[0] : @"";

    [[IshBridge shared] stopSession:sessionId completion:^(NSError * _Nullable error) {
        if (error) {
            CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:error.localizedDescription];
            [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
            return;
        }
        [sessionCallbacks removeObjectForKey:sessionId];
        CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
        [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
    }];
}

- (void)exec:(CDVInvokedUrlCommand *)command {
    CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"Not supported yet on iOS."];
    [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
}

- (void)stopService:(CDVInvokedUrlCommand *)command {
    CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
    [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
}

- (void)isRunning:(CDVInvokedUrlCommand *)command {
    CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsBool:NO];
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
