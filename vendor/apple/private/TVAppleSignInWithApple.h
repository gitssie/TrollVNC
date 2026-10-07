#import "TVAppleSettingsSession.h"
NS_ASSUME_NONNULL_BEGIN
@protocol TVAppleSignInWithAppleBackend <NSObject>
- (nullable NSDictionary *)signInWithAppleAppsForAppleID:(NSString *)appleID error:(NSError **)error;
- (nullable NSDictionary *)stopUsingAppleIDForBundleID:(NSString *)bundleID appleID:(NSString *)appleID error:(NSError **)error;
@end
@interface TVAppleServices (SignInWithAppleWorker)
- (void)enqueueSignInWithApple:(NSString *)appleID bundleID:(nullable NSString *)bundleID mutation:(BOOL)mutation completion:(TVAppleCompletion)completion;
@end
@interface TVAppleNativeSettingsSession (SignInWithApple)
- (nullable NSDictionary *)querySignInWithAppleApps:(NSString *)appleID error:(NSError **)error;
- (nullable NSDictionary *)stopUsingAppleIDForBundleID:(NSString *)bundleID appleID:(NSString *)appleID error:(NSError **)error;
@end
FOUNDATION_EXPORT BOOL TVAppleValidBundleID(id value);
// Internal records include the native detail link. Public results omit it.
FOUNDATION_EXPORT NSArray * _Nullable TVAppleSIWAApplications(id model,NSURL *origin,NSError **error);
FOUNDATION_EXPORT NSMutableURLRequest * _Nullable TVAppleSIWARevokeRequest(id model,NSDictionary *application,NSURL *origin,NSError **error);
// Capture only whitelisted revoke button metadata from the native parser's XML.
FOUNDATION_EXPORT NSDictionary * _Nullable TVAppleSIWAConfirmationFromXML(NSData *xml);
FOUNDATION_EXPORT void TVAppleAttachSIWAConfirmation(id model,NSDictionary *confirmation);
FOUNDATION_EXPORT void TVAppleCaptureSIWAConfirmation(id loader,id model);
NS_ASSUME_NONNULL_END
