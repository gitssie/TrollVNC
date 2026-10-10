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
@optional
// Production login including native first-use Review. Legacy test/backends
// may implement the basic authentication/trust methods above instead.
- (nullable NSDictionary *)signInStoreAppleID:(NSString *)appleID password:(NSString *)password
    provider:(nullable id<TVAppleVerificationCodeProvider>)provider error:(NSError **)error;
@end
FOUNDATION_EXPORT TVAppleStoreAttempt TVAppleNativeStoreLogin(NSString *appleID, NSString *password, NSError **error);
// Private continuation only: response/context may contain credentials and must
// never enter a public result, log, persisted job or socket response.
FOUNDATION_EXPORT TVAppleStoreAttempt TVAppleNativeStoreLoginForReview(NSString *appleID, NSString *password,
    NSDictionary * _Nullable * _Nullable response, id _Nullable * _Nullable context, NSError **error);
FOUNDATION_EXPORT TVAppleStoreAttempt TVAppleNativeStoreLoginForReviewWithPET(NSString *appleID, NSString *pet,
    NSDictionary * _Nullable * _Nullable response, id _Nullable * _Nullable context, NSError **error);
// Pre-conversion authentication only. Success here does not complete Review.
FOUNDATION_EXPORT TVAppleStoreAttempt TVAppleNativeStoreReviewAuthentication(NSString *appleID, NSString *nativeCredential,
    NSDictionary * _Nullable * _Nullable response, id _Nullable * _Nullable context, NSError **error);
FOUNDATION_EXPORT BOOL TVAppleNativeEstablishTrust(NSString *appleID, NSString *password,
    id<TVAppleVerificationCodeProvider> provider, NSError **error);
// Internal authentication data contains credentials. Pass directly to native
// iCloud registration; never expose it through the public result dictionaries.
FOUNDATION_EXPORT NSDictionary * _Nullable TVAppleNativeAuthenticate(NSString *appleID, NSString *password,
    id<TVAppleVerificationCodeProvider> _Nullable provider, BOOL requireChallenge, NSError **error);
// SMS continuation uses Apple's original phone selection/send/postback machinery.
// The provider only supplies a fresh SMS code; it never fetches an SMS URL.
FOUNDATION_EXPORT NSDictionary * _Nullable TVAppleNativeAuthenticateSMS(NSString *appleID, NSString *password,
    id<TVAppleVerificationCodeProvider> provider, NSError **error);
NS_ASSUME_NONNULL_END
