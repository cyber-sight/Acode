#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class AcodeIshTerminal;

@interface IshWebSocketServer : NSObject

@property (nonatomic, readonly) in_port_t port;
@property (nonatomic, readonly, getter=isRunning) BOOL running;
@property (nonatomic, copy, nullable) NSString *sessionId;
@property (nonatomic, copy, nullable) void (^disconnectHandler)(void);

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
- (instancetype)initWithTerminal:(AcodeIshTerminal *)terminal NS_DESIGNATED_INITIALIZER;
- (BOOL)startWithError:(NSError **)error;
- (void)stop;

/// Best-effort delivery of one WebSocket text control frame to the connected
/// client. Buffered PTY output is flushed first so trailing bytes are not
/// reordered behind the control frame. No-op when no upgraded client exists.
/// Used for the additive {"type":"exit","status":N} frame on guest exit.
- (void)sendControlFrame:(NSData *)data;

/// Return and clear the buffered PTY output. Must not be called from the
/// server's internal queue; used to migrate a backlog into a replacement
/// server when a dead listener is recreated during reconnect.
- (nullable NSData *)drainOutputBuffer;

/// Seed the output buffer with previously drained bytes before any new PTY
/// output handler is installed, preserving output produced while the old
/// listener was down.
- (void)primeOutputBuffer:(NSData *)data;

@end

NS_ASSUME_NONNULL_END
