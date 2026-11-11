#import <Foundation/Foundation.h>
#import "AcodeTerminalBackend.h"

NS_ASSUME_NONNULL_BEGIN

/// The vsock port acode-vsock-pty listens on inside the guest
/// (src/plugins/terminal/kernarium/build-guest-image.sh).
FOUNDATION_EXPORT const uint32_t AcodeKernariumAgentPort;

/// One terminal session: a vsock stream to the guest agent, framed as
/// src/plugins/terminal/kernarium/guest/acode-vsock-pty.c describes.
@interface KernariumTerminal : NSObject <AcodeTerminalEndpoint>
@property (nonatomic, readonly) NSString *sessionId;
@end

/// Terminal backend that runs a real Linux guest through a Kernarium runtime
/// framework (KRuntime_6_18_4K) embedded in the app. The guest boots on the
/// first session and lives until the app process ends; every session is one
/// vsock connection to the guest's PTY agent.
@interface KernariumBridge : NSObject <AcodeTerminalBackend>

+ (instancetype)shared;

/// Whether a Linux Kernarium runtime framework is embedded in the app.
+ (BOOL)isRuntimeAvailable;

/// The last lines the guest wrote to its console, for diagnostics.
- (NSString *)recentConsoleOutput;

- (nullable KernariumTerminal *)terminalForSession:(NSString *)sessionId;

@end

NS_ASSUME_NONNULL_END
