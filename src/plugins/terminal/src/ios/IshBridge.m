#import "IshBridge.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <sqlite3.h>
#import <sys/stat.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <resolv.h>
#include <stdlib.h>
#include <string.h>
#import "IshRootfs.h"
#import "RootfsManager.h"

#if __has_include("ish/include/LinuxInterop.h")
#import "ish/include/LinuxInterop.h"
#import "ish/include/Terminal.h"
#define ISH_AVAILABLE 1
#elif __has_include("LinuxInterop.h")
#import "LinuxInterop.h"
#import "Terminal.h"
#define ISH_AVAILABLE 1
#else
#define ISH_AVAILABLE 0
#endif

@interface IshBridge ()
#if ISH_AVAILABLE
@property (nonatomic, strong) NSMapTable<NSString *, Terminal *> *sessions;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSString *> *sessionIdsByPid;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSNumber *> *pendingExitStatuses;
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
        sharedInstance.sessionIdsByPid = [NSMutableDictionary dictionary];
        sharedInstance.pendingExitStatuses = [NSMutableDictionary dictionary];
        [sharedInstance setupTerminalHookIfNeeded];
        linux_set_session_exit_handler(^(int pid, int status) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [[IshBridge shared] handleSessionExitForPid:pid status:status];
            });
        });
#endif
    });
    return sharedInstance;
}

- (void)setEventHandler:(IshEventHandler)handler {
    _eventHandler = [handler copy];
}

