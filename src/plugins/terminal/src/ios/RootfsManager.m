#import "RootfsManager.h"
#import <Cordova/CDVPluginResult.h>
#import "IshBridge.h"
#include "tools/fakefs.h"
#import <sqlite3.h>
#include <sys/stat.h>
#include <stdlib.h>
#include <string.h>

NSString *const AcodeIshDefaultRootId = @"default";
static NSString *const AcodeIshRootsKey = @"AcodeIshRoots";
static NSString *const AcodeIshActiveRootKey = @"AcodeIshActiveRoot";
static NSString *const AcodeIshDefaultInitKey = @"AcodeIshDefaultRootInit";
static NSString *const AcodeIshFallbackInitPath = @"/bin/sh";
static NSString *const AcodeIshPreferredInitPath = @"/sbin/init";

static NSString *DocumentsPath(void) {
    return NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject ?: @"";
}

static NSString *RootsPath(void) {
    return [DocumentsPath() stringByAppendingPathComponent:@"ish-roots"];
}

static NSString *RootPathForId(NSString *rootId) {
    if ([rootId isEqualToString:AcodeIshDefaultRootId])
        return [DocumentsPath() stringByAppendingPathComponent:@"ish-rootfs"];
    return [RootsPath() stringByAppendingPathComponent:rootId];
}

NSString *AcodeIshDefaultRootPath(void) {
    return RootPathForId(AcodeIshDefaultRootId);
}

NSString *AcodeIshActiveRootPath(void) {
    NSString *rootId = [NSUserDefaults.standardUserDefaults stringForKey:AcodeIshActiveRootKey];
    if (rootId.length == 0)
        rootId = AcodeIshDefaultRootId;
    return RootPathForId(rootId);
}

BOOL AcodeIshIsDefaultRootActive(void) {
    NSString *rootId = [NSUserDefaults.standardUserDefaults stringForKey:AcodeIshActiveRootKey];
    return rootId.length == 0 || [rootId isEqualToString:AcodeIshDefaultRootId];
}

