#import "BackgroundExecutor.h"

// Explicit stubs: BackgroundExecutor subclasses Executor, so without these
// overrides every inherited method would create REAL guest sessions with no
// background semantics attached (iOS grants the guest no independent process
// lifetime). Each stub answers with an error so JS callers fail fast instead
// of silently forking terminal state. moveToBackground/moveToForeground are
// intentionally NOT overridden; their inherited no-op OK responses are
// harmless. setProotDebug: is Android-only and does not exist on iOS
// Executor.h, so there is nothing to stub here.

static void SendNotSupported(Executor *self, CDVInvokedUrlCommand *command) {
    CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR
                                                messageAsString:@"Not supported on iOS"];
    [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
}

@implementation BackgroundExecutor

- (void)start:(CDVInvokedUrlCommand *)command { SendNotSupported(self, command); }
- (void)write:(CDVInvokedUrlCommand *)command { SendNotSupported(self, command); }
- (void)resize:(CDVInvokedUrlCommand *)command { SendNotSupported(self, command); }
- (void)stop:(CDVInvokedUrlCommand *)command { SendNotSupported(self, command); }
- (void)exec:(CDVInvokedUrlCommand *)command { SendNotSupported(self, command); }
- (void)stopService:(CDVInvokedUrlCommand *)command { SendNotSupported(self, command); }
- (void)isRunning:(CDVInvokedUrlCommand *)command { SendNotSupported(self, command); }
- (void)spawn:(CDVInvokedUrlCommand *)command { SendNotSupported(self, command); }
- (void)reconnect:(CDVInvokedUrlCommand *)command { SendNotSupported(self, command); }
- (void)loadLibrary:(CDVInvokedUrlCommand *)command { SendNotSupported(self, command); }

@end
