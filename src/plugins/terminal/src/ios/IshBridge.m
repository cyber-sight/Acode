#import "IshBridge.h"
#import "AcodeIshTerminal.h"
#import "IshBackgroundRuntime.h"
#import "RootfsManager.h"
#include <arpa/inet.h>
#include <netdb.h>
#include <resolv.h>
#import <sqlite3.h>
#import <Network/Network.h>

#define ISH_INTERNAL 1
#include "fs/dev.h"
#include "fs/devices.h"
#include "fs/fd.h"
#include "fs/path.h"
#include "fs/tty.h"
#include "debug.h"
#include "kernel/calls.h"
#include "kernel/fs.h"
#include "kernel/init.h"
#include "kernel/task.h"

static NSString *const IshBridgeErrorDomain = @"IshBridge";

/** Exit statuses that arrive before their session is registered are kept
 * briefly so a natural exit racing a spawn is still reported, then dropped. */
static const NSTimeInterval IshPendingExitMaxAge = 10.0;
static const NSUInteger IshPendingExitCapacity = 64;

static NSError *IshError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:IshBridgeErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

static NSData *IshStringVector(NSArray<NSString *> *strings) {
    NSMutableData *data = [NSMutableData data];
    for (NSString *string in strings) {
        NSData *encoded = [string dataUsingEncoding:NSUTF8StringEncoding];
        if (encoded.length) [data appendData:encoded];
        uint8_t zero = 0;
        [data appendBytes:&zero length:1];
    }
    uint8_t finalZero = 0;
    [data appendBytes:&finalZero length:1];
    return data;
}

static void AcodeIshHandleFatalError(const char *message) {
    // Runs on an arbitrary guest/emulator thread with kernel state corrupt.
    // Touch nothing here but logging and an async hop to a safe queue.
    NSString *reason = (message && message[0])
        ? ([NSString stringWithUTF8String:message] ?: @"unknown")
        : @"unknown";
    NSLog(@"iSH fatal error: %@", reason);
    dispatch_async(dispatch_get_main_queue(), ^{
        [[IshBridge shared] notifyFatalEmulatorErrorWithReason:reason];
    });
}

@interface IshBridge ()
@property (nonatomic) dispatch_queue_t kernelQueue;
/** Guards only the sessions dictionary, which Executor reads cross-thread
 * from spawn/reconnect completions on the main thread. All other session
 * bookkeeping stays kernel-queue-confined. */
@property (nonatomic, strong) NSLock *sessionsLock;
@property (nonatomic) NSMutableDictionary<NSString *, AcodeIshTerminal *> *sessions;
@property (nonatomic) NSMutableDictionary<NSNumber *, NSString *> *sessionIdsByPid;
/** pid -> @[status, timestamp]. Kernel queue only. */
@property (nonatomic) NSMutableDictionary<NSNumber *, NSArray<NSNumber *> *> *pendingExitStatuses;
/** Session ids with an explicit stop in flight, including the pending
 * SIGKILL fallback. Kernel queue only; prevents a natural exit racing the
 * teardown sequence into double-signalling or double-cleanup. */
@property (nonatomic) NSMutableSet<NSString *> *terminatingSessionIds;
@property (nonatomic, copy) IshEventHandler eventHandler;
@property (nonatomic) BOOL kernelStarted;
/** Latched once a kernel boot mutates state and then fails; see
 * startKernelIfNeeded. */
@property (nonatomic) BOOL bootFailed;
/** Watches iOS network-path changes so guest /etc/resolv.conf can track the
 * current DNS servers instead of staying frozen at boot-time values.
 * Raw C handle; retained once and never released (bridge is a singleton). */
@property (nonatomic, assign, nullable) nw_path_monitor_t dnsPathMonitor;
/** Coalesces rapid path-change bursts into one rewrite. Kernel queue only. */
@property (nonatomic, strong, nullable) dispatch_source_t dnsRefreshTimer;
- (BOOL)installBundledDefaultRootfs:(NSError **)error;
- (BOOL)installGuestCli:(NSError **)error;
@end

@implementation IshBridge

+ (instancetype)shared {
    static IshBridge *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[IshBridge alloc] initPrivate];
    });
    return instance;
}

- (instancetype)initPrivate {
    self = [super init];
    if (self) {
        _kernelQueue = dispatch_queue_create("com.foxdebug.acode.ish-kernel", DISPATCH_QUEUE_SERIAL);
        _sessionsLock = [NSLock new];
        _sessions = [NSMutableDictionary dictionary];
        _sessionIdsByPid = [NSMutableDictionary dictionary];
        _pendingExitStatuses = [NSMutableDictionary dictionary];
        _terminatingSessionIds = [NSMutableSet set];
    }
    return self;
}

