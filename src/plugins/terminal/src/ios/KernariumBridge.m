#import "KernariumBridge.h"

#import <UIKit/UIKit.h>
#import <MetalKit/MetalKit.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

// KernariumRuntime.h comes from a Kernarium checkout
// (Kernarium/Runtime/KernariumRuntime.h); hooks/ios/add-kernarium-runtime.js
// adds it to the header search path when KERNARIUM_DIR is set. Without it this
// backend compiles to a stub that reports no runtime, and iSH stays in use.
#if __has_include("KernariumRuntime.h")
#include "KernariumRuntime.h"
#define ACODE_HAS_KERNARIUM 1
#else
#define ACODE_HAS_KERNARIUM 0
#endif

const uint32_t AcodeKernariumAgentPort = 7000;

static NSString *const KernariumErrorDomain = @"KernariumBridge";
static const NSUInteger KernariumMaxPendingOutput = 256 * 1024;
static const NSUInteger KernariumConsoleTailBytes = 64 * 1024;
static const uint32_t KernariumMaxFramePayload = 1u << 20;
// The first session waits for the whole boot, which takes longest on a cold
// start with a fresh overlay disk to format.
static const NSTimeInterval KernariumAgentDeadlineSeconds = 180.0;
static const uint32_t KernariumOverlayGiB = 4;

enum {
    KernariumFrameOpen = 'O',
    KernariumFrameData = 'D',
    KernariumFrameResize = 'R',
    KernariumFrameKill = 'K',
    KernariumFrameExit = 'X',
};

static NSError *KernariumError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:KernariumErrorDomain code:code
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

static NSData *KernariumFrame(uint8_t type, const void *payload, uint32_t length) {
    NSMutableData *frame = [NSMutableData dataWithCapacity:5 + length];
    uint8_t header[5] = {
        type,
        (uint8_t)(length >> 24), (uint8_t)(length >> 16),
        (uint8_t)(length >> 8), (uint8_t)length,
    };
    [frame appendBytes:header length:sizeof header];
    if (length > 0) [frame appendBytes:payload length:length];
    return frame;
}

static void KernariumPutSize(uint8_t *out, int columns, int rows) {
    uint16_t c = (uint16_t)MAX(1, MIN(columns, 0xffff));
    uint16_t r = (uint16_t)MAX(1, MIN(rows, 0xffff));
    out[0] = (uint8_t)(c >> 8); out[1] = (uint8_t)c;
    out[2] = (uint8_t)(r >> 8); out[3] = (uint8_t)r;
}

#pragma mark - KernariumTerminal

@interface KernariumTerminal ()
- (instancetype)initWithSessionId:(NSString *)sessionId
                       descriptor:(int)descriptor
                      exitHandler:(void (^)(KernariumTerminal *terminal, int status))exitHandler;
- (void)openWithCommand:(NSString *)command columns:(int)columns rows:(int)rows;
- (void)startReading;
- (void)hangUp;
- (void)close;
@end

@implementation KernariumTerminal {
    int _descriptor;
    dispatch_queue_t _readQueue;
    dispatch_queue_t _writeQueue;
    dispatch_source_t _readSource;
    NSMutableData *_inbound;        // _readQueue only
    BOOL _finished;                 // _readQueue only
    int _exitStatus;                // _readQueue only
    NSLock *_lock;                  // guards _outputHandler, _pending, _closed
    AcodeTerminalOutputHandler _outputHandler;
    NSMutableData *_pending;
    BOOL _closed;
    void (^_exitHandler)(KernariumTerminal *, int);
}

- (instancetype)initWithSessionId:(NSString *)sessionId
                       descriptor:(int)descriptor
                      exitHandler:(void (^)(KernariumTerminal *, int))exitHandler {
    if ((self = [super init])) {
        _sessionId = [sessionId copy];
        _descriptor = descriptor;
        _exitHandler = [exitHandler copy];
        _readQueue = dispatch_queue_create("acode.kernarium.session.read", DISPATCH_QUEUE_SERIAL);
        _writeQueue = dispatch_queue_create("acode.kernarium.session.write", DISPATCH_QUEUE_SERIAL);
        _inbound = [NSMutableData data];
        _pending = [NSMutableData data];
        _lock = [NSLock new];
        _exitStatus = 255;
        int flags = fcntl(descriptor, F_GETFL);
        if (flags >= 0) (void)fcntl(descriptor, F_SETFL, flags | O_NONBLOCK);
        int on = 1;
        (void)setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof on);
    }
    return self;
}

