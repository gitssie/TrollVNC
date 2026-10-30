#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface TVAppStateServices : NSObject
- (nullable NSDictionary *)accessTokenForBundle:(NSString *)bundleID error:(NSError **)error;
// Persistent facade; scoped native operations run in disposable exact-group workers.
- (void)executeBundle:(NSString *)bundleID request:(NSDictionary *)request
           completion:(void (^)(NSDictionary * _Nullable, NSError * _Nullable))completion;
- (void)executeBundle:(NSString *)bundleID request:(NSDictionary *)request
            progress:(void (^ _Nullable)(NSDictionary *event))progress
           completion:(void (^)(NSDictionary * _Nullable, NSError * _Nullable))completion;
@end
// External method/params -> validated native session request. Never accepts paths/scopes.
FOUNDATION_EXPORT NSDictionary * _Nullable TVASRequest(NSString *method, NSDictionary *params, NSError **error);
FOUNDATION_EXPORT NSDictionary * _Nullable TVASResult(NSDictionary *result, NSString *bundleID, NSError **error);
// Shadow helper transport. The root argument is retained for ABI compatibility and ignored.
// Upload stages one bounded pair; only Shadow publishes the validated transaction.
FOUNDATION_EXPORT NSData * _Nullable TVASReadShadowPart(NSString *root, NSDictionary *params, NSError **error);
FOUNDATION_EXPORT NSDictionary * _Nullable TVASWriteShadowPart(NSString *root, NSDictionary *params, NSError **error);
NS_ASSUME_NONNULL_END
