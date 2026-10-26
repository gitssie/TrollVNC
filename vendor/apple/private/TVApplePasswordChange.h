#import "TVAppleBackend.h"
NS_ASSUME_NONNULL_BEGIN
@protocol TVApplePasswordChangeBackend <NSObject>
- (nullable NSDictionary *)changePasswordAppleID:(NSString *)appleID password:(NSString *)password
    newPassword:(NSString *)newPassword devicePasscode:(nullable NSString *)passcode
    provider:(nullable id<TVAppleVerificationCodeProvider>)provider error:(NSError **)error;
@end
FOUNDATION_EXPORT BOOL TVAppleValidNewPassword(NSString *value);
FOUNDATION_EXPORT NSDictionary * _Nullable TVAppleNativeChangePassword(NSString *appleID, NSString *password,
    NSString *newPassword, NSString * _Nullable passcode,
    id<TVAppleVerificationCodeProvider> _Nullable provider, NSError **error);
NS_ASSUME_NONNULL_END
