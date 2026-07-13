#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^IshEventHandler)(NSString *sessionId, NSString *type, NSString *payload);

@interface IshBridge : NSObject

+ (instancetype)shared;

- (void)startWithCommand:(NSString *)command completion:(void (^)(NSString *sessionId, NSError * _Nullable error))completion;
- (void)writeToSession:(NSString *)sessionId input:(NSString *)input completion:(void (^ _Nullable)(NSError * _Nullable error))completion;
- (void)resizeSession:(NSString *)sessionId columns:(NSInteger)columns rows:(NSInteger)rows completion:(void (^ _Nullable)(NSError * _Nullable error))completion;
- (void)stopSession:(NSString *)sessionId completion:(void (^ _Nullable)(NSError * _Nullable error))completion;

- (void)setEventHandler:(IshEventHandler)handler;

/** Replace the Documents copy of the bundled default rootfs before the kernel
 * mounts it. Completion is delivered on the main queue. */
- (void)restoreDefaultRootfsWithCompletion:(void (^)(NSError * _Nullable error))completion;

/**
 * Validate the active fakefs metadata and checkpoint it when the kernel has
 * not mounted it yet. Host-side files must be imported through RootfsManager;
 * this method intentionally does not synthesize metadata records.
 */
- (BOOL)reconcileFs:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