- (void)dealloc {
    [self close];
}

#pragma mark Output

- (AcodeTerminalOutputHandler)outputHandler {
    [_lock lock];
    AcodeTerminalOutputHandler handler = _outputHandler;
    [_lock unlock];
    return handler;
}

- (void)setOutputHandler:(AcodeTerminalOutputHandler)outputHandler {
    [_lock lock];
    _outputHandler = [outputHandler copy];
    [_lock unlock];
    if (!outputHandler) return;
    // Output is only ever delivered on the read queue, so the backlog drains
    // there too and cannot be overtaken by newer bytes.
    dispatch_async(_readQueue, ^{
        [self deliverOnReadQueue:nil];
    });
}

- (void)deliverOnReadQueue:(NSData *)data {
    [_lock lock];
    AcodeTerminalOutputHandler handler = _outputHandler;
    if (!handler) {
        if (data.length > 0) {
            [_pending appendData:data];
            if (_pending.length > KernariumMaxPendingOutput) {
                NSUInteger overflow = _pending.length - KernariumMaxPendingOutput;
                [_pending replaceBytesInRange:NSMakeRange(0, overflow) withBytes:NULL length:0];
            }
        }
        [_lock unlock];
        return;
    }
    NSData *backlog = nil;
    if (_pending.length > 0) {
        backlog = _pending;
        _pending = [NSMutableData data];
    }
    [_lock unlock];
    if (backlog) handler(backlog);
    if (data.length > 0) handler(data);
}

#pragma mark Input

- (void)writeFrame:(NSData *)frame {
    dispatch_async(_writeQueue, ^{
        [self->_lock lock];
        BOOL closed = self->_closed;
        int descriptor = self->_descriptor;
        [self->_lock unlock];
        if (closed) return;
        const uint8_t *cursor = frame.bytes;
        size_t remaining = frame.length;
        while (remaining > 0) {
            ssize_t written = write(descriptor, cursor, remaining);
            if (written > 0) {
                cursor += written;
                remaining -= (size_t)written;
                continue;
            }
            if (written < 0 && errno == EINTR) continue;
            if (written < 0 && errno == EAGAIN) {
                // The guest applies vsock flow control; wait for credit.
                struct pollfd target = { .fd = descriptor, .events = POLLOUT };
                if (poll(&target, 1, 1000) >= 0) continue;
            }
            NSLog(@"[Kernarium] session %@ write failed: %s", self.sessionId, strerror(errno));
            return;
        }
    });
}

- (void)openWithCommand:(NSString *)command columns:(int)columns rows:(int)rows {
    NSData *text = [command dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
    NSMutableData *payload = [NSMutableData dataWithLength:4];
    KernariumPutSize(payload.mutableBytes, columns, rows);
    [payload appendData:text];
    [self writeFrame:KernariumFrame(KernariumFrameOpen, payload.bytes, (uint32_t)payload.length)];
}

- (void)sendInput:(NSData *)input {
    const uint8_t *bytes = input.bytes;
    NSUInteger offset = 0;
    while (offset < input.length) {
        uint32_t chunk = (uint32_t)MIN(input.length - offset, (NSUInteger)KernariumMaxFramePayload);
        [self writeFrame:KernariumFrame(KernariumFrameData, bytes + offset, chunk)];
        offset += chunk;
    }
}

- (void)resizeToColumns:(int)columns rows:(int)rows {
    uint8_t size[4];
    KernariumPutSize(size, columns, rows);
    [self writeFrame:KernariumFrame(KernariumFrameResize, size, sizeof size)];
}

- (void)hangUp {
    [self writeFrame:KernariumFrame(KernariumFrameKill, NULL, 0)];
}

#pragma mark Reading

- (void)startReading {
    dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)_descriptor, 0, _readQueue);
    __weak KernariumTerminal *weakSelf = self;
    int descriptor = _descriptor;
    dispatch_queue_t writeQueue = _writeQueue;
    dispatch_source_set_event_handler(source, ^{
        [weakSelf readAvailable];
    });
    // Close on the write queue so a write already in progress finishes first
    // and no later write can reach a reused descriptor number.
    dispatch_source_set_cancel_handler(source, ^{
        dispatch_async(writeQueue, ^{ close(descriptor); });
    });
    [_lock lock];
    BOOL closed = _closed;
    if (!closed) _readSource = source;
    [_lock unlock];
    dispatch_resume(source);
    if (closed) dispatch_source_cancel(source);
}

