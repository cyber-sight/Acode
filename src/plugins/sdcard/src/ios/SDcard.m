#import "SDcard.h"
#import <Cordova/CDVPluginResult.h>
#import <UIKit/UIKit.h>
#import <MobileCoreServices/MobileCoreServices.h>
#if __has_include(<UniformTypeIdentifiers/UniformTypeIdentifiers.h>)
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#endif
#import <fcntl.h>

@interface SDcard () <UIDocumentPickerDelegate, UINavigationControllerDelegate, UIImagePickerControllerDelegate>
@property (nonatomic, copy) NSString *activityCallbackId;
@property (nonatomic, copy) NSString *pickerMode;
@property (nonatomic, strong) NSMutableDictionary<NSString *, dispatch_source_t> *fileObservers;
@end

@implementation SDcard

static NSString *const kSeparator = @"::";

- (void)pluginInitialize {
    self.fileObservers = [NSMutableDictionary dictionary];
}

- (void)createDir:(CDVInvokedUrlCommand *)command {
    NSString *parent = command.arguments.count > 0 ? command.arguments[0] : @"";
    NSString *name = command.arguments.count > 1 ? command.arguments[1] : @"";
    NSURL *parentURL = [self urlFromString:parent];
    NSURL *dirURL = [parentURL URLByAppendingPathComponent:name isDirectory:YES];

    NSError *error = nil;
    BOOL ok = [[NSFileManager defaultManager] createDirectoryAtURL:dirURL withIntermediateDirectories:YES attributes:nil error:&error];
    if (!ok || error) {
        [self sendError:error.localizedDescription ?: @"Unable to create directory" callbackId:command.callbackId];
        return;
    }

    CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:[dirURL absoluteString]];
    [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
}

- (void)createFile:(CDVInvokedUrlCommand *)command {
    NSString *parent = command.arguments.count > 0 ? command.arguments[0] : @"";
    NSString *name = command.arguments.count > 1 ? command.arguments[1] : @"";
    NSURL *parentURL = [self urlFromString:parent];
    NSURL *fileURL = [parentURL URLByAppendingPathComponent:name isDirectory:NO];

    BOOL ok = [[NSFileManager defaultManager] createFileAtPath:fileURL.path contents:[NSData data] attributes:nil];
    if (!ok) {
        [self sendError:@"Unable to create file" callbackId:command.callbackId];
        return;
    }

    CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:[fileURL absoluteString]];
    [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
}

- (void)openDocumentFile:(CDVInvokedUrlCommand *)command {
    NSString *mimeType = command.arguments.count > 0 ? command.arguments[0] : nil;
    UIDocumentPickerViewController *picker = nil;
    if (@available(iOS 14.0, *)) {
        NSArray<UTType *> *types = [self utTypesFromMime:mimeType];
        picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types asCopy:YES];
    } else {
        NSArray<NSString *> *types = [self legacyDocumentTypesFromMime:mimeType];
        picker = [[UIDocumentPickerViewController alloc] initWithDocumentTypes:types inMode:UIDocumentPickerModeOpen];
    }
    picker.delegate = self;
    self.activityCallbackId = command.callbackId;
    self.pickerMode = @"openDocument";
    [self.viewController presentViewController:picker animated:YES completion:nil];
}

- (void)getImage:(CDVInvokedUrlCommand *)command {
    NSString *mimeType = command.arguments.count > 0 ? command.arguments[0] : @"image/*";
    UIDocumentPickerViewController *picker = nil;
    if (@available(iOS 14.0, *)) {
        NSArray<UTType *> *types = [self utTypesFromMime:mimeType];
        picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types asCopy:YES];
    } else {
        NSArray<NSString *> *types = [self legacyDocumentTypesFromMime:mimeType];
        picker = [[UIDocumentPickerViewController alloc] initWithDocumentTypes:types inMode:UIDocumentPickerModeOpen];
    }
    picker.delegate = self;
    self.activityCallbackId = command.callbackId;
    self.pickerMode = @"getImage";
    [self.viewController presentViewController:picker animated:YES completion:nil];
}