- (instancetype)init {
    return [IshBridge shared];
}

- (void)setEventHandler:(IshEventHandler)handler {
    _eventHandler = [handler copy];
}

static void AcodeIshProcessExited(struct task *task, int status) {
    if (!task || task->pid <= 1) return;
    int pid = task->pid;
    dispatch_async(dispatch_get_main_queue(), ^{
        [[IshBridge shared] handleSessionExitForPid:pid status:status];
    });
}

/// Kernel queue only. Stores a status for a pid that has no session yet,
/// pruning stale entries and enforcing the capacity cap first.
- (void)recordPendingExitStatusForPid:(int)pid status:(int)status {
    double now = NSDate.timeIntervalSinceReferenceDate;
    NSMutableArray<NSNumber *> *expired = [NSMutableArray array];
    [self.pendingExitStatuses enumerateKeysAndObjectsUsingBlock:^(NSNumber *key, NSArray<NSNumber *> *entry, BOOL *stop) {
        if (now - entry[1].doubleValue > IshPendingExitMaxAge) [expired addObject:key];
    }];
    [self.pendingExitStatuses removeObjectsForKeys:expired];
    // Drop the oldest entries so an unreferenced-pid burst cannot grow the
    // dictionary without bound.
    while (self.pendingExitStatuses.count >= IshPendingExitCapacity) {
        __block NSNumber *oldestKey = nil;
        __block double oldestTimestamp = DBL_MAX;
        [self.pendingExitStatuses enumerateKeysAndObjectsUsingBlock:^(NSNumber *key, NSArray<NSNumber *> *entry, BOOL *stop) {
            double timestamp = entry[1].doubleValue;
            if (timestamp < oldestTimestamp) {
                oldestTimestamp = timestamp;
                oldestKey = key;
            }
        }];
        if (!oldestKey) break;
        [self.pendingExitStatuses removeObjectForKey:oldestKey];
    }
    self.pendingExitStatuses[@(pid)] = @[@(status), @(now)];
}

/// Kernel queue only. Returns and removes the recorded status for pid, or nil
/// when none was stored or the entry has outlived its freshness window.
- (nullable NSNumber *)takePendingExitStatusForPid:(int)pid {
    NSArray<NSNumber *> *entry = self.pendingExitStatuses[@(pid)];
    if (!entry) return nil;
    [self.pendingExitStatuses removeObjectForKey:@(pid)];
    if (NSDate.timeIntervalSinceReferenceDate - entry[1].doubleValue > IshPendingExitMaxAge) return nil;
    return entry[0];
}

- (void)startWithCommand:(NSString *)command
              completion:(void (^)(NSString *sessionId, NSError * _Nullable error))completion {
    dispatch_async(self.kernelQueue, ^{
        NSError *bootError = nil;
        if (![self startKernelIfNeeded:&bootError]) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(@"", bootError); });
            return;
        }

        NSString *trimmed = [command stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        BOOL interactive = trimmed.length == 0 || [trimmed isEqualToString:@"sh"] || [trimmed isEqualToString:@"/bin/sh"];
        NSArray<NSString *> *arguments;
        if (interactive) {
            arguments = @[@"/bin/sh", @"-i"];
        } else {
            NSString *bootstrap = @"mkdir -p /home/acode /workspace; cd /home/acode; export HOME=/home/acode USER=acode LOGNAME=acode PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin; ";
            arguments = @[@"/bin/sh", @"-lc", [bootstrap stringByAppendingString:command ?: @""]];
        }

        int errorCode = become_new_init_child();
        if (errorCode < 0) {
            NSError *error = IshError(20, [NSString stringWithFormat:@"Unable to create guest process (%d)", errorCode]);
            dispatch_async(dispatch_get_main_queue(), ^{ completion(@"", error); });
            return;
        }

        struct tty *tty = NULL;
        AcodeIshTerminal *terminal = [AcodeIshTerminal createPseudoTerminal:&tty];
        if (!terminal) {
            int ttyError = tty ? (int)PTR_ERR(tty) : -1;
            NSError *error = IshError(21, [NSString stringWithFormat:@"Unable to create pseudo-terminal (%d)", ttyError]);
            dispatch_async(dispatch_get_main_queue(), ^{ completion(@"", error); });
            return;
        }

        NSString *stdioPath = [NSString stringWithFormat:@"/dev/pts/%d", tty->num];
        errorCode = create_stdio(stdioPath.fileSystemRepresentation, TTY_PSEUDO_SLAVE_MAJOR, tty->num);
        if (errorCode < 0) {
            [terminal destroy];
            NSError *error = IshError(22, [NSString stringWithFormat:@"Unable to attach guest stdio (%d)", errorCode]);
            dispatch_async(dispatch_get_main_queue(), ^{ completion(@"", error); });
            return;
        }

        lock(&ttys_lock);
        tty_release(tty);
        unlock(&ttys_lock);

        NSData *argv = IshStringVector(arguments);
        NSData *envp = IshStringVector(@[
            @"TERM=xterm-256color",
            @"HOME=/home/acode",
            @"USER=acode",
            @"LOGNAME=acode",
            @"PATH=/home/acode/.bun/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
        ]);
        errorCode = do_execve("/bin/sh", arguments.count, argv.bytes, envp.bytes);
        if (errorCode < 0) {
            [terminal destroy];
            NSError *error = IshError(23, [NSString stringWithFormat:@"Unable to execute guest shell (%d)", errorCode]);
            dispatch_async(dispatch_get_main_queue(), ^{ completion(@"", error); });
            return;
        }

        NSString *sessionId = terminal.uuid.UUIDString;
        int pid = current->pid;
        // Captured before task_start so an explicit stop can signal the guest
        // later; each session task is its own session leader (task_setsid), so
        // the pid doubles as the process group id.
        terminal.sessionLeaderPid = pid;
        [self.sessionsLock lock];
        self.sessions[sessionId] = terminal;
        [self.sessionsLock unlock];
        self.sessionIdsByPid[@(pid)] = sessionId;
        [[IshBackgroundRuntime shared] sessionDidStart:sessionId];

        // No output consumer is installed here on purpose. The terminal
        // buffers bytes until one attaches: streaming spawns attach a
        // WebSocket-backed handler right after this completion, and legacy
        // start()/exec() consumers attach theirs in Executor's completion.
        // Installing anything before task_start would either race the real
        // consumer or route early prompt output into a dead legacy path.

        task_start(current);
        NSNumber *pendingStatus = [self takePendingExitStatusForPid:pid];
        if (pendingStatus) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self handleSessionExitForPid:pid status:pendingStatus.intValue];
            });
        }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(sessionId, nil); });
    });
}