/// Detaches the read source and marks the session closed. Returns the source
/// to cancel, or nil when there is none (or it was already taken).
- (dispatch_source_t)takeReadSourceClosing:(BOOL *)wasClosed {
    [_lock lock];
    if (wasClosed) *wasClosed = _closed;
    _closed = YES;
    dispatch_source_t source = _readSource;
    _readSource = nil;
    [_lock unlock];
    return source;
}

- (void)readAvailable {
    if (_finished) return;
    uint8_t buffer[16384];
    for (;;) {
        ssize_t got = read(_descriptor, buffer, sizeof buffer);
        if (got > 0) {
            [_inbound appendBytes:buffer length:(NSUInteger)got];
            if (![self parseInbound]) return;
            continue;
        }
        if (got < 0 && errno == EINTR) continue;
        if (got < 0 && errno == EAGAIN) return;
        // End of stream or an error: the guest ended the session, or stopped.
        [self finish];
        return;
    }
}

/// Returns NO once the session has finished.
- (BOOL)parseInbound {
    while (_inbound.length >= 5) {
        const uint8_t *bytes = _inbound.bytes;
        uint32_t length = (uint32_t)bytes[1] << 24 | (uint32_t)bytes[2] << 16 |
            (uint32_t)bytes[3] << 8 | bytes[4];
        if (length > KernariumMaxFramePayload) {
            NSLog(@"[Kernarium] session %@: oversized frame from the guest", self.sessionId);
            [self finish];
            return NO;
        }
        if (_inbound.length < 5 + (NSUInteger)length) break;
        uint8_t type = bytes[0];
        NSData *payload = [_inbound subdataWithRange:NSMakeRange(5, length)];
        [_inbound replaceBytesInRange:NSMakeRange(0, 5 + length) withBytes:NULL length:0];
        if (type == KernariumFrameData) {
            [self deliverOnReadQueue:payload];
        } else if (type == KernariumFrameExit && payload.length >= 4) {
            const uint8_t *code = payload.bytes;
            _exitStatus = (int32_t)((uint32_t)code[0] << 24 | (uint32_t)code[1] << 16 |
                (uint32_t)code[2] << 8 | code[3]);
            [self finish];
            return NO;
        }
    }
    return YES;
}

- (void)finish {
    if (_finished) return;
    _finished = YES;
    [self deliverOnReadQueue:nil];
    dispatch_source_t source = [self takeReadSourceClosing:NULL];
    if (source) dispatch_source_cancel(source);
    void (^handler)(KernariumTerminal *, int) = _exitHandler;
    _exitHandler = nil;
    if (handler) handler(self, _exitStatus);
}

/// Ends the stream from the host side. Safe from any thread, including
/// dealloc. An exit the read queue reports afterwards is ignored by the
/// bridge, which has already forgotten the session.
- (void)close {
    BOOL wasClosed = NO;
    dispatch_source_t source = [self takeReadSourceClosing:&wasClosed];
    if (source) {
        // The cancel handler closes the descriptor.
        dispatch_source_cancel(source);
    } else if (!wasClosed) {
        // Reading never started, so nothing else owns the descriptor.
        close(_descriptor);
    }
}

@end

#pragma mark - KernariumBridge

typedef NS_ENUM(NSInteger, KernariumGuestState) {
    KernariumGuestIdle,
    KernariumGuestBooting,
    KernariumGuestRunning,
    KernariumGuestEnded,
};

@interface KernariumBridge ()
- (void)appendConsoleOutput:(const void *)buffer length:(size_t)length;
@end

