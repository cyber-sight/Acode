#import "Executor.h"
#import <Cordova/CDVPluginResult.h>
#import <objc/runtime.h>

static void notSupportedIMP(id self, SEL _cmd, CDVInvokedUrlCommand *command) {
    CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR
                                                 messageAsString:@"Not supported on iOS."];
    [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
}

@implementation Executor

+ (BOOL)resolveInstanceMethod:(SEL)sel {
    class_addMethod(self, sel, (IMP)notSupportedIMP, "v@:@");
    return YES;
}

@end
