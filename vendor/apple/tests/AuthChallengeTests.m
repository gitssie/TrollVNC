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
@property NSString *method;
@end
@implementation DeferredProvider
- (instancetype)init { if ((self = [super init])) _requested = dispatch_semaphore_create(0); return self; }
- (void)prepareForAuthentication:(void (^)(NSError *))completion { completion(nil); }
- (void)requestCodeForChallenge:(NSDictionary *)challenge completion:(TVAppleCodeCompletion)completion {
    self.method = challenge[@"verification_method"];
    @synchronized (self) { _requests++; _reply = [completion copy]; }
    dispatch_semaphore_signal(_requested);
}
@end
static void Wait(dispatch_semaphore_t signal) {
    assert(!dispatch_semaphore_wait(signal, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC)));
}
static void NativeSMS(id context, SEL selector, id dictionary, long long status, id configuration,
                      void (^completion)(NSHTTPURLResponse *, NSDictionary *, NSError *)) {
    (void)selector; (void)configuration;
    assert([dictionary[@"hsa2Account"] boolValue] && (status == 200 || status == 201));
    // Test stand-in for Apple's original SMS implementation. The adapter must
    // delegate to it rather than constructing a trusted-device verification.
    assert([CodePrompt(context, NULL, NO, [NSObject new]) isEqual:@"000123"]);
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:[NSURL URLWithString:@"https://gsa.apple.com/auth/verify/phone/securitycode"]
        statusCode:200 HTTPVersion:@"HTTP/1.1" headerFields:@{}];
    completion(response, @{}, nil);
}
int main(void) {
    @autoreleasepool {
        // A getter before the actual challenge must not request any code.
        TestContext *context = [TestContext new];
        DeferredProvider *provider = [DeferredProvider new];
        TVAppleChallengeState *state = [TVAppleChallengeState new]; state.provider = provider; state.automaticMethod = YES;
        objc_setAssociatedObject(context, &ChallengeKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        assert(!context.secondFactorCode && provider.requests == 0);
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
            assert([CodePrompt(context, NULL, YES, nil) isEqual:@"123456"]);
            assert(!context.secondFactorCode);
            assert(!state.failure && provider.requests == 1 && state.methodSelected && !state.useSMS);
            assert([provider.method isEqual:@"trusted_device"]);
            // A second actual prompt is a rejected-code retry, not a getter.
            assert(!CodePrompt(context, NULL, YES, nil));
            assert(state.failure.code == TVAppleErrorVerificationCode);
            assert(!context.secondFactorCode);
            dispatch_semaphore_signal(done);
        });
        Wait(provider.requested); provider.reply(@"123456", nil); Wait(done);
        puts("PASS native_prompt_then_getter");
        // A direct native phone prompt selects SMS without a ServerUI dictionary.
        context=[TestContext new]; provider=[DeferredProvider new]; state=[TVAppleChallengeState new];
        state.provider=provider; state.automaticMethod=YES;
        objc_setAssociatedObject(context,&ChallengeKey,state,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        done=dispatch_semaphore_create(0);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT,0), ^{
            assert([CodePrompt(context,NULL,NO,[NSObject new]) isEqual:@"000123"]);
            assert(state.methodSelected && state.useSMS); dispatch_semaphore_signal(done);
        });
        Wait(provider.requested); assert([provider.method isEqual:@"sms"]);
        provider.reply(@"000123",nil); Wait(done);
        puts("PASS automatic direct native phone prompt");
        // Exercise the real iOS 15 callback shape; getters during its wait are passive.
        context = [TestContext new]; provider = [DeferredProvider new];
        state = [TVAppleChallengeState new]; state.provider = provider;
        objc_setAssociatedObject(context, &ChallengeKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        done = dispatch_semaphore_create(0);
        TestContext *callbackContext = context;
        TVAppleChallengeState *callbackState = state;
        state.automaticMethod=YES;
        SecondFactorUI(context, NULL, ^(NSNumber *code, NSError *error) {
            assert([code isKindOfClass:NSNumber.class] && [code isEqual:@123456] && !error);
            assert([callbackContext.secondFactorCode isEqual:code]);
            assert([callbackContext.secondFactorCode isEqual:code]);
            assert(callbackState.requests == 1 && callbackState.methodSelected && !callbackState.useSMS);
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
        // Observed iOS15 HTTP423 carries the same HSA2 challenge, not a rejection.
        context = [TestContext new]; context.utility = [TestUtility new];
        context.response = verifiedContext.response;
        provider = [DeferredProvider new]; state = [TVAppleChallengeState new]; state.provider = provider;
        objc_setAssociatedObject(context, &ChallengeKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        done = dispatch_semaphore_create(0);
        TrustedDeviceUI(context, NULL, @{ @"hsa2Account":@YES, @"securityCode":@{ @"length":@6 } }, 423, configuration,
            ^(NSHTTPURLResponse *response, NSDictionary *body, NSError *error) {
                assert(!error && !body && response.statusCode == 204); dispatch_semaphore_signal(done);
            });
        Wait(provider.requested); provider.reply(@"000123", nil); Wait(done);
        assert(context.verifiedRequest && provider.requests == 1);
        puts("PASS native_trusted_device_http423");
        for (NSNumber *smsStatus in @[@423, @201]) {
        context = [TestContext new]; provider = [DeferredProvider new];
        state = [TVAppleChallengeState new]; state.provider = provider; state.useSMS = YES;
        objc_setAssociatedObject(context, &ChallengeKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        SEL smsSelector = NSSelectorFromString(@"_handleServerUISMSVerificationWithResponseDictionary:statusCode:configuration:completion:");
        OriginalPrompts = @{NSStringFromSelector(smsSelector):[NSValue valueWithPointer:(void *)NativeSMS]};
        done = dispatch_semaphore_create(0);
        TrustedDeviceUI(context, smsSelector, @{@"hsa2Account":@YES,@"securityCode":@{}}, smsStatus.longLongValue, configuration,
            ^(NSHTTPURLResponse *response, NSDictionary *body, NSError *error) {
                assert(!error && body && [response.URL.path isEqual:@"/auth/verify/phone/securitycode"]);
                dispatch_semaphore_signal(done);
            });
        Wait(provider.requested); assert([provider.method isEqual:@"sms"]);
        provider.reply(@"000123", nil); Wait(done);
        assert(!context.verifiedRequest && provider.requests == 1);
        puts("PASS native_sms_continuation_and_code_kind");
        }
        // Automatic routing uses Apple's boolean, even when both responses
        // include a trusted phone. It never requires an external method option.
        for (NSNumber *noDevices in @[@NO, @YES]) {
            context = [TestContext new]; context.utility = [TestUtility new]; context.response = verifiedContext.response;
            provider = [DeferredProvider new]; state = [TVAppleChallengeState new]; state.provider = provider; state.automaticMethod = YES;
            objc_setAssociatedObject(context, &ChallengeKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            SEL sel = NSSelectorFromString(@"_handleServerUISMSVerificationWithResponseDictionary:statusCode:configuration:completion:");
            OriginalPrompts = @{NSStringFromSelector(sel):[NSValue valueWithPointer:(void *)NativeSMS]};
            done = dispatch_semaphore_create(0);
            BOOL sms = noDevices.boolValue;
            TrustedDeviceUI(context, sel, @{@"hsa2Account":@YES,@"securityCode":@{},@"noTrustedDevices":noDevices,
                @"trustedPhoneNumbers":@[@{@"id":@1}]}, 201, configuration,
                ^(NSHTTPURLResponse *response, NSDictionary *body, NSError *error) {
                    assert(!error && response && (sms ? body!=nil : body==nil)); dispatch_semaphore_signal(done);
                });
            Wait(provider.requested); assert([provider.method isEqual:sms ? @"sms" : @"trusted_device"]);
            provider.reply(@"000123", nil); Wait(done);
            assert(provider.requests==1 && state.methodSelected);
            assert(sms ? !context.verifiedRequest : [context.verifiedRequest.URL.path isEqual:@"/auth/verify/trusteddevice/securitycode"]);
        }
        puts("PASS automatic server response selects trusted device or SMS");
        // Native password-change authentication can return an already selected
        // SMS number instead of noTrustedDevices. A phone list alone is not this
        // challenge: require the selected number's exact ID and explicit mode.
        context=[TestContext new]; context.response=verifiedContext.response;
        provider=[DeferredProvider new]; state=[TVAppleChallengeState new];
        state.provider=provider;state.automaticMethod=YES;
        objc_setAssociatedObject(context,&ChallengeKey,state,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        SEL selectedSMSSelector=NSSelectorFromString(@"_handleServerUISMSVerificationWithResponseDictionary:statusCode:configuration:completion:");
        OriginalPrompts=@{NSStringFromSelector(selectedSMSSelector):[NSValue valueWithPointer:(void *)NativeSMS]};
        done=dispatch_semaphore_create(0);
        TrustedDeviceUI(context,selectedSMSSelector,@{@"hsa2Account":@YES,@"securityCode":@{},
            @"trustedPhoneNumber":@{@"id":@1,@"pushMode":@"sms"},
            @"trustedPhoneNumbers":@[@{@"id":@1,@"pushMode":@"sms"}]},200,configuration,
            ^(NSHTTPURLResponse *response,NSDictionary *body,NSError *error){
                assert(!error&&response&&body);dispatch_semaphore_signal(done);
            });
        Wait(provider.requested);assert([provider.method isEqual:@"sms"]);
        provider.reply(@"000123",nil);Wait(done);
        assert(state.methodSelected&&state.useSMS&&!context.verifiedRequest);
        puts("PASS automatic selected native SMS challenge");
        NSDictionary *selectedPhone=@{@"id":@1,@"pushMode":@"sms"};
        NSArray *selectedPhones=@[selectedPhone];
        for(NSDictionary *extra in @[
            @{@"trustedPhoneNumbers":selectedPhones},
            @{@"trustedPhoneNumber":@{@"id":@1,@"pushMode":@"voice"},@"trustedPhoneNumbers":selectedPhones},
            @{@"trustedPhoneNumber":@{@"id":@2,@"pushMode":@"sms"},@"trustedPhoneNumbers":selectedPhones},
            @{@"trustedPhoneNumber":@{@"id":@YES,@"pushMode":@"sms"},@"trustedPhoneNumbers":selectedPhones},
            @{@"trustedPhoneNumber":selectedPhone,@"trustedPhoneNumbers":@[selectedPhone,selectedPhone]},
            @{@"trustedPhoneNumber":selectedPhone,@"trustedPhoneNumbers":@[@{@"id":@YES,@"pushMode":@"sms"}]},
            @{@"trustedPhoneNumber":selectedPhone,@"trustedPhoneNumbers":selectedPhones,@"noTrustedDevices":@0}
        ]){
            context=[TestContext new];provider=[DeferredProvider new];state=[TVAppleChallengeState new];
            state.provider=provider;state.automaticMethod=YES;
            objc_setAssociatedObject(context,&ChallengeKey,state,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            NSMutableDictionary *payload=[@{@"hsa2Account":@YES,@"securityCode":@{}} mutableCopy];
            [payload addEntriesFromDictionary:extra];__block BOOL invalid=NO;
            TrustedDeviceUI(context,NULL,payload,200,configuration,^(NSHTTPURLResponse *response,NSDictionary *body,NSError *error){
                assert(!response&&!body&&error.code==TVAppleErrorUnsupported);invalid=YES;
            });
            assert(invalid&&!provider.requests&&!context.verifiedRequest);
        }
        // Missing, numeric/string, rejected and changed methods fail before asking
        // for input or calling either verification endpoint.
        for (id noDevices in @[NSNull.null, @0, @1, @"false"]) {
            context=[TestContext new]; provider=[DeferredProvider new]; state=[TVAppleChallengeState new];
            state.provider=provider; state.automaticMethod=YES;
            objc_setAssociatedObject(context, &ChallengeKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            NSMutableDictionary *payload=[@{@"hsa2Account":@YES,@"securityCode":@{}} mutableCopy];
            if (noDevices!=NSNull.null) payload[@"noTrustedDevices"]=noDevices;
            __block BOOL rejected=NO;
            TrustedDeviceUI(context, NULL, payload, 200, configuration, ^(NSHTTPURLResponse *response, NSDictionary *body, NSError *error) {
                assert(!response && !body && error.code==TVAppleErrorUnsupported); rejected=YES;
            });
            assert(rejected && !provider.requests && !context.verifiedRequest);
        }
        context=[TestContext new]; provider=[DeferredProvider new]; state=[TVAppleChallengeState new];
        state.provider=provider; state.automaticMethod=YES; state.methodSelected=YES; state.useSMS=YES;
        objc_setAssociatedObject(context, &ChallengeKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        __block BOOL changedRejected=NO;
        TrustedDeviceUI(context,NULL,@{@"hsa2Account":@YES,@"securityCode":@{},@"noTrustedDevices":@NO},200,configuration,
            ^(NSHTTPURLResponse *response, NSDictionary *body, NSError *error) {
                assert(!response && !body && error.code==TVAppleErrorVerificationCode); changedRejected=YES;
            });
        assert(changedRejected && !provider.requests);
        puts("PASS automatic selection rejects missing malformed or changing methods");
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
