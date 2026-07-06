#import <Cordova/CDVPlugin.h>

@interface Executor : CDVPlugin
- (void)start:(CDVInvokedUrlCommand *)command;
- (void)write:(CDVInvokedUrlCommand *)command;
- (void)stop:(CDVInvokedUrlCommand *)command;
- (void)exec:(CDVInvokedUrlCommand *)command;
- (void)stopService:(CDVInvokedUrlCommand *)command;
- (void)isRunning:(CDVInvokedUrlCommand *)command;
- (void)moveToBackground:(CDVInvokedUrlCommand *)command;
- (void)moveToForeground:(CDVInvokedUrlCommand *)command;
- (void)loadLibrary:(CDVInvokedUrlCommand *)command;
@end