#if ACODE_HAS_KERNARIUM
// The guest kernel calibrates with a process-directed SIGALRM that only its
// vCPU0 thread may take, so every other thread must keep it blocked. Blocking
// it before main makes every later thread inherit the mask (Kernarium's own
// loader does the same). Applied only when Kernarium is the chosen runtime, so
// an iSH build behaves exactly as before.
__attribute__((constructor)) static void AcodeKernariumIsolateGuestTimer(void) {
    @autoreleasepool {
        NSString *runtime = [NSUserDefaults.standardUserDefaults stringForKey:@"AcodeTerminalRuntime"];
        if (runtime.length == 0) {
            id value = [NSBundle.mainBundle objectForInfoDictionaryKey:@"AcodeTerminalRuntime"];
            if ([value isKindOfClass:[NSString class]]) runtime = value;
        }
        if (![runtime.lowercaseString isEqualToString:@"kernarium"]) return;
    }
    sigset_t blocked;
    sigemptyset(&blocked);
    sigaddset(&blocked, SIGALRM);
    if (pthread_sigmask(SIG_BLOCK, &blocked, NULL) != 0) {
        static const char message[] = "Acode: cannot block SIGALRM for the Kernarium guest\n";
        (void)write(STDERR_FILENO, message, sizeof message - 1);
    }
}

static void KernariumConsoleOutput(void *context, const void *buffer, size_t length) {
    [(__bridge KernariumBridge *)context appendConsoleOutput:buffer length:length];
}

static void KernariumRestart(void *context, uint32_t event, uint32_t restartCount) {
    (void)context;
    NSLog(@"[Kernarium] guest restart event %u (restart %u)", event, restartCount);
}

/// The embedded Linux runtime framework: KRuntime_<version>_4K.framework,
/// never the Android one.
static NSURL *KernariumFrameworkURL(void) {
    NSURL *frameworks = NSBundle.mainBundle.privateFrameworksURL;
    if (!frameworks) return nil;
    NSArray<NSURL *> *contents = [NSFileManager.defaultManager contentsOfDirectoryAtURL:frameworks
                                                             includingPropertiesForKeys:nil
                                                                                options:0
                                                                                  error:nil];
    for (NSURL *url in contents) {
        NSString *name = url.lastPathComponent;
        if ([name hasPrefix:@"KRuntime_"] && ![name hasPrefix:@"KRuntime_Android_"] &&
            [name hasSuffix:@"_4K.framework"]) {
            return url;
        }
    }
    return nil;
}

static const kernarium_runtime_api *KernariumLoadAPI(NSString **failure) {
    static const kernarium_runtime_api *api;
    static NSString *loadFailure;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURL *framework = KernariumFrameworkURL();
        NSString *executable = framework ? [NSBundle bundleWithURL:framework].executablePath : nil;
        if (!executable) {
            loadFailure = @"No Kernarium Linux runtime framework is embedded";
            return;
        }
        void *handle = dlopen(executable.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL);
        if (!handle) {
            const char *error = dlerror();
            loadFailure = [NSString stringWithFormat:@"Cannot load %@: %s",
                           framework.lastPathComponent, error ?: "unknown error"];
            return;
        }
        typedef const kernarium_runtime_api *(*Getter)(void);
        Getter getter = (Getter)dlsym(handle, "kernarium_runtime_get_api_v28");
        const kernarium_runtime_api *candidate = getter ? getter() : NULL;
        if (!candidate) {
            loadFailure = @"The runtime framework has no API table";
            return;
        }
        if (candidate->abi_version != KERNARIUM_RUNTIME_API_VERSION ||
            candidate->struct_size < sizeof(kernarium_runtime_api)) {
            loadFailure = [NSString stringWithFormat:
                           @"Runtime API %u does not match the %u Acode was built against",
                           candidate->abi_version, KERNARIUM_RUNTIME_API_VERSION];
            return;
        }
        if (candidate->guest_flavor != KERNARIUM_RUNTIME_GUEST_LINUX) {
            loadFailure = @"The embedded runtime is not a Linux runtime";
            return;
        }
        api = candidate;
        NSLog(@"[Kernarium] loaded %@ (API %u)", framework.lastPathComponent, candidate->abi_version);
    });
    if (failure) *failure = loadFailure;
    return api;
}
#endif

@implementation KernariumBridge {
    dispatch_queue_t _stateQueue;  // guards everything below
    NSMutableDictionary<NSString *, KernariumTerminal *> *_sessions;
    AcodeTerminalEventHandler _eventHandler;
    KernariumGuestState _state;
    NSString *_endReason;
    MTKView *_view;
    BOOL _quiesced;
    dispatch_queue_t _lifecycleQueue;
    NSLock *_consoleLock;
    NSMutableData *_console;
}