- (void)writeToSession:(NSString *)sessionId
                  input:(NSString *)input
             completion:(void (^)(NSError * _Nullable error))completion {
    dispatch_async(self.kernelQueue, ^{
        NSError *error = nil;
        [self.sessionsLock lock];
        AcodeIshTerminal *terminal = self.sessions[sessionId];
        [self.sessionsLock unlock];
        if (!terminal) {
            error = IshError(24, @"Session not found");
        } else {
            NSData *data = [input dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
            [terminal sendInput:data];
        }
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(error); });
    });
}

- (void)resizeSession:(NSString *)sessionId
               columns:(NSInteger)columns
                  rows:(NSInteger)rows
            completion:(void (^)(NSError * _Nullable error))completion {
    dispatch_async(self.kernelQueue, ^{
        NSError *error = nil;
        [self.sessionsLock lock];
        AcodeIshTerminal *terminal = self.sessions[sessionId];
        [self.sessionsLock unlock];
        if (!terminal) {
            error = IshError(25, @"Session not found");
        } else if (columns < 2 || columns > 1000 || rows < 1 || rows > 1000) {
            error = IshError(26, @"Invalid terminal dimensions");
        } else {
            [terminal resizeToColumns:(int)columns rows:(int)rows];
        }
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(error); });
    });
}

- (void)stopSession:(NSString *)sessionId
          completion:(void (^)(NSError * _Nullable error))completion {
    dispatch_async(self.kernelQueue, ^{
        AcodeIshTerminal *terminal = self.sessions[sessionId];
        NSError *error = nil;
        if (!terminal) {
            error = IshError(27, @"Session not found");
        } else if (![self.terminatingSessionIds containsObject:sessionId]) {
            [self.terminatingSessionIds addObject:sessionId];
            int leaderPid = terminal.sessionLeaderPid;

            // tty_hangup alone leaves the guest shell running as an invisible
            // task, so raise SIGHUP first, then tear the PTY down.
            [terminal terminateGuest];
            [terminal destroy];

            [self.sessionsLock lock];
            [self.sessions removeObjectForKey:sessionId];
            [self.sessionsLock unlock];
            NSArray<NSNumber *> *pids = [self.sessionIdsByPid allKeysForObject:sessionId];
            [self.sessionIdsByPid removeObjectsForKeys:pids];
            [[IshBackgroundRuntime shared] sessionDidEnd:sessionId];

            if (leaderPid > 1) {
                // SIGHUP may be blocked or ignored by a misbehaving guest.
                // Escalate to SIGKILL once; send_group_signal returns ESRCH
                // harmlessly when the group is already gone. Skipped when the
                // pid has since been recycled into a new live session.
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1500 * NSEC_PER_MSEC)),
                               self.kernelQueue, ^{
                    [self killSessionFallbackForLeaderPid:leaderPid sessionId:sessionId];
                });
            }
        }
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(error); });
    });
}

