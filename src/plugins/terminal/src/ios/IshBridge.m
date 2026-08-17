#import "IshBridge.h"
#import "AcodeIshTerminal.h"
#import "IshBackgroundRuntime.h"
#import "RootfsManager.h"
#include <arpa/inet.h>
#include <netdb.h>
#include <resolv.h>
#import <sqlite3.h>

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
    NSLog(@"iSH fatal error: %s", message ?: "unknown");
}

@interface IshBridge ()
@property (nonatomic) dispatch_queue_t kernelQueue;
@property (nonatomic) NSMutableDictionary<NSString *, AcodeIshTerminal *> *sessions;
@property (nonatomic) NSMutableDictionary<NSNumber *, NSString *> *sessionIdsByPid;
@property (nonatomic) NSMutableDictionary<NSNumber *, NSNumber *> *pendingExitStatuses;
@property (nonatomic, copy) IshEventHandler eventHandler;
@property (nonatomic) BOOL kernelStarted;
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
        _sessions = [NSMutableDictionary dictionary];
        _sessionIdsByPid = [NSMutableDictionary dictionary];
        _pendingExitStatuses = [NSMutableDictionary dictionary];
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
        self.sessions[sessionId] = terminal;
        self.sessionIdsByPid[@(pid)] = sessionId;
        [[IshBackgroundRuntime shared] sessionDidStart:sessionId];

        __weak IshBridge *weakSelf = self;
        terminal.outputHandler = ^(NSData *data) {
            NSString *output = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding] ?: @"";
            IshBridge *strongSelf = weakSelf;
            if (!strongSelf) return;
            dispatch_async(strongSelf.kernelQueue, ^{
                if (!strongSelf.sessions[sessionId]) return;
                dispatch_async(dispatch_get_main_queue(), ^{
                    IshEventHandler handler = strongSelf.eventHandler;
                    if (handler) handler(sessionId, @"stdout", output);
                });
            });
        };

        task_start(current);
        NSNumber *pendingStatus = self.pendingExitStatuses[@(pid)];
        if (pendingStatus) {
            [self.pendingExitStatuses removeObjectForKey:@(pid)];
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
        AcodeIshTerminal *terminal = self.sessions[sessionId];
        NSError *error = nil;
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
        AcodeIshTerminal *terminal = self.sessions[sessionId];
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
        } else {
            [terminal destroy];
            [self.sessions removeObjectForKey:sessionId];
            NSArray<NSNumber *> *pids = [self.sessionIdsByPid allKeysForObject:sessionId];
            [self.sessionIdsByPid removeObjectsForKeys:pids];
            [[IshBackgroundRuntime shared] sessionDidEnd:sessionId];
        }
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(error); });
    });
}

- (void)handleSessionExitForPid:(int)pid status:(int)status {
    dispatch_async(self.kernelQueue, ^{
        NSString *sessionId = self.sessionIdsByPid[@(pid)];
        if (!sessionId) {
            self.pendingExitStatuses[@(pid)] = @(status);
            return;
        }

        [self.sessionIdsByPid removeObjectForKey:@(pid)];
        AcodeIshTerminal *terminal = self.sessions[sessionId];
        terminal.outputHandler = nil;
        [self.sessions removeObjectForKey:sessionId];
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
    if (![self ensureRootfsReady:error]) return NO;

    NSString *dataPath = [AcodeIshActiveRootPath() stringByAppendingPathComponent:@"data"];
    int result = mount_root(&fakefs, dataPath.fileSystemRepresentation);
    if (result < 0) {
        if (error) *error = IshError(30, [NSString stringWithFormat:@"Unable to mount root filesystem (%d)", result]);
        return NO;
    }

    result = become_first_process();
    if (result < 0) {
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
        if (error) *error = IshError(32, [NSString stringWithFormat:@"Unable to create init stdio (%d)", result]);
        return NO;
    }

    NSError *dnsError = nil;
    if (![self configureGuestDns:&dnsError]) {
        NSLog(@"iSH: %@", dnsError.localizedDescription);
    }

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

- (AcodeIshTerminal *)terminalForSession:(NSString *)sessionId {
    // Access is safe without dispatching because:
    // - sessions is only mutated during startWithCommand (kernel queue)
    //   and stopSession (kernel queue)
    // - The completion callback fires after the session is stored
    // - We're reading during the active session lifecycle
    // - AcodeIshTerminal is immutable for I/O purposes after creation
    if (sessionId.length == 0) return nil;
    __block AcodeIshTerminal *terminal = nil;
    dispatch_sync(self.kernelQueue, ^{
        terminal = self.sessions[sessionId];
    });
    return terminal;
}

@end