+ (instancetype)shared {
    static KernariumBridge *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shared = [[KernariumBridge alloc] initPrivate];
    });
    return shared;
}

+ (BOOL)isRuntimeAvailable {
#if ACODE_HAS_KERNARIUM
    return KernariumFrameworkURL() != nil;
#else
    return NO;
#endif
}

- (instancetype)initPrivate {
    if ((self = [super init])) {
        _stateQueue = dispatch_queue_create("acode.kernarium.state", DISPATCH_QUEUE_SERIAL);
        _lifecycleQueue = dispatch_queue_create("acode.kernarium.lifecycle", DISPATCH_QUEUE_SERIAL);
        _sessions = [NSMutableDictionary dictionary];
        _consoleLock = [NSLock new];
        _console = [NSMutableData data];
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        [center addObserver:self selector:@selector(applicationDidEnterBackground:)
                       name:UIApplicationDidEnterBackgroundNotification object:nil];
        [center addObserver:self selector:@selector(applicationWillEnterForeground:)
                       name:UIApplicationWillEnterForegroundNotification object:nil];
    }
    return self;
}

#pragma mark Console

- (void)appendConsoleOutput:(const void *)buffer length:(size_t)length {
    if (length == 0) return;
    [_consoleLock lock];
    [_console appendBytes:buffer length:length];
    if (_console.length > KernariumConsoleTailBytes) {
        NSUInteger overflow = _console.length - KernariumConsoleTailBytes;
        [_console replaceBytesInRange:NSMakeRange(0, overflow) withBytes:NULL length:0];
    }
    [_consoleLock unlock];
    NSString *text = [[NSString alloc] initWithBytes:buffer length:length encoding:NSUTF8StringEncoding];
    if (text.length > 0) NSLog(@"[Kernarium guest] %@", text);
}

- (NSString *)recentConsoleOutput {
    [_consoleLock lock];
    NSData *copy = [_console copy];
    [_consoleLock unlock];
    return [[NSString alloc] initWithData:copy encoding:NSUTF8StringEncoding]
        ?: [[NSString alloc] initWithData:copy encoding:NSISOLatin1StringEncoding] ?: @"";
}

#pragma mark Boot

#if ACODE_HAS_KERNARIUM
static uint32_t KernariumSetting(NSString *key, uint32_t fallback) {
    NSInteger value = [NSUserDefaults.standardUserDefaults integerForKey:key];
    return value > 0 ? (uint32_t)value : fallback;
}

/// The read-only root image: a user-supplied Documents/kernarium/rootfs.ext4
/// wins; otherwise the bundled image, copied into Documents once per change
/// because Kernarium requires a .ext4 root whose permissions deny writes.
- (NSString *)prepareRootfs:(NSError **)error {
    NSFileManager *files = NSFileManager.defaultManager;
    NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *directory = [documents stringByAppendingPathComponent:@"kernarium"];
    if (![files createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:error]) return nil;

    NSString *custom = [directory stringByAppendingPathComponent:@"rootfs.ext4"];
    NSString *target = custom;
    if (![files fileExistsAtPath:custom]) {
        NSString *bundled = [NSBundle.mainBundle pathForResource:@"acode-kernarium-rootfs" ofType:@"ext4"
                                                     inDirectory:@"kernarium"];
        if (!bundled) {
            if (error) *error = KernariumError(2, @"No Kernarium guest image is bundled or in Documents/kernarium/rootfs.ext4");
            return nil;
        }
        target = [directory stringByAppendingPathComponent:@"acode-kernarium-rootfs.ext4"];
        NSDictionary *source = [files attributesOfItemAtPath:bundled error:nil];
        NSDictionary *current = [files attributesOfItemAtPath:target error:nil];
        BOOL stale = current == nil ||
            ![current[NSFileSize] isEqual:source[NSFileSize]] ||
            [source.fileModificationDate compare:current.fileModificationDate] == NSOrderedDescending;
        if (stale) {
            NSString *staging = [target stringByAppendingString:@".staging"];
            [files removeItemAtPath:staging error:nil];
            if (![files copyItemAtPath:bundled toPath:staging error:error]) return nil;
            [files removeItemAtPath:target error:nil];
            if (![files moveItemAtPath:staging toPath:target error:error]) return nil;
            NSLog(@"[Kernarium] installed the bundled guest image");
        }
    }
    if (![files setAttributes:@{NSFilePosixPermissions: @0444} ofItemAtPath:target error:error]) return nil;
    return target;
}