- (void)listStorages:(CDVInvokedUrlCommand *)command {
    NSURL *docs = [[[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask] firstObject];
    NSURL *caches = [[[NSFileManager defaultManager] URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask] firstObject];

    NSArray *volumes = @[
        @{ @"uuid": @"documents", @"name": @"Documents", @"path": docs.path ?: @"" },
        @{ @"uuid": @"caches", @"name": @"Caches", @"path": caches.path ?: @"" }
    ];

    CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsArray:volumes];
    [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
}

- (void)getStorageAccessPermission:(CDVInvokedUrlCommand *)command {
    UIDocumentPickerViewController *picker = nil;
    if (@available(iOS 14.0, *)) {
        picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeFolder] asCopy:NO];
    } else {
        picker = [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[(NSString *)kUTTypeFolder] inMode:UIDocumentPickerModeOpen];
    }
    picker.delegate = self;
    self.activityCallbackId = command.callbackId;
    self.pickerMode = @"openFolder";
    [self.viewController presentViewController:picker animated:YES completion:nil];
}

- (void)read:(CDVInvokedUrlCommand *)command {
    NSString *path = command.arguments.count > 0 ? command.arguments[0] : @"";
    NSURL *url = [self urlFromString:path];
    NSData *data = [NSData dataWithContentsOfURL:url];
    if (!data) {
        [self sendError:@"File not found" callbackId:command.callbackId];
        return;
    }

    CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsArrayBuffer:data];
    [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
}

- (void)write:(CDVInvokedUrlCommand *)command {
    NSString *path = command.arguments.count > 0 ? command.arguments[0] : @"";
    NSString *content = command.arguments.count > 1 ? command.arguments[1] : @"";
    BOOL isArrayBuffer = command.arguments.count > 2 ? [command.arguments[2] boolValue] : NO;

    NSURL *url = [self urlFromString:path];
    NSData *data = nil;

    if (isArrayBuffer) {
        data = [[NSData alloc] initWithBase64EncodedString:content options:0];
    } else {
        data = [content dataUsingEncoding:NSUTF8StringEncoding];
    }

    NSError *error = nil;
    BOOL ok = [data writeToURL:url options:NSDataWritingAtomic error:&error];
    if (!ok || error) {
        [self sendError:error.localizedDescription ?: @"Write failed" callbackId:command.callbackId];
        return;
    }

    [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:@"OK"] callbackId:command.callbackId];
}

- (void)rename:(CDVInvokedUrlCommand *)command {
    NSString *path = command.arguments.count > 0 ? command.arguments[0] : @"";
    NSString *newName = command.arguments.count > 1 ? command.arguments[1] : @"";
    NSURL *url = [self urlFromString:path];
    NSURL *destURL = [[url URLByDeletingLastPathComponent] URLByAppendingPathComponent:newName];

    NSError *error = nil;
    BOOL ok = [[NSFileManager defaultManager] moveItemAtURL:url toURL:destURL error:&error];
    if (!ok || error) {
        [self sendError:error.localizedDescription ?: @"Rename failed" callbackId:command.callbackId];
        return;
    }

    [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:[destURL absoluteString]] callbackId:command.callbackId];
}

- (void)delete:(CDVInvokedUrlCommand *)command {
    NSString *path = command.arguments.count > 0 ? command.arguments[0] : @"";
    NSURL *url = [self urlFromString:path];
    NSError *error = nil;
    BOOL ok = [[NSFileManager defaultManager] removeItemAtURL:url error:&error];
    if (!ok || error) {
        [self sendError:error.localizedDescription ?: @"Unable to delete file" callbackId:command.callbackId];
        return;
    }
    [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:path] callbackId:command.callbackId];
}

- (void)copy:(CDVInvokedUrlCommand *)command {
    NSString *src = command.arguments.count > 0 ? command.arguments[0] : @"";
    NSString *dest = command.arguments.count > 1 ? command.arguments[1] : @"";

    NSURL *srcURL = [self urlFromString:src];
    NSURL *destURL = [self urlFromString:dest];

    NSError *error = nil;
    BOOL ok = [[NSFileManager defaultManager] copyItemAtURL:srcURL toURL:destURL error:&error];
    if (!ok || error) {
        [self sendError:error.localizedDescription ?: @"Copy failed" callbackId:command.callbackId];
        return;
    }

    [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:[destURL absoluteString]] callbackId:command.callbackId];
}

