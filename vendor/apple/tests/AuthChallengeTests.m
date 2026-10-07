// Include the native adapter so tests exercise its private prompt/getter paths.
#import "../src/appstore/TVAppleStoreAuthentication.m"
#include <assert.h>
@interface TestUtility : NSObject
@end
@implementation TestUtility
- (NSMutableURLRequest *)mutableJSONRequestForPath:(NSString *)path {
    return [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[@"https://gsa.apple.com" stringByAppendingString:path]]];
}
@end
@interface TestSigner : NSObject
@property NSUInteger signs;
@end
@implementation TestSigner
- (void)signRequest:(NSMutableURLRequest *)request {
    _signs++; [request setValue:@"test-signature" forHTTPHeaderField:@"X-Test-Signed"];
}
@end
@interface TestConfiguration : NSObject
@property TestSigner *resourceLoadDelegate;
@end
@implementation TestConfiguration
@end
@interface TestContext : NSObject
@property NSNumber *secondFactorCode;
@property TestUtility *utility;
@property NSURLRequest *verifiedRequest;
@property NSHTTPURLResponse *response;
@end
@implementation TestContext
- (void)_verifySecondFactorCodeWithRequest:(NSURLRequest *)request completion:(void (^)(NSHTTPURLResponse *, NSDictionary *, NSError *))completion {
    assert([request valueForHTTPHeaderField:@"X-Test-Signed"]);
    _verifiedRequest = request;
    completion(_response, nil, nil);
}
@end
@interface DeferredProvider : NSObject <TVAppleVerificationCodeProvider>
@property NSUInteger requests;
@property TVAppleCodeCompletion reply;
@property dispatch_semaphore_t requested;
@end
@implementation DeferredProvider
- (instancetype)init { if ((self = [super init])) _requested = dispatch_semaphore_create(0); return self; }
- (void)prepareForAuthentication:(void (^)(NSError *))completion { completion(nil); }
- (void)requestCodeForChallenge:(NSDictionary *)challenge completion:(TVAppleCodeCompletion)completion {
    (void)challenge;
    @synchronized (self) { _requests++; _reply = [completion copy]; }
    dispatch_semaphore_signal(_requested);
}
@end
static void Wait(dispatch_semaphore_t signal) {
    assert(!dispatch_semaphore_wait(signal, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC)));
}
int main(void) {
    @autoreleasepool {
        // A getter before the actual challenge must not request any code.
        TestContext *context = [TestContext new];
        DeferredProvider *provider = [DeferredProvider new];
        TVAppleChallengeState *state = [TVAppleChallengeState new]; state.provider = provider;
        objc_setAssociatedObject(context, &ChallengeKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        assert(!context.secondFactorCode && provider.requests == 0);
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
            assert([CodePrompt(context, NULL, YES, nil) isEqual:@"123456"]);
            assert(!context.secondFactorCode);
            assert(!state.failure && provider.requests == 1);
            // A second actual prompt is a rejected-code retry, not a getter.
            assert(!CodePrompt(context, NULL, YES, nil));
            assert(state.failure.code == TVAppleErrorVerificationCode);
            assert(!context.secondFactorCode);
            dispatch_semaphore_signal(done);
        });
        Wait(provider.requested); provider.reply(@"123456", nil); Wait(done);
        puts("PASS native_prompt_then_getter");
        // Exercise the real iOS 15 callback shape; getters during its wait are passive.
        context = [TestContext new]; provider = [DeferredProvider new];
        state = [TVAppleChallengeState new]; state.provider = provider;
        objc_setAssociatedObject(context, &ChallengeKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        done = dispatch_semaphore_create(0);
        TestContext *callbackContext = context;
        TVAppleChallengeState *callbackState = state;
        SecondFactorUI(context, NULL, ^(NSNumber *code, NSError *error) {
            assert([code isKindOfClass:NSNumber.class] && [code isEqual:@123456] && !error);
            assert([callbackContext.secondFactorCode isEqual:code]);
            assert([callbackContext.secondFactorCode isEqual:code]);
            assert(callbackState.requests == 1);
            dispatch_semaphore_signal(done);
        });
        Wait(provider.requested);
        dispatch_group_t group = dispatch_group_create();
        for (NSUInteger i = 0; i < 2; i++) dispatch_group_async(group, dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
            assert(!context.secondFactorCode);
        });
        assert(!dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC)));
        assert(provider.requests == 1);
        provider.reply(@"123456", nil); Wait(done);
        @synchronized (state) { state.closed = YES; state.suppliedCode = nil; context.secondFactorCode = nil; }
        assert(!context.secondFactorCode);
        assert(provider.requests == 1);
        puts("PASS native_ui_callback_and_passive_getters");
        // The ServerUI callback must submit a device code, never an SMS body.
        context = [TestContext new]; context.utility = [TestUtility new];
        context.response = [[NSHTTPURLResponse alloc] initWithURL:[NSURL URLWithString:@"https://gsa.apple.com/auth/verify/trusteddevice/securitycode"]
            statusCode:204 HTTPVersion:@"HTTP/1.1" headerFields:@{}];
        TestConfiguration *configuration = [TestConfiguration new]; configuration.resourceLoadDelegate = [TestSigner new];
        provider = [DeferredProvider new]; state = [TVAppleChallengeState new]; state.provider = provider;
        objc_setAssociatedObject(context, &ChallengeKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        done = dispatch_semaphore_create(0); TestContext *verifiedContext = context;
        TrustedDeviceUI(context, NULL, @{ @"hsa2Account":@YES, @"securityCode":@{ @"length":@6 } }, 200, configuration,
            ^(NSHTTPURLResponse *response, NSDictionary *body, NSError *error) {
                assert(!error && !body && response == verifiedContext.response);
                assert(response.statusCode == 204); // actual native response is retained
                dispatch_semaphore_signal(done);
            });
        Wait(provider.requested); provider.reply(@"000123", nil); Wait(done);
        assert([context.verifiedRequest.URL.path isEqual:@"/auth/verify/trusteddevice/securitycode"]);
        assert([context.verifiedRequest.HTTPMethod isEqual:@"POST"] && configuration.resourceLoadDelegate.signs == 1);
        NSDictionary *body = [NSJSONSerialization JSONObjectWithData:context.verifiedRequest.HTTPBody options:0 error:NULL];
        assert(([body isEqual:@{ @"securityCode":@{ @"code":@"000123" } }]));
        puts("PASS native_trusted_device_request");
        // Unknown account responses cannot request a code or send a request.
        context = [TestContext new]; provider = [DeferredProvider new];
        state = [TVAppleChallengeState new]; state.provider = provider;
        objc_setAssociatedObject(context, &ChallengeKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        __block BOOL rejected = NO;
        TrustedDeviceUI(context, NULL, @{}, 200, configuration,
            ^(NSHTTPURLResponse *response, NSDictionary *body, NSError *error) {
                assert(!response && !body && error.code == TVAppleErrorAccountNeedsReview); rejected = YES;
            });
        assert(rejected && provider.requests == 0 && !context.verifiedRequest);
        puts("PASS native_trusted_device_preflight");
    }
    return 0;
}
