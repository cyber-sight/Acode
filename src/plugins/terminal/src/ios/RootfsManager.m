#import "RootfsManager.h"
#import <Cordova/CDVPluginResult.h>
#import "fakefs.h"
#include <sys/stat.h>
#include <stdlib.h>

NSString *const AcodeIshDefaultRootId = @"default";
static NSString *const AcodeIshRootsKey = @"AcodeIshRoots";
static NSString *const AcodeIshActiveRootKey = @"AcodeIshActiveRoot";

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

static NSDictionary *RootDictionary(NSString *rootId, NSString *name, BOOL isDefault, BOOL isActive, NSString *importedAt) {
    return @{
        @"id": rootId,
        @"name": name,
        @"isDefault": @(isDefault),
        @"isActive": @(isActive),
        @"path": RootPathForId(rootId),
        @"importedAt": importedAt ?: @"",
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
    BOOL valid = [fm fileExistsAtPath:[path stringByAppendingPathComponent:@"meta.db"]] &&
        [fm fileExistsAtPath:[path stringByAppendingPathComponent:@"data"] isDirectory:&dataIsDirectory] &&
        dataIsDirectory &&
        [fm isExecutableFileAtPath:[path stringByAppendingPathComponent:@"data/bin/sh"]];
    if (!valid && error)
        *error = [NSError errorWithDomain:@"RootfsManager" code:2 userInfo:@{NSLocalizedDescriptionKey: @"The selected source is not a complete root filesystem (missing bin/sh)."}];
    return valid;
}

- (void)sendError:(NSError *)error command:(CDVInvokedUrlCommand *)command {
    [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:error.localizedDescription ?: @"Root filesystem operation failed."] callbackId:command.callbackId];
}

- (NSURL *)fileURLFromArgument:(NSString *)sourceString error:(NSError **)error {
    if (sourceString.length == 0) {
        if (error) *error = [NSError errorWithDomain:@"RootfsManager" code:3 userInfo:@{NSLocalizedDescriptionKey: @"Root filesystem imports require a local file or folder."}];
        return nil;
    }

    NSURL *url = [NSURL URLWithString:sourceString];
    if (url.isFileURL)
        return url;

    if ([sourceString hasPrefix:@"file://"]) {
        NSString *path = [sourceString stringByRemovingPercentEncoding] ?: sourceString;
        path = [path stringByReplacingOccurrencesOfString:@"file://" withString:@"" options:NSAnchoredSearch range:NSMakeRange(0, path.length)];
        if (![path hasPrefix:@"/"])
            path = [@"/" stringByAppendingString:path];
        return [NSURL fileURLWithPath:path];
    }

    if (error) *error = [NSError errorWithDomain:@"RootfsManager" code:3 userInfo:@{NSLocalizedDescriptionKey: @"Root filesystem imports require a local iOS file or folder."}];
    return nil;
}

- (void)list:(CDVInvokedUrlCommand *)command {
    NSMutableArray *roots = [NSMutableArray array];
    NSString *activeRootId = self.activeRootId;
    [roots addObject:RootDictionary(AcodeIshDefaultRootId, @"Default Root", YES, [activeRootId isEqualToString:AcodeIshDefaultRootId], @"")];
    for (NSDictionary *root in self.storedRoots) {
        [roots addObject:RootDictionary(root[@"id"], root[@"name"], NO, [activeRootId isEqualToString:root[@"id"]], root[@"importedAt"])];
    }
    [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsArray:roots] callbackId:command.callbackId];
}

- (void)importArchive:(CDVInvokedUrlCommand *)command {
    [self importCommand:command directory:NO];
}

- (void)importDirectory:(CDVInvokedUrlCommand *)command {
    [self importCommand:command directory:YES];
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
        struct fakefsify_error importError = {0};
        BOOL imported = directory
            ? fakefs_import_directory(sourceURL.path.fileSystemRepresentation, stagingPath.fileSystemRepresentation, &importError, (struct progress){NULL, rootfs_progress_callback})
            : fakefs_import(archiveURL.path.fileSystemRepresentation, stagingPath.fileSystemRepresentation, &importError, (struct progress){NULL, rootfs_progress_callback});
        [NSFileManager.defaultManager removeItemAtURL:archiveURL error:nil];
        if (accessingSecurityScope) [sourceURL stopAccessingSecurityScopedResource];
        if (!imported) {
            NSString *message = importError.message ? [NSString stringWithUTF8String:importError.message] : @"Unable to import the root filesystem.";
            free(importError.message);
            [fm removeItemAtPath:stagingPath error:nil];
            NSError *importNSError = [NSError errorWithDomain:@"RootfsManager" code:5 userInfo:@{NSLocalizedDescriptionKey: message}];
            dispatch_async(dispatch_get_main_queue(), ^{ [self sendError:importNSError command:command]; });
            return;
        }
        if (![self validateRootAtPath:stagingPath error:&error]) {
            [fm removeItemAtPath:stagingPath error:nil];
            dispatch_async(dispatch_get_main_queue(), ^{ [self sendError:error command:command]; });
            return;
        }
        NSString *destination = RootPathForId(rootId);
        if (![fm moveItemAtPath:stagingPath toPath:destination error:&error]) {
            [fm removeItemAtPath:stagingPath error:nil];
            dispatch_async(dispatch_get_main_queue(), ^{ [self sendError:error command:command]; });
            return;
        }
        NSISO8601DateFormatter *formatter = [NSISO8601DateFormatter new];
        NSString *importedAt = [formatter stringFromDate:NSDate.date];
        NSDictionary *storedRoot = @{@"id": rootId, @"name": name, @"importedAt": importedAt};
        dispatch_async(dispatch_get_main_queue(), ^{
            [self saveRoots:[self.storedRoots arrayByAddingObject:storedRoot]];
            NSDictionary *result = RootDictionary(rootId, name, NO, NO, importedAt);
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
        [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:RootDictionary(rootId, name, NO, [rootId isEqualToString:self.activeRootId], root[@"importedAt"])] callbackId:command.callbackId];
        return;
    }
    [self sendError:[NSError errorWithDomain:@"RootfsManager" code:6 userInfo:@{NSLocalizedDescriptionKey: @"Root filesystem not found."}] command:command];
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

@end
