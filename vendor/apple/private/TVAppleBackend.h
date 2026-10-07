#import "TVAppleServices.h"

NS_ASSUME_NONNULL_BEGIN
// Internal injection boundary. Called only on the module's serial worker.
// Snapshot records: identifier, domain(icloud/identity/media), apple_id,
// selected(primary cloud/all identity/active media), find_my, enabled_dataclasses.
@protocol TVAppleBackend <NSObject>
- (nullable NSDictionary *)snapshot:(NSError **)error;
// Preflight every target BEFORE the first mutation. Return opaque prepared context.
- (nullable id)prepareAccount:(NSDictionary *)account policy:(TVAppleLocalDataPolicy)policy error:(NSError **)error;
// Must recheck identifier, target identity, active/primary status and Find My.
- (BOOL)removePreparedAccount:(id)prepared error:(NSError **)error;
@end
@interface TVAppleServices (Testing)
- (instancetype)initWithBackend:(id<TVAppleBackend>)backend
                 callbackQueue:(dispatch_queue_t)callbackQueue
           verificationTimeout:(NSTimeInterval)timeout;
@end
FOUNDATION_EXPORT id<TVAppleBackend> TVAppleCreateNativeBackend(void);
FOUNDATION_EXPORT NSError *TVAppleError(TVAppleErrorCode code, NSString *message);
NS_ASSUME_NONNULL_END