static NSString *RootfsSanitizedInitPath(id value) {
    if (![value isKindOfClass:NSString.class]) return AcodeIshPreferredInitPath;
    NSString *path = [(NSString *)value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return path.length ? path : AcodeIshPreferredInitPath;
}

NSString *AcodeIshActiveRootInitPath(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSString *rootId = [defaults stringForKey:AcodeIshActiveRootKey];
    if (rootId.length == 0 || [rootId isEqualToString:AcodeIshDefaultRootId])
        return RootfsSanitizedInitPath([defaults stringForKey:AcodeIshDefaultInitKey]);

    NSArray *roots = [defaults objectForKey:AcodeIshRootsKey];
    if (![roots isKindOfClass:NSArray.class]) return AcodeIshPreferredInitPath;
    for (NSDictionary *root in roots) {
        if ([root isKindOfClass:NSDictionary.class] && [root[@"id"] isEqualToString:rootId])
            return RootfsSanitizedInitPath(root[@"init"]);
    }
    return AcodeIshPreferredInitPath;
}

static BOOL RootfsLookupPath(sqlite3 *db, NSString *fakePath, uint32_t *mode) {
    sqlite3_stmt *stmt = NULL;
    BOOL found = NO;
    const char *pathBytes = fakePath.UTF8String;
    int pathLength = (int)strlen(pathBytes);
    const char *sql = "SELECT s.stat FROM paths p JOIN stats s ON s.inode = p.inode "
                      "WHERE p.path = ?1 OR CAST(p.path AS BLOB) = ?1 LIMIT 1";
    if (sqlite3_prepare_v2(db, sql, -1, &stmt, NULL) == SQLITE_OK) {
        sqlite3_bind_blob(stmt, 1, pathBytes, pathLength, SQLITE_TRANSIENT);
        if (sqlite3_step(stmt) == SQLITE_ROW) {
            const void *statBytes = sqlite3_column_blob(stmt, 0);
            int statLength = sqlite3_column_bytes(stmt, 0);
            if (statLength >= (int)sizeof(uint32_t)) {
                if (mode) memcpy(mode, statBytes, sizeof(uint32_t));
                found = YES;
            }
        }
    }
    sqlite3_finalize(stmt);
    return found;
}

static NSString *RootfsNormalizedPath(NSString *path) {
    NSString *normalized = [path stringByStandardizingPath];
    return [normalized hasPrefix:@"/"] ? normalized : [@"/" stringByAppendingString:normalized];
}

static NSString *RootfsSymlinkTarget(NSString *rootPath, NSString *fakePath) {
    if (fakePath.length < 2) return nil;
    NSString *backingPath = [[rootPath stringByAppendingPathComponent:@"data"]
                             stringByAppendingPathComponent:[fakePath substringFromIndex:1]];
    NSData *targetData = [NSData dataWithContentsOfFile:backingPath];
    NSString *target = targetData ? [[NSString alloc] initWithData:targetData encoding:NSUTF8StringEncoding] : nil;
    return target.length ? target : nil;
}

/** Resolve both intermediate and final fakefs symlinks, such as
 * /bin -> usr/bin and /usr/bin/sh -> busybox. */
static BOOL RootfsResolvePath(sqlite3 *db,
                              NSString *rootPath,
                              NSString *fakePath,
                              NSString **resolvedPath,
                              uint32_t *resolvedMode) {
    NSString *candidate = RootfsNormalizedPath(fakePath);
    for (NSUInteger depth = 0; depth < 32; depth++) {
        NSArray<NSString *> *components = candidate.pathComponents;
        NSString *prefix = @"/";
        BOOL followedSymlink = NO;
        uint32_t mode = 0;

        for (NSUInteger index = 0; index < components.count; index++) {
            NSString *component = components[index];
            if ([component isEqualToString:@"/"] || component.length == 0) continue;
            prefix = [prefix stringByAppendingPathComponent:component];
            if (!RootfsLookupPath(db, prefix, &mode)) return NO;
            if (!S_ISLNK(mode)) continue;

            NSString *target = RootfsSymlinkTarget(rootPath, prefix);
            if (!target) return NO;
            NSString *next = [target hasPrefix:@"/"]
                ? target
                : [[prefix stringByDeletingLastPathComponent] stringByAppendingPathComponent:target];
            for (NSUInteger remainder = index + 1; remainder < components.count; remainder++) {
                next = [next stringByAppendingPathComponent:components[remainder]];
            }
            candidate = RootfsNormalizedPath(next);
            followedSymlink = YES;
            break;
        }

        if (followedSymlink) continue;
        if (resolvedPath) *resolvedPath = candidate;
        if (resolvedMode) *resolvedMode = mode;
        return YES;
    }
    return NO;
}

BOOL AcodeIshRootfsContainsPath(NSString *rootPath, NSString *fakePath) {
    NSString *metaPath = [rootPath stringByAppendingPathComponent:@"meta.db"];
    sqlite3 *db = NULL;
    if (sqlite3_open_v2(metaPath.fileSystemRepresentation, &db, SQLITE_OPEN_READONLY, NULL) != SQLITE_OK) {
        NSLog(@"[rootfs] unable to open metadata for %@: %s", fakePath, db ? sqlite3_errmsg(db) : "unknown");
        if (db) sqlite3_close(db);
        return NO;
    }

    NSString *candidate = nil;
    BOOL found = RootfsResolvePath(db, rootPath, fakePath, &candidate, NULL);

    if (found && ![candidate isEqualToString:fakePath])
        NSLog(@"[rootfs] resolved virtual path %@ -> %@", fakePath, candidate);
    sqlite3_close(db);
    return found;
}

BOOL AcodeIshRootfsExecutableIsArm64(NSString *rootPath, NSString *fakePath) {
    NSString *metaPath = [rootPath stringByAppendingPathComponent:@"meta.db"];
    sqlite3 *db = NULL;
    if (sqlite3_open_v2(metaPath.fileSystemRepresentation, &db, SQLITE_OPEN_READONLY, NULL) != SQLITE_OK) {
        if (db) sqlite3_close(db);
        return NO;
    }

    NSString *candidate = nil;
    uint32_t mode = 0;
    BOOL resolved = RootfsResolvePath(db, rootPath, RootfsNormalizedPath(fakePath), &candidate, &mode);
    sqlite3_close(db);

    if (!resolved || !S_ISREG(mode) || (mode & 0111) == 0 || candidate.length < 2) return NO;
    NSString *backingPath = [[rootPath stringByAppendingPathComponent:@"data"]
                             stringByAppendingPathComponent:[candidate substringFromIndex:1]];
    NSData *executable = [NSData dataWithContentsOfFile:backingPath options:NSDataReadingMappedIfSafe error:nil];
    if (executable.length < 20) return NO;
    const uint8_t *bytes = executable.bytes;
    if (bytes[0] != 0x7f || bytes[1] != 'E' || bytes[2] != 'L' || bytes[3] != 'F') return NO;
    uint16_t machine = (uint16_t)bytes[18] | ((uint16_t)bytes[19] << 8);
    return machine == 183; // EM_AARCH64
}

BOOL AcodeIshRootfsIsArm64(NSString *rootPath) {
    return AcodeIshRootfsExecutableIsArm64(rootPath, AcodeIshFallbackInitPath);
}

static NSDictionary *RootDictionary(NSString *rootId, NSString *name, BOOL isDefault, BOOL isActive, NSString *importedAt, NSString *initPath) {
    return @{
        @"id": rootId,
        @"name": name,
        @"isDefault": @(isDefault),
        @"isActive": @(isActive),
        @"path": RootPathForId(rootId),
        @"importedAt": importedAt ?: @"",
        @"init": RootfsSanitizedInitPath(initPath),
    };
}

static void rootfs_progress_callback(void *cookie, double progress, const char *message, bool *should_cancel) {
    (void)progress;
    (void)message;
    (void)should_cancel;
    // The Cordova command retains the UI callback until completion. Progress is
    // intentionally native-side only for now to avoid flooding the WebView.
    (void)cookie;
}

@interface RootfsManager ()
@end

@implementation RootfsManager

- (NSArray<NSDictionary *> *)storedRoots {
    id roots = [NSUserDefaults.standardUserDefaults objectForKey:AcodeIshRootsKey];
    return [roots isKindOfClass:NSArray.class] ? roots : @[];
}

- (void)saveRoots:(NSArray<NSDictionary *> *)roots {
    [NSUserDefaults.standardUserDefaults setObject:roots forKey:AcodeIshRootsKey];
}

- (NSDictionary *)rootWithId:(NSString *)rootId {
    for (NSDictionary *root in self.storedRoots) {
        if ([root[@"id"] isEqualToString:rootId])
            return root;
    }
    return nil;
}

- (NSString *)activeRootId {
    NSString *rootId = [NSUserDefaults.standardUserDefaults stringForKey:AcodeIshActiveRootKey];
    return rootId.length ? rootId : AcodeIshDefaultRootId;
}

- (BOOL)isValidName:(NSString *)name error:(NSError **)error {
    if (name.length == 0 || [name containsString:@"/"] || [name isEqualToString:@"."] || [name isEqualToString:@".."] || name.length > 80) {
        if (error) *error = [NSError errorWithDomain:@"RootfsManager" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Root filesystem names must be 1-80 characters and cannot contain /."}];
        return NO;
    }
    return YES;
}

- (BOOL)validateRootAtPath:(NSString *)path error:(NSError **)error {
    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL dataIsDirectory = NO;

    BOOL hasMetaDb = [fm fileExistsAtPath:[path stringByAppendingPathComponent:@"meta.db"]];
    BOOL hasDataDir = [fm fileExistsAtPath:[path stringByAppendingPathComponent:@"data"] isDirectory:&dataIsDirectory];
    BOOL dataIsDir = dataIsDirectory;
    BOOL hasBinSh = hasMetaDb && AcodeIshRootfsContainsPath(path, @"/bin/sh");
    BOOL isArm64 = hasBinSh && AcodeIshRootfsIsArm64(path);

    NSLog(@"[rootfs] validateRootAtPath: %@", path);
    NSLog(@"[rootfs]   meta.db exists:      %d", hasMetaDb);
    NSLog(@"[rootfs]   data exists + isDir: %d / %d", hasDataDir, dataIsDir);
    NSLog(@"[rootfs]   virtual /bin/sh exists: %d", hasBinSh);
    NSLog(@"[rootfs]   /bin/sh is arm64: %d", isArm64);

    if (!hasMetaDb || !hasDataDir || !dataIsDir || !hasBinSh || !isArm64) {
        // List what's actually in the data dir to help debug
        NSString *dataPath = [path stringByAppendingPathComponent:@"data"];
        NSArray *contents = [fm contentsOfDirectoryAtPath:dataPath error:nil];
        if (contents) {
            NSLog(@"[rootfs]   contents of data/: %@", contents);
            // Check for bin/sh at alternative paths
            BOOL alt1 = [fm fileExistsAtPath:[path stringByAppendingPathComponent:@"data/bin"]];
            BOOL alt2 = [fm fileExistsAtPath:[path stringByAppendingPathComponent:@"bin"]];
            BOOL alt3 = [fm fileExistsAtPath:[path stringByAppendingPathComponent:@"bin/sh"]];
            NSLog(@"[rootfs]   alt checks — data/bin: %d  bin/: %d  bin/sh: %d", alt1, alt2, alt3);
        } else {
            NSLog(@"[rootfs]   data/ directory does not exist or is empty");
            // List top-level contents of staging path instead
            NSArray *topContents = [fm contentsOfDirectoryAtPath:path error:nil];
            if (topContents) {
                NSLog(@"[rootfs]   contents of staging root: %@", topContents);
            }
        }

        if (error) {
            NSString *detail = @"missing components";
            if (!hasMetaDb) detail = @"meta.db not found";
            else if (!hasDataDir || !dataIsDir) detail = @"data/ directory not found";
            else if (!hasBinSh) detail = @"virtual /bin/sh not found in meta.db";
            else if (!isArm64) detail = @"/bin/sh is not an ARM64 Linux executable";
            *error = [NSError errorWithDomain:@"RootfsManager" code:2
                                     userInfo:@{NSLocalizedDescriptionKey:
                                                   [NSString stringWithFormat:@"The selected source is not a complete root filesystem (%@).", detail]}];
        }
        return NO;
    }
    return YES;
}

- (void)sendError:(NSError *)error command:(CDVInvokedUrlCommand *)command {
    [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:error.localizedDescription ?: @"Root filesystem operation failed."] callbackId:command.callbackId];
}

- (NSURL *)fileURLFromArgument:(NSString *)sourceString error:(NSError **)error {
    NSLog(@"[rootfs] fileURLFromArgument received: %@", sourceString);
    if (sourceString.length == 0) {
        if (error) *error = [NSError errorWithDomain:@"RootfsManager" code:3 userInfo:@{NSLocalizedDescriptionKey: @"Root filesystem imports require a local file or folder."}];
        return nil;
    }

    NSURL *url = [NSURL URLWithString:sourceString];
    if (url.isFileURL) {
        NSLog(@"[rootfs]   parsed as file URL, path=%@", url.path);
        return url;
    }

    if ([sourceString hasPrefix:@"file://"]) {
        NSString *path = [sourceString stringByRemovingPercentEncoding] ?: sourceString;
        path = [path stringByReplacingOccurrencesOfString:@"file://" withString:@"" options:NSAnchoredSearch range:NSMakeRange(0, path.length)];
        if (![path hasPrefix:@"/"])
            path = [@"/" stringByAppendingString:path];
        NSURL *result = [NSURL fileURLWithPath:path];
        NSLog(@"[rootfs]   reconstructed file URL, path=%@", result.path);
        return result;
    }

    NSLog(@"[rootfs]   FAILED: not a file URL, scheme=%@", url.scheme ?: @"(nil)");
    if (error) *error = [NSError errorWithDomain:@"RootfsManager" code:3 userInfo:@{NSLocalizedDescriptionKey: @"Root filesystem imports require a local iOS file or folder."}];
    return nil;
}

- (void)list:(CDVInvokedUrlCommand *)command {
    NSMutableArray *roots = [NSMutableArray array];
    NSString *activeRootId = self.activeRootId;
    NSString *defaultInit = [NSUserDefaults.standardUserDefaults stringForKey:AcodeIshDefaultInitKey];
    [roots addObject:RootDictionary(AcodeIshDefaultRootId, @"Default Root", YES, [activeRootId isEqualToString:AcodeIshDefaultRootId], @"", defaultInit)];
    for (NSDictionary *root in self.storedRoots) {
        [roots addObject:RootDictionary(root[@"id"], root[@"name"], NO, [activeRootId isEqualToString:root[@"id"]], root[@"importedAt"], root[@"init"])];
    }
    [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsArray:roots] callbackId:command.callbackId];
}

