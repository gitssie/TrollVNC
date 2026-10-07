#import "TVAppleSettingsSession.h"
NS_ASSUME_NONNULL_BEGIN
@protocol TVAppleNameSettingsBackend <NSObject>
- (nullable NSDictionary *)nameSettingsForAppleID:(NSString *)appleID error:(NSError **)error;
- (nullable NSDictionary *)setFirstName:(NSString *)first lastName:(NSString *)last appleID:(NSString *)appleID error:(NSError **)error;
@end
@interface TVAppleServices (NameSettingsWorker)
- (void)enqueueNameSettings:(NSString *)appleID firstName:(nullable NSString *)first lastName:(nullable NSString *)last mutation:(BOOL)mutation completion:(TVAppleCompletion)completion;
@end
@interface TVAppleNativeSettingsSession (NameSettings)
- (nullable NSDictionary *)queryName:(NSString *)appleID error:(NSError **)error;
- (nullable NSDictionary *)setFirstName:(NSString *)first lastName:(NSString *)last appleID:(NSString *)appleID error:(NSError **)error;
@end
FOUNDATION_EXPORT BOOL TVAppleRefreshAuthKitName(id manager,id controller,NSString *appleID,NSString *first,NSString *last,NSTimeInterval timeout,NSError **error);
FOUNDATION_EXPORT BOOL TVAppleValidName(id value);
FOUNDATION_EXPORT NSDictionary * _Nullable TVAppleNameFromPersonalInfo(id model,NSString *appleID,NSError **error);
FOUNDATION_EXPORT NSMutableURLRequest * _Nullable TVAppleNamePostback(id form,NSString *first,NSString *last,NSURL *origin,NSString * _Nullable * _Nullable preservedMiddle,NSError **error);
NS_ASSUME_NONNULL_END
