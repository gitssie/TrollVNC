#import "TVAppleBackend.h"
NS_ASSUME_NONNULL_BEGIN
// Synchronous worker entry: independent native profile sessions run concurrently.
// Initial/final account snapshots still bracket all profile reads.
FOUNDATION_EXPORT NSDictionary * _Nullable TVAppleAggregateState(id<TVAppleBackend> backend,NSError **error);
FOUNDATION_EXPORT NSDictionary *TVAppleAccountState(NSDictionary *state);
NS_ASSUME_NONNULL_END
