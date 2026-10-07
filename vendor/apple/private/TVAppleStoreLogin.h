#import "TVAppleBackend.h"
NS_ASSUME_NONNULL_BEGIN
typedef NS_ENUM(NSInteger, TVAppleStoreAttempt) {
    TVAppleStoreAttemptSucceeded,
    TVAppleStoreAttemptNeedsTrust,
    TVAppleStoreAttemptFailed,
    TVAppleStoreAttemptUnknown,
};
@protocol TVAppleStoreLoginBackend <NSObject>
- (TVAppleStoreAttempt)authenticateStoreAppleID:(NSString *)appleID password:(NSString *)password error:(NSError **)error;
- (BOOL)establishTrustForAppleID:(NSString *)appleID password:(NSString *)password
                      provider:(id<TVAppleVerificationCodeProvider>)provider error:(NSError **)error;
@end
FOUNDATION_EXPORT TVAppleStoreAttempt TVAppleNativeStoreLogin(NSString *appleID, NSString *password, NSError **error);
FOUNDATION_EXPORT BOOL TVAppleNativeEstablishTrust(NSString *appleID, NSString *password,
    id<TVAppleVerificationCodeProvider> provider, NSError **error);
// Internal authentication data contains credentials. Pass directly to native
// iCloud registration; never expose it through the public result dictionaries.
FOUNDATION_EXPORT NSDictionary * _Nullable TVAppleNativeAuthenticate(NSString *appleID, NSString *password,
    id<TVAppleVerificationCodeProvider> _Nullable provider, BOOL requireChallenge, NSError **error);
NS_ASSUME_NONNULL_END