- (void)importArchive:(CDVInvokedUrlCommand *)command {
    [self importCommand:command directory:NO];
}

- (void)importDirectory:(CDVInvokedUrlCommand *)command {
    [self importCommand:command directory:YES];
}

- (void)restoreDefault:(CDVInvokedUrlCommand *)command {
    [[IshBridge shared] restoreDefaultRootfsWithCompletion:^(NSError *error) {
        if (error) {
            [self sendError:error command:command];
            return;
        }
        [NSUserDefaults.standardUserDefaults setObject:AcodeIshDefaultRootId forKey:AcodeIshActiveRootKey];
        NSDictionary *result = @{ @"restartRequired": @YES };
        [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:result]
                                     callbackId:command.callbackId];
    }];
}

- (NSString *)archiveSuffixForURL:(NSURL *)sourceURL {
    NSString *name = sourceURL.lastPathComponent.lowercaseString;
    if ([name hasSuffix:@".tar.gz"]) return @".tar.gz";
    if ([name hasSuffix:@".tgz"]) return @".tgz";
    if ([name hasSuffix:@".tar.xz"]) return @".tar.xz";
    if ([name hasSuffix:@".txz"]) return @".txz";
    if ([name hasSuffix:@".zip"]) return @".zip";
    return sourceURL.pathExtension.length ? [@"." stringByAppendingString:sourceURL.pathExtension] : @"";
}