/// Runs on the kernel queue 1.5s after an explicit stop. Kills the stopped
/// session's process group if SIGHUP did not finish it. The terminating flag
/// is always cleared so a later session reusing the id starts clean.
- (void)killSessionFallbackForLeaderPid:(int)leaderPid sessionId:(NSString *)sessionId {
    [self.terminatingSessionIds removeObject:sessionId];
    // If a brand-new session has already been handed this recycled pid,
    // leave its tasks alone.
    NSString *currentSession = self.sessionIdsByPid[@(leaderPid)];
    if (currentSession && ![currentSession isEqualToString:sessionId]) return;
    send_group_signal((dword_t)leaderPid, SIGKILL_, SIGINFO_NIL);
}

- (void)handleSessionExitForPid:(int)pid status:(int)status {
    dispatch_async(self.kernelQueue, ^{
        NSString *sessionId = self.sessionIdsByPid[@(pid)];
        if (!sessionId) {
            [self recordPendingExitStatusForPid:pid status:status];
            return;
        }

        [self.sessionIdsByPid removeObjectForKey:@(pid)];
        // The guest died before/while an explicit stop was tearing it down;
        // clear the flag so the stop's kill fallback knows the id is free.
        [self.terminatingSessionIds removeObject:sessionId];
        [self.sessionsLock lock];
        AcodeIshTerminal *terminal = self.sessions[sessionId];
        terminal.outputHandler = nil;
        [self.sessions removeObjectForKey:sessionId];
        [self.sessionsLock unlock];
        [[IshBackgroundRuntime shared] sessionDidEnd:sessionId];

        int exitCode = (status & 0x7f) == 0 ? ((status >> 8) & 0xff) : 128 + (status & 0x7f);
        dispatch_async(dispatch_get_main_queue(), ^{
            IshEventHandler handler = self.eventHandler;
            if (handler) handler(sessionId, @"exit", [NSString stringWithFormat:@"%d", exitCode]);
        });
    });
}