- (void)move:(CDVInvokedUrlCommand *)command {
    NSString *src = command.arguments.count > 0 ? command.arguments[0] : @"";
    NSString *dest = command.arguments.count > 1 ? command.arguments[1] : @"";

    NSURL *srcURL = [self urlFromString:src];
    NSURL *destURL = [self urlFromString:dest];

    NSError *error = nil;
    BOOL ok = [[NSFileManager defaultManager] moveItemAtURL:srcURL toURL:destURL error:&error];
    if (!ok || error) {
        [self sendError:error.localizedDescription ?: @"Move failed" callbackId:command.callbackId];
        return;
    }

    [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:[destURL absoluteString]] callbackId:command.callbackId];
}

- (void)getPath:(CDVInvokedUrlCommand *)command {
    NSString *uriString = command.arguments.count > 0 ? command.arguments[0] : @"";
    NSURL *url = [self urlFromString:uriString];
    if (!url) {
        [self sendError:@"Unable to get path" callbackId:command.callbackId];
        return;
    }
    [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:url.absoluteString] callbackId:command.callbackId];
}

- (void)exists:(CDVInvokedUrlCommand *)command {
    NSString *path = command.arguments.count > 0 ? command.arguments[0] : @"";
    NSURL *url = [self urlFromString:path];
    BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:url.path];
    NSString *resultString = exists ? @"TRUE" : @"FALSE";
    [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:resultString] callbackId:command.callbackId];
}

- (void)formatUri:(CDVInvokedUrlCommand *)command {
    NSString *path = command.arguments.count > 0 ? command.arguments[0] : @"";
    NSURL *url = [self urlFromString:path];
    [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:url.absoluteString] callbackId:command.callbackId];
}

- (void)listDir:(CDVInvokedUrlCommand *)command {
    NSString *src = command.arguments.count > 0 ? command.arguments[0] : @"";
    NSString *parentId = command.arguments.count > 1 ? command.arguments[1] : nil;

    NSURL *rootURL = [self urlFromString:src];
    NSURL *dirURL = rootURL;
    if (parentId.length > 0) {
        dirURL = [rootURL URLByAppendingPathComponent:parentId isDirectory:YES];
    }

    NSError *error = nil;
    NSArray<NSURL *> *items = [[NSFileManager defaultManager] contentsOfDirectoryAtURL:dirURL includingPropertiesForKeys:@[NSURLIsDirectoryKey] options:0 error:&error];
    if (error) {
        [self sendError:error.localizedDescription ?: @"Cannot read directory" callbackId:command.callbackId];
        return;
    }

    NSMutableArray *result = [NSMutableArray array];
    for (NSURL *item in items) {
        NSNumber *isDir = nil;
        [item getResourceValue:&isDir forKey:NSURLIsDirectoryKey error:nil];
        NSDictionary *entry = @{
            @"name": item.lastPathComponent ?: @"",
            @"mime": @"",
            @"isDirectory": isDir ?: @NO,
            @"isFile": @(!isDir.boolValue),
            @"uri": item.absoluteString ?: @"",
            @"url": item.absoluteString ?: @""
        };
        [result addObject:entry];
    }

    CDVPluginResult *resultPlugin = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsArray:result];
    [self.commandDelegate sendPluginResult:resultPlugin callbackId:command.callbackId];
}

- (void)stats:(CDVInvokedUrlCommand *)command {
    NSString *path = command.arguments.count > 0 ? command.arguments[0] : @"";
    NSURL *url = [self urlFromString:path];

    NSError *error = nil;
    NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:url.path error:&error];
    if (error || !attributes) {
        [self sendError:error.localizedDescription ?: @"Unable to read file" callbackId:command.callbackId];
        return;
    }

    BOOL isDir = [attributes[NSFileType] isEqualToString:NSFileTypeDirectory];
    NSDictionary *result = @{
        @"exists": @YES,
        @"canRead": @YES,
        @"canWrite": @YES,
        @"name": url.lastPathComponent ?: @"",
        @"length": attributes[NSFileSize] ?: @0,
        @"type": @"",
        @"isFile": @(!isDir),
        @"isDirectory": @(isDir),
        @"isVirtual": @NO,
        @"lastModified": @((long long)([attributes[NSFileModificationDate] timeIntervalSince1970] * 1000)),
        @"url": url.absoluteString ?: @""
    };

    [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:result] callbackId:command.callbackId];
}

- (void)listEncodings:(CDVInvokedUrlCommand *)command {
    CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsArray:@[]];
    [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
}

