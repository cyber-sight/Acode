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

@end

NS_ASSUME_NONNULL_END
