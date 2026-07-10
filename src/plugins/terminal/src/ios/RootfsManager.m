#import "RootfsManager.h"
#import <Cordova/CDVPluginResult.h>
#import "fakefs.h"
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

- (void)importCommand:(CDVInvokedUrlCommand *)command directory:(BOOL)directory {
    NSString *sourceString = command.arguments.count > 0 ? command.arguments[0] : @"";
    NSString *name = command.arguments.count > 1 ? command.arguments[1] : @"";
    NSURL *sourceURL = [NSURL URLWithString:sourceString];
    if (!sourceURL.isFileURL) {
        [self sendError:[NSError errorWithDomain:@"RootfsManager" code:3 userInfo:@{NSLocalizedDescriptionKey: @"Root filesystem imports require a local file or folder."}] command:command];
        return;
    }
    if (!directory) {
        NSString *lowercaseName = sourceURL.lastPathComponent.lowercaseString;
        if (!([lowercaseName hasSuffix:@".tar.gz"] || [lowercaseName hasSuffix:@".tgz"] || [lowercaseName hasSuffix:@".zip"])) {
            [self sendError:[NSError errorWithDomain:@"RootfsManager" code:9 userInfo:@{NSLocalizedDescriptionKey: @"Select a .tar.gz, .tgz, or .zip root filesystem archive."}] command:command];
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
        [sourceURL startAccessingSecurityScopedResource];
        struct fakefsify_error importError = {0};
        BOOL imported = directory
            ? fakefs_import_directory(sourceURL.path.fileSystemRepresentation, stagingPath.fileSystemRepresentation, &importError, (struct progress){NULL, rootfs_progress_callback})
            : fakefs_import(sourceURL.path.fileSystemRepresentation, stagingPath.fileSystemRepresentation, &importError, (struct progress){NULL, rootfs_progress_callback});
        [sourceURL stopAccessingSecurityScopedResource];
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
