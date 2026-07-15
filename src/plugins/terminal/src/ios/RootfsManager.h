#import <Cordova/CDVPlugin.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const AcodeIshDefaultRootId;
FOUNDATION_EXPORT NSString *AcodeIshDefaultRootPath(void);
FOUNDATION_EXPORT NSString *AcodeIshActiveRootPath(void);
FOUNDATION_EXPORT BOOL AcodeIshIsDefaultRootActive(void);
FOUNDATION_EXPORT BOOL AcodeIshRootfsContainsPath(NSString *rootPath, NSString *fakePath);
FOUNDATION_EXPORT BOOL AcodeIshRootfsIsArm64(NSString *rootPath);
FOUNDATION_EXPORT BOOL AcodeIshRootfsExecutableIsArm64(NSString *rootPath, NSString *fakePath);
FOUNDATION_EXPORT NSString *AcodeIshActiveRootInitPath(void);

@interface RootfsManager : CDVPlugin
- (void)list:(CDVInvokedUrlCommand *)command;
- (void)importArchive:(CDVInvokedUrlCommand *)command;
- (void)importDirectory:(CDVInvokedUrlCommand *)command;
- (void)restoreDefault:(CDVInvokedUrlCommand *)command;
- (void)activate:(CDVInvokedUrlCommand *)command;
- (void)rename:(CDVInvokedUrlCommand *)command;
- (void)setInit:(CDVInvokedUrlCommand *)command;
- (void)delete:(CDVInvokedUrlCommand *)command;
- (void)getActivePublicHome:(CDVInvokedUrlCommand *)command;

/**
 * Validate the active fakefs metadata. External files must be imported rather
 * than moved directly into data/, because meta.db is authoritative.
 */
- (void)reconcileFs:(CDVInvokedUrlCommand *)command;
@end

NS_ASSUME_NONNULL_END
