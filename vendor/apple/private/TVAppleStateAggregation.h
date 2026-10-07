#import "TVAppleBackend.h"
NS_ASSUME_NONNULL_BEGIN
// Synchronous backend aggregation; called only from the serialized account worker.
FOUNDATION_EXPORT NSDictionary * _Nullable TVAppleAggregateState(id<TVAppleBackend> backend,NSError **error);
NS_ASSUME_NONNULL_END