- (BOOL)ensureReadableFileAtURL:(NSURL *)sourceURL error:(NSError **)error {
    NSNumber *ubiquitous = nil;
    [sourceURL getResourceValue:&ubiquitous forKey:NSURLIsUbiquitousItemKey error:nil];
    if (ubiquitous.boolValue) {
        NSError *downloadError = nil;
        if (![NSFileManager.defaultManager startDownloadingUbiquitousItemAtURL:sourceURL error:&downloadError] && downloadError) {
            if (error) *error = downloadError;
            return NO;
        }
    }

    if ([NSFileManager.defaultManager isReadableFileAtPath:sourceURL.path])
        return YES;

    if (error) *error = [NSError errorWithDomain:@"RootfsManager" code:10 userInfo:@{NSLocalizedDescriptionKey: @"The selected root filesystem archive is not readable. If it is in iCloud, download it locally and try again."}];
    return NO;
}

- (NSURL *)stageArchiveAtURL:(NSURL *)sourceURL error:(NSError **)error {
    NSString *suffix = [self archiveSuffixForURL:sourceURL];
    NSURL *destinationURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[NSUUID.UUID.UUIDString stringByAppendingString:suffix]]];
    __block NSError *copyError = nil;
    __block BOOL copied = NO;
    NSFileCoordinator *coordinator = [NSFileCoordinator new];
    [coordinator coordinateReadingItemAtURL:sourceURL options:0 error:&copyError byAccessor:^(NSURL *coordinatedURL) {
        if (![self ensureReadableFileAtURL:coordinatedURL error:&copyError])
            return;
        copied = [NSFileManager.defaultManager copyItemAtURL:coordinatedURL toURL:destinationURL error:&copyError];
    }];
    if (!copied) {
        [NSFileManager.defaultManager removeItemAtURL:destinationURL error:nil];
        NSString *detail = copyError.localizedDescription ?: @"Unable to read the selected root filesystem archive.";
        if (error) *error = [NSError errorWithDomain:@"RootfsManager" code:10 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Unable to stage selected archive: %@", detail]}];
        return nil;
    }
    struct stat stagedStat;
    if (stat(destinationURL.path.fileSystemRepresentation, &stagedStat) < 0 || stagedStat.st_size == 0) {
        [NSFileManager.defaultManager removeItemAtURL:destinationURL error:nil];
        if (error) *error = [NSError errorWithDomain:@"RootfsManager" code:10 userInfo:@{NSLocalizedDescriptionKey: @"Unable to stage selected archive: copied file is empty or unreadable."}];
        return nil;
    }
    return destinationURL;
}