- (BOOL)startKernelIfNeeded:(NSError **)error {
    if (self.kernelStarted) return YES;
    // Once a boot has mutated kernel state (mount, init task) and then failed,
    // retrying would re-run idempotent-unsafe calls on that state. Only an app
    // restart gives a clean iSH.
    if (self.bootFailed) {
        if (error) *error = IshError(39, @"iSH kernel boot failed previously; restart Acode to try again");
        return NO;
    }
    if (![self ensureRootfsReady:error]) return NO;

    NSString *dataPath = [AcodeIshActiveRootPath() stringByAppendingPathComponent:@"data"];
    int result = mount_root(&fakefs, dataPath.fileSystemRepresentation);
    if (result < 0) {
        self.bootFailed = YES;
        if (error) *error = IshError(30, [NSString stringWithFormat:@"Unable to mount root filesystem (%d)", result]);
        return NO;
    }

    result = become_first_process();
    if (result < 0) {
        self.bootFailed = YES;
        if (error) *error = IshError(31, [NSString stringWithFormat:@"Unable to create init process (%d)", result]);
        return NO;
    }

    AcodeIshInstallConsoleDriver();
    generic_mknodat(AT_PWD, "/dev/tty1", S_IFCHR | 0666, dev_make(TTY_CONSOLE_MAJOR, 1));
    generic_mknodat(AT_PWD, "/dev/tty", S_IFCHR | 0666, dev_make(TTY_ALTERNATE_MAJOR, DEV_TTY_MINOR));
    generic_mknodat(AT_PWD, "/dev/console", S_IFCHR | 0666, dev_make(TTY_ALTERNATE_MAJOR, DEV_CONSOLE_MINOR));
    generic_mknodat(AT_PWD, "/dev/ptmx", S_IFCHR | 0666, dev_make(TTY_ALTERNATE_MAJOR, DEV_PTMX_MINOR));
    generic_mknodat(AT_PWD, "/dev/null", S_IFCHR | 0666, dev_make(MEM_MAJOR, DEV_NULL_MINOR));
    generic_mknodat(AT_PWD, "/dev/zero", S_IFCHR | 0666, dev_make(MEM_MAJOR, DEV_ZERO_MINOR));
    generic_mknodat(AT_PWD, "/dev/full", S_IFCHR | 0666, dev_make(MEM_MAJOR, DEV_FULL_MINOR));
    generic_mknodat(AT_PWD, "/dev/random", S_IFCHR | 0666, dev_make(MEM_MAJOR, DEV_RANDOM_MINOR));
    generic_mknodat(AT_PWD, "/dev/urandom", S_IFCHR | 0666, dev_make(MEM_MAJOR, DEV_URANDOM_MINOR));
    generic_mkdirat(AT_PWD, "/dev/pts", 0755);
    generic_mkdirat(AT_PWD, "/home", 0755);
    generic_mkdirat(AT_PWD, "/home/acode", 0755);
    generic_mkdirat(AT_PWD, "/workspace", 0755);
    generic_setattrat(AT_PWD, "/", make_attr(mode, 0755), false);
    do_mount(&procfs, "proc", "/proc", "", 0);
    do_mount(&devptsfs, "devpts", "/dev/pts", "", 0);

    exit_hook = AcodeIshProcessExited;
    die_handler = AcodeIshHandleFatalError;
    set_console_device(TTY_CONSOLE_MAJOR, 1);
    result = create_stdio("/dev/console", TTY_CONSOLE_MAJOR, 1);
    if (result < 0) {
        self.bootFailed = YES;
        if (error) *error = IshError(32, [NSString stringWithFormat:@"Unable to create init stdio (%d)", result]);
        return NO;
    }

    NSError *dnsError = nil;
    if (![self configureGuestDns:&dnsError]) {
        NSLog(@"iSH: %@", dnsError.localizedDescription);
    }
    [self startDnsPathMonitor];

    NSError *cliError = nil;
    if (![self installGuestCli:&cliError]) {
        NSLog(@"iSH: %@", cliError.localizedDescription);
    }

    NSData *envp = IshStringVector(@[
        @"TERM=xterm-256color",
        @"HOME=/root",
        @"PATH=/home/acode/.bun/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
    ]);
    NSString *configuredInit = AcodeIshActiveRootInitPath();
    NSArray<NSString *> *initCandidates = [configuredInit isEqualToString:@"/bin/sh"]
        ? @[configuredInit]
        : @[configuredInit, @"/bin/sh"];
    NSString *startedInit = nil;
    NSMutableArray<NSString *> *failures = [NSMutableArray array];
    for (NSString *initPath in initCandidates) {
        NSData *argv = IshStringVector(@[initPath]);
        result = do_execve(initPath.fileSystemRepresentation, 1, argv.bytes, envp.bytes);
        if (result == 0) {
            startedInit = initPath;
            break;
        }
        [failures addObject:[NSString stringWithFormat:@"%@ (%d)", initPath, result]];
        NSLog(@"iSH: init %@ failed with %d%@", initPath, result,
              [initPath isEqualToString:@"/bin/sh"] ? @"" : @"; falling back to /bin/sh");
    }
    if (!startedInit) {
        self.bootFailed = YES;
        if (error) *error = IshError(33, [NSString stringWithFormat:@"Unable to execute a guest init: %@", [failures componentsJoinedByString:@", "]]);
        return NO;
    }
    NSLog(@"iSH: started %@ as init for root %@", startedInit, AcodeIshActiveRootPath());

    task_start(current);
    self.kernelStarted = YES;
    return YES;
}

- (BOOL)configureGuestDns:(NSError **)error {
    struct __res_state resolver = {0};
    if (res_ninit(&resolver) != 0) {
        if (error) *error = IshError(34, @"Unable to read the iOS DNS configuration");
        return NO;
    }

    NSMutableString *content = [NSMutableString string];
    if (resolver.dnsrch[0] != NULL) {
        [content appendString:@"search"];
        for (int index = 0; resolver.dnsrch[index] != NULL; index++) {
            [content appendFormat:@" %s", resolver.dnsrch[index]];
        }
        [content appendString:@"\n"];
    }

    union res_sockaddr_union servers[NI_MAXSERV];
    int serverCount = res_getservers(&resolver, servers, NI_MAXSERV);
    for (int index = 0; index < serverCount; index++) {
        union res_sockaddr_union server = servers[index];
        const struct sockaddr *address = (const struct sockaddr *)&server;
        socklen_t addressLength = address->sa_len;
        if (addressLength == 0) continue;

        char host[NI_MAXHOST];
        int result = getnameinfo(address, addressLength, host, sizeof(host), NULL, 0, NI_NUMERICHOST);
        if (result == 0) [content appendFormat:@"nameserver %s\n", host];
    }
    res_nclose(&resolver);

    // A resolver can temporarily report no servers while iOS changes network
    // paths. Keep the guest usable until its next launch in that edge case.
    if ([content rangeOfString:@"nameserver "].location == NSNotFound) {
        [content appendString:@"nameserver 1.1.1.1\nnameserver 8.8.8.8\n"];
    }

    BOOL wroteConfiguration = [self writeGuestFile:@"/etc/resolv.conf" content:content error:error];
    if (wroteConfiguration) NSLog(@"iSH: wrote %d iOS DNS server(s) to /etc/resolv.conf", serverCount);
    return wroteConfiguration;
}

