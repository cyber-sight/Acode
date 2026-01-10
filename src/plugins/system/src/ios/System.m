#import "System.h"
#import <Cordova/CDVPluginResult.h>
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <sys/sysctl.h>

@interface System ()
@property (nonatomic, copy) NSString *intentHandlerCallbackId;
@property (nonatomic, copy) NSString *lastOpenUrl;
@property (nonatomic, strong) UIDocumentInteractionController *docController;
@end

@implementation System

- (void)handleOpenURL:(NSNotification *)notification {
    NSURL *url = notification.object;
    if (!url) {
        return;
    }

    self.lastOpenUrl = url.absoluteString;
    if (self.intentHandlerCallbackId) {
        CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:self.lastOpenUrl];
        [result setKeepCallback:@YES];
        [self.commandDelegate sendPluginResult:result callbackId:self.intentHandlerCallbackId];
    }
}

- (void)getFilesDir:(CDVInvokedUrlCommand *)command {
    NSString *path = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject ?: @"";
    [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:path] callbackId:command.callbackId];
}

- (void)getNativeLibraryPath:(CDVInvokedUrlCommand *)command {
    NSString *path = [[NSBundle mainBundle] privateFrameworksPath] ?: @"";
    [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:path] callbackId:command.callbackId];
}

- (void)getParentPath:(CDVInvokedUrlCommand *)command {
    NSString *path = command.arguments.count > 0 ? command.arguments[0] : @"";
    NSString *parent = [path stringByDeletingLastPathComponent] ?: @"";
    [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:parent] callbackId:command.callbackId];
}

- (void)listChildren:(CDVInvokedUrlCommand *)command {
    NSString *path = command.arguments.count > 0 ? command.arguments[0] : @"";
    NSError *error = nil;
    NSArray *items = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:path error:&error];
    if (error) {
        [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:error.localizedDescription] callbackId:command.callbackId];
        return;
    }
    [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsArray:items ?: @[]] callbackId:command.callbackId];
}

- (void)mkdirs:(CDVInvokedUrlCommand *)command {
    NSString *path = command.arguments.count > 0 ? command.arguments[0] : @"";
    NSError *error = nil;
    BOOL ok = [[NSFileManager defaultManager] createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:&error];
    if (!ok || error) {
        [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:error.localizedDescription ?: @"mkdirs failed"] callbackId:command.callbackId];
        return;
    }
    [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK] callbackId:command.callbackId];
}

- (void)fileExists:(CDVInvokedUrlCommand *)command {
    NSString *path = command.arguments.count > 0 ? command.arguments[0] : @"";
    BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:path];
    NSNumber *value = exists ? @1 : @0;
    [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsInt:value.intValue] callbackId:command.callbackId];
}

- (void)createSymlink:(CDVInvokedUrlCommand *)command {
    NSString *target = command.arguments.count > 0 ? command.arguments[0] : @"";
    NSString *linkPath = command.arguments.count > 1 ? command.arguments[1] : @"";
    NSError *error = nil;
    BOOL ok = [[NSFileManager defaultManager] createSymbolicLinkAtPath:linkPath withDestinationPath:target error:&error];
    if (!ok || error) {
        [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:error.localizedDescription ?: @"createSymlink failed"] callbackId:command.callbackId];
        return;
    }
    [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsInt:1] callbackId:command.callbackId];
}

- (void)writeText:(CDVInvokedUrlCommand *)command {
    NSString *path = command.arguments.count > 0 ? command.arguments[0] : @"";
    NSString *content = command.arguments.count > 1 ? command.arguments[1] : @"";
    NSError *error = nil;
    BOOL ok = [content writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&error];
    if (!ok || error) {
        [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:error.localizedDescription ?: @"Failed to write file"] callbackId:command.callbackId];
        return;
    }
    [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:@"File written successfully"] callbackId:command.callbackId];
}

- (void)deleteFile:(CDVInvokedUrlCommand *)command {
    NSString *path = command.arguments.count > 0 ? command.arguments[0] : @"";
    NSError *error = nil;
    BOOL ok = [[NSFileManager defaultManager] removeItemAtPath:path error:&error];
    if (!ok && error) {
        [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:error.localizedDescription ?: @"delete failed"] callbackId:command.callbackId];
        return;
    }
    [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK] callbackId:command.callbackId];
}

- (void)setExec:(CDVInvokedUrlCommand *)command {
    [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK] callbackId:command.callbackId];
}

- (void)getArch:(CDVInvokedUrlCommand *)command {
    size_t size = 0;
    sysctlbyname("hw.machine", NULL, &size, NULL, 0);
    char *machine = malloc(size);
    sysctlbyname("hw.machine", machine, &size, NULL, 0);
    NSString *arch = [NSString stringWithCString:machine encoding:NSUTF8StringEncoding] ?: @"ios";
    free(machine);

    [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:arch] callbackId:command.callbackId];
}

