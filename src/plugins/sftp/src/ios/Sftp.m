#import "Sftp.h"
#import <Cordova/CDVPluginResult.h>

@implementation Sftp

- (void)connectUsingPassword:(CDVInvokedUrlCommand *)command {
    [self sendUnsupported:command];
}

- (void)connectUsingKeyFile:(CDVInvokedUrlCommand *)command {
    [self sendUnsupported:command];
}

- (void)exec:(CDVInvokedUrlCommand *)command {
    [self sendUnsupported:command];
}

- (void)getFile:(CDVInvokedUrlCommand *)command {
    [self sendUnsupported:command];
}

- (void)putFile:(CDVInvokedUrlCommand *)command {
    [self sendUnsupported:command];
}

- (void)lsDir:(CDVInvokedUrlCommand *)command {
    [self sendUnsupported:command];
}

- (void)stat:(CDVInvokedUrlCommand *)command {
    [self sendUnsupported:command];
}

- (void)mkdir:(CDVInvokedUrlCommand *)command {
    [self sendUnsupported:command];
}

- (void)rm:(CDVInvokedUrlCommand *)command {
    [self sendUnsupported:command];
}

- (void)createFile:(CDVInvokedUrlCommand *)command {
    [self sendUnsupported:command];
}

- (void)rename:(CDVInvokedUrlCommand *)command {
    [self sendUnsupported:command];
}

- (void)pwd:(CDVInvokedUrlCommand *)command {
    [self sendUnsupported:command];
}

- (void)close:(CDVInvokedUrlCommand *)command {
    CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
    [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
}

- (void)isConnected:(CDVInvokedUrlCommand *)command {
    CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:@"0"];
    [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
}

- (void)sendUnsupported:(CDVInvokedUrlCommand *)command {
    CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"SFTP is not supported on iOS yet."];
    [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
}

@end
