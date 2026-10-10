#import "TVAppleStoreLogin.h"
NS_ASSUME_NONNULL_BEGIN
// Short-lived, in-process native Store continuation. This is NOT a Settings
// AuthKit session; it uses StoreServices for device headers, cookies and signing.
// All returned bytes and URLs are private authentication-bearing material.
@interface TVAppleNativeStoreReviewSession : NSObject
- (nullable instancetype)initWithAuthenticationResponse:(NSDictionary *)response
                                                context:(id)context error:(NSError **)error;
- (nullable NSDictionary *)loadEntry:(NSError **)error;
- (nullable NSDictionary *)loadConversionFields:(NSError **)error;
// US billing fields use Apple's field IDs; paymentMethodType is None. Calling
// validateBilling explicitly authorizes the agreedToTerms=1 field. Only a
// successful server validation enables the single final submission below.
- (nullable NSDictionary *)validateBilling:(NSDictionary *)billing error:(NSError **)error;
- (nullable NSDictionary *)submitConversion:(NSError **)error;
@end
FOUNDATION_EXPORT NSURL * _Nullable TVAppleStoreReviewEntryURL(NSDictionary *response);
NS_ASSUME_NONNULL_END