- (void)clearCache:(CDVInvokedUrlCommand *)command {
    NSURL *cacheURL = [[[NSFileManager defaultManager] URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask] firstObject];
    if (!cacheURL) {
        [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK] callbackId:command.callbackId];
        return;
    }
    NSArray *contents = [[NSFileManager defaultManager] contentsOfDirectoryAtURL:cacheURL includingPropertiesForKeys:nil options:0 error:nil];
    for (NSURL *url in contents) {
        [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
    }
    [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK] callbackId:command.callbackId];
}

- (void)getWebviewInfo:(CDVInvokedUrlCommand *)command {
    NSDictionary *info = @{
        @"engine": @"WKWebView",
        @"userAgent": @""
    };
    [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:info] callbackId:command.callbackId];
}

- (void)isPowerSaveMode:(CDVInvokedUrlCommand *)command {
    BOOL lowPower = NSProcessInfo.processInfo.lowPowerModeEnabled;
    [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsBool:lowPower] callbackId:command.callbackId];
}

- (void)fileAction:(CDVInvokedUrlCommand *)command {
    NSString *fileUri = command.arguments.count > 0 ? command.arguments[0] : @"";
    NSURL *url = [NSURL URLWithString:fileUri];
    if (!url || !url.isFileURL) {
        url = [NSURL fileURLWithPath:fileUri];
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        self.docController = [UIDocumentInteractionController interactionControllerWithURL:url];
        [self.docController presentPreviewAnimated:YES];
    });

    [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK] callbackId:command.callbackId];
}

- (void)getAppInfo:(CDVInvokedUrlCommand *)command {
    NSDictionary *info = [[NSBundle mainBundle] infoDictionary];
    NSString *bundleId = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    NSDictionary *payload = @{
        @"packageName": bundleId,
        @"version": info[@"CFBundleShortVersionString"] ?: @"",
        @"build": info[@"CFBundleVersion"] ?: @"",
        @"name": info[@"CFBundleName"] ?: @""
    };
    [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:payload] callbackId:command.callbackId];
}

- (void)addShortcut:(CDVInvokedUrlCommand *)command {
    NSString *shortcutId = command.arguments.count > 0 ? command.arguments[0] : @"";
    NSString *label = command.arguments.count > 1 ? command.arguments[1] : @"";

    UIApplicationShortcutItem *item = [[UIApplicationShortcutItem alloc] initWithType:shortcutId localizedTitle:label localizedSubtitle:nil icon:nil userInfo:nil];
    NSMutableArray *items = [NSMutableArray arrayWithArray:[UIApplication sharedApplication].shortcutItems ?: @[]];
    [items addObject:item];
    [UIApplication sharedApplication].shortcutItems = items;
    [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK] callbackId:command.callbackId];
}

- (void)removeShortcut:(CDVInvokedUrlCommand *)command {
    NSString *shortcutId = command.arguments.count > 0 ? command.arguments[0] : @"";
    NSMutableArray *items = [NSMutableArray array];
    for (UIApplicationShortcutItem *item in [UIApplication sharedApplication].shortcutItems ?: @[]) {
        if (![item.type isEqualToString:shortcutId]) {
            [items addObject:item];
        }
    }
    [UIApplication sharedApplication].shortcutItems = items;
    [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK] callbackId:command.callbackId];
}

- (void)pinShortcut:(CDVInvokedUrlCommand *)command {
    [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK] callbackId:command.callbackId];
}

- (void)requestPermissions:(CDVInvokedUrlCommand *)command {
    CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsArray:@[]];
    [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
}

- (void)requestPermission:(CDVInvokedUrlCommand *)command {
    [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsInt:1] callbackId:command.callbackId];
}

- (void)hasPermission:(CDVInvokedUrlCommand *)command {
    [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsInt:1] callbackId:command.callbackId];
}

- (void)openInBrowser:(CDVInvokedUrlCommand *)command {
    NSString *urlString = command.arguments.count > 0 ? command.arguments[0] : @"";
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"Invalid URL"] callbackId:command.callbackId];
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        if (@available(iOS 10.0, *)) {
            [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
        } else {
            [[UIApplication sharedApplication] openURL:url];
        }
    });

    [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK] callbackId:command.callbackId];
}

- (void)launchApp:(CDVInvokedUrlCommand *)command {
    NSString *app = command.arguments.count > 0 ? command.arguments[0] : @"";
    NSString *data = command.arguments.count > 2 ? command.arguments[2] : @"";

    NSString *urlString = app;
    if (![urlString containsString:@"://"]) {
        urlString = [NSString stringWithFormat:@"%@://%@", app, data ?: @""];
    }

    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"Invalid URL"] callbackId:command.callbackId];
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        if (@available(iOS 10.0, *)) {
            [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
        } else {
            [[UIApplication sharedApplication] openURL:url];
        }
    });

    [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK] callbackId:command.callbackId];
}

