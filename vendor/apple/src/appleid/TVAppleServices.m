#import "TVAppleBackend.h"
#import "TVAppleStoreLogin.h"
#import "TVAppleScopedSignOut.h"
#import "TVAppleFindMy.h"
#import "TVAppleICloud.h"
#import "TVAppleEmailSettings.h"
#import "TVAppleEmailActions.h"
#import "TVAppleNameSettings.h"
#import "TVAppleStateAggregation.h"
#import "TVAppleSignInWithApple.h"
#import "TVAppleICloudDevices.h"

static dispatch_queue_t Worker(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("org.trollvnc.apple.accounts", DISPATCH_QUEUE_SERIAL); });
    return queue;
}
// A timed-out native request can still finish later. Fence all subsequent writes.
static BOOL uncertainMutation;
static NSString *Normalize(NSString *value) {
    return [[value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] lowercaseString];
}
static NSArray *Targets(NSDictionary *state, NSString *appleID) {
    NSMutableArray *result = [NSMutableArray new];
    for (NSString *domain in @[@"icloud", @"identity", @"media"]) {
        for (NSDictionary *record in state[@"accounts"]) {
            if ([record[@"selected"] boolValue] && [record[@"domain"] isEqual:domain] &&
                [Normalize(record[@"apple_id"]) isEqual:appleID]) [result addObject:record];
        }
    }
    return result;
}
static NSArray *SignOutTargets(NSDictionary *state, NSString *appleID, BOOL iCloudOnly) {
    NSArray *all = Targets(state, appleID);
    if (!iCloudOnly) return all;
    NSMutableArray *cloud = [NSMutableArray new];
    for (NSDictionary *record in all) {
        if ([record[@"domain"] isEqual:@"icloud"] && [record[@"primary"] boolValue]) [cloud addObject:record];
    }
    return cloud;
}
@implementation TVAppleServices {
    id<TVAppleBackend> _backend;
    dispatch_queue_t _callbacks;
    NSTimeInterval _verificationTimeout;
}
- (instancetype)init { return [self initWithCallbackQueue:dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0)]; }
- (instancetype)initWithCallbackQueue:(dispatch_queue_t)queue {
    return [self initWithBackend:TVAppleCreateNativeBackend() callbackQueue:queue verificationTimeout:5];
}
- (instancetype)initWithBackend:(id<TVAppleBackend>)backend callbackQueue:(dispatch_queue_t)queue verificationTimeout:(NSTimeInterval)timeout {
    if ((self = [super init])) { _backend = backend; _callbacks = queue; _verificationTimeout = MAX(0, timeout); }
    return self;
}
- (void)queryState:(TVAppleCompletion)completion {
    TVAppleCompletion reply = [completion copy];
    dispatch_async(Worker(), ^{
        @autoreleasepool {
            NSError *error = nil;
            NSDictionary *state = TVAppleAggregateState(self->_backend,&error);
            dispatch_async(self->_callbacks, ^{ reply(state, error); });
        }
    });
}
- (void)enqueueEmailSettingsForAppleID:(NSString *)appleID completion:(TVAppleCompletion)completion {
    NSString *target=[appleID copy];TVAppleCompletion reply=[completion copy];
    dispatch_async(Worker(),^{@autoreleasepool{
        NSError *error=nil;NSDictionary *settings=nil;NSString *normalized=Normalize(target);
        if(!normalized.length||normalized.length>320||[normalized rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location!=NSNotFound)
            error=TVAppleError(TVAppleErrorInvalidRequest,@"A valid Apple ID is required.");
        else if(![self->_backend conformsToProtocol:@protocol(TVAppleEmailSettingsBackend)])
            error=TVAppleError(TVAppleErrorUnsupported,@"Email settings backend is unavailable.");
        else settings=[(id<TVAppleEmailSettingsBackend>)self->_backend emailSettingsForAppleID:normalized error:&error];
        dispatch_async(self->_callbacks,^{reply(settings,error);});
    }});
}
- (void)enqueueICloudDevices:(NSString *)appleID mutation:(BOOL)mutation completion:(TVAppleCompletion)completion{
    NSString *target=[appleID copy];TVAppleCompletion reply=[completion copy];
    dispatch_async(Worker(),^{@autoreleasepool{
        NSError *error=nil;NSDictionary *result=nil;NSString *normalized=Normalize(target);
        if(!normalized.length||normalized.length>320||[normalized rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location!=NSNotFound)
            error=TVAppleError(TVAppleErrorInvalidRequest,@"A valid Apple ID is required.");
        else if(mutation&&uncertainMutation)error=TVAppleError(TVAppleErrorOutcomeUnknown,@"A previous mutation has an uncertain outcome; inspect state before further writes.");
        else if(![self->_backend conformsToProtocol:@protocol(TVAppleICloudDevicesBackend)])error=TVAppleError(TVAppleErrorUnsupported,@"Native iCloud devices backend is unavailable.");
        else{
            id<TVAppleICloudDevicesBackend> backend=(id)self->_backend;
            result=mutation?[backend removeOtherICloudDevicesForAppleID:normalized error:&error]:[backend iCloudDevicesForAppleID:normalized error:&error];
            if(!result&&!error)error=TVAppleError(mutation?TVAppleErrorOutcomeUnknown:TVAppleErrorBackendRead,@"Native device operation returned no confirmed result.");
            if(mutation&&[error.domain isEqual:TVAppleErrorDomain]&&error.code==TVAppleErrorOutcomeUnknown)uncertainMutation=YES;
        }
        dispatch_async(self->_callbacks,^{reply(result,error);});
    }});
}
- (void)enqueueSignInWithApple:(NSString *)appleID bundleID:(NSString *)bundleID mutation:(BOOL)mutation completion:(TVAppleCompletion)completion{
    NSString *target=[appleID copy],*application=[bundleID copy];TVAppleCompletion reply=[completion copy];
    dispatch_async(Worker(),^{@autoreleasepool{
        NSError *error=nil;NSDictionary *result=nil;NSString *normalized=Normalize(target);
        if(!normalized.length||normalized.length>320||[normalized rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location!=NSNotFound||(mutation&&!TVAppleValidBundleID(application)))
            error=TVAppleError(TVAppleErrorInvalidRequest,@"A valid Apple ID and explicit native application bundle ID are required.");
        else if(mutation&&uncertainMutation)error=TVAppleError(TVAppleErrorOutcomeUnknown,@"A previous mutation has an uncertain outcome; inspect state before further writes.");
        else if(![self->_backend conformsToProtocol:@protocol(TVAppleSignInWithAppleBackend)])error=TVAppleError(TVAppleErrorUnsupported,@"Native Sign in with Apple backend is unavailable.");
        else{
            id<TVAppleSignInWithAppleBackend> backend=(id)self->_backend;
            result=mutation?[backend stopUsingAppleIDForBundleID:application appleID:normalized error:&error]:[backend signInWithAppleAppsForAppleID:normalized error:&error];
            if(!result&&!error)error=TVAppleError(mutation?TVAppleErrorOutcomeUnknown:TVAppleErrorBackendRead,@"Native application authorization returned no confirmed result.");
            if(mutation&&[error.domain isEqual:TVAppleErrorDomain]&&error.code==TVAppleErrorOutcomeUnknown)uncertainMutation=YES;
        }
        dispatch_async(self->_callbacks,^{reply(result,error);});
    }});
}
- (void)enqueueNameSettings:(NSString *)appleID firstName:(NSString *)first lastName:(NSString *)last mutation:(BOOL)mutation completion:(TVAppleCompletion)completion{
    NSString *target=[appleID copy],*given=[first copy],*family=[last copy];TVAppleCompletion reply=[completion copy];
    dispatch_async(Worker(),^{@autoreleasepool{
        NSError *error=nil;NSDictionary *result=nil;NSString *normalized=Normalize(target);
        if(!normalized.length||normalized.length>320||[normalized rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location!=NSNotFound||
           (mutation&&(!TVAppleValidName(given)||!TVAppleValidName(family))))
            error=TVAppleError(TVAppleErrorInvalidRequest,@"A valid Apple ID and explicit First Name and Last Name are required.");
        else if(mutation&&uncertainMutation)error=TVAppleError(TVAppleErrorOutcomeUnknown,@"A previous mutation has an uncertain outcome; inspect state before further writes.");
        else if(![self->_backend conformsToProtocol:@protocol(TVAppleNameSettingsBackend)])error=TVAppleError(TVAppleErrorUnsupported,@"Native name settings backend is unavailable.");
        else{
            id<TVAppleNameSettingsBackend> backend=(id)self->_backend;
            result=mutation?[backend setFirstName:given lastName:family appleID:normalized error:&error]:[backend nameSettingsForAppleID:normalized error:&error];
            if(!result&&!error)error=TVAppleError(mutation?TVAppleErrorOutcomeUnknown:TVAppleErrorBackendRead,@"Native name settings returned no confirmed result.");
            if(mutation&&[error.domain isEqual:TVAppleErrorDomain]&&error.code==TVAppleErrorOutcomeUnknown)uncertainMutation=YES;
        }
        dispatch_async(self->_callbacks,^{reply(result,error);});
    }});
}
- (void)enqueueEmailAction:(NSString *)action appleID:(NSString *)appleID value:(NSString *)value code:(NSString *)code completion:(TVAppleCompletion)completion {
    NSString *target=[appleID copy],*input=[value copy],*verification=[code copy];TVAppleCompletion reply=[completion copy];
    dispatch_async(Worker(),^{@autoreleasepool{
        NSError *error=nil;NSDictionary *result=nil;NSString *normalized=Normalize(target);
        BOOL isVerification=[action isEqual:@"verify"];
        BOOL valid=normalized.length&&normalized.length<=320&&[normalized rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location==NSNotFound;
        valid=valid&&(isVerification?(input.length>0&&input.length<=128&&verification.length==6&&
            [verification rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789"]invertedSet]].location==NSNotFound):TVAppleValidEmailAddress(input));
        if(!valid)error=TVAppleError(TVAppleErrorInvalidRequest,@"A valid target, email address or six-digit email verification code is required.");
        else if(uncertainMutation)error=TVAppleError(TVAppleErrorOutcomeUnknown,@"A previous mutation has an uncertain outcome; inspect state before further writes.");
        else if(![self->_backend conformsToProtocol:@protocol(TVAppleEmailActionsBackend)])error=TVAppleError(TVAppleErrorUnsupported,@"Native email actions backend is unavailable.");
        else{
            id<TVAppleEmailActionsBackend> backend=(id)self->_backend;
            if(isVerification)result=[backend verifyContactEmail:input code:verification appleID:normalized error:&error];
            else if([action isEqual:@"begin"])result=[backend beginContactEmail:input appleID:normalized error:&error];
            else if([action isEqual:@"forward"])result=[backend setRelayEmail:input appleID:normalized error:&error];
            else error=TVAppleError(TVAppleErrorInvalidRequest,@"Unknown email operation.");
            if(!result&&!error)error=TVAppleError(TVAppleErrorOutcomeUnknown,@"Native email action returned no confirmed result.");
            if([error.domain isEqual:TVAppleErrorDomain]&&error.code==TVAppleErrorOutcomeUnknown)uncertainMutation=YES;
        }
        dispatch_async(self->_callbacks,^{reply(result,error);});
    }});
}
- (void)enqueueEnableICloudAppleID:(NSString *)appleID password:(NSString *)password devicePasscode:(NSString *)passcode
 provider:(id<TVAppleVerificationCodeProvider>)provider completion:(TVAppleCompletion)completion {
    NSString *target=[appleID copy],*secret=[password copy],*localSecret=[passcode copy];
    TVAppleCompletion reply=[completion copy];
    dispatch_async(Worker(),^{@autoreleasepool{
        NSError *error=nil;
        NSDictionary *result=[self enableICloud:target password:secret passcode:localSecret provider:provider error:&error];
        dispatch_async(self->_callbacks,^{reply(result,error);});
    }});
}
- (NSDictionary *)enableICloud:(NSString *)appleID password:(NSString *)password passcode:(NSString *)passcode
 provider:(id<TVAppleVerificationCodeProvider>)provider error:(NSError **)error {
    NSString *target=Normalize(appleID);
    if(!target.length||target.length>320||[target rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location!=NSNotFound||
       !password.length||password.length>4096||!passcode.length||passcode.length>256) {
        *error=TVAppleError(TVAppleErrorInvalidRequest,@"Apple ID, password and local device passcode are required.");return nil;
    }
    if(uncertainMutation){*error=TVAppleError(TVAppleErrorOutcomeUnknown,@"A previous account mutation has an uncertain outcome.");return nil;}
    NSDictionary *before=[_backend snapshot:error];if(!before)return nil;
    for(NSDictionary *record in before[@"accounts"]) {
        if([record[@"selected"]boolValue]&&![Normalize(record[@"apple_id"])isEqual:target]) {
            *error=TVAppleError(TVAppleErrorConflict,@"Another Apple ID is signed in; explicitly sign it out before enabling iCloud.");return nil;
        }
    }
    if(![before[@"find_my_enabled"]isKindOfClass:NSNumber.class]){*error=TVAppleError(TVAppleErrorBackendRead,@"Find My state is unknown.");return nil;}
    if([before[@"find_my_enabled"]boolValue]){*error=TVAppleError(TVAppleErrorFindMyEnabled,@"Disable Find My before this iCloud enablement operation.");return nil;}
    // Preflight can save dataclasses even if local CDP recovery fails. Existing
    // account records therefore cannot skip the native authentication/CDP flow.
    BOOL alreadyEnabled=NO;
    for(NSDictionary *record in SignOutTargets(before,target,YES)) if([record[@"enabled_dataclasses"]count])alreadyEnabled=YES;
    if(![_backend conformsToProtocol:@protocol(TVAppleICloudBackend)]){*error=TVAppleError(TVAppleErrorUnsupported,@"iCloud enablement backend is unavailable.");return nil;}
    if(![(id<TVAppleICloudBackend>)_backend enableICloudAppleID:target password:password devicePasscode:passcode provider:provider error:error]) {
        if(!*error||(*error).code==TVAppleErrorOutcomeUnknown){uncertainMutation=YES;if(!*error)*error=TVAppleError(TVAppleErrorOutcomeUnknown,@"Native iCloud enablement has an uncertain outcome.");}
        return [self failedLoginForTarget:target stage:@"icloud_sign_in" error:error];
    }
    NSTimeInterval deadline=NSProcessInfo.processInfo.systemUptime+_verificationTimeout;
    NSDictionary *state=nil;BOOL verified=NO;
    do {
        state=[_backend snapshot:error];if(!state)break;
        NSArray *primary=SignOutTargets(state,target,YES);
        verified=primary.count==1 && [primary[0][@"enabled_dataclasses"]count]>0 &&
            [state[@"find_my_enabled"]isKindOfClass:NSNumber.class] && ![state[@"find_my_enabled"]boolValue];
        if(verified||NSProcessInfo.processInfo.systemUptime>=deadline)break;
        [[NSRunLoop currentRunLoop]runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    }while(YES);
    if(!verified){uncertainMutation=YES;*error=TVAppleError(TVAppleErrorOutcomeUnknown,@"Native iCloud success was not confirmed with data services enabled and Find My disabled.");return [self failedLoginForTarget:target stage:@"icloud_verification" error:error];}
    NSMutableOrderedSet *domains=[NSMutableOrderedSet new];for(NSDictionary *record in Targets(state,target))[domains addObject:record[@"domain"]];
    *error=nil;return @{@"outcome":@"succeeded",@"already_enabled":@(alreadyEnabled),@"state":state,@"signed_in_domains":domains.array};
}
- (void)signOutAppleID:(NSString *)appleID localDataPolicy:(TVAppleLocalDataPolicy)policy completion:(TVAppleCompletion)completion {
    [self enqueueSignOutAppleID:appleID localDataPolicy:policy iCloudOnly:NO completion:completion];
}
- (void)enqueueSignOutAppleID:(NSString *)appleID localDataPolicy:(TVAppleLocalDataPolicy)policy iCloudOnly:(BOOL)iCloudOnly completion:(TVAppleCompletion)completion {
    NSString *target = [appleID copy];
    TVAppleCompletion reply = [completion copy];
    dispatch_async(Worker(), ^{
        @autoreleasepool {
            NSError *error = nil;
            NSDictionary *result = [self signOut:target policy:policy iCloudOnly:iCloudOnly error:&error];
            dispatch_async(self->_callbacks, ^{ reply(result, error); });
        }
    });
}
- (NSDictionary *)signOut:(NSString *)appleID policy:(TVAppleLocalDataPolicy)policy iCloudOnly:(BOOL)iCloudOnly error:(NSError **)error {
    NSString *target = Normalize(appleID);
    if (!target.length || target.length > 320 || [target rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound ||
        (policy != TVAppleLocalDataKeep && policy != TVAppleLocalDataRemove)) {
        *error = TVAppleError(TVAppleErrorInvalidRequest, @"Explicit Apple ID and local data policy are required."); return nil;
    }
    if (uncertainMutation) {
        *error = TVAppleError(TVAppleErrorOutcomeUnknown, @"A previous mutation has an uncertain outcome; inspect state and restart the module before further writes."); return nil;
    }
    NSDictionary *initial = [_backend snapshot:error];
    if (!initial) return nil;
    NSArray *targets = SignOutTargets(initial, target, iCloudOnly);
    NSMutableArray *prepared = [NSMutableArray new];
    for (NSDictionary *record in targets) {
        id item = [_backend prepareAccount:record policy:policy error:error];
        if (!item) return nil;
        [prepared addObject:item];
    }
    NSMutableArray *completed = [NSMutableArray new];
    NSMutableArray *warnings = [NSMutableArray new];
    NSMutableArray *recoveries = [NSMutableArray new];
    for(id item in prepared)if([item isKindOfClass:NSDictionary.class]&&item[@"service_recovery"])[recoveries addObject:item[@"service_recovery"]];
    BOOL attempted = NO;
    for (NSUInteger i = 0; i < prepared.count; i++) {
        attempted = YES;
        BOOL removed = [_backend removePreparedAccount:prepared[i] error:error];
        if ([prepared[i] isKindOfClass:NSDictionary.class] && prepared[i][@"removal_warning"]) [warnings addObject:prepared[i][@"removal_warning"]];
        if (!removed) {
            uncertainMutation = YES;
            *error = TVAppleError(TVAppleErrorOutcomeUnknown, @"A native removal did not complete successfully. Inspect account state; do not replay automatically.");
            NSMutableDictionary *result=[@{ @"outcome":@"unknown", @"completed_domains":[completed copy], @"service_recoveries":[recoveries copy], @"warnings":[warnings copy] } mutableCopy];
            NSError *readError=nil;
            NSDictionary *observed=[_backend snapshot:&readError];
            if(observed) {
                result[@"state"]=observed;
                result[@"target_signed_out"]=@(!SignOutTargets(observed,target,iCloudOnly).count);
            }
            return result;
        }
        [completed addObject:targets[i][@"domain"]];
    }
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + _verificationTimeout;
    NSDictionary *final = nil;
    do {
        final = [_backend snapshot:error];
        if (!final || !SignOutTargets(final, target, iCloudOnly).count) break;
        if (NSProcessInfo.processInfo.systemUptime >= deadline) break;
        [NSThread sleepForTimeInterval:0.1];
    } while (YES);
    // Callback success is insufficient: the refreshed system records must agree.
    if (!final || SignOutTargets(final, target, iCloudOnly).count) {
        if (attempted) uncertainMutation = YES;
        *error = TVAppleError(TVAppleErrorOutcomeUnknown, @"Final account verification failed. Inspect state; do not replay automatically.");
        return @{ @"outcome":@"unknown", @"completed_domains":[completed copy], @"service_recoveries":[recoveries copy], @"warnings":[warnings copy] };
    }
    *error = nil;
    return @{ @"outcome":@"succeeded", @"completed_domains":[completed copy],
              @"already_signed_out":@(!targets.count), @"state":final, @"service_recoveries":[recoveries copy], @"warnings":[warnings copy] };
}
- (void)enqueueDisableFindMyAppleID:(NSString *)appleID password:(NSString *)password completion:(TVAppleCompletion)completion {
    NSString *target=[appleID copy], *secret=[password copy];
    TVAppleCompletion reply=[completion copy];
    dispatch_async(Worker(), ^{
        @autoreleasepool {
            NSError *error=nil;
            NSDictionary *result=[self disableFindMy:target password:secret error:&error];
            dispatch_async(self->_callbacks, ^{reply(result,error);});
        }
    });
}
- (NSDictionary *)disableFindMy:(NSString *)appleID password:(NSString *)password error:(NSError **)error {
    NSString *target=Normalize(appleID);
    if (!target.length || target.length>320 || [target rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location!=NSNotFound || !password.length || password.length>4096) {
        *error=TVAppleError(TVAppleErrorInvalidRequest,@"Apple ID and password are required.");return nil;
    }
    if (uncertainMutation) { *error=TVAppleError(TVAppleErrorOutcomeUnknown,@"A previous account mutation has an uncertain outcome.");return nil; }
    NSDictionary *before=[_backend snapshot:error];if(!before)return nil;
    if (![before[@"find_my_enabled"]isKindOfClass:NSNumber.class]) { *error=TVAppleError(TVAppleErrorBackendRead,@"Find My state is unknown.");return nil; }
    NSDictionary *primary=nil;
    for(NSDictionary *record in before[@"accounts"]) {
        if([record[@"domain"]isEqual:@"icloud"] && [record[@"primary"]boolValue] && [record[@"selected"]boolValue]) {
            if(primary || ![Normalize(record[@"apple_id"])isEqual:target]) { *error=TVAppleError(TVAppleErrorConflict,@"A matching primary iCloud account is required.");return nil; }
            primary=record;
        }
    }
    if (![before[@"find_my_enabled"]boolValue]) { *error=nil;return @{@"outcome":@"succeeded",@"already_disabled":@YES,@"state":before}; }
    if(!primary) { *error=TVAppleError(TVAppleErrorConflict,@"A matching primary iCloud account is required.");return nil; }
    if(![_backend conformsToProtocol:@protocol(TVAppleFindMyBackend)]) { *error=TVAppleError(TVAppleErrorUnsupported,@"Find My disable backend is unavailable.");return nil; }
    if(![(id<TVAppleFindMyBackend>)_backend disableFindMyAppleID:target password:password error:error]) {
        if(!*error || (*error).code==TVAppleErrorOutcomeUnknown) {
            uncertainMutation=YES;
            if (!*error) *error=TVAppleError(TVAppleErrorOutcomeUnknown,@"Find My disable has an uncertain outcome. Inspect state; do not replay automatically.");
        }
        return @{@"outcome":uncertainMutation?@"unknown":@"failed"};
    }
    NSTimeInterval deadline=NSProcessInfo.processInfo.systemUptime+_verificationTimeout;
    NSDictionary *state=nil;BOOL verified=NO;
    do {
        state=[_backend snapshot:error];if(!state)break;
        BOOL matching=NO;
        for(NSDictionary *record in state[@"accounts"]) if([record[@"identifier"]isEqual:primary[@"identifier"]] && [record[@"primary"]boolValue] && [record[@"selected"]boolValue] && [Normalize(record[@"apple_id"])isEqual:target])matching=YES;
        verified=matching && [state[@"find_my_enabled"]isKindOfClass:NSNumber.class] && ![state[@"find_my_enabled"]boolValue];
        if(verified || NSProcessInfo.processInfo.systemUptime>=deadline)break;
        [NSThread sleepForTimeInterval:0.1];
    } while(YES);
    if(!verified) { uncertainMutation=YES;*error=TVAppleError(TVAppleErrorOutcomeUnknown,@"Find My disable could not be verified.");return @{@"outcome":@"unknown"}; }
    *error=nil;return @{@"outcome":@"succeeded",@"already_disabled":@NO,@"state":state};
}
- (void)signInAppStoreAppleID:(NSString *)appleID password:(NSString *)password
   verificationCodeProvider:(id<TVAppleVerificationCodeProvider>)provider completion:(TVAppleCompletion)completion {
    NSString *target = [appleID copy], *secret = [password copy];
    TVAppleCompletion reply = [completion copy];
    dispatch_async(Worker(), ^{
        @autoreleasepool {
            NSError *error = nil;
            NSDictionary *result = [self signInStore:target password:secret provider:provider error:&error];
            dispatch_async(self->_callbacks, ^{ reply(result, error); });
        }
    });
}
- (NSDictionary *)signInStore:(NSString *)appleID password:(NSString *)password
                     provider:(id<TVAppleVerificationCodeProvider>)provider error:(NSError **)error {
    NSString *target = Normalize(appleID);
    if (!target.length || target.length > 320 || [target rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound ||
        !password.length || password.length > 4096) {
        *error = TVAppleError(TVAppleErrorInvalidRequest, @"Apple ID and password are required."); return nil;
    }
    if (uncertainMutation) {
        *error = TVAppleError(TVAppleErrorOutcomeUnknown, @"A previous account mutation has an uncertain outcome."); return nil;
    }
    if (![_backend conformsToProtocol:@protocol(TVAppleStoreLoginBackend)]) {
        *error = TVAppleError(TVAppleErrorUnsupported, @"App Store authentication backend is unavailable."); return nil;
    }
    NSDictionary *before = [_backend snapshot:error]; if (!before) return nil;
    appleID = target;
    for (NSDictionary *record in before[@"accounts"]) {
        if ([record[@"selected"] boolValue] && ![Normalize(record[@"apple_id"]) isEqual:target]) {
            *error = TVAppleError(TVAppleErrorConflict, @"Another Apple ID is currently signed in; explicitly sign it out before switching."); return nil;
        }
        // Apple's account lookup is case-sensitive; preserve an existing stored spelling.
        if ([record[@"domain"] isEqual:@"media"] && [Normalize(record[@"apple_id"]) isEqual:target]) appleID = record[@"apple_id"];
    }
    id<TVAppleStoreLoginBackend> auth = (id)_backend;
    TVAppleStoreAttempt attempt = [auth authenticateStoreAppleID:appleID password:password error:error];
    BOOL usedTrust = NO;
    if (attempt == TVAppleStoreAttemptNeedsTrust && provider) {
        *error = nil;
        if (![auth establishTrustForAppleID:appleID password:password provider:provider error:error]) {
            if ((*error).code == TVAppleErrorOutcomeUnknown) uncertainMutation = YES;
            return [self failedLoginForTarget:target stage:@"two_factor" error:error];
        }
        usedTrust = YES;
        *error = nil;
        // One retry after a verified trust bootstrap, never a blind retry loop.
        attempt = [auth authenticateStoreAppleID:appleID password:password error:error];
    }
    if (attempt != TVAppleStoreAttemptSucceeded) {
        if (attempt == TVAppleStoreAttemptUnknown) uncertainMutation = YES;
        if (!*error) *error = TVAppleError(TVAppleErrorAuthenticationFailed, @"App Store authentication failed.");
        return [self failedLoginForTarget:target stage:@"store_authentication" error:error];
    }
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + _verificationTimeout;
    NSDictionary *state = nil;
    BOOL verified = NO;
    do {
        *error = nil;
        state = [_backend snapshot:error];
        if (!state) break;
        for (NSDictionary *record in Targets(state, target)) {
            if ([record[@"domain"] isEqual:@"media"] && [record[@"authenticated"] boolValue]) verified = YES;
        }
        if (verified || NSProcessInfo.processInfo.systemUptime >= deadline) break;
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    } while (YES);
    if (!verified) {
        uncertainMutation = YES;
        *error = TVAppleError(TVAppleErrorOutcomeUnknown, @"Store success was not confirmed by an active authenticated system account.");
        return @{ @"outcome":@"unknown", @"stage":@"verification" };
    }
    NSMutableOrderedSet *domains = [NSMutableOrderedSet new];
    for (NSDictionary *record in Targets(state, target)) [domains addObject:record[@"domain"]];
    *error = nil;
    return @{ @"outcome":@"succeeded", @"authenticated":@YES, @"two_factor_bootstrap":@(usedTrust),
              @"signed_in_domains":domains.array, @"state":state };
}
- (NSDictionary *)failedLoginForTarget:(NSString *)target stage:(NSString *)stage error:(NSError **)error {
    NSError *queryError = nil;
    NSDictionary *state = [_backend snapshot:&queryError];
    if (!state) {
        uncertainMutation = YES;
        *error = TVAppleError(TVAppleErrorOutcomeUnknown, @"Authentication failed and the resulting account state could not be read.");
        return @{ @"outcome":@"unknown", @"stage":stage };
    }
    NSMutableOrderedSet *domains = [NSMutableOrderedSet new];
    for (NSDictionary *record in Targets(state, target)) [domains addObject:record[@"domain"]];
    return @{ @"outcome":uncertainMutation ? @"unknown" : @"failed", @"stage":stage, @"state":state,
              @"signed_in_domains":domains.array };
}
@end
