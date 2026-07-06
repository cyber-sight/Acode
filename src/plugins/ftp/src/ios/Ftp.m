#import "Ftp.h"
#import <Cordova/CDVPluginResult.h>

@implementation Ftp

- (void)connect:(CDVInvokedUrlCommand *)command {
    [self sendUnsupported:command];
}

- (void)listDirectory:(CDVInvokedUrlCommand *)command {
    [self sendUnsupported:command];
}

- (void)execCommand:(CDVInvokedUrlCommand *)command {
    [self sendUnsupported:command];
}

- (void)isConnected:(CDVInvokedUrlCommand *)command {
    CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsInt:0];
    [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
}

- (void)disconnect:(CDVInvokedUrlCommand *)command {
    CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
    [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
}

- (void)downloadFile:(CDVInvokedUrlCommand *)command {
    [self sendUnsupported:command];
}

- (void)uploadFile:(CDVInvokedUrlCommand *)command {
    [self sendUnsupported:command];
}

- (void)deleteFile:(CDVInvokedUrlCommand *)command {
    [self sendUnsupported:command];
}

- (void)deleteDirectory:(CDVInvokedUrlCommand *)command {
    [self sendUnsupported:command];
}

- (void)createDirectory:(CDVInvokedUrlCommand *)command {
    [self sendUnsupported:command];
}

- (void)createFile:(CDVInvokedUrlCommand *)command {
    [self sendUnsupported:command];
}

- (void)getStat:(CDVInvokedUrlCommand *)command {
    [self sendUnsupported:command];
}

- (void)exists:(CDVInvokedUrlCommand *)command {
    [self sendUnsupported:command];
}

- (void)changeDirectory:(CDVInvokedUrlCommand *)command {
    [self sendUnsupported:command];
}

- (void)changeToParentDirectory:(CDVInvokedUrlCommand *)command {
    [self sendUnsupported:command];
}

- (void)getWorkingDirectory:(CDVInvokedUrlCommand *)command {
    CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:@"/"];
    [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
}

- (void)rename:(CDVInvokedUrlCommand *)command {
    [self sendUnsupported:command];
}

- (void)getKeepAlive:(CDVInvokedUrlCommand *)command {
    CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsInt:0];
    [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
}

- (void)sendNoOp:(CDVInvokedUrlCommand *)command {
    CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
    [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
}

- (void)sendUnsupported:(CDVInvokedUrlCommand *)command {
    CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"FTP is not supported on iOS yet."];
    [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
}

@end