- (void)startWithCommand:(NSString *)command completion:(void (^)(NSString *sessionId, NSError * _Nullable error))completion {
#if !ISH_AVAILABLE
    if (completion) {
        NSError *error = [NSError errorWithDomain:@"IshBridge" code:1 userInfo:@{NSLocalizedDescriptionKey: @"iSH sources not available in build"}];
        completion(@"", error);
    }
    return;
#else
    if (![self startKernelIfNeeded]) {
        NSError *error = [NSError errorWithDomain:@"IshBridge" code:7 userInfo:@{NSLocalizedDescriptionKey: @"The iSH root filesystem could not be initialized"}];
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(@"", error);
        });
        return;
    }

    NSString *shell = @"/bin/sh";
    NSString *bootstrap = @"mkdir -p /home/acode /workspace; export HOME=/home/acode USER=acode LOGNAME=acode PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin; ";
    NSString *finalCommand = command.length > 0 ? [bootstrap stringByAppendingString:command] : @"";
    NSArray<NSString *> *argv = finalCommand.length > 0 ? @[shell, @"-lc", finalCommand] : @[shell];

    const char *exe = shell.UTF8String;
    const char *envp_storage[] = {
        "TERM=xterm-256color",
        "HOME=/home/acode",
        "USER=acode",
        "LOGNAME=acode",
        "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
        NULL,
    };
    const char **envp_arr = envp_storage;

    NSUInteger argc = argv.count;
    const char **argv_arr = calloc(argc + 1, sizeof(char *));
    for (NSUInteger i = 0; i < argc; i++) {
        argv_arr[i] = argv[i].UTF8String;
    }
    argv_arr[argc] = NULL;

    __block int err = 0;
    __block int processId = 0;
    __block Terminal *terminal = nil;

    sync_do_in_workqueue(^(void (^done)(void)) {
        linux_start_session(exe, argv_arr, envp_arr, ^(int retval, int pid, nsobj_t terminalObj) {
            err = retval;
            processId = pid;
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
    if (processId > 0) {
        NSNumber *processKey = @(processId);
        self.sessionIdsByPid[processKey] = sessionId;
        NSNumber *pendingStatus = self.pendingExitStatuses[processKey];
        if (pendingStatus) {
            [self.pendingExitStatuses removeObjectForKey:processKey];
            [self handleSessionExitForPid:processId status:pendingStatus.intValue];
        }
    }
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
	// Finder edits bypass fakefs' SQLite directory index. Reconcile before the
	// command is delivered so newly copied paths resolve in the live shell.
	if (![self reconcileFakefsMetadataAtRootPath:[self rootfsPath]]) {
		if (completion) {
			completion([NSError errorWithDomain:@"IshBridge" code:8 userInfo:@{NSLocalizedDescriptionKey: @"Unable to refresh externally copied rootfs files"}]);
		}
		return;
	}

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
    NSArray<NSNumber *> *processIds = [self.sessionIdsByPid allKeysForObject:sessionId];
    [self.sessionIdsByPid removeObjectsForKeys:processIds];
    if (completion) {
        completion(nil);
    }
#endif
}

#if ISH_AVAILABLE
- (void)handleSessionExitForPid:(int)pid status:(int)status {
    NSString *sessionId = self.sessionIdsByPid[@(pid)];
    if (!sessionId) {
        self.pendingExitStatuses[@(pid)] = @(status);
        return;
    }

    [self.sessionIdsByPid removeObjectForKey:@(pid)];
    [self.sessions removeObjectForKey:sessionId];

    IshEventHandler handler = self.eventHandler;
    if (handler) {
        int exitCode = (status & 0x7f) == 0 ? (status >> 8) : 128 + (status & 0x7f);
        handler(sessionId, @"exit", [NSString stringWithFormat:@"%d", exitCode]);
    }
}

- (BOOL)startKernelIfNeeded {
    if (self.kernelStarted) {
        return [self reconcileFakefsMetadataAtRootPath:[self rootfsPath]];
    }
    if (![self ensureRootfsReady]) {
        NSLog(@"iSH rootfs: initialization failed; kernel start skipped");
        return NO;
    }

    @try {
        actuate_kernel("");
        self.kernelStarted = YES;
        return YES;
    } @catch (NSException *exception) {
        NSLog(@"iSH rootfs: kernel start raised exception: %@", exception);
        return NO;
    }
}

- (BOOL)ensureRootfsReady {
    NSString *rootPath = [self rootfsPath];
    if (rootPath.length == 0) {
        NSLog(@"iSH rootfs: documents directory unavailable");
        return NO;
    }

    IshSetRootPath(rootPath.fileSystemRepresentation);

    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    NSString *rootMeta = [rootPath stringByAppendingPathComponent:@"meta.db"];
    NSString *rootData = [rootPath stringByAppendingPathComponent:@"data"];
    NSString *rootShell = [rootData stringByAppendingPathComponent:@"bin/sh"];
    BOOL dataIsDir = NO;
    if ([fm fileExistsAtPath:rootPath isDirectory:&isDir] &&
        isDir &&
        [fm fileExistsAtPath:rootMeta] &&
        [fm fileExistsAtPath:rootData isDirectory:&dataIsDir] &&
        dataIsDir &&
        [fm fileExistsAtPath:rootShell] &&
        [self stampRootfsMetadataAtPath:rootMeta]) {
        [self writeResolverConfigurationAtRootPath:rootPath];
        return [self reconcileFakefsMetadataAtRootPath:rootPath];
    }

    // Imported roots are immutable after their staged import succeeds. Only
    // bootstrap the bundled default root when it has not been initialized yet.
    if (!AcodeIshIsDefaultRootActive()) {
        NSLog(@"iSH rootfs: selected imported root is missing or invalid");
        return NO;
    }

    NSString *bundleRoot = [[NSBundle mainBundle] pathForResource:@"ish-rootfs" ofType:nil];
    if (!bundleRoot) {
        bundleRoot = [[NSBundle mainBundle] pathForResource:@"ish-rootfs" ofType:nil inDirectory:@"www"];
    }
    if (!bundleRoot) {
        NSLog(@"iSH rootfs: bundled ish-rootfs not found");
        return NO;
    }

    NSError *error = nil;
    if ([fm fileExistsAtPath:rootPath]) {
        NSError *removeError = nil;
        if (![fm removeItemAtPath:rootPath error:&removeError]) {
            NSLog(@"iSH rootfs: failed removing stale rootfs %@: %@", rootPath, removeError);
        }
    }
    [fm createDirectoryAtPath:rootPath withIntermediateDirectories:YES attributes:nil error:&error];
    if (error) {
        NSLog(@"iSH rootfs: failed creating rootfs directory %@: %@", rootPath, error);
        return NO;
    }

    NSDirectoryEnumerator *enumerator = [fm enumeratorAtPath:bundleRoot];
    for (NSString *relativePath in enumerator) {
        NSString *src = [bundleRoot stringByAppendingPathComponent:relativePath];
        NSString *dest = [rootPath stringByAppendingPathComponent:relativePath];
        BOOL isDirEntry = NO;
        [fm fileExistsAtPath:src isDirectory:&isDirEntry];
        if (isDirEntry) {
            NSError *dirError = nil;
            if (![fm createDirectoryAtPath:dest withIntermediateDirectories:YES attributes:nil error:&dirError]) {
                NSLog(@"iSH rootfs: failed creating copied directory %@: %@", dest, dirError);
                [fm removeItemAtPath:rootPath error:nil];
                return NO;
            }
        } else {
            NSError *copyError = nil;
            if (![fm copyItemAtPath:src toPath:dest error:&copyError]) {
                NSLog(@"iSH rootfs: failed copying %@ to %@: %@", src, dest, copyError);
                [fm removeItemAtPath:rootPath error:nil];
                return NO;
            }
        }
    }

    dataIsDir = NO;
    BOOL ready = [fm fileExistsAtPath:rootMeta] &&
                 [fm fileExistsAtPath:rootData isDirectory:&dataIsDir] &&
                 dataIsDir &&
                 [fm fileExistsAtPath:rootShell] &&
                 [self stampRootfsMetadataAtPath:rootMeta];
    if (ready) {
        [self writeResolverConfigurationAtRootPath:rootPath];
        ready = [self reconcileFakefsMetadataAtRootPath:rootPath];
    }
    if (!ready) {
        NSLog(@"iSH rootfs: copied rootfs validation failed");
    }
    return ready;
}

- (void)writeResolverConfigurationAtRootPath:(NSString *)rootPath {
    NSString *etcPath = [rootPath stringByAppendingPathComponent:@"data/etc"];
    NSError *dirError = nil;
    [[NSFileManager defaultManager] createDirectoryAtPath:etcPath withIntermediateDirectories:YES attributes:nil error:&dirError];
    if (dirError) {
        NSLog(@"iSH rootfs: failed creating resolver directory %@: %@", etcPath, dirError);
        return;
    }

    NSString *resolvConf = [self resolverConfiguration];
    NSString *resolvPath = [etcPath stringByAppendingPathComponent:@"resolv.conf"];
    NSError *writeError = nil;
    if (![resolvConf writeToFile:resolvPath atomically:YES encoding:NSUTF8StringEncoding error:&writeError]) {
        NSLog(@"iSH rootfs: failed writing resolver configuration %@: %@", resolvPath, writeError);
        return;
    }

    [self ensureFakefsPath:@"/etc/resolv.conf"
                   forFile:resolvPath
              withRootPath:rootPath
                      mode:(S_IFREG | 0644)];
}

- (NSString *)resolverConfiguration {
    NSMutableString *resolvConf = [NSMutableString string];
    struct __res_state res;
    memset(&res, 0, sizeof(res));

    if (res_ninit(&res) == EXIT_SUCCESS) {
        if (res.dnsrch[0] != NULL) {
            [resolvConf appendString:@"search"];
            for (int i = 0; res.dnsrch[i] != NULL; i++) {
                [resolvConf appendFormat:@" %s", res.dnsrch[i]];
            }
            [resolvConf appendString:@"\n"];
        }

        union res_sockaddr_union servers[MAXNS];
        int serversFound = res_getservers(&res, servers, MAXNS);
        char address[NI_MAXHOST];
        for (int i = 0; i < serversFound; i++) {
            union res_sockaddr_union server = servers[i];
            if (server.sin.sin_len == 0) {
                continue;
            }

            int result = getnameinfo((struct sockaddr *)&server.sin,
                                     server.sin.sin_len,
                                     address,
                                     sizeof(address),
                                     NULL,
                                     0,
                                     NI_NUMERICHOST);
            if (result == 0) {
                [resolvConf appendFormat:@"nameserver %s\n", address];
            }
        }

        res_nclose(&res);
    }

    if ([resolvConf rangeOfString:@"nameserver "].location == NSNotFound) {
        [resolvConf appendString:@"nameserver 1.1.1.1\n"];
        [resolvConf appendString:@"nameserver 8.8.8.8\n"];
    }

    return resolvConf;
}

- (void)ensureFakefsPath:(NSString *)fakePath
                 forFile:(NSString *)filePath
            withRootPath:(NSString *)rootPath
                    mode:(uint32_t)mode {
    NSString *metaPath = [rootPath stringByAppendingPathComponent:@"meta.db"];
    sqlite3 *db = NULL;
    if (sqlite3_open_v2(metaPath.fileSystemRepresentation, &db, SQLITE_OPEN_READWRITE, NULL) != SQLITE_OK) {
        NSLog(@"iSH rootfs: sqlite open failed while registering %@: %s", fakePath, db ? sqlite3_errmsg(db) : "unknown");
        if (db) sqlite3_close(db);
        return;
    }

    sqlite3_exec(db, "begin immediate", NULL, NULL, NULL);

    sqlite3_stmt *stmt = NULL;
    int64_t inode = 0;
    const char *pathBytes = fakePath.UTF8String;
    int pathLength = (int)strlen(pathBytes);

    if (sqlite3_prepare_v2(db, "select inode from paths where path = ?", -1, &stmt, NULL) == SQLITE_OK) {
        sqlite3_bind_blob(stmt, 1, pathBytes, pathLength, SQLITE_TRANSIENT);
        if (sqlite3_step(stmt) == SQLITE_ROW) {
            inode = sqlite3_column_int64(stmt, 0);
        }
    }
    sqlite3_finalize(stmt);
    stmt = NULL;

    struct {
        uint32_t mode;
        uint32_t uid;
        uint32_t gid;
        uint32_t rdev;
    } stat = { mode, 0, 0, 0 };

    if (inode > 0) {
        if (sqlite3_prepare_v2(db, "update stats set stat = ? where inode = ?", -1, &stmt, NULL) == SQLITE_OK) {
            sqlite3_bind_blob(stmt, 1, &stat, sizeof(stat), SQLITE_TRANSIENT);
            sqlite3_bind_int64(stmt, 2, inode);
            sqlite3_step(stmt);
        }
        sqlite3_finalize(stmt);
    } else {
        if (sqlite3_prepare_v2(db, "insert into stats (stat) values (?)", -1, &stmt, NULL) == SQLITE_OK) {
            sqlite3_bind_blob(stmt, 1, &stat, sizeof(stat), SQLITE_TRANSIENT);
            sqlite3_step(stmt);
            inode = sqlite3_last_insert_rowid(db);
        }
        sqlite3_finalize(stmt);
        stmt = NULL;

        if (inode > 0 &&
            sqlite3_prepare_v2(db, "insert or replace into paths (path, inode) values (?, ?)", -1, &stmt, NULL) == SQLITE_OK) {
            sqlite3_bind_blob(stmt, 1, pathBytes, pathLength, SQLITE_TRANSIENT);
            sqlite3_bind_int64(stmt, 2, inode);
            sqlite3_step(stmt);
        }
        sqlite3_finalize(stmt);
    }

    sqlite3_exec(db, "commit", NULL, NULL, NULL);
    sqlite3_close(db);
    NSLog(@"iSH rootfs: registered fakefs path %@ -> %@", fakePath, filePath);
}

- (BOOL)reconcileFakefsMetadataAtRootPath:(NSString *)rootPath {
    NSString *metaPath = [rootPath stringByAppendingPathComponent:@"meta.db"];
    NSString *dataPath = [rootPath stringByAppendingPathComponent:@"data"];
    sqlite3 *db = NULL;
    if (sqlite3_open_v2(metaPath.fileSystemRepresentation, &db, SQLITE_OPEN_READWRITE, NULL) != SQLITE_OK) {
        NSLog(@"iSH rootfs: sqlite open failed while reconciling metadata: %s", db ? sqlite3_errmsg(db) : "unknown");
        if (db) sqlite3_close(db);
        return NO;
    }

    sqlite3_stmt *findPath = NULL;
    sqlite3_stmt *insertStat = NULL;
    sqlite3_stmt *insertPath = NULL;
    sqlite3_stmt *storedPaths = NULL;
    sqlite3_stmt *deletePath = NULL;
    BOOL success = sqlite3_exec(db, "begin immediate", NULL, NULL, NULL) == SQLITE_OK;
    if (success) {
        success = sqlite3_prepare_v2(db, "select 1 from paths where path = ? limit 1", -1, &findPath, NULL) == SQLITE_OK &&
                  sqlite3_prepare_v2(db, "insert into stats (stat) values (?)", -1, &insertStat, NULL) == SQLITE_OK &&
                  sqlite3_prepare_v2(db, "insert into paths (path, inode) values (?, ?)", -1, &insertPath, NULL) == SQLITE_OK &&
                  sqlite3_prepare_v2(db, "select path from paths", -1, &storedPaths, NULL) == SQLITE_OK &&
                  sqlite3_prepare_v2(db, "delete from paths where path = ?", -1, &deletePath, NULL) == SQLITE_OK;
    }

    NSUInteger registeredPaths = 0;
    NSUInteger removedPaths = 0;
    if (success) {
        NSFileManager *fm = [NSFileManager defaultManager];
        // fakefs uses meta.db as the directory index. Remove records that no
        // longer have a backing path before registering newly copied files.
        while (sqlite3_step(storedPaths) == SQLITE_ROW) {
            const void *pathBytes = sqlite3_column_blob(storedPaths, 0);
            int pathLength = sqlite3_column_bytes(storedPaths, 0);
            NSString *fakePath = [[NSString alloc] initWithBytes:pathBytes length:pathLength encoding:NSUTF8StringEncoding];
            if (!fakePath) {
                success = NO;
                break;
            }
            NSString *relativePath = [fakePath hasPrefix:@"/"] ? [fakePath substringFromIndex:1] : fakePath;
            NSString *hostPath = relativePath.length ? [dataPath stringByAppendingPathComponent:relativePath] : dataPath;
            struct stat fileStat;
            if (lstat(hostPath.fileSystemRepresentation, &fileStat) == 0) {
                continue;
            }
            if (errno != ENOENT && errno != ENOTDIR) {
                success = NO;
                break;
            }
            sqlite3_bind_blob(deletePath, 1, pathBytes, pathLength, SQLITE_TRANSIENT);
            if (sqlite3_step(deletePath) != SQLITE_DONE) {
                success = NO;
                break;
            }
            sqlite3_reset(deletePath);
            sqlite3_clear_bindings(deletePath);
            removedPaths++;
        }
        if (sqlite3_errcode(db) != SQLITE_OK && sqlite3_errcode(db) != SQLITE_DONE) {
            success = NO;
        }

        NSDirectoryEnumerator<NSString *> *enumerator = [fm enumeratorAtPath:dataPath];
        for (NSString *relativePath in enumerator) {
            if (!success) break;
            NSString *hostPath = [dataPath stringByAppendingPathComponent:relativePath];
            struct stat fileStat;
            if (lstat(hostPath.fileSystemRepresentation, &fileStat) != 0) {
                continue;
            }

            NSString *fakePath = [@"/" stringByAppendingString:relativePath];
            const char *pathBytes = fakePath.UTF8String;
            sqlite3_bind_blob(findPath, 1, pathBytes, (int)strlen(pathBytes), SQLITE_TRANSIENT);
            int findResult = sqlite3_step(findPath);
            sqlite3_reset(findPath);
            sqlite3_clear_bindings(findPath);
            if (findResult == SQLITE_ROW) {
                continue;
            }
            if (findResult != SQLITE_DONE) {
                success = NO;
                break;
            }

            struct {
                uint32_t mode;
                uint32_t uid;
                uint32_t gid;
                uint32_t rdev;
            } statRecord = { (uint32_t)fileStat.st_mode, 0, 0, (uint32_t)fileStat.st_rdev };
            sqlite3_bind_blob(insertStat, 1, &statRecord, sizeof(statRecord), SQLITE_TRANSIENT);
            if (sqlite3_step(insertStat) != SQLITE_DONE) {
                success = NO;
                break;
            }
            sqlite3_reset(insertStat);
            sqlite3_clear_bindings(insertStat);

            sqlite3_bind_blob(insertPath, 1, pathBytes, (int)strlen(pathBytes), SQLITE_TRANSIENT);
            sqlite3_bind_int64(insertPath, 2, sqlite3_last_insert_rowid(db));
            if (sqlite3_step(insertPath) != SQLITE_DONE) {
                success = NO;
                break;
            }
            sqlite3_reset(insertPath);
            sqlite3_clear_bindings(insertPath);
            registeredPaths++;
        }
    }

    sqlite3_finalize(findPath);
    sqlite3_finalize(insertStat);
    sqlite3_finalize(insertPath);
    sqlite3_finalize(storedPaths);
    sqlite3_finalize(deletePath);
    if (success) {
        success = sqlite3_exec(db, "delete from stats where not exists (select 1 from paths where inode = stats.inode)", NULL, NULL, NULL) == SQLITE_OK;
    }
    sqlite3_exec(db, success ? "commit" : "rollback", NULL, NULL, NULL);
    sqlite3_close(db);

    if (!success) {
        NSLog(@"iSH rootfs: metadata reconciliation failed");
        return NO;
    }
    if (registeredPaths > 0) {
        NSLog(@"iSH rootfs: registered %lu externally copied path(s)", (unsigned long)registeredPaths);
    }
    if (removedPaths > 0) {
        NSLog(@"iSH rootfs: removed %lu stale metadata path(s)", (unsigned long)removedPaths);
    }
    return YES;
}

- (BOOL)stampRootfsMetadataAtPath:(NSString *)metaPath {
    struct stat metaStat;
    if (stat(metaPath.fileSystemRepresentation, &metaStat) != 0) {
        NSLog(@"iSH rootfs: stat failed for meta.db at %@", metaPath);
        return NO;
    }

    sqlite3 *db = NULL;
    if (sqlite3_open_v2(metaPath.fileSystemRepresentation, &db, SQLITE_OPEN_READWRITE, NULL) != SQLITE_OK) {
        NSLog(@"iSH rootfs: sqlite open failed for meta.db at %@: %s", metaPath, db ? sqlite3_errmsg(db) : "unknown");
        if (db) {
            sqlite3_close(db);
        }
        return NO;
    }

    sqlite3_stmt *stmt = NULL;
    int rc = sqlite3_prepare_v2(db, "update meta set db_inode = ?", -1, &stmt, NULL);
    if (rc == SQLITE_OK) {
        sqlite3_bind_int64(stmt, 1, (sqlite3_int64)metaStat.st_ino);
        rc = sqlite3_step(stmt);
    }

    sqlite3_finalize(stmt);
    sqlite3_close(db);
    NSLog(@"iSH rootfs: stamped meta.db inode=%llu rc=%d", (unsigned long long)metaStat.st_ino, rc);
    return rc == SQLITE_DONE;
}

- (NSString *)rootfsPath {
    return AcodeIshActiveRootPath();
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
        NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (!output) {
            output = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding] ?: @"";
        }
        handler(sessionId, @"stdout", output);
    }
    return result;
}
#endif

@end
