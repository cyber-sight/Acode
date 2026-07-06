#import "System.h"
#import <Cordova/CDVPluginResult.h>
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <UserNotifications/UserNotifications.h>
#import <SafariServices/SafariServices.h>
#import <AVFoundation/AVFoundation.h>
#import <Photos/Photos.h>
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

- (void)pluginInitialize {
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleOpenURL:) name:CDVPluginHandleOpenURLNotification object:nil];
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

- (void)isManageExternalStorageDeclared:(CDVInvokedUrlCommand *)command {
    [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:@"false"] callbackId:command.callbackId];
}

- (void)hasGrantedStorageManager:(CDVInvokedUrlCommand *)command {
    [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:@"false"] callbackId:command.callbackId];
}

- (void)requestStorageManager:(CDVInvokedUrlCommand *)command {
    [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:@"false"] callbackId:command.callbackId];
}

- (void)isExternalStorageManager:(CDVInvokedUrlCommand *)command {
    [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:@"false"] callbackId:command.callbackId];
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

- (void)getInstaller:(CDVInvokedUrlCommand *)command {
    [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:@"app-store"] callbackId:command.callbackId];
}

- (void)shareText:(CDVInvokedUrlCommand *)command {
    NSString *text = command.arguments.count > 0 ? command.arguments[0] : @"";
    UIActivityViewController *controller = [[UIActivityViewController alloc] initWithActivityItems:@[text] applicationActivities:nil];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.viewController presentViewController:controller animated:YES completion:nil];
    });
    [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK] callbackId:command.callbackId];
}

- (void)getRewardStatus:(CDVInvokedUrlCommand *)command {
    NSDictionary *status = @{ @"isAdFree": @YES, @"source": @"ios" };
    [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:status] callbackId:command.callbackId];
}

- (void)redeemReward:(CDVInvokedUrlCommand *)command {
    NSDictionary *status = @{ @"success": @NO, @"message": @"Rewards are not supported on iOS." };
    [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:status] callbackId:command.callbackId];
}

- (void)extractAsset:(CDVInvokedUrlCommand *)command {
    NSString *assetName = command.arguments.count > 0 ? command.arguments[0] : @"";
    NSString *destinationPath = command.arguments.count > 1 ? command.arguments[1] : @"";
    NSString *sourcePath = [[NSBundle mainBundle] pathForResource:assetName ofType:nil];

    if (sourcePath.length == 0 || destinationPath.length == 0) {
        [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"Asset or destination path is missing"] callbackId:command.callbackId];
        return;
    }

    NSError *error = nil;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *parent = [destinationPath stringByDeletingLastPathComponent];
    if (parent.length > 0) {
        [fm createDirectoryAtPath:parent withIntermediateDirectories:YES attributes:nil error:nil];
    }
    if ([fm fileExistsAtPath:destinationPath]) {
        [fm removeItemAtPath:destinationPath error:nil];
    }

    BOOL ok = [fm copyItemAtPath:sourcePath toPath:destinationPath error:&error];
    if (!ok || error) {
        [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:error.localizedDescription ?: @"Asset extraction failed"] callbackId:command.callbackId];
        return;
    }

    [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK] callbackId:command.callbackId];
}

- (void)setNativeContextMenuDisabled:(CDVInvokedUrlCommand *)command {
    [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK] callbackId:command.callbackId];
}

- (void)compareFileText:(CDVInvokedUrlCommand *)command {
    NSString *fileUri = command.arguments.count > 0 ? command.arguments[0] : @"";
    NSString *currentText = command.arguments.count > 2 ? command.arguments[2] : @"";
    NSURL *url = [NSURL URLWithString:fileUri];
    if (!url || !url.isFileURL) {
        url = [NSURL fileURLWithPath:fileUri];
    }

    NSError *error = nil;
    NSString *fileText = [NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:&error];
    if (error || !fileText) {
        [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:error.localizedDescription ?: @"Unable to read file"] callbackId:command.callbackId];
        return;
    }

    int differs = [fileText isEqualToString:currentText] ? 0 : 1;
    [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsInt:differs] callbackId:command.callbackId];
}

- (void)compareTexts:(CDVInvokedUrlCommand *)command {
    NSString *text1 = command.arguments.count > 0 ? command.arguments[0] : @"";
    NSString *text2 = command.arguments.count > 1 ? command.arguments[1] : @"";
    int differs = [text1 isEqualToString:text2] ? 0 : 1;
    [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsInt:differs] callbackId:command.callbackId];
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

