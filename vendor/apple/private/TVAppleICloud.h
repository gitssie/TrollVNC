#import "TVAppleBackend.h"
NS_ASSUME_NONNULL_BEGIN
@protocol TVAppleICloudBackend <NSObject>
- (BOOL)enableICloudAppleID:(NSString *)appleID password:(NSString *)password
            devicePasscode:(NSString *)passcode
                  provider:(nullable id<TVAppleVerificationCodeProvider>)provider error:(NSError **)error;
@end
FOUNDATION_EXPORT BOOL TVAppleNativeEnableICloud(NSString *appleID, NSString *password,
    NSString *passcode, id<TVAppleVerificationCodeProvider> _Nullable provider, NSError **error);
// Production flow runner; injectable flow/deadline permit native callback regression tests.
FOUNDATION_EXPORT BOOL TVAppleRunICloudFlow(id flow, NSDictionary *authentication,
    NSString *passcode, NSTimeInterval timeout, NSError **error);
@interface TVAppleServices (ICloudWorker)
- (void)enqueueEnableICloudAppleID:(NSString *)appleID password:(NSString *)password
                   devicePasscode:(NSString *)passcode
                         provider:(nullable id<TVAppleVerificationCodeProvider>)provider
                       completion:(TVAppleCompletion)completion;
@end
NS_ASSUME_NONNULL_END
