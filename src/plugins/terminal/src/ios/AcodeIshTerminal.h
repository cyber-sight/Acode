#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

struct tty;

FOUNDATION_EXPORT void AcodeIshInstallConsoleDriver(void);

typedef void (^AcodeIshTerminalOutputHandler)(NSData *data);

@interface AcodeIshTerminal : NSObject

@property (nonatomic, readonly) NSUUID *uuid;
@property (nonatomic, copy, nullable) AcodeIshTerminalOutputHandler outputHandler;

+ (nullable instancetype)createPseudoTerminal:(struct tty * _Nullable * _Nonnull)tty;
- (void)sendInput:(NSData *)input;
- (void)resizeToColumns:(int)columns rows:(int)rows;
- (void)destroy;

@end

NS_ASSUME_NONNULL_END
