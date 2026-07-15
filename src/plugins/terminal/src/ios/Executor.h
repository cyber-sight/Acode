#import <Cordova/CDVPlugin.h>

@interface Executor : CDVPlugin
- (void)start:(CDVInvokedUrlCommand *)command;
- (void)write:(CDVInvokedUrlCommand *)command;
- (void)resize:(CDVInvokedUrlCommand *)command;
- (void)stop:(CDVInvokedUrlCommand *)command;
- (void)exec:(CDVInvokedUrlCommand *)command;
- (void)stopService:(CDVInvokedUrlCommand *)command;
- (void)isRunning:(CDVInvokedUrlCommand *)command;
- (void)moveToBackground:(CDVInvokedUrlCommand *)command;
- (void)moveToForeground:(CDVInvokedUrlCommand *)command;
- (void)loadLibrary:(CDVInvokedUrlCommand *)command;

/// Spawn a terminal session and return a WebSocket port for streaming I/O.
/// args[0]: command string (e.g. "sh")
/// args[1]: cols (NSNumber)
/// args[2]: rows (NSNumber)
- (void)spawn:(CDVInvokedUrlCommand *)command;
/// Return a live WebSocket endpoint for an existing terminal session,
/// recreating the native listener if necessary.
- (void)reconnect:(CDVInvokedUrlCommand *)command;
@end