/// A fresh sparse overlay disk; the guest's /init formats it every boot, so
/// nothing written outside the image survives an app relaunch.
- (NSString *)prepareOverlay:(NSError **)error {
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"acode-kernarium-overlay.ext4"];
    unlink(path.fileSystemRepresentation);
    int fd = open(path.fileSystemRepresentation, O_CREAT | O_WRONLY | O_TRUNC | O_CLOEXEC, 0600);
    if (fd < 0 || ftruncate(fd, (off_t)KernariumOverlayGiB << 30) != 0) {
        if (error) *error = KernariumError(3, [NSString stringWithFormat:@"Cannot create the overlay disk: %s", strerror(errno)]);
        if (fd >= 0) close(fd);
        return nil;
    }
    close(fd);
    return path;
}

- (void)runGuestWithView:(MTKView *)view {
    NSString *failure = nil;
    const kernarium_runtime_api *api = KernariumLoadAPI(&failure);
    if (!api) {
        [self guestEndedWithReason:failure];
        return;
    }
    NSError *error = nil;
    NSString *rootfs = [self prepareRootfs:&error];
    NSString *overlay = rootfs ? [self prepareOverlay:&error] : nil;
    if (!rootfs || !overlay) {
        [self guestEndedWithReason:error.localizedDescription ?: @"Cannot prepare the guest disks"];
        return;
    }

    api->set_console_output_callback(KernariumConsoleOutput, (__bridge void *)self);
    api->set_restart_callback(KernariumRestart, (__bridge void *)self);

    uint32_t hostProcessors = (uint32_t)MAX((NSUInteger)1, NSProcessInfo.processInfo.processorCount);
    uint32_t processors = MIN(KernariumSetting(@"AcodeKernariumProcessors", MIN(2u, hostProcessors)), hostProcessors);
    // The runtime accepts 512 to 4096 MiB in 64 MiB steps.
    uint32_t memory = KernariumSetting(@"AcodeKernariumMemoryMiB", 1024);
    memory = MAX(512u, MIN(4096u, memory - memory % 64u));

    kernarium_runtime_boot boot;
    memset(&boot, 0, sizeof boot);
    boot.struct_size = sizeof boot;
    // The guest has a framebuffer console nobody sees; keep it small.
    boot.width = 640;
    boot.height = 480;
    boot.dots_per_inch = 160;
    boot.guest_memory_mib = memory;
    boot.guest_processor_count = processors;
    boot.rootfs_path = rootfs.fileSystemRepresentation;
    boot.overlay_path = overlay.fileSystemRepresentation;

    NSLog(@"[Kernarium] booting %u MiB, %u vCPU, root %@", memory, processors, rootfs.lastPathComponent);
    int result = api->run(view, &boot);
    NSString *reason = result == 0
        ? @"The Linux guest powered off"
        : [NSString stringWithFormat:@"The Linux guest stopped (status %d)", result];
    [self guestEndedWithReason:reason];
}

- (const kernarium_runtime_api *)runningAPI {
    return KernariumLoadAPI(NULL);
}
#endif

/// Starts the guest once per process. Kernarium runs one guest per process
/// and cannot boot another after it ends, so an ended guest stays ended.
- (void)ensureBooted {
    dispatch_async(_stateQueue, ^{
        if (self->_state != KernariumGuestIdle) return;
        self->_state = KernariumGuestBooting;
#if ACODE_HAS_KERNARIUM
        dispatch_async(dispatch_get_main_queue(), ^{
            // run() requires a Metal view even for a guest without a desktop;
            // this one is never shown.
            id<MTLDevice> device = MTLCreateSystemDefaultDevice();
            MTKView *view = [[MTKView alloc] initWithFrame:CGRectMake(0, 0, 640, 480) device:device];
            self->_view = view;
            // The run occupies its thread for the guest's whole life.
            NSThread *launcher = [[NSThread alloc] initWithBlock:^{
                [self runGuestWithView:view];
            }];
            launcher.name = @"uml-launcher";
            [launcher start];
        });
#else
        [self guestEndedWithReason:@"Acode was built without the Kernarium runtime header"];
#endif
    });
}

