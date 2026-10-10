#import "TVAppleStoreReview.h"
NS_ASSUME_NONNULL_BEGIN
// One login owns all credentials/Review state. No continuation leaves the process.
@interface TVAppleNativeStoreSignIn : NSObject
- (nullable NSDictionary *)signIn:(NSString *)appleID password:(NSString *)password
    provider:(nullable id<TVAppleVerificationCodeProvider>)provider error:(NSError **)error;
@end
FOUNDATION_EXPORT NSDictionary * _Nullable TVAppleUSStoreBillingAddress(id response, NSError **error);
FOUNDATION_EXPORT BOOL TVAppleStoreConversionSucceeded(NSDictionary *reply);
NS_ASSUME_NONNULL_END
