#import <Cordova/CDVPlugin.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const AcodeIshDefaultRootId;
FOUNDATION_EXPORT NSString *AcodeIshActiveRootPath(void);
FOUNDATION_EXPORT BOOL AcodeIshIsDefaultRootActive(void);

@interface RootfsManager : CDVPlugin
- (void)list:(CDVInvokedUrlCommand *)command;
- (void)importArchive:(CDVInvokedUrlCommand *)command;
- (void)importDirectory:(CDVInvokedUrlCommand *)command;
- (void)activate:(CDVInvokedUrlCommand *)command;
- (void)rename:(CDVInvokedUrlCommand *)command;
- (void)delete:(CDVInvokedUrlCommand *)command;
- (void)getActivePublicHome:(CDVInvokedUrlCommand *)command;
@end

NS_ASSUME_NONNULL_END
