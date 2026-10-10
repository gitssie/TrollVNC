#import "TVAppleStoreLogin.h"
#import "TVAppleStoreSignIn.h"
@interface TVAppleNativeStoreSignIn (PrepareRegression)
- (TVAppleStoreAttempt)prepare:(NSString *)appleID credential:(NSString *)credential response:(NSDictionary **)response context:(id *)context error:(NSError **)error;
@end
#include <assert.h>
static NSUInteger initialPasswordWrites;
static BOOL ignoresConversion, suppressesDialogs;
static long long responseType = 3;
@interface NSObject (ReviewTicketTests)
- (void)close;
- (void)resolve:(NSDictionary *)value;
- (NSDictionary *)value;
- (BOOL)wait:(NSTimeInterval)timeout;
@end
@interface SSAuthenticationContext : NSObject <NSMutableCopying>
@end
@implementation SSAuthenticationContext
+ (id)contextForSignIn { return [self new]; }
- (id)mutableCopyWithZone:(NSZone *)zone { (void)zone; return [SSAuthenticationContext new]; }
- (void)setAccountName:(id)value { (void)value; }
- (void)setPassword:(id)value { (void)value; }
- (void)setInitialPassword:(id)value { if(value)initialPasswordWrites++; }
- (void)setShouldIgnoreAccountConversion:(BOOL)value { ignoresConversion=value; }
- (void)setShouldSuppressDialogs:(BOOL)value { suppressesDialogs=value; }
- (void)setPromptStyle:(long long)value { (void)value; }
#define BOOL_SETTER(name) - (void)name:(BOOL)value { (void)value; }
BOOL_SETTER(setCanSetActiveAccount) BOOL_SETTER(setCanCreateNewAccount)
BOOL_SETTER(setAllowsSilentAuthentication) BOOL_SETTER(setAllowsRetry)
BOOL_SETTER(setShouldCreateNewSession)
@end
@interface FakeReviewResponse:NSObject @end
@implementation FakeReviewResponse
- (long long)authenticateResponseType { return responseType; }
- (NSError *)error { return nil; }
- (NSDictionary *)responseDictionary { return @{@"dialog":@{@"test":@"retained"}}; }
@end
@interface SSAuthenticateRequest:NSObject @end
@implementation SSAuthenticateRequest
+ (BOOL)_isAuthkitEntitled { return YES; }
- (id)initWithAuthenticationContext:(id)context { (void)context; return [super init]; }
- (void)startWithAuthenticateResponseBlock:(void(^)(id,NSError *))completion { completion([FakeReviewResponse new],nil); }
@end
int main(){@autoreleasepool{
NSError*error=nil;NSDictionary*response=nil;id context=nil;
assert(TVAppleNativeStoreLoginForReview(@"test@example.com",@"test-password",&response,&context,&error)==TVAppleStoreAttemptFailed);
assert(error.code==TVAppleErrorAccountNeedsReview && response && context && initialPasswordWrites==0 && suppressesDialogs);
error=nil;assert(TVAppleNativeStoreLogin(@"test@example.com",@"test-password",&error)==TVAppleStoreAttemptFailed);
assert(error.code==TVAppleErrorAccountNeedsReview && initialPasswordWrites==1 && !suppressesDialogs);
responseType=4;error=nil;response=nil;context=nil;
assert(TVAppleNativeStoreReviewAuthentication(@"test@example.com",@"native-credential",&response,&context,&error)==TVAppleStoreAttemptSucceeded);
assert(!error && response && context && ignoresConversion && suppressesDialogs && initialPasswordWrites==2);
error=nil;context=nil;
assert([[TVAppleNativeStoreSignIn new] prepare:@"test@example.com" credential:@"native-credential" response:&response context:&context error:&error]==TVAppleStoreAttemptSucceeded);
assert(!error && context && ignoresConversion && suppressesDialogs);
responseType=3;error=nil;response=nil;context=nil;
assert([[TVAppleNativeStoreSignIn new] prepare:@"test@example.com" credential:@"native-credential" response:&response context:&context error:&error]==TVAppleStoreAttemptFailed);
assert(error.code==TVAppleErrorAccountNeedsReview && response && context && ignoresConversion && suppressesDialogs);
id ticket=[NSClassFromString(@"TVAppleAuthTicket")new];
[ticket close]; [ticket resolve:@{@"private_response":@"late"}];
assert(![ticket value] && ![ticket wait:0.01]);
puts("PASS native Review authentication: raw password avoids PET slot, continuation retained, existing entry preserved");
}return 0;}
