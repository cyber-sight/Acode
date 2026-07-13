#import "IshBridge.h"
#import "AcodeIshTerminal.h"
#import "RootfsManager.h"
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
            @"PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
            @"PYTHONMALLOC=malloc",
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

    [self writeGuestFile:@"/etc/resolv.conf"
                 content:@"nameserver 1.1.1.1\nnameserver 8.8.8.8\n"];

    NSData *argv = IshStringVector(@[@"/sbin/init"]);
    NSData *envp = IshStringVector(@[
        @"TERM=xterm-256color",
        @"HOME=/root",
        @"PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
        @"PYTHONMALLOC=malloc",
    ]);
    result = do_execve("/sbin/init", 1, argv.bytes, envp.bytes);
    if (result < 0) {
        if (error) *error = IshError(33, [NSString stringWithFormat:@"Unable to execute /sbin/init (%d)", result]);
        return NO;
    }

    task_start(current);
    self.kernelStarted = YES;
    return YES;
}

- (void)writeGuestFile:(NSString *)path content:(NSString *)content {
    struct fd *fd = generic_open(path.fileSystemRepresentation, O_WRONLY_ | O_CREAT_ | O_TRUNC_, 0644);
    if (IS_ERR(fd)) {
        NSLog(@"iSH: unable to open guest file %@ (%ld)", path, (long)PTR_ERR(fd));
        return;
    }
    NSData *data = [content dataUsingEncoding:NSUTF8StringEncoding];
    fd->ops->write(fd, data.bytes, data.length);
    fd_close(fd);
}

- (BOOL)ensureRootfsReady:(NSError **)error {
    NSString *rootPath = AcodeIshActiveRootPath();
    if ([self validateRootAtPath:rootPath requireRelease:AcodeIshIsDefaultRootActive() error:nil]) {
        [self checkpointRootAtPath:rootPath];
        return YES;
    }

    if (!AcodeIshIsDefaultRootActive()) {
        if (error) *error = IshError(40, @"The selected root filesystem is invalid or is not an ARM64 iSH root");
        return NO;
    }

    NSString *bundleRoot = [NSBundle.mainBundle pathForResource:@"ish-rootfs" ofType:nil];
    if (!bundleRoot) bundleRoot = [NSBundle.mainBundle pathForResource:@"ish-rootfs" ofType:nil inDirectory:@"www"];
    if (![self validateRootAtPath:bundleRoot requireRelease:YES error:error]) return NO;

    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *parent = rootPath.stringByDeletingLastPathComponent;
    NSString *staging = [parent stringByAppendingPathComponent:[NSString stringWithFormat:@".ish-rootfs-staging-%@", NSUUID.UUID.UUIDString]];
    NSString *backup = [parent stringByAppendingPathComponent:[NSString stringWithFormat:@".ish-rootfs-backup-%@", NSUUID.UUID.UUIDString]];
    NSError *copyError = nil;
    [fm createDirectoryAtPath:parent withIntermediateDirectories:YES attributes:nil error:nil];
    if (![fm copyItemAtPath:bundleRoot toPath:staging error:&copyError]) {
        if (error) *error = IshError(41, [NSString stringWithFormat:@"Unable to stage bundled root: %@", copyError.localizedDescription]);
        return NO;
    }
    [self checkpointRootAtPath:staging];
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
    if (![fm fileExistsAtPath:dataPath isDirectory:&isDirectory] || !isDirectory ||
        ![fm fileExistsAtPath:metaPath] || !AcodeIshRootfsContainsPath(rootPath, @"/bin/sh") ||
        !AcodeIshRootfsIsArm64(rootPath)) {
        if (error) *error = IshError(45, @"Root filesystem must contain meta.db, data/, and /bin/sh");
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

- (void)checkpointRootAtPath:(NSString *)rootPath {
    NSString *metaPath = [rootPath stringByAppendingPathComponent:@"meta.db"];
    sqlite3 *database = NULL;
    if (sqlite3_open_v2(metaPath.fileSystemRepresentation, &database, SQLITE_OPEN_READWRITE, NULL) == SQLITE_OK) {
        sqlite3_wal_checkpoint_v2(database, NULL, SQLITE_CHECKPOINT_TRUNCATE, NULL, NULL);
    }
    if (database) sqlite3_close(database);
    NSFileManager *fm = NSFileManager.defaultManager;
    [fm removeItemAtPath:[metaPath stringByAppendingString:@"-shm"] error:nil];
    [fm removeItemAtPath:[metaPath stringByAppendingString:@"-wal"] error:nil];
}

- (BOOL)reconcileFs:(NSError **)error {
    NSString *rootPath = AcodeIshActiveRootPath();
    BOOL valid = [self validateRootAtPath:rootPath requireRelease:AcodeIshIsDefaultRootActive() error:error];
    if (valid && !self.kernelStarted) [self checkpointRootAtPath:rootPath];
    return valid;
}

@end
