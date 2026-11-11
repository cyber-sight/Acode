#import <Foundation/Foundation.h>
#import "AcodeTerminalBackend.h"

@class AcodeIshTerminal;

NS_ASSUME_NONNULL_BEGIN

typedef AcodeTerminalEventHandler IshEventHandler;

@interface IshBridge : NSObject <AcodeTerminalBackend>

+ (instancetype)shared;

- (void)startWithCommand:(NSString *)command completion:(void (^)(NSString *sessionId, NSError * _Nullable error))completion;
- (void)writeToSession:(NSString *)sessionId input:(NSString *)input completion:(void (^ _Nullable)(NSError * _Nullable error))completion;
- (void)resizeSession:(NSString *)sessionId columns:(NSInteger)columns rows:(NSInteger)rows completion:(void (^ _Nullable)(NSError * _Nullable error))completion;
- (void)stopSession:(NSString *)sessionId completion:(void (^ _Nullable)(NSError * _Nullable error))completion;

- (void)setEventHandler:(IshEventHandler)handler;

/** Replace the Documents copy of the bundled default rootfs before the kernel
 * mounts it. Completion is delivered on the main queue. */
- (void)restoreDefaultRootfsWithCompletion:(void (^)(NSError * _Nullable error))completion;

/** Return the AcodeIshTerminal for an active session. */
- (nullable AcodeIshTerminal *)terminalForSession:(NSString *)sessionId;

/// Invoked when the iSH emulator raises its fatal die_handler. Notifies each
/// live session through the event handler ("fatal"), then clears session
/// bookkeeping and latches the bridge so further spawns fail fast until the
/// app restarts. Safe to call from any thread.
- (void)notifyFatalEmulatorErrorWithReason:(NSString *)reason;

/**
 * Validate the active fakefs metadata and checkpoint it when the kernel has
 * not mounted it yet. Host-side files must be imported through RootfsManager;
 * this method intentionally does not synthesize metadata records.
 */
- (BOOL)reconcileFs:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