/// Keeps the guest's view of DNS current. iOS hands out different resolver
/// addresses per network (Wi-Fi vs cellular, VPN split DNS); without this the
/// guest keeps boot-time servers until relaunch and lookups break after a
/// network switch.
- (void)startDnsPathMonitor {
    if (self.dnsPathMonitor) return;
    // Network.framework's Obj-C surface is the C API; NWPathMonitor is Swift.
    nw_path_monitor_t monitor = nw_path_monitor_create();
    self.dnsPathMonitor = monitor;
    nw_path_monitor_set_queue(monitor, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    nw_path_monitor_set_update_handler(monitor, ^(nw_path_t path) {
        (void)path;
        // Called on the monitor queue; all state below is kernelQueue-confined.
        dispatch_async(self.kernelQueue, ^{
            [self scheduleDnsRefresh];
        });
    });
    nw_path_monitor_start(monitor);
}

/// Arms a fresh one-shot 2s debounce on the kernel queue; any newer path
/// event replaces the pending one so a network flap rewrites resolv.conf
/// exactly once, after things settle.
- (void)scheduleDnsRefresh {
    if (!self.kernelStarted || self.bootFailed) return;
    if (self.dnsRefreshTimer) {
        dispatch_source_cancel(self.dnsRefreshTimer);
        self.dnsRefreshTimer = nil;
    }
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.kernelQueue);
    dispatch_source_set_timer(timer,
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), 0, 0);
    dispatch_source_set_event_handler(timer, ^{
        if (!self.kernelStarted || self.bootFailed) return;
        NSError *error = nil;
        if (![self configureGuestDns:&error]) {
            NSLog(@"iSH: DNS refresh failed: %@", error.localizedDescription);
        }
    });
    self.dnsRefreshTimer = timer;
    dispatch_resume(timer);
}

- (BOOL)writeGuestFile:(NSString *)path content:(NSString *)content error:(NSError **)error {
    struct fd *fd = generic_open(path.fileSystemRepresentation, O_WRONLY_ | O_CREAT_ | O_TRUNC_, 0644);
    if (IS_ERR(fd)) {
        if (error) {
            *error = IshError(35, [NSString stringWithFormat:@"Unable to open guest file %@ (%ld)", path, (long)PTR_ERR(fd)]);
        }
        return NO;
    }
    NSData *data = [content dataUsingEncoding:NSUTF8StringEncoding];
    ssize_t written = fd->ops->write(fd, data.bytes, data.length);
    fd_close(fd);
    if (written < 0 || (NSUInteger)written != data.length) {
        if (error) {
            *error = IshError(36, [NSString stringWithFormat:@"Unable to write guest file %@ (%ld of %lu bytes)",
                                   path, (long)written, (unsigned long)data.length]);
        }
        return NO;
    }
    return YES;
}

- (BOOL)installGuestCli:(NSError **)error {
    NSString *sourcePath = [NSBundle.mainBundle pathForResource:@"acode-cli" ofType:@"sh"];
    NSError *readError = nil;
    NSString *content = sourcePath
        ? [NSString stringWithContentsOfFile:sourcePath encoding:NSUTF8StringEncoding error:&readError]
        : nil;
    if (!content) {
        if (error) {
            *error = IshError(37, readError.localizedDescription ?: @"Bundled acode CLI was not found");
        }
        return NO;
    }
    generic_mkdirat(AT_PWD, "/usr/local", 0755);
    generic_mkdirat(AT_PWD, "/usr/local/bin", 0755);
    if (![self writeGuestFile:@"/usr/local/bin/acode" content:content error:error]) {
        return NO;
    }
    int result = generic_setattrat(AT_PWD, "/usr/local/bin/acode", make_attr(mode, 0755), false);
    if (result < 0) {
        if (error) {
            *error = IshError(38, [NSString stringWithFormat:@"Unable to make /usr/local/bin/acode executable (%d)", result]);
        }
        return NO;
    }
    return YES;
}

- (BOOL)ensureRootfsReady:(NSError **)error {
    NSString *rootPath = AcodeIshActiveRootPath();
    if ([self validateRootAtPath:rootPath requireRelease:AcodeIshIsDefaultRootActive() error:nil]) {
        return [self checkpointRootAtPath:rootPath error:error];
    }

    if (!AcodeIshIsDefaultRootActive()) {
        if (error) *error = IshError(40, @"The selected root filesystem is invalid or is not an ARM64 iSH root");
        return NO;
    }

    return [self installBundledDefaultRootfs:error];
}

