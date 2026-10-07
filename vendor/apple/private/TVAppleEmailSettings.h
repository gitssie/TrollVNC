#import "TVAppleBackend.h"
NS_ASSUME_NONNULL_BEGIN
@protocol TVAppleEmailSettingsBackend <NSObject>
- (nullable NSDictionary *)emailSettingsForAppleID:(NSString *)appleID error:(NSError **)error;
@end
@interface TVAppleServices (EmailSettingsWorker)
- (void)enqueueEmailSettingsForAppleID:(NSString *)appleID completion:(TVAppleCompletion)completion;
@end
FOUNDATION_EXPORT NSDictionary * _Nullable TVAppleFetchEmailSettings(id manager,id controller,NSString *appleID,NSTimeInterval timeout,NSError **error);
FOUNDATION_EXPORT NSDictionary * _Nullable TVAppleNativeEmailSettings(NSString *appleID,NSError **error);
FOUNDATION_EXPORT NSDictionary * _Nullable TVAppleEmailSettingsFromUserInfo(id info,NSError **error);
NS_ASSUME_NONNULL_END