- (void)importCommand:(CDVInvokedUrlCommand *)command directory:(BOOL)directory {
    NSString *sourceString = command.arguments.count > 0 ? command.arguments[0] : @"";
    NSString *name = command.arguments.count > 1 ? command.arguments[1] : @"";
    NSError *sourceError = nil;
    NSURL *sourceURL = [self fileURLFromArgument:sourceString error:&sourceError];
    if (!sourceURL) {
        [self sendError:sourceError command:command];
        return;
    }
    if (!directory) {
        NSString *lowercaseName = sourceURL.lastPathComponent.lowercaseString;
        if (!([lowercaseName hasSuffix:@".tar.gz"] || [lowercaseName hasSuffix:@".tgz"] || [lowercaseName hasSuffix:@".tar.xz"] || [lowercaseName hasSuffix:@".txz"] || [lowercaseName hasSuffix:@".zip"])) {
            [self sendError:[NSError errorWithDomain:@"RootfsManager" code:9 userInfo:@{NSLocalizedDescriptionKey: @"Select a .tar.gz, .tgz, .tar.xz, .txz, or .zip root filesystem archive."}] command:command];
            return;
        }
    }
    NSError *nameError = nil;
    if (![self isValidName:name error:&nameError]) {
        [self sendError:nameError command:command];
        return;
    }
    for (NSDictionary *root in self.storedRoots) {
        if ([root[@"name"] caseInsensitiveCompare:name] == NSOrderedSame) {
            [self sendError:[NSError errorWithDomain:@"RootfsManager" code:4 userInfo:@{NSLocalizedDescriptionKey: @"A root filesystem with that name already exists."}] command:command];
            return;
        }
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSFileManager *fm = NSFileManager.defaultManager;
        NSError *error = nil;
        [fm createDirectoryAtPath:RootsPath() withIntermediateDirectories:YES attributes:nil error:&error];
        if (error) {
            dispatch_async(dispatch_get_main_queue(), ^{ [self sendError:error command:command]; });
            return;
        }
        NSString *rootId = NSUUID.UUID.UUIDString.lowercaseString;
        NSString *stagingPath = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        BOOL accessingSecurityScope = [sourceURL startAccessingSecurityScopedResource];
        NSURL *archiveURL = directory ? nil : [self stageArchiveAtURL:sourceURL error:&error];
        if (!directory && !archiveURL) {
            if (accessingSecurityScope) [sourceURL stopAccessingSecurityScopedResource];
            dispatch_async(dispatch_get_main_queue(), ^{ [self sendError:error command:command]; });
            return;
        }

        NSLog(@"[rootfs] importing %@ as %@", directory ? @"directory" : @"archive", name);

        struct fakefsify_error importError = {0};
        BOOL imported = directory
            ? fakefs_import_directory(sourceURL.path.fileSystemRepresentation, stagingPath.fileSystemRepresentation, &importError, (struct progress){NULL, rootfs_progress_callback})
            : fakefs_import(archiveURL.path.fileSystemRepresentation, stagingPath.fileSystemRepresentation, &importError, (struct progress){NULL, rootfs_progress_callback});
        if (archiveURL) [NSFileManager.defaultManager removeItemAtURL:archiveURL error:nil];
        if (accessingSecurityScope) [sourceURL stopAccessingSecurityScopedResource];

        NSLog(@"[rootfs] fakefs_import returned: %d", imported);
        if (!imported) {
            NSString *message = importError.message ? [NSString stringWithUTF8String:importError.message] : @"Unable to import the root filesystem.";
            NSLog(@"[rootfs]   import error: %@ (type=%d, code=%d)", message, importError.type, importError.code);
            free(importError.message);
            [fm removeItemAtPath:stagingPath error:nil];
            NSError *importNSError = [NSError errorWithDomain:@"RootfsManager" code:5 userInfo:@{NSLocalizedDescriptionKey: message}];
            dispatch_async(dispatch_get_main_queue(), ^{ [self sendError:importNSError command:command]; });
            return;
        }

        if (![self validateRootAtPath:stagingPath error:&error]) {
            NSLog(@"[rootfs]   VALIDATION FAILED: %@", error.localizedDescription);
            [fm removeItemAtPath:stagingPath error:nil];
            dispatch_async(dispatch_get_main_queue(), ^{ [self sendError:error command:command]; });
            return;
        }
        NSLog(@"[rootfs]   validation passed");
        NSString *destination = RootPathForId(rootId);
        if (![fm moveItemAtPath:stagingPath toPath:destination error:&error]) {
            [fm removeItemAtPath:stagingPath error:nil];
            dispatch_async(dispatch_get_main_queue(), ^{ [self sendError:error command:command]; });
            return;
        }
        NSISO8601DateFormatter *formatter = [NSISO8601DateFormatter new];
        NSString *importedAt = [formatter stringFromDate:NSDate.date];
        NSDictionary *storedRoot = @{@"id": rootId, @"name": name, @"importedAt": importedAt, @"init": AcodeIshPreferredInitPath};
        dispatch_async(dispatch_get_main_queue(), ^{
            [self saveRoots:[self.storedRoots arrayByAddingObject:storedRoot]];
            NSDictionary *result = RootDictionary(rootId, name, NO, NO, importedAt, AcodeIshPreferredInitPath);
            [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:result] callbackId:command.callbackId];
        });
    });
}