- (void)getWebkitInfo:(CDVInvokedUrlCommand *)command {
    [self getWebviewInfo:command];
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

- (void)getConfiguration:(CDVInvokedUrlCommand *)command {
    UIInterfaceOrientation orientation = UIInterfaceOrientationUnknown;
    UIWindowScene *windowScene = nil;

    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:UIWindowScene.class] && scene.activationState == UISceneActivationStateForegroundActive) {
            windowScene = (UIWindowScene *)scene;
            break;
        }
    }

    if (windowScene) {
        orientation = windowScene.interfaceOrientation;
    }

    NSInteger orientationValue = UIInterfaceOrientationIsLandscape(orientation) ? 2 : 1;
    NSDictionary *payload = @{
        @"hardKeyboardHidden": @2,
        @"navigationHidden": @2,
        @"keyboardHidden": @1,
        @"keyboardHeight": @0,
        @"orientation": @(orientationValue),
        @"navigation": @0,
        @"fontScale": @1,
        @"keyboard": @0,
        @"locale": NSLocale.currentLocale.localeIdentifier ?: @"en_US"
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
    id permsArg = command.arguments.count > 0 ? command.arguments[0] : @[];
    NSArray *permissions = [permsArg isKindOfClass:[NSArray class]] ? permsArg : @[];
    NSMutableArray *denied = [NSMutableArray array];

    dispatch_group_t group = dispatch_group_create();
    BOOL needsNotification = NO;
    BOOL needsCamera = NO;
    BOOL needsMicrophone = NO;
    BOOL needsPhotos = NO;
    for (NSString *perm in permissions) {
        if ([self isNotificationPermission:perm]) {
            needsNotification = YES;
        } else if ([self isCameraPermission:perm]) {
            needsCamera = YES;
        } else if ([self isMicrophonePermission:perm]) {
            needsMicrophone = YES;
        } else if ([self isPhotoPermission:perm]) {
            needsPhotos = YES;
        } else if ([self isStoragePermission:perm]) {
            continue;
        } else {
            [denied addObject:perm ?: @""];
        }
    }

    if (needsNotification) {
        dispatch_group_enter(group);
        [self requestNotificationPermission:^(BOOL granted) {
            if (!granted) {
                [denied addObject:@"android.permission.POST_NOTIFICATIONS"];
            }
            dispatch_group_leave(group);
        }];
    }

    if (needsCamera) {
        dispatch_group_enter(group);
        [self requestCameraPermission:^(BOOL granted) {
            if (!granted) {
                [denied addObject:@"android.permission.CAMERA"];
            }
            dispatch_group_leave(group);
        }];
    }

    if (needsMicrophone) {
        dispatch_group_enter(group);
        [self requestMicrophonePermission:^(BOOL granted) {
            if (!granted) {
                [denied addObject:@"android.permission.RECORD_AUDIO"];
            }
            dispatch_group_leave(group);
        }];
    }

    if (needsPhotos) {
        dispatch_group_enter(group);
        [self requestPhotoPermission:^(BOOL granted) {
            if (!granted) {
                [denied addObject:@"android.permission.READ_EXTERNAL_STORAGE"];
            }
            dispatch_group_leave(group);
        }];
    }

    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsArray:denied];
        [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
    });
}

- (void)requestPermission:(CDVInvokedUrlCommand *)command {
    NSString *permission = command.arguments.count > 0 ? command.arguments[0] : @"";
    if ([self isNotificationPermission:permission]) {
        [self requestNotificationPermission:^(BOOL granted) {
            CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsInt:(granted ? 1 : 0)];
            [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
        }];
        return;
    }

    if ([self isCameraPermission:permission]) {
        [self requestCameraPermission:^(BOOL granted) {
            CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsInt:(granted ? 1 : 0)];
            [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
        }];
        return;
    }

    if ([self isMicrophonePermission:permission]) {
        [self requestMicrophonePermission:^(BOOL granted) {
            CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsInt:(granted ? 1 : 0)];
            [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
        }];
        return;
    }

    if ([self isPhotoPermission:permission]) {
        [self requestPhotoPermission:^(BOOL granted) {
            CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsInt:(granted ? 1 : 0)];
            [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
        }];
        return;
    }

    if ([self isStoragePermission:permission]) {
        [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsInt:1] callbackId:command.callbackId];
        return;
    }

    [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsInt:0] callbackId:command.callbackId];
}

- (void)hasPermission:(CDVInvokedUrlCommand *)command {
    NSString *permission = command.arguments.count > 0 ? command.arguments[0] : @"";
    if ([self isNotificationPermission:permission]) {
        [self notificationPermissionStatus:^(BOOL granted) {
            CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsInt:(granted ? 1 : 0)];
            [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
        }];
        return;
    }

    if ([self isCameraPermission:permission]) {
        AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
        BOOL granted = status == AVAuthorizationStatusAuthorized;
        [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsInt:(granted ? 1 : 0)] callbackId:command.callbackId];
        return;
    }

    if ([self isMicrophonePermission:permission]) {
        AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];
        BOOL granted = status == AVAuthorizationStatusAuthorized;
        [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsInt:(granted ? 1 : 0)] callbackId:command.callbackId];
        return;
    }

    if ([self isPhotoPermission:permission]) {
        PHAuthorizationStatus status = [PHPhotoLibrary authorizationStatus];
        BOOL granted = status == PHAuthorizationStatusAuthorized || status == PHAuthorizationStatusLimited;
        [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsInt:(granted ? 1 : 0)] callbackId:command.callbackId];
        return;
    }

    if ([self isStoragePermission:permission]) {
        [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsInt:1] callbackId:command.callbackId];
        return;
    }

    [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsInt:0] callbackId:command.callbackId];
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