- (void)guestEndedWithReason:(NSString *)reason {
    NSLog(@"[Kernarium] %@", reason);
    dispatch_async(_stateQueue, ^{
        self->_state = KernariumGuestEnded;
        self->_endReason = [reason copy];
        NSArray<KernariumTerminal *> *open = self->_sessions.allValues;
        [self->_sessions removeAllObjects];
        AcodeTerminalEventHandler handler = self->_eventHandler;
        for (KernariumTerminal *terminal in open) {
            [terminal close];
            if (!handler) continue;
            handler(terminal.sessionId, @"fatal", reason);
            // Executor stops a session's WebSocket on "exit"; 255 marks a
            // session the guest did not end itself.
            handler(terminal.sessionId, @"exit", @"255");
        }
    });
}

#pragma mark Sessions

static NSString *KernariumAgentCommand(NSString *command) {
    NSString *trimmed = [command stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    // The iSH bridge treats these as "an interactive shell"; so does the agent
    // when the command is empty.
    if (trimmed.length == 0 || [trimmed isEqualToString:@"sh"] ||
        [trimmed isEqualToString:@"/bin/sh"] || [trimmed isEqualToString:@"login"]) {
        return @"";
    }
    return command;
}

/// Connects to the guest agent, waiting while the guest boots. Returns a
/// descriptor or -1 with `error` set. Blocks; never call it on the main queue.
- (int)connectAgent:(NSError **)error {
#if ACODE_HAS_KERNARIUM
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:KernariumAgentDeadlineSeconds];
    for (;;) {
        __block KernariumGuestState state;
        __block NSString *endReason;
        dispatch_sync(_stateQueue, ^{
            state = self->_state;
            endReason = self->_endReason;
        });
        if (state == KernariumGuestEnded) {
            if (error) *error = KernariumError(4, endReason ?: @"The Linux guest is not running");
            return -1;
        }
        const kernarium_runtime_api *api = [self runningAPI];
        int result = api ? api->connect_vsock(AcodeKernariumAgentPort, 2000) : -ENODEV;
        if (result >= 0) {
            dispatch_async(_stateQueue, ^{
                if (self->_state == KernariumGuestBooting) self->_state = KernariumGuestRunning;
            });
            return result;
        }
        // No guest yet, no agent listening yet, or the guest is busy booting.
        BOOL transient = result == -ENODEV || result == -ECONNREFUSED ||
            result == -ETIMEDOUT || result == -ECONNRESET;
        if (!transient || deadline.timeIntervalSinceNow <= 0) {
            NSString *message = transient
                ? @"The Linux guest did not start its terminal service in time"
                : [NSString stringWithFormat:@"Cannot reach the guest terminal service: %s", strerror(-result)];
            if (error) *error = KernariumError(5, message);
            return -1;
        }
        usleep(250 * 1000);
    }
#else
    if (error) *error = KernariumError(1, @"Acode was built without the Kernarium runtime header");
    return -1;
#endif
}

- (void)startWithCommand:(NSString *)command
              completion:(void (^)(NSString *sessionId, NSError * _Nullable error))completion {
    [self ensureBooted];
    NSString *agentCommand = KernariumAgentCommand(command ?: @"");
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        int descriptor = [self connectAgent:&error];
        if (descriptor < 0) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(@"", error); });
            return;
        }
        NSString *sessionId = NSUUID.UUID.UUIDString;
        __weak KernariumBridge *weakSelf = self;
        KernariumTerminal *terminal = [[KernariumTerminal alloc] initWithSessionId:sessionId
            descriptor:descriptor
            exitHandler:^(KernariumTerminal *ended, int status) {
                [weakSelf sessionEnded:ended status:status];
            }];
        // Register before reading so an immediate exit finds the session.
        dispatch_sync(self->_stateQueue, ^{
            self->_sessions[sessionId] = terminal;
        });
        [terminal openWithCommand:agentCommand columns:80 rows:24];
        [terminal startReading];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(sessionId, nil); });
    });
}

