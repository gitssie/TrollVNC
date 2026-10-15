#import "TVAppleICloud.h"
#import "TVAppleStoreLogin.h"
#import "TVAppleNativeSelectors.h"
#import <dlfcn.h>

@interface NSObject (TVAppleICloudSelectors)
- (void)setDelegate:(id)delegate;
- (void)setCdpUIProvider:(id)provider;
- (void)setShouldAutomaticallySaveSignInResults:(BOOL)save;
- (void)signInWithIDMSAuthenticationResults:(NSDictionary *)results completion:(void (^)(BOOL,id,NSError *))completion;
+ (id)sharedConnection;
- (BOOL)hasLocalSecret;
- (BOOL)unlockDeviceWithPasscode:(NSString *)passcode outError:(NSError **)error;
- (int)unlockScreenTypeWithOutSimplePasscodeType:(int *)type;
- (id)initWithValidatedSecret:(NSString *)secret secretType:(NSUInteger)type;
- (void)cancelValidationWithError:(NSError *)error;
@end
static BOOL CloudSupports(id object, NSArray<NSString *> *selectors) {
    if(!object)return NO;
    for(NSString *selector in selectors)if(![object respondsToSelector:NSSelectorFromString(selector)])return NO;
    return YES;
}

// Foundation CDP input provider. Only the supplied local device passcode is supported.
// Native ManagedConfiguration verifies it before a CDPLocalSecret is constructed.
@interface TVAppleCloudInput : NSObject
@property NSString *passcode;
@property(nonatomic) NSError *failure;
@property(copy) void (^failureHandler)(NSError *);
@property(copy) BOOL (^operationActive)(void);
@property BOOL closed;
@property NSUInteger localPrompts;
@end
@implementation TVAppleCloudInput
@synthesize failure=_failure;
- (void)setFailure:(NSError *)error {
    // All provider failures converge on the same first-terminal gate as completion.
    @synchronized(self) {
        if(_failure)return;
        _failure=error;
        if(self.failureHandler)self.failureHandler(error);
    }
}
- (NSUInteger)findMyActivationAction { return 2; }
- (BOOL)skipCDPEnablement { return NO; }
- (BOOL)skipDataclassEnablement { return NO; }
- (BOOL)shouldStashLoginResponse { return NO; }
- (BOOL)backgroundDataclassEnablement { return NO; }
- (void)signInFlowController:(id)flow presentGenericTermsUIForAccount:(id)account completion:(void (^)(BOOL,id,NSError *))completion {
    (void)flow;
    @synchronized(self){self.failure=TVAppleError(TVAppleErrorAccountNeedsReview,@"iCloud terms require explicit review.");completion(NO,account,self.failure);}
}
- (void)signInFlowController:(id)flow showAlertWithTitle:(id)title message:(id)message completion:(void (^)(BOOL))completion {
    (void)flow;(void)title;(void)message;
    @synchronized(self){self.failure=TVAppleError(TVAppleErrorAccountNeedsReview,@"iCloud sign-in requires additional interaction.");completion(NO);}
}
- (void)cdpContext:(id)context promptForLocalSecretWithCompletion:(void (^)(id,NSError *))completion {
    (void)context;
    @synchronized(self) {
        if(self.closed||(self.operationActive&&!self.operationActive())||++self.localPrompts>1||!self.passcode.length) {
            self.failure=TVAppleError(TVAppleErrorAccountNeedsReview,@"The local passcode challenge is unavailable or repeated.");completion(nil,self.failure);return;
        }
        id device=[NSClassFromString(@"CDPLocalDevice")sharedInstance];
        id connection=[NSClassFromString(@"MCProfileConnection")sharedConnection];
        NSError *nativeError=nil;
        if(![device hasLocalSecret]) {
            self.failure=TVAppleError(TVAppleErrorUnsupported,@"Native device reports no local passcode.");completion(nil,self.failure);return;
        }
        if(![connection unlockDeviceWithPasscode:self.passcode outError:&nativeError] || nativeError) {
            self.failure=TVAppleError(TVAppleErrorAuthenticationFailed,[NSString stringWithFormat:@"Native local passcode verification failed (code %ld).",(long)nativeError.code]);completion(nil,self.failure);return;
        }
        int simpleType=-2;
        [connection unlockScreenTypeWithOutSimplePasscodeType:&simpleType];
        // Apple's CDP command-line provider maps simple passcodes to 2, complex to 3.
        if(simpleType < -1) { self.failure=TVAppleError(TVAppleErrorUnsupported,@"Native passcode type is unavailable.");completion(nil,self.failure);return; }
        id localSecret=[[NSClassFromString(@"CDPLocalSecret")alloc]initWithValidatedSecret:self.passcode secretType:simpleType==-1?3:2];
        if(!localSecret){self.failure=TVAppleError(TVAppleErrorUnsupported,@"Native local secret could not be created.");completion(nil,self.failure);return;}
        completion(localSecret,nil);
    }
}
- (void)rejectValidator:(id)validator {
    @synchronized(self){self.failure=TVAppleError(TVAppleErrorAccountNeedsReview,@"CoreCDP requires a remote-device or recovery secret.");
        if(CloudSupports(validator,@[@"cancelValidationWithError:"])) [validator cancelValidationWithError:self.failure];}
}
- (void)cdpContext:(id)context promptForRemoteSecretWithDevices:(id)devices offeringRemoteApproval:(BOOL)approval validator:(id)validator {
    (void)context;(void)devices;(void)approval;[self rejectValidator:validator];
}
- (void)cdpContext:(id)context promptForICSCWithIsNumeric:(BOOL)numeric numericLength:(id)length isRandom:(BOOL)random validator:(id)validator {
    (void)context;(void)numeric;(void)length;(void)random;[self rejectValidator:validator];
}
// Recovery-key protocol completions are (BOOL, NSError *). EDP continuation
// signals success only and must never be invoked by this rejecting provider.
- (void)cdpContext:(id)context promptForRecoveryKeyWithValidator:(id)validator completion:(void (^)(BOOL,NSError *))completion {
    (void)context;[self rejectValidator:validator];if(completion)completion(NO,self.failure);
}
- (void)cdpContext:(id)context promptForRecoveryKeyWithSecretValidator:(id)validator completion:(void (^)(BOOL,NSError *))completion {
    (void)context;[self rejectValidator:validator];if(completion)completion(NO,self.failure);
}
- (void)cdpContext:(id)context presentRecoveryKeyWithValidator:(id)validator completion:(void (^)(BOOL,NSError *))completion {
    (void)context;[self rejectValidator:validator];if(completion)completion(NO,self.failure);
}
- (void)cdpContext:(id)context promptForAdoptionOfMultipleICSC:(void (^)(BOOL,NSError *))completion {
    (void)context;[self rejectValidator:nil];if(completion)completion(NO,self.failure);
}
- (void)cdpContext:(id)context promptForBeneficiaryAccessKeyWithCompletion:(void (^)(id,NSError *))completion {
    (void)context;[self rejectValidator:nil];if(completion)completion(nil,self.failure);
}
- (void)cdpContext:(id)context promptForEDPRecoveryTokenWithValidator:(id)validator successfulCDPRecoveryContinuationHandler:(void (^)(void))continuation {
    (void)context;(void)continuation;[self rejectValidator:validator];
}
- (void)cdpRecoveryFlowContext:(id)context promptForRemoteSecretWithDevices:(id)devices validator:(id)validator {
    (void)context;(void)devices;[self rejectValidator:validator];
}
- (void)cdpContext:(id)context promptForInteractiveAuthenticationWithCompletion:(void (^)(NSDictionary *,NSError *))completion {
    (void)context;@synchronized(self){self.failure=TVAppleError(TVAppleErrorAccountNeedsReview,@"CoreCDP requires additional Apple ID authentication.");completion(nil,self.failure);}
}
@end

