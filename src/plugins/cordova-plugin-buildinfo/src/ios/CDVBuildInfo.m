#import "CDVBuildInfo.h"

@implementation CDVBuildInfo

- (void)init:(CDVInvokedUrlCommand *)command {
    NSDictionary *info = [[NSBundle mainBundle] infoDictionary];
    NSString *bundleId = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    NSString *displayName = info[@"CFBundleDisplayName"] ?: info[@"CFBundleName"] ?: @"";
    NSString *name = info[@"CFBundleName"] ?: @"";
    NSString *version = info[@"CFBundleShortVersionString"] ?: @"";
    NSString *build = info[@"CFBundleVersion"] ?: @"";

#ifdef DEBUG
    NSNumber *debug = @YES;
    NSString *buildType = @"debug";
#else
    NSNumber *debug = @NO;
    NSString *buildType = @"release";
#endif

    NSString *installDateString = @"";
    NSString *bundlePath = [[NSBundle mainBundle] bundlePath];
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:bundlePath error:nil];
    NSDate *installDate = attrs[NSFileCreationDate];
    if (installDate) {
        NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss.SSSZZZZZ";
        installDateString = [formatter stringFromDate:installDate] ?: @"";
    }

    NSDictionary *payload = @{
        @"packageName": bundleId,
        @"basePackageName": bundleId,
        @"displayName": displayName,
        @"name": name,
        @"version": version,
        @"versionCode": build,
        @"debug": debug,
        @"buildType": buildType,
        @"flavor": @"",
        @"installDate": installDateString
    };

    CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:payload];
    [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
}

@end
