#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^IshEventHandler)(NSString *sessionId, NSString *type, NSString *payload);

@interface IshBridge : NSObject

+ (instancetype)shared;

- (void)startWithCommand:(NSString *)command completion:(void (^)(NSString *sessionId, NSError * _Nullable error))completion;
- (void)writeToSession:(NSString *)sessionId input:(NSString *)input completion:(void (^)(NSError * _Nullable error))completion;
- (void)resizeSession:(NSString *)sessionId columns:(NSInteger)columns rows:(NSInteger)rows completion:(void (^)(NSError * _Nullable error))completion;
- (void)stopSession:(NSString *)sessionId completion:(void (^)(NSError * _Nullable error))completion;

- (void)setEventHandler:(IshEventHandler)handler;

/**
 * Reconcile metadata: scans the active rootfs data/ directory and registers
 * any files that exist on disk but are missing from meta.db. Also removes
 * stale entries for files that no longer exist.
 *
 * Call this after files are added or removed outside of iSH (e.g. via Finder).
 * Returns YES on success.
 */
- (BOOL)reconcileFs:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