@implementation TVAppleServices (ICloudEnablement)
- (void)enableICloudAppleID:(NSString *)appleID password:(NSString *)password devicePasscode:(NSString *)passcode
 verificationCodeProvider:(id<TVAppleVerificationCodeProvider>)provider completion:(TVAppleCompletion)completion {
    [self enqueueEnableICloudAppleID:appleID password:password devicePasscode:passcode provider:provider completion:completion];
}
@end

BOOL TVAppleNativeEnableICloud(NSString *appleID,NSString *password,NSString *passcode,id<TVAppleVerificationCodeProvider> provider,NSError **error) {
    for(NSString *framework in @[@"AppleAccount",@"CoreCDP",@"ManagedConfiguration"]) {
        NSString *path=[NSString stringWithFormat:@"/System/Library/PrivateFrameworks/%@.framework/%@",framework,framework];
        if(!dlopen(path.UTF8String,RTLD_NOW)){*error=TVAppleError(TVAppleErrorUnsupported,@"An iCloud native framework is unavailable.");return NO;}
    }
    Class deviceClass=NSClassFromString(@"CDPLocalDevice"),connectionClass=NSClassFromString(@"MCProfileConnection");
    id flow=[NSClassFromString(@"AASignInFlowController")new];
    if(!CloudSupports(flow,@[@"setDelegate:",@"setCdpUIProvider:",@"setShouldAutomaticallySaveSignInResults:",@"signInWithIDMSAuthenticationResults:completion:"]) ||
       !CloudSupports(deviceClass,@[@"sharedInstance"]) || !CloudSupports(connectionClass,@[@"sharedConnection"]) ||
       !CloudSupports([deviceClass sharedInstance],@[@"hasLocalSecret"]) ||
       !CloudSupports([connectionClass sharedConnection],@[@"unlockDeviceWithPasscode:outError:",@"unlockScreenTypeWithOutSimplePasscodeType:"]) ||
       !CloudSupports([NSClassFromString(@"CDPLocalSecret")alloc],@[@"initWithValidatedSecret:secretType:"])) {
        *error=TVAppleError(TVAppleErrorUnsupported,@"Native iCloud/CDP input interfaces are unavailable.");return NO;
    }
    NSDictionary *authentication=TVAppleNativeAuthenticate(appleID,password,provider,NO,error);
    if(!authentication)return NO;
    return TVAppleRunICloudFlow(flow,authentication,passcode,240,error);
}