- (void)watchFile:(CDVInvokedUrlCommand *)command {
    NSString *path = command.arguments.count > 0 ? command.arguments[0] : @"";
    NSString *observerId = command.arguments.count > 1 ? command.arguments[1] : @"";

    NSURL *url = [self urlFromString:path];
    int fd = open(url.path.UTF8String, O_EVTONLY);
    if (fd < 0) {
        [self sendError:@"File not found" callbackId:command.callbackId];
        return;
    }

    dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
    dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE, fd, DISPATCH_VNODE_DELETE | DISPATCH_VNODE_WRITE | DISPATCH_VNODE_RENAME, queue);
    self.fileObservers[observerId] = source;

    CDVPluginResult *keep = [CDVPluginResult resultWithStatus:CDVCommandStatus_NO_RESULT];
    [keep setKeepCallback:@YES];
    [self.commandDelegate sendPluginResult:keep callbackId:command.callbackId];

    dispatch_source_set_event_handler(source, ^{
        CDVPluginResult *eventResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
        [eventResult setKeepCallback:@YES];
        [self.commandDelegate sendPluginResult:eventResult callbackId:command.callbackId];
    });

    dispatch_source_set_cancel_handler(source, ^{
        close(fd);
    });

    dispatch_resume(source);
}

- (void)unwatchFile:(CDVInvokedUrlCommand *)command {
    NSString *observerId = command.arguments.count > 0 ? command.arguments[0] : @"";
    dispatch_source_t source = self.fileObservers[observerId];
    if (source) {
        dispatch_source_cancel(source);
        [self.fileObservers removeObjectForKey:observerId];
    }
    [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK] callbackId:command.callbackId];
}

#pragma mark - UIDocumentPickerDelegate

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if (!self.activityCallbackId) {
        return;
    }

    NSURL *url = urls.firstObject;
    if (!url) {
        [self sendError:@"No file selected" callbackId:self.activityCallbackId];
        return;
    }

    if ([self.pickerMode isEqualToString:@"openFolder"]) {
        CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:url.absoluteString];
        [self.commandDelegate sendPluginResult:result callbackId:self.activityCallbackId];
        return;
    }

    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:url.path error:nil];
    NSDictionary *payload = @{
        @"length": attrs[NSFileSize] ?: @0,
        @"type": @"",
        @"filename": url.lastPathComponent ?: @"",
        @"canWrite": @YES,
        @"uri": url.absoluteString ?: @""
    };

    CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:payload];
    [self.commandDelegate sendPluginResult:result callbackId:self.activityCallbackId];
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    if (self.activityCallbackId) {
        [self sendError:@"Operation cancelled" callbackId:self.activityCallbackId];
    }
}

#pragma mark - Helpers

- (NSURL *)urlFromString:(NSString *)path {
    if ([path containsString:kSeparator]) {
        NSArray *parts = [path componentsSeparatedByString:kSeparator];
        if (parts.count >= 2) {
            NSString *root = parts[0];
            NSString *docId = parts[1];
            NSURL *rootURL = [self urlFromString:root];
            return [rootURL URLByAppendingPathComponent:docId];
        }
    }

    NSURL *url = [NSURL URLWithString:path];
    if (url && url.scheme.length > 0) {
        return url;
    }
    return [NSURL fileURLWithPath:path];
}

- (NSArray<UTType *> *)utTypesFromMime:(NSString *)mime {
    if (@available(iOS 14.0, *)) {
        if (!mime || [mime isEqualToString:@"*"] || [mime isEqualToString:@"*/*"]) {
            return @[UTTypeItem];
        }
        UTType *type = [UTType typeWithMIMEType:mime];
        if (type) {
            return @[type];
        }
        return @[UTTypeItem];
    }
    return @[];
}

- (NSArray<NSString *> *)legacyDocumentTypesFromMime:(NSString *)mime {
    if (!mime || [mime isEqualToString:@"*"] || [mime isEqualToString:@"*/*"]) {
        return @[(NSString *)kUTTypeItem];
    }
    CFStringRef uti = UTTypeCreatePreferredIdentifierForTag(kUTTagClassMIMEType, (__bridge CFStringRef)mime, NULL);
    if (uti) {
        return @[(__bridge_transfer NSString *)uti];
    }
    return @[(NSString *)kUTTypeItem];
}

- (void)sendError:(NSString *)message callbackId:(NSString *)callbackId {
    CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:message ?: @"Error"];
    [self.commandDelegate sendPluginResult:result callbackId:callbackId];
}

@end
