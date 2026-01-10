#import "IshBridge.h"
#import <objc/runtime.h>
#import <objc/message.h>
#include <stdlib.h>
#import "IshRootfs.h"

#if __has_include("ish/include/LinuxInterop.h")
#import "ish/include/LinuxInterop.h"
#import "ish/include/Terminal.h"
#define ISH_AVAILABLE 1
#else
#define ISH_AVAILABLE 0
#endif

@interface IshBridge ()
#if ISH_AVAILABLE
@property (nonatomic, strong) NSMapTable<NSString *, Terminal *> *sessions;
#endif
@property (nonatomic, copy) IshEventHandler eventHandler;
@property (nonatomic, assign) BOOL kernelStarted;
@end

@implementation IshBridge

+ (instancetype)shared {
    static IshBridge *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[IshBridge alloc] init];
#if ISH_AVAILABLE
        sharedInstance.sessions = [NSMapTable strongToStrongObjectsMapTable];
        [sharedInstance setupTerminalHookIfNeeded];
#endif
    });
    return sharedInstance;
}

- (void)setEventHandler:(IshEventHandler)handler {
    self.eventHandler = handler;
}

- (void)startWithCommand:(NSString *)command completion:(void (^)(NSString *sessionId, NSError * _Nullable error))completion {
#if !ISH_AVAILABLE
    if (completion) {
        NSError *error = [NSError errorWithDomain:@"IshBridge" code:1 userInfo:@{NSLocalizedDescriptionKey: @"iSH sources not available in build"}];
        completion(@"", error);
    }
    return;
#else
    [self startKernelIfNeeded];

    NSString *shell = @"/bin/sh";
    NSString *finalCommand = command.length > 0 ? command : @"";
    NSArray<NSString *> *argv = finalCommand.length > 0 ? @[shell, @"-lc", finalCommand] : @[shell];

    const char *exe = shell.UTF8String;
    const char *envp_arr[] = { "TERM=xterm-256color", NULL };

    NSUInteger argc = argv.count;
    const char **argv_arr = calloc(argc + 1, sizeof(char *));
    for (NSUInteger i = 0; i < argc; i++) {
        argv_arr[i] = argv[i].UTF8String;
    }
    argv_arr[argc] = NULL;

    __block int err = 0;
    __block Terminal *terminal = nil;

    sync_do_in_workqueue(^(void (^done)(void)) {
        linux_start_session(exe, argv_arr, envp_arr, ^(int retval, int pid, nsobj_t terminalObj) {
            err = retval;
            if (terminalObj) {
                terminal = (__bridge Terminal *)terminalObj;
            }
            done();
        });
    });

    free(argv_arr);

    if (err != 0 || terminal == nil) {
        NSError *error = [NSError errorWithDomain:@"IshBridge" code:2 userInfo:@{NSLocalizedDescriptionKey: @"Failed to start iSH session"}];
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(@"", error);
        });
        return;
    }

    NSString *sessionId = terminal.uuid.UUIDString ?: [[NSUUID UUID] UUIDString];
    [self.sessions setObject:terminal forKey:sessionId];
    dispatch_async(dispatch_get_main_queue(), ^{
        completion(sessionId, nil);
    });
#endif
}

