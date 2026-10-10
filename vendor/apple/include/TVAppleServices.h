#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT NSString *const TVAppleErrorDomain;
// Only module-authored diagnostic text; native userInfo and descriptions are excluded.
FOUNDATION_EXPORT NSString * _Nullable TVAppleDiagnosticMessage(NSError *error);
typedef NS_ENUM(NSInteger, TVAppleErrorCode) {
    TVAppleErrorUnsupported = 1,
    TVAppleErrorPermissionDenied,
    TVAppleErrorInvalidRequest,
    TVAppleErrorFindMyEnabled,
    TVAppleErrorBackendRead,
    TVAppleErrorOutcomeUnknown,
    TVAppleErrorConflict,
    TVAppleErrorAuthenticationFailed,
    TVAppleErrorVerificationCode,
    TVAppleErrorAccountNeedsReview,
};
typedef NS_ENUM(NSInteger, TVAppleLocalDataPolicy) {
    TVAppleLocalDataRemove = 1,
    // Explicitly permits the system's MergeSyncDataIntoLocalData action.
    TVAppleLocalDataKeep = 2,
};
typedef void (^TVAppleCompletion)(NSDictionary * _Nullable result, NSError * _Nullable error);
typedef void (^TVAppleCodeCompletion)(NSString * _Nullable code, NSError * _Nullable error);

// Providers must be asynchronous and reply once. Never call account methods to
// produce a code: the serialized account operation is waiting for this reply.
@protocol TVAppleVerificationCodeProvider <NSObject>
- (void)prepareForAuthentication:(void (^)(NSError * _Nullable error))completion;
- (void)requestCodeForChallenge:(NSDictionary *)challenge completion:(TVAppleCodeCompletion)completion;
@optional
// Invalidates any pending challenge when native authentication finishes or times out.
- (void)cancelAuthentication;
@end

// Two separate steps: receive a challenge, then submit its code externally.
// This object performs no networking, polling or credential storage.
@interface TVAppleManualCodeProvider : NSObject <TVAppleVerificationCodeProvider>
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
- (instancetype)initWithChallengeHandler:(void (^)(NSDictionary *challenge))handler;
- (BOOL)submitCode:(NSString *)code forChallengeID:(NSString *)challengeID
             error:(NSError * _Nullable * _Nullable)error;
- (BOOL)cancelChallengeID:(NSString *)challengeID error:(NSError * _Nullable * _Nullable)error;
@end

// Foundation-only API. All calls are asynchronous; callbacks run on callbackQueue.
// Results contain JSON-compatible values, never credentials or authentication tokens.
@interface TVAppleServices : NSObject
- (instancetype)init;
- (instancetype)initWithCallbackQueue:(dispatch_queue_t)callbackQueue;
// Account snapshot plus domain summaries and fresh name/email sections.
// Optional profile errors are reported in sections; unreadable account state fails the call.
- (void)queryAccountState:(TVAppleCompletion)completion;
- (void)queryState:(TVAppleCompletion)completion;
- (void)signOutAppStoreAppleID:(NSString *)appleID completion:(TVAppleCompletion)completion;
- (void)signOutAppleID:(NSString *)appleID
      localDataPolicy:(TVAppleLocalDataPolicy)policy
           completion:(TVAppleCompletion)completion;
- (void)signInAppStoreAppleID:(NSString *)appleID
                   password:(NSString *)password
   verificationCodeProvider:(nullable id<TVAppleVerificationCodeProvider>)provider
                 completion:(TVAppleCompletion)completion;
@end

@interface TVAppleServices (FindMy)
- (void)disableFindMyAppleID:(NSString *)appleID
                  password:(NSString *)password
                completion:(TVAppleCompletion)completion;
@end

@interface TVAppleServices (ICloudSignOut)
// Removes only the target primary iCloud account; reports actual resulting state.
- (void)signOutICloudAppleID:(NSString *)appleID
           localDataPolicy:(TVAppleLocalDataPolicy)policy
                completion:(TVAppleCompletion)completion;
@end
@interface TVAppleServices (ICloudEnablement)
// Device passcode is supplied by the host's existing local configuration; never stored here.
// Native CDP verification is required. Find My activation is explicitly disabled.
- (void)enableICloudAppleID:(NSString *)appleID
                 password:(NSString *)password
           devicePasscode:(NSString *)passcode
 verificationCodeProvider:(nullable id<TVAppleVerificationCodeProvider>)provider
               completion:(TVAppleCompletion)completion;
@end
@interface TVAppleServices (EmailSettings)
// Fresh native server information for the selected phone identity; no tokens exported.
- (void)queryAppleIDEmailSettings:(NSString *)appleID completion:(TVAppleCompletion)completion;
@end
@interface TVAppleServices (EmailActions)
// The external caller supplies the email verification code in a separate call.
- (void)beginAddingContactEmail:(NSString *)email appleID:(NSString *)appleID completion:(TVAppleCompletion)completion;
- (void)verifyContactEmailChallenge:(NSString *)challengeID code:(NSString *)code appleID:(NSString *)appleID completion:(TVAppleCompletion)completion;
// Changes the common Sign in with Apple relay destination, not iCloud Mail.
- (void)setSignInWithAppleForwardingEmail:(NSString *)email appleID:(NSString *)appleID completion:(TVAppleCompletion)completion;
@end
@interface TVAppleServices (NameSettings)
- (void)queryAppleIDNameSettings:(NSString *)appleID completion:(TVAppleCompletion)completion;
// Both names are explicit; the native form's middle name is preserved.
- (void)setAppleIDFirstName:(NSString *)firstName lastName:(NSString *)lastName appleID:(NSString *)appleID completion:(TVAppleCompletion)completion;
@end
@interface TVAppleServices (SignInWithApple)
- (void)querySignInWithAppleApps:(NSString *)appleID completion:(TVAppleCompletion)completion;
// Stops the native application grant, not the device Apple ID or the App's own session.
- (void)stopUsingAppleIDForBundleID:(NSString *)bundleID appleID:(NSString *)appleID completion:(TVAppleCompletion)completion;
@end
NS_ASSUME_NONNULL_END

// iCloud companion device management. Always preserves the native current device.
@interface TVAppleServices (ICloudDevices)
- (void)queryICloudDevices:(NSString * _Nonnull)appleID completion:(TVAppleCompletion _Nonnull)completion;
- (void)removeOtherICloudDevices:(NSString * _Nonnull)appleID completion:(TVAppleCompletion _Nonnull)completion;
@end
