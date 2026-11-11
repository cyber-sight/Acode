#import "AcodeTerminalBackend.h"
#import "IshBridge.h"
#import "KernariumBridge.h"

static NSString *const AcodeTerminalRuntimeKey = @"AcodeTerminalRuntime";

static NSString *RequestedRuntime(void) {
    NSString *requested = [NSUserDefaults.standardUserDefaults stringForKey:AcodeTerminalRuntimeKey];
    if (requested.length == 0) {
        id value = [NSBundle.mainBundle objectForInfoDictionaryKey:AcodeTerminalRuntimeKey];
        if ([value isKindOfClass:[NSString class]]) requested = value;
    }
    return requested.lowercaseString ?: @"ish";
}

static id<AcodeTerminalBackend> SelectedBackend(NSString **name) {
    static id<AcodeTerminalBackend> backend;
    static NSString *backendName;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Both runtimes own process-wide state (the iSH kernel, Kernarium's
        // single guest), so the choice holds until the app is relaunched.
        if ([RequestedRuntime() isEqualToString:@"kernarium"]) {
            if ([KernariumBridge isRuntimeAvailable]) {
                backend = [KernariumBridge shared];
                backendName = @"kernarium";
            } else {
                NSLog(@"[Terminal] Kernarium requested but no runtime framework is embedded; using iSH");
            }
        }
        if (!backend) {
            backend = [IshBridge shared];
            backendName = @"ish";
        }
        NSLog(@"[Terminal] runtime: %@", backendName);
    });
    if (name) *name = backendName;
    return backend;
}

id<AcodeTerminalBackend> AcodeActiveTerminalBackend(void) {
    return SelectedBackend(NULL);
}

NSString *AcodeActiveTerminalRuntimeName(void) {
    NSString *name = nil;
    SelectedBackend(&name);
    return name;
}