- (void)writeToSession:(NSString *)sessionId input:(NSString *)input completion:(void (^)(NSError * _Nullable error))completion {
#if !ISH_AVAILABLE
    if (completion) {
        NSError *error = [NSError errorWithDomain:@"IshBridge" code:3 userInfo:@{NSLocalizedDescriptionKey: @"iSH sources not available in build"}];
        completion(error);
    }
    return;
#else
    Terminal *terminal = [self.sessions objectForKey:sessionId];
    if (!terminal) {
        if (completion) {
            NSError *error = [NSError errorWithDomain:@"IshBridge" code:4 userInfo:@{NSLocalizedDescriptionKey: @"Session not found"}];
            completion(error);
        }
        return;
    }

    NSData *data = [input dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
    [terminal sendInput:data];
    if (completion) {
        completion(nil);
    }
#endif
}

- (void)stopSession:(NSString *)sessionId completion:(void (^)(NSError * _Nullable error))completion {
#if !ISH_AVAILABLE
    if (completion) {
        NSError *error = [NSError errorWithDomain:@"IshBridge" code:5 userInfo:@{NSLocalizedDescriptionKey: @"iSH sources not available in build"}];
        completion(error);
    }
    return;
#else
    Terminal *terminal = [self.sessions objectForKey:sessionId];
    if (!terminal) {
        if (completion) {
            NSError *error = [NSError errorWithDomain:@"IshBridge" code:6 userInfo:@{NSLocalizedDescriptionKey: @"Session not found"}];
            completion(error);
        }
        return;
    }

    [terminal destroy];
    [self.sessions removeObjectForKey:sessionId];
    if (completion) {
        completion(nil);
    }
#endif
}

#if ISH_AVAILABLE
- (void)startKernelIfNeeded {
    if (self.kernelStarted) {
        return;
    }
    self.kernelStarted = YES;

    [self ensureRootfsReady];

    @try {
        actuate_kernel("");
    } @catch (NSException *exception) {
        // Ignore here; session start will error if kernel isn't ready.
    }
}

- (void)ensureRootfsReady {
    NSString *rootPath = [self rootfsPath];
    if (rootPath.length == 0) {
        return;
    }

    IshSetRootPath(rootPath.fileSystemRepresentation);

    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if ([fm fileExistsAtPath:rootPath isDirectory:&isDir] && isDir) {
        return;
    }

    NSString *bundleRoot = [[NSBundle mainBundle] pathForResource:@"ish-rootfs" ofType:nil];
    if (!bundleRoot) {
        return;
    }

    NSError *error = nil;
    [fm createDirectoryAtPath:rootPath withIntermediateDirectories:YES attributes:nil error:&error];
    if (error) {
        return;
    }

    NSDirectoryEnumerator *enumerator = [fm enumeratorAtPath:bundleRoot];
    for (NSString *relativePath in enumerator) {
        NSString *src = [bundleRoot stringByAppendingPathComponent:relativePath];
        NSString *dest = [rootPath stringByAppendingPathComponent:relativePath];
        BOOL isDirEntry = NO;
        [fm fileExistsAtPath:src isDirectory:&isDirEntry];
        if (isDirEntry) {
            [fm createDirectoryAtPath:dest withIntermediateDirectories:YES attributes:nil error:nil];
        } else {
            [fm copyItemAtPath:src toPath:dest error:nil];
        }
    }
}

- (NSString *)rootfsPath {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (!docs) {
        return @"";
    }
    return [docs stringByAppendingPathComponent:@"ish-rootfs"];
}

- (void)setupTerminalHookIfNeeded {
    Class terminalClass = NSClassFromString(@"Terminal");
    if (!terminalClass) {
        return;
    }

    SEL originalSelector = @selector(sendOutput:length:);
    SEL swizzledSelector = @selector(ish_sendOutput:length:);

    Method originalMethod = class_getInstanceMethod(terminalClass, originalSelector);
    Method swizzledMethod = class_getInstanceMethod([self class], swizzledSelector);

    if (!originalMethod || !swizzledMethod) {
        return;
    }

    BOOL didAdd = class_addMethod(terminalClass, swizzledSelector, method_getImplementation(swizzledMethod), method_getTypeEncoding(swizzledMethod));
    if (didAdd) {
        Method newMethod = class_getInstanceMethod(terminalClass, swizzledSelector);
        method_exchangeImplementations(originalMethod, newMethod);
    }
}

- (int)ish_sendOutput:(const void *)buf length:(int)len {
    int result = 0;
    // Call original implementation (swizzled)
    SEL originalSelector = @selector(ish_sendOutput:length:);
    if ([self respondsToSelector:originalSelector]) {
        result = ((int (*)(id, SEL, const void *, int))objc_msgSend)(self, originalSelector, buf, len);
    }

    Terminal *terminal = (Terminal *)self;
    NSString *sessionId = terminal.uuid.UUIDString;
    IshEventHandler handler = [IshBridge shared].eventHandler;
    if (sessionId && handler) {
        NSData *data = [NSData dataWithBytes:buf length:len];
        NSString *output = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding] ?: @"";
        handler(sessionId, @"stdout", output);
    }
    return result;
}
#endif

@end