- (BOOL)installBundledDefaultRootfs:(NSError **)error {
    NSString *rootPath = AcodeIshDefaultRootPath();
    NSString *bundleRoot = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"www/ish-rootfs"];

    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL bundleRootIsDirectory = NO;
    if (![fm fileExistsAtPath:bundleRoot isDirectory:&bundleRootIsDirectory] || !bundleRootIsDirectory) {
        if (error) *error = IshError(44, [NSString stringWithFormat:@"Bundled root filesystem was not found at %@", bundleRoot]);
        return NO;
    }

    NSString *parent = rootPath.stringByDeletingLastPathComponent;
    NSString *staging = [parent stringByAppendingPathComponent:[NSString stringWithFormat:@".ish-rootfs-staging-%@", NSUUID.UUID.UUIDString]];
    NSString *backup = [parent stringByAppendingPathComponent:[NSString stringWithFormat:@".ish-rootfs-backup-%@", NSUUID.UUID.UUIDString]];
    NSError *copyError = nil;
    [fm createDirectoryAtPath:parent withIntermediateDirectories:YES attributes:nil error:nil];
    if (![fm copyItemAtPath:bundleRoot toPath:staging error:&copyError]) {
        if (error) *error = IshError(41, [NSString stringWithFormat:@"Unable to stage bundled root: %@", copyError.localizedDescription]);
        return NO;
    }
    // App bundle resources are signed and read-only. Validate only after the
    // bundled root has been copied into its writable staging directory.
    if (![self checkpointRootAtPath:staging error:error]) {
        [fm removeItemAtPath:staging error:nil];
        return NO;
    }
    if (![self validateRootAtPath:staging requireRelease:YES error:error]) {
        [fm removeItemAtPath:staging error:nil];
        return NO;
    }

    BOOL hadRoot = [fm fileExistsAtPath:rootPath];
    if (hadRoot && ![fm moveItemAtPath:rootPath toPath:backup error:&copyError]) {
        [fm removeItemAtPath:staging error:nil];
        if (error) *error = IshError(42, [NSString stringWithFormat:@"Unable to replace invalid root: %@", copyError.localizedDescription]);
        return NO;
    }
    if (![fm moveItemAtPath:staging toPath:rootPath error:&copyError]) {
        if (hadRoot) [fm moveItemAtPath:backup toPath:rootPath error:nil];
        if (error) *error = IshError(43, [NSString stringWithFormat:@"Unable to install bundled root: %@", copyError.localizedDescription]);
        return NO;
    }
    if (hadRoot) [fm removeItemAtPath:backup error:nil];
    return YES;
}

- (void)restoreDefaultRootfsWithCompletion:(void (^)(NSError * _Nullable error))completion {
    dispatch_async(self.kernelQueue, ^{
        NSError *error = nil;
        if (self.kernelStarted) {
            error = IshError(48, @"Close and relaunch Acode before restoring the default root filesystem. The iSH kernel is already running.");
        } else if (![self installBundledDefaultRootfs:&error]) {
            if (!error) error = IshError(49, @"Unable to restore the bundled root filesystem");
        }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(error); });
    });
}

- (BOOL)validateRootAtPath:(NSString *)rootPath
            requireRelease:(BOOL)requireRelease
                     error:(NSError **)error {
    if (rootPath.length == 0) {
        if (error) *error = IshError(44, @"Root filesystem path is unavailable");
        return NO;
    }
    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL isDirectory = NO;
    NSString *dataPath = [rootPath stringByAppendingPathComponent:@"data"];
    NSString *metaPath = [rootPath stringByAppendingPathComponent:@"meta.db"];
    BOOL hasData = [fm fileExistsAtPath:dataPath isDirectory:&isDirectory] && isDirectory;
    BOOL hasMetadata = [fm fileExistsAtPath:metaPath];
    BOOL hasShell = hasData && hasMetadata && AcodeIshRootfsContainsPath(rootPath, @"/bin/sh");
    BOOL hasArm64Shell = hasShell && AcodeIshRootfsIsArm64(rootPath);
    NSLog(@"[rootfs] validating %@: data=%d metadata=%d shell=%d arm64=%d",
          rootPath, hasData, hasMetadata, hasShell, hasArm64Shell);
    if (!hasData || !hasMetadata || !hasShell || !hasArm64Shell) {
        NSString *reason;
        if (!hasData) reason = @"data/ is missing or is not a directory";
        else if (!hasMetadata) reason = @"meta.db is missing";
        else if (!hasShell) reason = @"/bin/sh is missing from the fakefs metadata";
        else reason = @"/bin/sh does not resolve to an executable ARM64 Linux ELF file";
        if (error) *error = IshError(45, [NSString stringWithFormat:@"Invalid root filesystem: %@.", reason]);
        return NO;
    }

    sqlite3 *database = NULL;
    BOOL databaseOK = sqlite3_open_v2(metaPath.fileSystemRepresentation, &database, SQLITE_OPEN_READONLY, NULL) == SQLITE_OK;
    sqlite3_stmt *statement = NULL;
    if (databaseOK) databaseOK = sqlite3_prepare_v2(database, "pragma integrity_check", -1, &statement, NULL) == SQLITE_OK;
    if (databaseOK) databaseOK = sqlite3_step(statement) == SQLITE_ROW && strcmp((const char *)sqlite3_column_text(statement, 0), "ok") == 0;
    sqlite3_finalize(statement);
    if (database) sqlite3_close(database);
    if (!databaseOK) {
        if (error) *error = IshError(46, @"Root filesystem metadata database failed its integrity check");
        return NO;
    }

    if (requireRelease) {
        NSString *releasePath = [dataPath stringByAppendingPathComponent:@"etc/acode-rootfs-release"];
        NSString *release = [NSString stringWithContentsOfFile:releasePath encoding:NSUTF8StringEncoding error:nil];
        if ([release rangeOfString:@"guest_arch=arm64"].location == NSNotFound) {
            if (error) *error = IshError(47, @"Bundled root filesystem is not marked as an ARM64 guest");
            return NO;
        }
    }
    return YES;
}

