#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

struct tty;

FOUNDATION_EXPORT void AcodeIshInstallConsoleDriver(void);

typedef void (^AcodeIshTerminalOutputHandler)(NSData *data);

@interface AcodeIshTerminal : NSObject

@property (nonatomic, readonly) NSUUID *uuid;
/** Guest pid of this session's leader task. Each session is created through
 * become_new_init_child, whose construct_task calls task_setsid, so the pid
 * is also the process group id. The bridge captures it after do_execve so an
 * explicit stop can signal guest processes that tty_hangup never reaches. */
@property (nonatomic, assign) int sessionLeaderPid;
@property (nonatomic, copy, nullable) AcodeIshTerminalOutputHandler outputHandler;

+ (nullable instancetype)createPseudoTerminal:(struct tty * _Nullable * _Nonnull)tty;
- (void)sendInput:(NSData *)input;
- (void)resizeToColumns:(int)columns rows:(int)rows;
/** Raise SIGHUP on the guest foreground process group (falling back to the
 * stored leader's own group). Must run on the iSH kernel queue because it
 * mutates kernel signal state. Does not destroy the PTY; call -destroy after. */
- (void)terminateGuest;
- (void)destroy;

@end

NS_ASSUME_NONNULL_END
