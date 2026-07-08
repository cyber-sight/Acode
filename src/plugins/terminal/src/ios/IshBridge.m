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
    [self startKernelIfNeeded];

    NSString *shell = @"/bin/sh";
    NSString *finalCommand = command.length > 0 ? command : @"";
    NSArray<NSString *> *argv = finalCommand.length > 0 ? @[shell, @"-lc", finalCommand] : @[shell];

    const char *exe = shell.UTF8String;
    const char *envp_storage[] = { "TERM=xterm-256color", NULL };
    const char **envp_arr = envp_storage;

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
    if (![self ensureRootfsReady]) {
        NSLog(@"iSH rootfs: ensureRootfsReady returned NO; kernel start skipped");
        return;
    }

    @try {
        NSLog(@"iSH rootfs: starting kernel");
        actuate_kernel("");
        self.kernelStarted = YES;
    } @catch (NSException *exception) {
        NSLog(@"iSH rootfs: kernel start raised exception: %@", exception);
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
    NSString *docsPath = [rootPath stringByDeletingLastPathComponent];
    NSLog(@"iSH rootfs: documents path=%@", docsPath);
    [self logDirectoryContentsAtPath:docsPath label:@"Documents" maxDepth:2];

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
        NSLog(@"iSH rootfs: existing rootfs validated at %@", rootPath);
        [self logDirectoryContentsAtPath:rootPath label:@"Documents/ish-rootfs existing" maxDepth:2];
        return YES;
    }

    NSLog(@"iSH rootfs: existing rootfs missing or invalid at %@", rootPath);
    [self logDirectoryContentsAtPath:rootPath label:@"Documents/ish-rootfs before copy" maxDepth:2];

    NSString *bundleRoot = [[NSBundle mainBundle] pathForResource:@"ish-rootfs" ofType:nil];
    if (!bundleRoot) {
        bundleRoot = [[NSBundle mainBundle] pathForResource:@"ish-rootfs" ofType:nil inDirectory:@"www"];
    }
    if (!bundleRoot) {
        NSLog(@"iSH rootfs: bundled ish-rootfs not found");
        return NO;
    }

    NSLog(@"iSH rootfs: copying bundled rootfs from %@", bundleRoot);
    [self logDirectoryContentsAtPath:bundleRoot label:@"Bundle/ish-rootfs" maxDepth:2];

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
    }
    NSLog(@"iSH rootfs: copied rootfs ready=%d", ready);
    [self logDirectoryContentsAtPath:rootPath label:@"Documents/ish-rootfs after copy" maxDepth:2];
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

- (void)logDirectoryContentsAtPath:(NSString *)path label:(NSString *)label maxDepth:(NSUInteger)maxDepth {
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:path isDirectory:&isDir]) {
        NSLog(@"iSH rootfs: %@ missing at %@", label, path);
        return;
    }
    if (!isDir) {
        NSDictionary<NSFileAttributeKey, id> *attrs = [fm attributesOfItemAtPath:path error:nil];
        NSLog(@"iSH rootfs: %@ file %@ size=%@ inode=%@", label, path, attrs[NSFileSize], attrs[NSFileSystemFileNumber]);
        return;
    }

    NSLog(@"iSH rootfs: listing %@ at %@", label, path);
    [self logDirectoryContentsAtPath:path basePath:path depth:0 maxDepth:maxDepth];
}

- (void)logDirectoryContentsAtPath:(NSString *)path basePath:(NSString *)basePath depth:(NSUInteger)depth maxDepth:(NSUInteger)maxDepth {
    if (depth > maxDepth) {
        return;
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *error = nil;
    NSArray<NSString *> *entries = [[fm contentsOfDirectoryAtPath:path error:&error] sortedArrayUsingSelector:@selector(compare:)];
    if (!entries) {
        NSLog(@"iSH rootfs: failed listing %@: %@", path, error);
        return;
    }

    for (NSString *entry in entries) {
        NSString *entryPath = [path stringByAppendingPathComponent:entry];
        NSString *relativePath = [entryPath substringFromIndex:basePath.length];
        if ([relativePath hasPrefix:@"/"]) {
            relativePath = [relativePath substringFromIndex:1];
        }

        BOOL isDir = NO;
        [fm fileExistsAtPath:entryPath isDirectory:&isDir];
        NSDictionary<NSFileAttributeKey, id> *attrs = [fm attributesOfItemAtPath:entryPath error:nil];
        NSLog(@"iSH rootfs:   %@%@ type=%@ size=%@ inode=%@",
              relativePath,
              isDir ? @"/" : @"",
              attrs[NSFileType],
              attrs[NSFileSize],
              attrs[NSFileSystemFileNumber]);

        if (isDir && depth < maxDepth) {
            [self logDirectoryContentsAtPath:entryPath basePath:basePath depth:depth + 1 maxDepth:maxDepth];
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
