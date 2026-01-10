#import "BackgroundExecutor.h"
#import "Executor.h"

@implementation BackgroundExecutor

- (void)start:(CDVInvokedUrlCommand *)command {
    Executor *executor = [Executor new];
    [executor start:command];
}

- (void)write:(CDVInvokedUrlCommand *)command {
    Executor *executor = [Executor new];
    [executor write:command];
}

- (void)stop:(CDVInvokedUrlCommand *)command {
    Executor *executor = [Executor new];
    [executor stop:command];
}

- (void)exec:(CDVInvokedUrlCommand *)command {
    Executor *executor = [Executor new];
    [executor exec:command];
}

- (void)stopService:(CDVInvokedUrlCommand *)command {
    Executor *executor = [Executor new];
    [executor stopService:command];
}

- (void)isRunning:(CDVInvokedUrlCommand *)command {
    Executor *executor = [Executor new];
    [executor isRunning:command];
}

- (void)moveToBackground:(CDVInvokedUrlCommand *)command {
    Executor *executor = [Executor new];
    [executor moveToBackground:command];
}

- (void)moveToForeground:(CDVInvokedUrlCommand *)command {
    Executor *executor = [Executor new];
    [executor moveToForeground:command];
}

- (void)loadLibrary:(CDVInvokedUrlCommand *)command {
    Executor *executor = [Executor new];
    [executor loadLibrary:command];
}

@end