- (void)inAppBrowser:(CDVInvokedUrlCommand *)command {
    NSString *urlString = command.arguments.count > 0 ? command.arguments[0] : @"";
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"Invalid URL"] callbackId:command.callbackId];
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        if (@available(iOS 9.0, *)) {
            SFSafariViewController *safari = [[SFSafariViewController alloc] initWithURL:url];
            [self.viewController presentViewController:safari animated:YES completion:nil];
        } else {
            [[UIApplication sharedApplication] openURL:url];
        }
    });

    CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_NO_RESULT];
    [result setKeepCallback:@YES];
    [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
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

- (void)manageAllFiles:(CDVInvokedUrlCommand *)command {
    [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK] callbackId:command.callbackId];
}

- (void)getAndroidVersion:(CDVInvokedUrlCommand *)command {
    NSString *version = UIDevice.currentDevice.systemVersion ?: @"";
    [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:version] callbackId:command.callbackId];
}

- (void)getAvailableEncodings:(CDVInvokedUrlCommand *)command {
    const CFStringEncoding *encodings = CFStringGetListOfAvailableEncodings();
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    for (CFIndex i = 0; encodings[i] != kCFStringEncodingInvalidId; i++) {
        CFStringEncoding enc = encodings[i];
        CFStringRef ianaName = CFStringConvertEncodingToIANACharSetName(enc);
        NSString *name = ianaName ? (__bridge NSString *)ianaName : @"";
        if (name.length == 0) {
            continue;
        }
        result[name] = @{ @"label": name, @"aliases": @[], @"name": name };
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

- (BOOL)isNotificationPermission:(NSString *)permission {
    return [permission isKindOfClass:[NSString class]] && [permission isEqualToString:@"android.permission.POST_NOTIFICATIONS"];
}

- (BOOL)isStoragePermission:(NSString *)permission {
    if (![permission isKindOfClass:[NSString class]]) {
        return NO;
    }
    return [permission isEqualToString:@"android.permission.READ_EXTERNAL_STORAGE"] ||
        [permission isEqualToString:@"android.permission.WRITE_EXTERNAL_STORAGE"] ||
        [permission isEqualToString:@"android.permission.MANAGE_EXTERNAL_STORAGE"];
}

- (BOOL)isCameraPermission:(NSString *)permission {
    return [permission isKindOfClass:[NSString class]] && [permission isEqualToString:@"android.permission.CAMERA"];
}

- (BOOL)isMicrophonePermission:(NSString *)permission {
    return [permission isKindOfClass:[NSString class]] && [permission isEqualToString:@"android.permission.RECORD_AUDIO"];
}

- (BOOL)isPhotoPermission:(NSString *)permission {
    return [permission isKindOfClass:[NSString class]] &&
        ([permission isEqualToString:@"android.permission.READ_MEDIA_IMAGES"] || [permission isEqualToString:@"android.permission.READ_EXTERNAL_STORAGE"]);
}

- (void)requestNotificationPermission:(void (^)(BOOL granted))completion {
    if (@available(iOS 10.0, *)) {
        UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
        [center requestAuthorizationWithOptions:(UNAuthorizationOptionAlert | UNAuthorizationOptionSound | UNAuthorizationOptionBadge)
                              completionHandler:^(BOOL granted, NSError * _Nullable error) {
            if (completion) {
                completion(granted && error == nil);
            }
        }];
    } else {
        if (completion) {
            completion(YES);
        }
    }
}

- (void)requestCameraPermission:(void (^)(BOOL granted))completion {
    AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
    if (status == AVAuthorizationStatusAuthorized) {
        completion(YES);
        return;
    }
    [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL granted) {
        completion(granted);
    }];
}

- (void)requestMicrophonePermission:(void (^)(BOOL granted))completion {
    AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];
    if (status == AVAuthorizationStatusAuthorized) {
        completion(YES);
        return;
    }
    [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL granted) {
        completion(granted);
    }];
}

- (void)requestPhotoPermission:(void (^)(BOOL granted))completion {
    PHAuthorizationStatus status = [PHPhotoLibrary authorizationStatus];
    if (status == PHAuthorizationStatusAuthorized || status == PHAuthorizationStatusLimited) {
        completion(YES);
        return;
    }
    [PHPhotoLibrary requestAuthorization:^(PHAuthorizationStatus status) {
        BOOL granted = status == PHAuthorizationStatusAuthorized || status == PHAuthorizationStatusLimited;
        completion(granted);
    }];
}

- (void)notificationPermissionStatus:(void (^)(BOOL granted))completion {
    if (@available(iOS 10.0, *)) {
        UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
        [center getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings * _Nonnull settings) {
            BOOL granted = settings.authorizationStatus == UNAuthorizationStatusAuthorized ||
                settings.authorizationStatus == UNAuthorizationStatusProvisional ||
                settings.authorizationStatus == UNAuthorizationStatusEphemeral;
            if (completion) {
                completion(granted);
            }
        }];
    } else {
        if (completion) {
            completion(YES);
        }
    }
}

@end