- (void)sessionEnded:(KernariumTerminal *)terminal status:(int)status {
    dispatch_async(_stateQueue, ^{
        if (self->_sessions[terminal.sessionId] != terminal) return;
        [self->_sessions removeObjectForKey:terminal.sessionId];
        AcodeTerminalEventHandler handler = self->_eventHandler;
        if (handler) handler(terminal.sessionId, @"exit", [NSString stringWithFormat:@"%d", status]);
    });
}

- (KernariumTerminal *)terminalForSession:(NSString *)sessionId {
    __block KernariumTerminal *terminal;
    dispatch_sync(_stateQueue, ^{
        terminal = self->_sessions[sessionId];
    });
    return terminal;
}

- (void)writeToSession:(NSString *)sessionId
                 input:(NSString *)input
            completion:(void (^)(NSError * _Nullable))completion {
    KernariumTerminal *terminal = [self terminalForSession:sessionId];
    if (terminal) [terminal sendInput:[input dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data]];
    if (completion) {
        NSError *error = terminal ? nil : KernariumError(6, @"Terminal session not found");
        dispatch_async(dispatch_get_main_queue(), ^{ completion(error); });
    }
}

- (void)resizeSession:(NSString *)sessionId
              columns:(NSInteger)columns
                 rows:(NSInteger)rows
           completion:(void (^)(NSError * _Nullable))completion {
    KernariumTerminal *terminal = [self terminalForSession:sessionId];
    if (terminal) [terminal resizeToColumns:(int)columns rows:(int)rows];
    if (completion) {
        NSError *error = terminal ? nil : KernariumError(6, @"Terminal session not found");
        dispatch_async(dispatch_get_main_queue(), ^{ completion(error); });
    }
}

- (void)stopSession:(NSString *)sessionId completion:(void (^)(NSError * _Nullable))completion {
    __block KernariumTerminal *terminal;
    dispatch_sync(_stateQueue, ^{
        terminal = self->_sessions[sessionId];
        [self->_sessions removeObjectForKey:sessionId];
    });
    // Hang up the guest's process group, then drop the stream; the agent also
    // hangs up when the stream closes, so either alone ends the session.
    [terminal hangUp];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(200 * NSEC_PER_MSEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [terminal close];
    });
    if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(nil); });
}

- (void)setEventHandler:(AcodeTerminalEventHandler)handler {
    dispatch_async(_stateQueue, ^{
        self->_eventHandler = [handler copy];
    });
}

#pragma mark Lifecycle

// iOS takes the GPU away soon after the app is backgrounded, and a guest GPU
// request that reaches Metal afterwards breaks the device for good, so the
// requests are held before the guest is quiesced (Kernarium/README.md,
// "Lifecycle"). The guest then stays suspended until the app returns.
- (void)applicationDidEnterBackground:(NSNotification *)notification {
#if ACODE_HAS_KERNARIUM
    __block KernariumGuestState state;
    dispatch_sync(_stateQueue, ^{ state = self->_state; });
    if (state != KernariumGuestRunning && state != KernariumGuestBooting) return;
    const kernarium_runtime_api *api = [self runningAPI];
    if (!api) return;
    UIApplication *application = UIApplication.sharedApplication;
    __block UIBackgroundTaskIdentifier task = [application beginBackgroundTaskWithName:@"acode-kernarium-quiesce"
                                                                    expirationHandler:^{
        [application endBackgroundTask:task];
        task = UIBackgroundTaskInvalid;
    }];
    api->set_gpu_hold(1);
    dispatch_async(_lifecycleQueue, ^{
        int result = api->quiesce();
        self->_quiesced = YES;
        NSLog(@"[Kernarium] quiesced the guest (%d)", result);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (task != UIBackgroundTaskInvalid) [application endBackgroundTask:task];
            task = UIBackgroundTaskInvalid;
        });
    });
#endif
}

- (void)applicationWillEnterForeground:(NSNotification *)notification {
#if ACODE_HAS_KERNARIUM
    const kernarium_runtime_api *api = [self runningAPI];
    if (!api) return;
    dispatch_async(_lifecycleQueue, ^{
        if (self->_quiesced) {
            api->resume();
            self->_quiesced = NO;
            NSLog(@"[Kernarium] resumed the guest");
        }
        api->set_gpu_hold(0);
    });
#endif
}

@end
