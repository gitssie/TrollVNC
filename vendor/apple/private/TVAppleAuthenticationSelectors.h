#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
// Minimal ABI declarations independently authored from runtime inspection.
@interface NSObject (TVAppleAuthenticationSelectors)
+ (id)contextForSignIn;
+ (BOOL)_isAuthkitEntitled;
- (void)setAccountName:(NSString *)name;
- (void)setPassword:(NSString * _Nullable)password;
- (void)setInitialPassword:(NSString * _Nullable)password;
- (void)setPromptStyle:(long long)style;
- (void)setCanSetActiveAccount:(BOOL)value;
- (void)setCanCreateNewAccount:(BOOL)value;
- (void)setAllowsSilentAuthentication:(BOOL)value;
- (void)setAllowsRetry:(BOOL)value;
- (void)setShouldSuppressDialogs:(BOOL)value;
- (void)setShouldCreateNewSession:(BOOL)value;
- (id)initWithAuthenticationContext:(id)context;
- (void)startWithAuthenticateResponseBlock:(void (^)(id response, NSError *error))completion;
- (long long)authenticateResponseType;
- (NSError *)error;
- (id)initWithVerificationType:(long long)type;
- (id)utility;
- (id)resourceLoadDelegate;
- (NSMutableURLRequest *)mutableJSONRequestForPath:(NSString *)path;
- (void)signRequest:(NSMutableURLRequest *)request;
- (void)_verifySecondFactorCodeWithRequest:(NSURLRequest *)request completion:(void (^)(NSHTTPURLResponse *, NSDictionary *, NSError *))completion;
- (void)setServiceType:(long long)type;
- (void)setShouldRequestConfigurationInfo:(BOOL)value;
- (void)setUsername:(NSString *)username;
- (void)_setPassword:(NSString * _Nullable)password;
- (void)setReason:(NSString *)reason;
- (void)setSecurityCode:(NSString * _Nullable)code;
- (void)setSecondFactorCode:(NSNumber * _Nullable)code;
- (id)_identifier;
- (NSString *)username;
- (NSString *)reason;
- (void)authenticateWithContext:(id)context completion:(void (^)(NSDictionary *results, NSError *error))completion;
@end
NS_ASSUME_NONNULL_END