- (void)setInputType:(CDVInvokedUrlCommand *)command {
    [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK] callbackId:command.callbackId];
}

- (void)getCordovaIntent:(CDVInvokedUrlCommand *)command {
    NSString *intent = self.lastOpenUrl ?: @"";
    [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:intent] callbackId:command.callbackId];
}

- (void)setIntentHandler:(CDVInvokedUrlCommand *)command {
    self.intentHandlerCallbackId = command.callbackId;
    CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_NO_RESULT];
    [result setKeepCallback:@YES];
    [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
}

- (void)setUiTheme:(CDVInvokedUrlCommand *)command {
    [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK] callbackId:command.callbackId];
}

- (void)getGlobalSetting:(CDVInvokedUrlCommand *)command {
    [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:@""] callbackId:command.callbackId];
}

- (void)getAndroidVersion:(CDVInvokedUrlCommand *)command {
    NSString *version = UIDevice.currentDevice.systemVersion ?: @"";
    [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:version] callbackId:command.callbackId];
}

- (void)getAvailableEncodings:(CDVInvokedUrlCommand *)command {
    CFStringEncoding *encodings = CFStringGetListOfAvailableEncodings();
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    for (CFIndex i = 0; encodings[i] != kCFStringEncodingInvalidId; i++) {
        CFStringEncoding enc = encodings[i];
        NSStringEncoding nsEnc = CFStringConvertEncodingToNSStringEncoding(enc);
        NSString *name = (__bridge_transfer NSString *)CFStringConvertEncodingToIANACharSetName(enc) ?: @"";
        if (name.length == 0) {
            continue;
        }
        result[name] = @{ @"label": name, @"aliases": @[], @"name": name };
        (void)nsEnc;
    }

    [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:result] callbackId:command.callbackId];
}

- (void)decode:(CDVInvokedUrlCommand *)command {
    NSString *content = command.arguments.count > 0 ? command.arguments[0] : @"";
    NSString *charset = command.arguments.count > 1 ? command.arguments[1] : @"UTF-8";

    NSData *data = [[NSData alloc] initWithBase64EncodedString:content options:0];
    NSStringEncoding encoding = CFStringConvertEncodingToNSStringEncoding(CFStringConvertIANACharSetNameToEncoding((__bridge CFStringRef)charset));
    NSString *decoded = [[NSString alloc] initWithData:data encoding:encoding];
    if (!decoded) {
        decoded = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    }
    [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:decoded ?: @""] callbackId:command.callbackId];
}

- (void)encode:(CDVInvokedUrlCommand *)command {
    NSString *content = command.arguments.count > 0 ? command.arguments[0] : @"";
    NSString *charset = command.arguments.count > 1 ? command.arguments[1] : @"UTF-8";

    NSStringEncoding encoding = CFStringConvertEncodingToNSStringEncoding(CFStringConvertIANACharSetNameToEncoding((__bridge CFStringRef)charset));
    NSData *data = [content dataUsingEncoding:encoding] ?: [content dataUsingEncoding:NSUTF8StringEncoding];
    CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsArrayBuffer:data];
    [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
}

- (void)copyToUri:(CDVInvokedUrlCommand *)command {
    NSString *srcString = command.arguments.count > 0 ? command.arguments[0] : @"";
    NSString *destString = command.arguments.count > 1 ? command.arguments[1] : @"";
    NSString *fileName = command.arguments.count > 2 ? command.arguments[2] : @"";

    NSURL *srcURL = [NSURL URLWithString:srcString];
    if (!srcURL || !srcURL.isFileURL) {
        srcURL = [NSURL fileURLWithPath:srcString];
    }

    NSURL *destURL = [NSURL URLWithString:destString];
    if (!destURL || !destURL.isFileURL) {
        destURL = [NSURL fileURLWithPath:destString];
    }

    NSURL *targetURL = [destURL URLByAppendingPathComponent:fileName];
    NSError *error = nil;
    if ([[NSFileManager defaultManager] fileExistsAtPath:targetURL.path]) {
        [[NSFileManager defaultManager] removeItemAtURL:targetURL error:nil];
    }

    BOOL ok = [[NSFileManager defaultManager] copyItemAtURL:srcURL toURL:targetURL error:&error];
    if (!ok || error) {
        [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:error.localizedDescription ?: @"Copy failed"] callbackId:command.callbackId];
        return;
    }
    [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK] callbackId:command.callbackId];
}

@end