- (void)activate:(CDVInvokedUrlCommand *)command {
    NSString *rootId = command.arguments.count > 0 ? command.arguments[0] : @"";
    if (![rootId isEqualToString:AcodeIshDefaultRootId] && ![self rootWithId:rootId]) {
        [self sendError:[NSError errorWithDomain:@"RootfsManager" code:6 userInfo:@{NSLocalizedDescriptionKey: @"Root filesystem not found."}] command:command];
        return;
    }
    [NSUserDefaults.standardUserDefaults setObject:rootId forKey:AcodeIshActiveRootKey];
    [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:@{@"restartRequired": @YES}] callbackId:command.callbackId];
}

- (void)rename:(CDVInvokedUrlCommand *)command {
    NSString *rootId = command.arguments.count > 0 ? command.arguments[0] : @"";
    NSString *name = command.arguments.count > 1 ? command.arguments[1] : @"";
    if ([rootId isEqualToString:AcodeIshDefaultRootId]) {
        [self sendError:[NSError errorWithDomain:@"RootfsManager" code:7 userInfo:@{NSLocalizedDescriptionKey: @"The bundled default root cannot be renamed."}] command:command];
        return;
    }
    NSError *error = nil;
    if (![self isValidName:name error:&error]) { [self sendError:error command:command]; return; }
    NSMutableArray *roots = [self.storedRoots mutableCopy];
    for (NSUInteger index = 0; index < roots.count; index++) {
        NSMutableDictionary *root = [roots[index] mutableCopy];
        if (![root[@"id"] isEqualToString:rootId]) continue;
        root[@"name"] = name;
        roots[index] = root;
        [self saveRoots:roots];
        [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:RootDictionary(rootId, name, NO, [rootId isEqualToString:self.activeRootId], root[@"importedAt"], root[@"init"])] callbackId:command.callbackId];
        return;
    }
    [self sendError:[NSError errorWithDomain:@"RootfsManager" code:6 userInfo:@{NSLocalizedDescriptionKey: @"Root filesystem not found."}] command:command];
}

