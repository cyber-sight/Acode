#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface IshBackgroundRuntime : NSObject

+ (instancetype)shared;
- (void)sessionDidStart:(NSString *)sessionId;
- (void)sessionDidEnd:(NSString *)sessionId;

@end

NS_ASSUME_NONNULL_END