BOOL TVAppleRunICloudFlow(id flow,NSDictionary *authentication,NSString *passcode,NSTimeInterval timeout,NSError **error) {
    TVAppleCloudInput *input=[TVAppleCloudInput new];input.passcode=[passcode copy];
    dispatch_semaphore_t signal=dispatch_semaphore_create(0);
    NSMutableDictionary *ticket=[NSMutableDictionary new];
    // One gate owns both early provider failure and the eventual native completion.
    // No callback may overwrite the first terminal observation or revive this flow.
    void (^finish)(BOOL,NSError *,BOOL)=^(BOOL ok,NSError *failure,BOOL nativeCompleted) {
        @synchronized(ticket) {
            if(ticket[@"closed"]||ticket[@"finished"])return;
            ticket[@"finished"]=@YES;ticket[@"ok"]=@(ok);
            ticket[@"native_completed"]=@(nativeCompleted);
            if(failure)ticket[@"failure"]=failure;
            dispatch_semaphore_signal(signal);
        }
    };
    input.failureHandler=^(NSError *failure){finish(NO,failure,NO);};
    input.operationActive=^BOOL{@synchronized(ticket){return !ticket[@"closed"]&&!ticket[@"finished"];}};
    [flow setDelegate:(id)input];[flow setCdpUIProvider:input];[flow setShouldAutomaticallySaveSignInResults:YES];
    [flow signInWithIDMSAuthenticationResults:authentication completion:^(BOOL success,id account,NSError *failure){
        NSError *reported=nil;
        if(failure||!success) {
            // Preserve only native domain/code, never userInfo or localizedDescription.
            NSMutableDictionary *info=[TVAppleError(TVAppleErrorNativeFailure,@"Native iCloud/CDP sign-in failed.").userInfo mutableCopy];
            NSString *domain=failure.domain;
            NSCharacterSet *allowed=[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"];
            if(domain.length&&domain.length<=128&&[domain rangeOfCharacterFromSet:allowed.invertedSet].location==NSNotFound)
                info[@"TVAppleNativeDomain"]=domain;
            if(failure)info[@"TVAppleNativeCode"]=@(failure.code);
            reported=[NSError errorWithDomain:TVAppleErrorDomain code:TVAppleErrorNativeFailure userInfo:info];
        } else if(!account)reported=TVAppleError(TVAppleErrorOutcomeUnknown,@"Native iCloud/CDP completion omitted its account.");
        finish(success&&account&&!failure,reported,YES);
    }];
    authentication=nil;
    NSTimeInterval deadline=NSProcessInfo.processInfo.systemUptime+timeout;
    while(NSProcessInfo.processInfo.systemUptime<deadline) {
        NSTimeInterval remaining=deadline-NSProcessInfo.processInfo.systemUptime;
        if(dispatch_semaphore_wait(signal,dispatch_time(DISPATCH_TIME_NOW,(int64_t)(MAX(0,MIN(.01,remaining))*NSEC_PER_SEC)))==0)break;
        // Pump native callbacks without busy-spinning on a worker with no run-loop sources.
        [[NSRunLoop currentRunLoop]runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.001]];
    }
    BOOL ok=NO,nativeCompleted=NO;NSError *failure=nil;
    @synchronized(ticket) {
        ticket[@"closed"]=@YES;
        ok=[ticket[@"ok"]boolValue];nativeCompleted=[ticket[@"native_completed"]boolValue];failure=ticket[@"failure"];
        if(!ticket[@"finished"])failure=TVAppleError(TVAppleErrorOutcomeUnknown,@"Native iCloud/CDP sign-in timed out; inspect actual account state.");
    }
    @synchronized(input){input.closed=YES;input.passcode=nil;input.failureHandler=nil;input.operationActive=nil;}
    [flow setDelegate:nil];[flow setCdpUIProvider:nil];
    if(ok&&error)*error=nil;
    if(!ok) {
        NSMutableDictionary *info=[failure.userInfo mutableCopy];
        info[@"TVAppleFailureStage"]=@"icloud_cdp";
        info[@"TVAppleNativeCompletionReceived"]=@(nativeCompleted);
        *error=[NSError errorWithDomain:TVAppleErrorDomain code:failure.code userInfo:info];
    }
    return ok;
}