- (BOOL)checkpointRootAtPath:(NSString *)rootPath error:(NSError **)error {
    NSString *metaPath = [rootPath stringByAppendingPathComponent:@"meta.db"];
    sqlite3 *database = NULL;
    int result = sqlite3_open_v2(metaPath.fileSystemRepresentation, &database, SQLITE_OPEN_READWRITE, NULL);
    if (result == SQLITE_OK) {
        result = sqlite3_wal_checkpoint_v2(database, NULL, SQLITE_CHECKPOINT_TRUNCATE, NULL, NULL);
    }
    if (result == SQLITE_OK) {
        result = sqlite3_exec(database, "PRAGMA journal_mode=DELETE", NULL, NULL, NULL);
    }
    NSString *message = result == SQLITE_OK
        ? nil
        : [NSString stringWithFormat:@"Unable to checkpoint root filesystem metadata (%d: %s)",
                                      result, database ? sqlite3_errmsg(database) : "database unavailable"];
    if (database) sqlite3_close(database);

    if (result != SQLITE_OK) {
        NSLog(@"[rootfs] %@", message);
        if (error) *error = IshError(50, message);
        return NO;
    }

    NSFileManager *fm = NSFileManager.defaultManager;
    [fm removeItemAtPath:[metaPath stringByAppendingString:@"-shm"] error:nil];
    [fm removeItemAtPath:[metaPath stringByAppendingString:@"-wal"] error:nil];
    return YES;
}

- (BOOL)reconcileFs:(NSError **)error {
    NSString *rootPath = AcodeIshActiveRootPath();
    BOOL valid = [self validateRootAtPath:rootPath requireRelease:AcodeIshIsDefaultRootActive() error:error];
    if (valid && !self.kernelStarted) valid = [self checkpointRootAtPath:rootPath error:error];
    return valid;
}

- (void)notifyFatalEmulatorErrorWithReason:(NSString *)reason {
    // Main queue: snapshot session ids, surface one fatal event per live
    // session so the UI can show an error instead of a silently dead terminal.
    [self.sessionsLock lock];
    NSArray<NSString *> *liveSessions = self.sessions.allKeys;
    [self.sessionsLock unlock];

    for (NSString *sessionId in liveSessions) {
        IshEventHandler handler = self.eventHandler;
        if (handler) handler(sessionId, @"fatal", reason ?: @"iSH emulator fatal error");
        [[IshBackgroundRuntime shared] sessionDidEnd:sessionId];
    }

    dispatch_async(self.kernelQueue, ^{
        // The emulator's global state is corrupt; never re-boot in-process.
        self.bootFailed = YES;
        [self.sessionsLock lock];
        [self.sessions removeAllObjects];
        [self.sessionsLock unlock];
        [self.sessionIdsByPid removeAllObjects];
        [self.pendingExitStatuses removeAllObjects];
        [self.terminatingSessionIds removeAllObjects];
    });
}

- (AcodeIshTerminal *)terminalForSession:(NSString *)sessionId {
    // Called from Executor's main-thread completions. dispatch_sync onto
    // kernelQueue would freeze the UI for the whole duration of any in-flight
    // boot or teardown, so the sessions dictionary is guarded by a dedicated
    // lock instead (see sessionsLock).
    if (sessionId.length == 0) return nil;
    [self.sessionsLock lock];
    AcodeIshTerminal *terminal = self.sessions[sessionId];
    [self.sessionsLock unlock];
    return terminal;
}

@end
