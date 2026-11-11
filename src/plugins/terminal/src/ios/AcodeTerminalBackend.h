#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^AcodeTerminalOutputHandler)(NSData *data);

/// One terminal session's byte stream, as the WebSocket server and the legacy
/// Cordova callbacks consume it. Output produced while no handler is attached
/// is buffered (bounded) and delivered when one is set.
@protocol AcodeTerminalEndpoint <NSObject>
@property (nonatomic, copy, nullable) AcodeTerminalOutputHandler outputHandler;
- (void)sendInput:(NSData *)input;
- (void)resizeToColumns:(int)columns rows:(int)rows;
@end

/// Events: type "exit" with the decimal exit status as payload, "fatal" with
/// a reason when the runtime itself fails.
typedef void (^AcodeTerminalEventHandler)(NSString *sessionId, NSString *type, NSString *payload);

/// A guest runtime that creates terminal sessions. The iSH bridge and the
/// Kernarium bridge both implement it; Executor talks only to this.
@protocol AcodeTerminalBackend <NSObject>
- (void)startWithCommand:(NSString *)command completion:(void (^)(NSString *sessionId, NSError * _Nullable error))completion;
- (void)writeToSession:(NSString *)sessionId input:(NSString *)input completion:(void (^ _Nullable)(NSError * _Nullable error))completion;
- (void)resizeSession:(NSString *)sessionId columns:(NSInteger)columns rows:(NSInteger)rows completion:(void (^ _Nullable)(NSError * _Nullable error))completion;
- (void)stopSession:(NSString *)sessionId completion:(void (^ _Nullable)(NSError * _Nullable error))completion;
- (void)setEventHandler:(AcodeTerminalEventHandler)handler;
- (nullable id<AcodeTerminalEndpoint>)terminalForSession:(NSString *)sessionId;
@end

/// The process's terminal backend, chosen once. Kernarium is selected when the
/// user default or Info.plist key "AcodeTerminalRuntime" is "kernarium" and a
/// Kernarium runtime framework is embedded; anything else selects iSH.
FOUNDATION_EXPORT id<AcodeTerminalBackend> AcodeActiveTerminalBackend(void);

/// "ish" or "kernarium": the backend AcodeActiveTerminalBackend returns.
FOUNDATION_EXPORT NSString *AcodeActiveTerminalRuntimeName(void);

NS_ASSUME_NONNULL_END