- (void)setInit:(CDVInvokedUrlCommand *)command {
    NSString *rootId = command.arguments.count > 0 ? command.arguments[0] : @"";
    NSString *initPath = command.arguments.count > 1 ? RootfsSanitizedInitPath(command.arguments[1]) : @"";
    NSDictionary *root = [rootId isEqualToString:AcodeIshDefaultRootId] ? @{} : [self rootWithId:rootId];
    if (rootId.length == 0 || (![rootId isEqualToString:AcodeIshDefaultRootId] && !root)) {
        [self sendError:[NSError errorWithDomain:@"RootfsManager" code:6 userInfo:@{NSLocalizedDescriptionKey: @"Root filesystem not found."}] command:command];
        return;
    }
    if (![initPath hasPrefix:@"/"] || [initPath rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location != NSNotFound) {
        [self sendError:[NSError errorWithDomain:@"RootfsManager" code:11 userInfo:@{NSLocalizedDescriptionKey: @"Init must be one absolute executable path, such as /sbin/init or /bin/sh."}] command:command];
        return;
    }

    NSString *rootPath = RootPathForId(rootId);
    if (!AcodeIshRootfsExecutableIsArm64(rootPath, initPath)) {
        [self sendError:[NSError errorWithDomain:@"RootfsManager" code:12 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@ is missing, not executable, or not an ARM64 Linux program in this root filesystem.", initPath]}] command:command];
        return;
    }

    if ([rootId isEqualToString:AcodeIshDefaultRootId]) {
        [NSUserDefaults.standardUserDefaults setObject:initPath forKey:AcodeIshDefaultInitKey];
    } else {
        NSMutableArray *roots = [self.storedRoots mutableCopy];
        for (NSUInteger index = 0; index < roots.count; index++) {
            if (![roots[index][@"id"] isEqualToString:rootId]) continue;
            NSMutableDictionary *updated = [roots[index] mutableCopy];
            updated[@"init"] = initPath;
            roots[index] = updated;
            break;
        }
        [self saveRoots:roots];
    }

    BOOL restartRequired = [rootId isEqualToString:self.activeRootId];
    NSDictionary *result = @{@"init": initPath, @"restartRequired": @(restartRequired)};
    [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:result] callbackId:command.callbackId];
}

- (void)delete:(CDVInvokedUrlCommand *)command {
    NSString *rootId = command.arguments.count > 0 ? command.arguments[0] : @"";
    if ([rootId isEqualToString:AcodeIshDefaultRootId] || [rootId isEqualToString:self.activeRootId]) {
        [self sendError:[NSError errorWithDomain:@"RootfsManager" code:8 userInfo:@{NSLocalizedDescriptionKey: @"The active or bundled default root cannot be deleted."}] command:command];
        return;
    }
    NSDictionary *root = [self rootWithId:rootId];
    if (!root) { [self sendError:[NSError errorWithDomain:@"RootfsManager" code:6 userInfo:@{NSLocalizedDescriptionKey: @"Root filesystem not found."}] command:command]; return; }
    NSError *error = nil;
    if (![NSFileManager.defaultManager removeItemAtPath:RootPathForId(rootId) error:&error]) { [self sendError:error command:command]; return; }
    NSMutableArray *roots = [self.storedRoots mutableCopy];
    [roots removeObject:root];
    [self saveRoots:roots];
    [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK] callbackId:command.callbackId];
}

- (void)getActivePublicHome:(CDVInvokedUrlCommand *)command {
    NSString *path = [[AcodeIshActiveRootPath() stringByAppendingPathComponent:@"data"] stringByAppendingPathComponent:@"home"];
    [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:path] callbackId:command.callbackId];
}

- (void)reconcileFs:(CDVInvokedUrlCommand *)command {
    NSError *error = nil;
    BOOL ok = [[IshBridge shared] reconcileFs:&error];
    if (ok) {
        [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK] callbackId:command.callbackId];
    } else {
        NSString *msg = error.localizedDescription ?: @"Reconciliation failed";
        [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:msg] callbackId:command.callbackId];
    }
}

@end
