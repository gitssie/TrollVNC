#import "TVAppleBackend.h"
#import "TVApplePolicy.h"
#import "TVAppleStoreLogin.h"
#import "TVAppleFindMy.h"
#import "TVAppleICloud.h"
#import "TVAppleEmailSettings.h"
#include <assert.h>

@interface EmailInfo : NSObject
@property id accountName,primaryEmailAddress,reachableEmails,forwardingEmail;
@property NSString *authenticationToken;
@end
@implementation EmailInfo
@end

@interface EmailAccount : NSObject
@property NSString *username,*identifier;
@end
@implementation EmailAccount
@end
@interface EmailManager : NSObject
@property EmailAccount *account;
@property BOOL changed;
@end
@implementation EmailManager
- (id)primaryAuthKitAccount{if(!self.changed)return self.account;EmailAccount *a=[EmailAccount new];a.username=self.account.username;a.identifier=@"different";return a;}
- (id)altDSIDForAccount:(id)account{(void)account;return @"private-identifier";}
@end
@interface EmailController : NSObject
@property EmailInfo *info;
@property NSString *mode;
@property EmailManager *manager;
@property(copy) void(^pending)(id,NSError*);
@end
@implementation EmailController
- (void)fetchUserInformationForAltDSID:(NSString *)identifier completion:(void(^)(id,NSError*))completion{
    assert([identifier isEqual:@"private-identifier"]);
    if([self.mode isEqual:@"timeout"]){self.pending=completion;return;}
    if([self.mode isEqual:@"identity"])self.manager.changed=YES;
    if([self.mode isEqual:@"error"])completion(self.info,[NSError errorWithDomain:@"native-private" code:42 userInfo:@{@"token":@"must-not-export"}]);
    else completion(self.info,nil);
    completion(nil,[NSError errorWithDomain:@"duplicate" code:99 userInfo:nil]);
}
@end

// Exercise the production daemon-state reader, including the observed off enum.
static NSUInteger daemonState;
static NSError *daemonError;
@interface FMDFMIPManager : NSObject
+ (instancetype)sharedInstance;
- (void)fmipStateWithCompletion:(void (^)(NSUInteger, NSError *))completion;
@end
@implementation FMDFMIPManager
+ (instancetype)sharedInstance { return [self new]; }
- (void)fmipStateWithCompletion:(void (^)(NSUInteger, NSError *))completion {
    completion(daemonState, daemonError);
    completion(0, nil); // A duplicate callback must not overwrite the first.
}
@end

// Native provider regression fixtures: exercise the production local secret path.
static BOOL localUnlockOK=YES, localHasSecret=YES;
static int localSimpleType=0;
static NSUInteger localUnlockCalls;
@interface MCProfileConnection : NSObject
+ (id)sharedConnection;
- (BOOL)unlockDeviceWithPasscode:(NSString *)passcode outError:(NSError **)error;
- (int)unlockScreenTypeWithOutSimplePasscodeType:(int *)type;
@end
@implementation MCProfileConnection
+ (id)sharedConnection{return [self new];}
- (BOOL)unlockDeviceWithPasscode:(NSString *)passcode outError:(NSError **)error {
    assert([passcode isEqual:@"123456"]);localUnlockCalls++;
    if(!localUnlockOK)*error=[NSError errorWithDomain:@"fixture" code:1 userInfo:nil];return localUnlockOK;
}
- (int)unlockScreenTypeWithOutSimplePasscodeType:(int *)type{*type=localSimpleType;return 0;}
@end
@interface CDPLocalDevice : NSObject
+ (id)sharedInstance;
- (BOOL)hasLocalSecret;
@end
@implementation CDPLocalDevice
+ (id)sharedInstance{return [self new];}
- (BOOL)hasLocalSecret{return localHasSecret;}
@end
@interface CDPLocalSecret : NSObject
@property NSUInteger secretType;
- (id)initWithValidatedSecret:(NSString *)secret secretType:(NSUInteger)type;
@end
@implementation CDPLocalSecret
- (id)initWithValidatedSecret:(NSString *)secret secretType:(NSUInteger)type {
    assert(localUnlockOK && localUnlockCalls && [secret isEqual:@"123456"]);
    if((self=[super init]))_secretType=type;return self;
}
@end
@interface CloudValidator : NSObject
@property NSError *error;
- (void)cancelValidationWithError:(NSError *)error;
@end
@implementation CloudValidator
- (void)cancelValidationWithError:(NSError *)error{self.error=error;}
@end
// Private class declarations for directly testing production input handling.
@interface TVAppleCloudInput : NSObject
@property NSString *passcode;
@property NSError *failure;
@property BOOL closed;
- (void)signInFlowController:(id)flow presentGenericTermsUIForAccount:(id)account completion:(void (^)(BOOL,id,NSError *))completion;
- (void)cdpContext:(id)context promptForLocalSecretWithCompletion:(void (^)(id,NSError *))completion;
- (void)cdpContext:(id)context promptForRecoveryKeyWithValidator:(id)validator completion:(void (^)(BOOL,NSError *))completion;
- (void)cdpContext:(id)context promptForRecoveryKeyWithSecretValidator:(id)validator completion:(void (^)(BOOL,NSError *))completion;
- (void)cdpContext:(id)context presentRecoveryKeyWithValidator:(id)validator completion:(void (^)(BOOL,NSError *))completion;
- (void)cdpContext:(id)context promptForAdoptionOfMultipleICSC:(void (^)(BOOL,NSError *))completion;
- (void)cdpContext:(id)context promptForBeneficiaryAccessKeyWithCompletion:(void (^)(id,NSError *))completion;
- (void)cdpContext:(id)context promptForEDPRecoveryTokenWithValidator:(id)validator successfulCDPRecoveryContinuationHandler:(void (^)(void))continuation;
- (void)cdpRecoveryFlowContext:(id)context promptForRemoteSecretWithDevices:(id)devices validator:(id)validator;
@end

// Run the real native wait/close path with a framework that never sends its total completion.
@interface FakeCloudFlow : NSObject
@property TVAppleCloudInput *retainedInput;
@property id delegate,cdpUIProvider;
@property BOOL shouldAutomaticallySaveSignInResults;
@property(copy) void(^pending)(BOOL,id,NSError *);
@property NSString *mode;
@end
@implementation FakeCloudFlow
- (void)signInWithIDMSAuthenticationResults:(NSDictionary *)results completion:(void (^)(BOOL,id,NSError *))completion {
    (void)results;self.pending=completion;self.retainedInput=self.cdpUIProvider;
    if([self.mode isEqual:@"terms"])
        [self.delegate signInFlowController:self presentGenericTermsUIForAccount:nil completion:^(BOOL success,id account,NSError *error){(void)account;assert(!success&&error);}];
    else if([self.mode isEqual:@"async_terms"]) {
        TVAppleCloudInput *input=self.cdpUIProvider;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,20*NSEC_PER_MSEC),dispatch_get_global_queue(QOS_CLASS_DEFAULT,0),^{
            [input signInFlowController:nil presentGenericTermsUIForAccount:nil completion:^(BOOL success,id account,NSError *error){(void)account;assert(!success&&error);}];
        });
    }
    else if([self.mode isEqual:@"passcode"])
        [self.cdpUIProvider cdpContext:nil promptForLocalSecretWithCompletion:^(id value,NSError *error){assert(!value&&error);}];
    else if([self.mode isEqual:@"native_error"])
        completion(NO,nil,[NSError errorWithDomain:@"com.apple.appleaccount" code:403 userInfo:@{@"private_token":@"DO-NOT-EXPORT"}]);
    else if([self.mode isEqual:@"success"]) {
        completion(YES,[NSObject new],nil);
        completion(NO,nil,[NSError errorWithDomain:@"late" code:99 userInfo:nil]);
    }
    else if([self.mode isEqual:@"missing_account"])completion(YES,nil,nil);
}
@end

// Exercise the production removal call boundary, not a copied callback predicate.
@interface TVAppleNativeBackend : NSObject <TVAppleBackend>
@end
static BOOL removalOK=YES, removalStillPresent, removalReadFailure, removalFindMy;
static NSError *removalError;
static NSDictionary *removalRecord;
@interface RemovalStore : NSObject
- (NSDictionary *)dataclassActionsForAccountDeletion:(id)account error:(NSError **)error;
- (void)removeAccount:(id)account withDataclassActions:(NSDictionary *)actions completion:(void (^)(BOOL,NSError *))completion;
@end
@implementation RemovalStore
- (NSDictionary *)dataclassActionsForAccountDeletion:(id)account error:(NSError **)error{(void)account;(void)error;return @{};}
- (void)removeAccount:(id)account withDataclassActions:(NSDictionary *)actions completion:(void (^)(BOOL,NSError *))completion{
    (void)account;(void)actions;completion(removalOK,removalError);completion(NO,nil);
}
@end
@interface RemovalBackend : TVAppleNativeBackend
@property NSUInteger reads;
@end
@implementation RemovalBackend
- (NSDictionary *)snapshot:(NSError **)error {
    self.reads++;
    if(self.reads>1&&removalReadFailure){*error=TVAppleError(TVAppleErrorBackendRead,@"fixture");return nil;}
    return @{@"accounts":(self.reads==1||removalStillPresent)?@[removalRecord]:@[],@"find_my_enabled":@(self.reads>1&&removalFindMy)};
}
@end

@interface FakeBackend : NSObject <TVAppleBackend, TVAppleStoreLoginBackend, TVAppleFindMyBackend, TVAppleICloudBackend, TVAppleEmailSettingsBackend>
@property NSMutableArray *records;
@property NSMutableArray *removed;
@property BOOL findMy, readFailure, prepareFailure, callbackFailure, stale, failAfterRemoval;
@property BOOL removedBeforeFailure;
@property NSString *loginMode;
@property NSUInteger loginAttempts, bootstraps, findMyAttempts;
@property NSUInteger cloudAttempts,emailReads;
@end
@interface FakeAction : NSObject
@property NSString *name;
@property BOOL destructive;
@end
@implementation FakeAction
- (NSString *)description { return _name; }
- (BOOL)isDestructive { return _destructive; }
@end
static FakeAction *Action(NSString *name, BOOL destructive) {
    FakeAction *action = [FakeAction new]; action.name = name; action.destructive = destructive; return action;
}
@implementation FakeBackend
- (instancetype)init { if ((self = [super init])) { _records = [NSMutableArray new]; _removed = [NSMutableArray new]; } return self; }
- (NSDictionary *)emailSettingsForAppleID:(NSString *)appleID error:(NSError **)error {
    (void)error;self.emailReads++;assert([appleID isEqual:@"test@example.com"]);
    return @{@"apple_id":appleID,@"reachable_emails":@[@"verified@example.com"]};
}
- (NSDictionary *)snapshot:(NSError **)error {
    if (_readFailure || (_failAfterRemoval && (_removed.count || _findMyAttempts || _cloudAttempts)) || ([_loginMode isEqual:@"trust_read_failure"] && _bootstraps)) {
        *error = TVAppleError(TVAppleErrorBackendRead, @"read failed"); return nil;
    }
    return @{ @"accounts":[_records copy], @"find_my_enabled":@(_findMy) };
}
- (id)prepareAccount:(NSDictionary *)account policy:(TVAppleLocalDataPolicy)policy error:(NSError **)error {
    if (_findMy || (_prepareFailure && [account[@"domain"] isEqual:@"media"])) {
        *error = TVAppleError(_findMy ? TVAppleErrorFindMyEnabled : TVAppleErrorUnsupported, @"preflight rejected"); return nil;
    }
    return account;
}
- (BOOL)removePreparedAccount:(NSDictionary *)record error:(NSError **)error {
    [_removed addObject:record[@"domain"]];
    if (_callbackFailure) {
        if(_removedBeforeFailure)[_records removeObject:record];
        *error = TVAppleError(TVAppleErrorOutcomeUnknown, @"callback timeout"); return NO;
    }
    if (!_stale) [_records removeObject:record];
    return YES;
}
- (BOOL)disableFindMyAppleID:(NSString *)appleID password:(NSString *)password error:(NSError **)error {
    assert([appleID isEqual:@"test@example.com"] && [password isEqual:@"test-secret"]);_findMyAttempts++;
    if(_callbackFailure){*error=TVAppleError(TVAppleErrorOutcomeUnknown,@"timeout");return NO;}
    if([_loginMode isEqual:@"rejected"]){*error=TVAppleError(TVAppleErrorAuthenticationFailed,@"rejected");return NO;}
    if(!_stale)_findMy=NO;return YES;
}
- (BOOL)enableICloudAppleID:(NSString *)appleID password:(NSString *)password devicePasscode:(NSString *)passcode provider:(id<TVAppleVerificationCodeProvider>)provider error:(NSError **)error {
    (void)provider;assert([appleID isEqual:@"test@example.com"]&&[password isEqual:@"test-secret"]&&[passcode isEqual:@"123456"]);_cloudAttempts++;
    if([_loginMode hasPrefix:@"cloud_rejected"]){*error=TVAppleError(TVAppleErrorAuthenticationFailed,@"rejected");return NO;}
    if(!_stale&&![[_records valueForKey:@"domain"]containsObject:@"icloud"])[_records addObject:@{@"identifier":@"new-cloud",@"apple_id":appleID,@"domain":@"icloud",@"selected":@YES,@"primary":@YES,@"enabled_dataclasses":@[@"com.apple.Dataclass.Contacts"]}];
    if([_loginMode isEqual:@"cloud_unknown"]){*error=TVAppleError(TVAppleErrorOutcomeUnknown,@"partial native save");return NO;}
    if([_loginMode isEqual:@"cloud_findmy_after"])_findMy=YES;
    return YES;
}
- (TVAppleStoreAttempt)authenticateStoreAppleID:(NSString *)appleID password:(NSString *)password error:(NSError **)error {
    assert([appleID isEqual:@"test@example.com"] && [password isEqual:@"test-secret"]);
    _loginAttempts++;
    if ([_loginMode isEqual:@"timeout"]) { *error = TVAppleError(TVAppleErrorOutcomeUnknown, @"timeout"); return TVAppleStoreAttemptUnknown; }
    if ([_loginMode isEqual:@"rejected"]) { *error = TVAppleError(TVAppleErrorAuthenticationFailed, @"rejected"); return TVAppleStoreAttemptFailed; }
    if ([_loginMode hasPrefix:@"trust"] && _loginAttempts == 1) return TVAppleStoreAttemptNeedsTrust;
    if ([_loginMode isEqual:@"trust_rejected"] || [_loginMode isEqual:@"trust_read_failure"]) {
        *error = TVAppleError(TVAppleErrorAuthenticationFailed, @"Store rejected after trust"); return TVAppleStoreAttemptFailed;
    }
    [_records addObject:@{ @"identifier":@"new-media", @"apple_id":appleID, @"domain":@"media",
                          @"selected":@(![_loginMode isEqual:@"inactive"]), @"authenticated":@(![_loginMode isEqual:@"unverified"]) }];
    return TVAppleStoreAttemptSucceeded;
}
- (BOOL)establishTrustForAppleID:(NSString *)appleID password:(NSString *)password provider:(id<TVAppleVerificationCodeProvider>)provider error:(NSError **)error {
    (void)password; (void)provider; (void)error; _bootstraps++;
    if ([_loginMode hasPrefix:@"trust_"]) [_records addObject:@{ @"identifier":@"new-identity", @"apple_id":appleID, @"domain":@"identity", @"selected":@YES }];
    return YES;
}
@end
@interface WaitingBackend : FakeBackend
@property dispatch_semaphore_t entered, proceed;
@end
@implementation WaitingBackend
- (TVAppleStoreAttempt)authenticateStoreAppleID:(NSString *)appleID password:(NSString *)password error:(NSError **)error {
    (void)appleID; (void)password;
    dispatch_semaphore_signal(self.entered);
    dispatch_semaphore_wait(self.proceed, DISPATCH_TIME_FOREVER);
    *error=TVAppleError(TVAppleErrorAuthenticationFailed,@"rejected");
    return TVAppleStoreAttemptFailed;
}
@end
@interface FakeCodeProvider : NSObject <TVAppleVerificationCodeProvider>
@end
@implementation FakeCodeProvider
- (void)prepareForAuthentication:(void (^)(NSError *))completion { completion(nil); }
- (void)requestCodeForChallenge:(NSDictionary *)challenge completion:(TVAppleCodeCompletion)completion { (void)challenge; completion(@"123456", nil); }
@end
static NSDictionary *Record(NSString *identifier, NSString *domain, NSString *appleID, BOOL selected) {
    return @{ @"identifier":identifier, @"domain":domain, @"apple_id":appleID, @"selected":@(selected), @"primary":@([domain isEqual:@"icloud"] && selected) };
}
static NSDictionary *SignOut(TVAppleServices *service, NSString *target, TVAppleLocalDataPolicy policy, NSError **outError) {
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block NSDictionary *result = nil;
    __block NSError *error = nil;
    [service signOutAppleID:target localDataPolicy:policy completion:^(NSDictionary *r, NSError *e) {
        assert(!NSThread.isMainThread); result = r; error = e; dispatch_semaphore_signal(done);
    }];
    assert(!dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC)));
    *outError = error;
    return result;
}
int main(int argc, char **argv) {
    @autoreleasepool {
        assert(argc == 2);
        NSString *test = @(argv[1]);
        if([test isEqual:@"independent_progress"]) {
            WaitingBackend *backend=[WaitingBackend new];
            backend.entered=dispatch_semaphore_create(0); backend.proceed=dispatch_semaphore_create(0);
            TVAppleServices *service=[[TVAppleServices alloc]initWithBackend:backend callbackQueue:dispatch_get_global_queue(QOS_CLASS_DEFAULT,0)verificationTimeout:0];
            dispatch_semaphore_t read=dispatch_semaphore_create(0), login=dispatch_semaphore_create(0);
            [service signInAppStoreAppleID:@"test@example.com" password:@"test-secret" verificationCodeProvider:nil completion:^(NSDictionary *r,NSError *e){(void)r;assert(e);dispatch_semaphore_signal(login);}];
            assert(!dispatch_semaphore_wait(backend.entered,dispatch_time(DISPATCH_TIME_NOW,3*NSEC_PER_SEC)));
            [service queryAccountState:^(NSDictionary *r,NSError *e){assert(r&&!e);dispatch_semaphore_signal(read);}];
            assert(!dispatch_semaphore_wait(read,dispatch_time(DISPATCH_TIME_NOW,1*NSEC_PER_SEC)));
            dispatch_semaphore_signal(backend.proceed);
            assert(!dispatch_semaphore_wait(login,dispatch_time(DISPATCH_TIME_NOW,3*NSEC_PER_SEC)));
            puts("PASS independent account query while authentication waits");return 0;
        }
        if([test hasPrefix:@"email_native_"]){
            EmailManager *manager=[EmailManager new];EmailAccount *account=[EmailAccount new];account.username=@"test@example.com";account.identifier=@"original";manager.account=account;
            EmailController *controller=[EmailController new];controller.manager=manager;controller.info=[EmailInfo new];controller.info.reachableEmails=@[@"verified@example.com"];
            controller.info.forwardingEmail=@"target@example.com";controller.mode=[test substringFromIndex:[@"email_native_"length]];
            if([controller.mode isEqual:@"conflict"])account.username=@"other@example.com";
            if([controller.mode isEqual:@"response_identity"])controller.info.accountName=@"other@example.com";
            NSError *error=nil;NSDictionary *result=TVAppleFetchEmailSettings(manager,controller,@"test@example.com",.05,&error);
            if([controller.mode isEqual:@"success"])assert(result&&!error&&[result[@"apple_id"]isEqual:@"test@example.com"]);
            else if([@[@"conflict",@"identity",@"response_identity"]containsObject:controller.mode])assert(!result&&error.code==TVAppleErrorConflict);
            else assert(!result&&error.code==TVAppleErrorBackendRead&&[error.localizedDescription rangeOfString:@"must-not-export"].location==NSNotFound);
            if(controller.pending){controller.pending(controller.info,nil);controller.pending(controller.info,nil);controller.pending=nil;}
            printf("PASS %s\n",argv[1]);return 0;
        }
        if([test isEqual:@"email_response"]){
            EmailInfo *info=[EmailInfo new];info.reachableEmails=@[];info.forwardingEmail=@"target@example.com";info.authenticationToken=@"must-not-export";
            NSError *error=nil;NSDictionary *result=TVAppleEmailSettingsFromUserInfo(info,&error);
            assert(result&&!error&&result[@"primary_email"]==NSNull.null&&[result[@"reachable_emails"]count]==0);
            assert([result[@"forwarding_email"]isEqual:@"target@example.com"]&&!result[@"authenticationToken"]&&result.count==5);
            info.reachableEmails=nil;error=nil;
            assert(!TVAppleEmailSettingsFromUserInfo(info,&error)&&error.code==TVAppleErrorBackendRead);
            error=nil;info.reachableEmails=@[@"verified@example.com"];
            assert([TVAppleEmailSettingsFromUserInfo(info,&error)[@"reachable_emails"]count]==1);
            info.reachableEmails=@[@{@"token":@"must-not-export"}];
            assert(!TVAppleEmailSettingsFromUserInfo(info,&error)&&error.code==TVAppleErrorBackendRead);
            error=nil;info.reachableEmails=@[];info.forwardingEmail=@123;
            assert(!TVAppleEmailSettingsFromUserInfo(info,&error)&&error.code==TVAppleErrorBackendRead);
            error=nil;assert(!TVAppleEmailSettingsFromUserInfo([NSObject new],&error));
            error=nil;assert(!TVAppleEmailSettingsFromUserInfo(@{},&error)&&error.code==TVAppleErrorBackendRead);
            error=nil;assert(!TVAppleEmailSettingsFromUserInfo(@{@"reachableEmails":@"malformed"},&error)&&error.code==TVAppleErrorBackendRead);
            puts("PASS email_response");return 0;
        }
        if([test hasPrefix:@"email_query"]){
            FakeBackend *backend=[FakeBackend new];
            TVAppleServices *service=[[TVAppleServices alloc]initWithBackend:backend callbackQueue:dispatch_get_global_queue(QOS_CLASS_DEFAULT,0)verificationTimeout:0];
            dispatch_semaphore_t done=dispatch_semaphore_create(0);BOOL invalid=[test isEqual:@"email_query_invalid"];
            [service queryAppleIDEmailSettings:invalid?@"bad\nidentity":@" TEST@example.com " completion:^(NSDictionary *result,NSError *error){
                if(invalid)assert(!result&&error.code==TVAppleErrorInvalidRequest&&backend.emailReads==0);
                else assert(result&&!error&&backend.emailReads==1&&[result[@"apple_id"]isEqual:@"test@example.com"]);
                assert(!backend.removed.count);dispatch_semaphore_signal(done);
            }];
            assert(!dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,3*NSEC_PER_SEC)));
            printf("PASS %s\n",argv[1]);return 0;
        }

        if([test hasPrefix:@"signout_warning_"]) {
            FakeBackend *backend=[FakeBackend new];
            NSMutableDictionary *cloud=[Record(@"cloud",@"icloud",@"test@example.com",YES) mutableCopy];
            cloud[@"removal_warning"]=@{@"domain":@"icloud",@"kind":@"dataclass_action_failed",@"error_domain":@"com.apple.accounts",@"code":@17};
            [backend.records addObject:cloud];
            backend.callbackFailure=[test isEqual:@"signout_warning_unknown"];
            TVAppleServices *service=[[TVAppleServices alloc]initWithBackend:backend callbackQueue:dispatch_get_global_queue(QOS_CLASS_DEFAULT,0) verificationTimeout:0];
            NSError *error=nil;NSDictionary *result=SignOut(service,@"test@example.com",TVAppleLocalDataRemove,&error);
            assert([result[@"warnings"]count]==1&&[result[@"warnings"][0][@"code"]integerValue]==17);
            if(backend.callbackFailure)assert(error.code==TVAppleErrorOutcomeUnknown&&[result[@"outcome"]isEqual:@"unknown"]);
            else assert(!error&&[result[@"outcome"]isEqual:@"succeeded"]);
            printf("PASS %s\n",argv[1]);return 0;
        }
        if([test hasPrefix:@"native_remove_"]) {
            removalOK=![test isEqual:@"native_remove_denied"];
            removalStillPresent=[test isEqual:@"native_remove_present"];
            removalReadFailure=[test isEqual:@"native_remove_read_failure"];
            removalFindMy=[test isEqual:@"native_remove_findmy"];
            NSString *domain=[test isEqual:@"native_remove_wrong_domain"]?@"other":@"com.apple.accounts";
            NSInteger code=[test isEqual:@"native_remove_other_error"]?1:17;
            removalError=[test isEqual:@"native_remove_clean"]?nil:[NSError errorWithDomain:domain code:code userInfo:nil];
            removalRecord=@{@"identifier":@"cloud",@"domain":@"icloud",@"apple_id":@"test@example.com",@"selected":@YES,@"primary":@YES,@"enabled_dataclasses":@[]};
            NSMutableDictionary *prepared=[@{@"record":removalRecord,@"store":[RemovalStore new],@"account":[NSObject new],@"action_signature":@{},@"policy":@(TVAppleLocalDataRemove)} mutableCopy];
            RemovalBackend *backend=[RemovalBackend new];NSError *error=nil;
            BOOL ok=[backend removePreparedAccount:prepared error:&error];
            BOOL expected=[test isEqual:@"native_remove_clean"]||[test isEqual:@"native_remove_dataclass_warning"];
            assert(ok==expected);assert(expected?!error:error.code==TVAppleErrorOutcomeUnknown);
            if([test isEqual:@"native_remove_dataclass_warning"]){assert([prepared[@"removal_warning"][@"code"]integerValue]==17);assert(backend.reads==2);}
            else if(removalOK && [domain isEqual:@"com.apple.accounts"] && code==17 && removalError) assert(prepared[@"removal_warning"]);
            else assert(!prepared[@"removal_warning"]);
            printf("PASS %s\n",argv[1]);return 0;
        }
        if([test hasPrefix:@"cloud_flow_"]) {
            FakeCloudFlow *flow=[FakeCloudFlow new];
            flow.mode=[test substringFromIndex:11];
            if([flow.mode isEqual:@"passcode"])localUnlockOK=NO;
            NSTimeInterval started=NSProcessInfo.processInfo.systemUptime;
            NSError *error=nil;
            BOOL ok=TVAppleRunICloudFlow(flow,@{@"fixture":@YES},@"123456",.3,&error);
            NSTimeInterval elapsed=NSProcessInfo.processInfo.systemUptime-started;
            if([flow.mode isEqual:@"success"])assert(ok&&!error);
            else if([flow.mode isEqual:@"timeout"])assert(!ok&&error.code==TVAppleErrorOutcomeUnknown&&elapsed>=.25);
            else if([flow.mode isEqual:@"missing_account"])assert(!ok&&error.code==TVAppleErrorOutcomeUnknown&&elapsed<.15);
            else {
                assert(!ok&&error);
                assert(elapsed<.15);
                assert(error.code==([flow.mode hasSuffix:@"terms"]?TVAppleErrorAccountNeedsReview:[flow.mode isEqual:@"native_error"]?TVAppleErrorNativeFailure:TVAppleErrorAuthenticationFailed));
                if([flow.mode isEqual:@"native_error"]) {
                    assert([error.userInfo[@"TVAppleNativeDomain"]isEqual:@"com.apple.appleaccount"]);
                    assert([error.userInfo[@"TVAppleNativeCode"]integerValue]==403);
                    assert(!error.userInfo[@"private_token"]);
                }
            }
            assert(!flow.delegate&&!flow.cdpUIProvider);
            NSUInteger unlocks=localUnlockCalls;
            [flow.retainedInput cdpContext:nil promptForLocalSecretWithCompletion:^(id value,NSError *failure){assert(!value&&failure);}];
            assert(localUnlockCalls==unlocks);
            // A late success is not allowed to resurrect or overwrite the returned failure.
            flow.pending(YES,[NSObject new],nil);
            flow.pending(NO,nil,[NSError errorWithDomain:@"late" code:99 userInfo:nil]);
            assert(![TVAppleDiagnosticMessage(error) containsString:@"DO-NOT-EXPORT"]);
            printf("PASS %s\n",argv[1]);return 0;
        }
        if([test hasPrefix:@"native_cloud_"]) {
            TVAppleCloudInput *input=[TVAppleCloudInput new];input.passcode=@"123456";
            if([test isEqual:@"native_cloud_recovery"]) {
                CloudValidator *validator=[CloudValidator new];__block NSUInteger callbacks=0;
                void (^reject)(BOOL,NSError *)=^(BOOL success,NSError *error){assert(!success&&error.code==TVAppleErrorAccountNeedsReview);callbacks++;};
                [input cdpContext:nil promptForRecoveryKeyWithValidator:validator completion:reject];assert(validator.error);
                [input cdpContext:nil promptForRecoveryKeyWithSecretValidator:validator completion:reject];
                [input cdpContext:nil presentRecoveryKeyWithValidator:validator completion:reject];
                [input cdpContext:nil promptForAdoptionOfMultipleICSC:reject];
                [input cdpContext:nil promptForBeneficiaryAccessKeyWithCompletion:^(id key,NSError *error){assert(!key&&error);callbacks++;}];
                [input cdpContext:nil promptForEDPRecoveryTokenWithValidator:validator successfulCDPRecoveryContinuationHandler:^{assert(0);}];
                [input cdpRecoveryFlowContext:nil promptForRemoteSecretWithDevices:nil validator:validator];
                assert(callbacks==5&&input.failure);
            } else {
                localUnlockOK=![test isEqual:@"native_cloud_wrong_passcode"];
                localHasSecret=![test isEqual:@"native_cloud_no_passcode"];
                localSimpleType=[test isEqual:@"native_cloud_complex"]?-1:[test isEqual:@"native_cloud_bad_type"]?-2:0;
                input.closed=[test isEqual:@"native_cloud_closed"];
                __block id secret;__block NSError *error;__block NSUInteger calls=0;
                [input cdpContext:nil promptForLocalSecretWithCompletion:^(id value,NSError *failure){secret=value;error=failure;calls++;}];
                BOOL expected=[test isEqual:@"native_cloud_simple"]||[test isEqual:@"native_cloud_complex"]||[test isEqual:@"native_cloud_repeat"];
                assert(calls==1);assert(expected?(secret&&!error):(!secret&&error&&input.failure));
                if(expected)assert([secret secretType]==(localSimpleType==-1?3:2));
                if([test isEqual:@"native_cloud_repeat"]){[input cdpContext:nil promptForLocalSecretWithCompletion:^(id value,NSError *failure){assert(!value&&failure);calls++;}];assert(calls==2&&localUnlockCalls==1);}
                if(input.closed||!localHasSecret)assert(!localUnlockCalls);
            }
            printf("PASS %s\n",argv[1]);return 0;
        }
        if([test hasPrefix:@"enable_cloud_"]) {
            FakeBackend *backend=[FakeBackend new];
            [backend.records addObject:Record(@"media",@"media",@"test@example.com",YES)];
            if([test isEqual:@"enable_cloud_already"]) { NSMutableDictionary *record=[Record(@"cloud",@"icloud",@"test@example.com",YES) mutableCopy];record[@"enabled_dataclasses"]=@[@"com.apple.Dataclass.Contacts"];[backend.records addObject:record]; }
            if([test isEqual:@"enable_cloud_conflict"])[backend.records addObject:Record(@"other",@"identity",@"other@example.com",YES)];
            backend.findMy=[test isEqual:@"enable_cloud_findmy_before"];
            backend.stale=[test isEqual:@"enable_cloud_stale"];
            backend.failAfterRemoval=[test isEqual:@"enable_cloud_read_failure"]||[test isEqual:@"enable_cloud_rejected_read_failure"];
            backend.loginMode=[test substringFromIndex:7];
            TVAppleServices *service=[[TVAppleServices alloc]initWithBackend:backend callbackQueue:dispatch_get_global_queue(QOS_CLASS_DEFAULT,0) verificationTimeout:0];
            dispatch_semaphore_t done=dispatch_semaphore_create(0);__block NSDictionary *result;__block NSError *error;
            [service enableICloudAppleID:@" TEST@example.com " password:@"test-secret" devicePasscode:[test isEqual:@"enable_cloud_invalid"]?@"":@"123456" verificationCodeProvider:nil completion:^(NSDictionary*r,NSError*e){result=r;error=e;dispatch_semaphore_signal(done);}];
            assert(!dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,3*NSEC_PER_SEC)));
            if([@[@"enable_cloud_success",@"enable_cloud_already",@"enable_cloud_stale",@"enable_cloud_read_failure",@"enable_cloud_findmy_after"]containsObject:test]){assert(!error&&[result[@"outcome"]isEqual:@"succeeded"]);assert(backend.cloudAttempts==1);}
            else if([test isEqual:@"enable_cloud_conflict"]||[test isEqual:@"enable_cloud_invalid"]||(backend.findMy&&!backend.cloudAttempts)){assert(error&&!backend.cloudAttempts);}
            else if([test hasPrefix:@"enable_cloud_rejected"]){assert(error.code==TVAppleErrorAuthenticationFailed&&[result[@"outcome"]isEqual:@"failed"]);
                if(backend.failAfterRemoval)assert(![result[@"account_state_available"]boolValue]&&[result[@"account_state_may_be_partial"]boolValue]);}
            else {
                assert(error.code==TVAppleErrorOutcomeUnknown&&[result[@"outcome"]isEqual:@"unknown"]);
                if([test isEqual:@"enable_cloud_unknown"])assert([result[@"signed_in_domains"]containsObject:@"icloud"]);
                NSError *fenced=nil;SignOut(service,@"test@example.com",TVAppleLocalDataRemove,&fenced);assert(!fenced || ![TVAppleDiagnosticMessage(fenced) containsString:@"previous"]);
            }
            puts(argv[1]);return 0;
        }
        if ([test isEqual:@"native_findmy_state"]) {
            for (NSUInteger state=0; state<=5; state++) {
                daemonState=state;daemonError=nil;BOOL enabled=YES;NSError *error=nil;
                BOOL valid=TVAppleNativeReadFindMyState(&enabled,&error);
                assert(valid==(state==0||state==1||state==3));
                if(valid)assert(enabled==(state==0||state==1));
                else assert(error.code==TVAppleErrorBackendRead);
            }
            daemonState=3;daemonError=[NSError errorWithDomain:@"test" code:1 userInfo:nil];
            BOOL enabled=YES;NSError *error=nil;
            assert(!TVAppleNativeReadFindMyState(&enabled,&error));
            assert(error.code==TVAppleErrorBackendRead);
            puts("PASS native_findmy_state");return 0;
        }
        if ([test hasPrefix:@"findmy_"]) {
            FakeBackend *backend=[FakeBackend new];backend.findMy=YES;
            [backend.records addObjectsFromArray:@[Record(@"cloud",@"icloud",@"test@example.com",YES),Record(@"media",@"media",@"test@example.com",YES)]];
            if([test isEqual:@"findmy_disabled"])backend.findMy=NO;
            if([test isEqual:@"findmy_conflict"])backend.records[0]=Record(@"other",@"icloud",@"other@example.com",YES);
            backend.callbackFailure=[test isEqual:@"findmy_timeout"];backend.stale=[test isEqual:@"findmy_unverified"];
            backend.failAfterRemoval=[test isEqual:@"findmy_verification_read"];if([test isEqual:@"findmy_rejected"])backend.loginMode=@"rejected";
            TVAppleServices *service=[[TVAppleServices alloc]initWithBackend:backend callbackQueue:dispatch_get_global_queue(QOS_CLASS_DEFAULT,0) verificationTimeout:0];
            dispatch_semaphore_t done=dispatch_semaphore_create(0);__block NSError *error;__block NSDictionary *result;
            [service disableFindMyAppleID:@" TEST@example.com " password:@"test-secret" completion:^(NSDictionary*r,NSError*e){result=r;error=e;dispatch_semaphore_signal(done);}];
            assert(!dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,3*NSEC_PER_SEC)));
            if([test isEqual:@"findmy_conflict"])assert(error.code==TVAppleErrorConflict&&!backend.findMyAttempts);
            else if([test isEqual:@"findmy_rejected"])assert(error.code==TVAppleErrorAuthenticationFailed&&[result[@"outcome"]isEqual:@"failed"]);
            else if(backend.callbackFailure){
                assert(error.code==TVAppleErrorOutcomeUnknown&&[result[@"outcome"]isEqual:@"unknown"]);NSError *fenced=nil;
                SignOut(service,@"test@example.com",TVAppleLocalDataRemove,&fenced);assert(!fenced || ![TVAppleDiagnosticMessage(fenced) containsString:@"previous"]);
            }else{assert(!error&&[result[@"outcome"]isEqual:@"succeeded"]&&backend.records.count==2);assert(backend.findMyAttempts==([test isEqual:@"findmy_disabled"]?0:1));}
            printf("PASS %s\n",argv[1]);return 0;
        }
        if ([test hasPrefix:@"icloud_"]) {
            FakeBackend *backend = [FakeBackend new];
            [backend.records addObjectsFromArray:@[Record(@"cloud", @"icloud", @"test@example.com", YES),
                Record(@"identity", @"identity", @"test@example.com", YES), Record(@"media", @"media", @"test@example.com", YES),
                Record(@"other-cloud", @"icloud", @"other@example.com", YES), Record(@"old-cloud", @"icloud", @"test@example.com", NO)]];
            if ([test isEqual:@"icloud_empty"]) [backend.records removeObjectAtIndex:0];
            backend.findMy = [test isEqual:@"icloud_findmy"];
            backend.stale = [test isEqual:@"icloud_stale"];
            backend.failAfterRemoval = [test isEqual:@"icloud_verification_read"];
            backend.callbackFailure=[test isEqual:@"icloud_unknown_removed"];
            backend.removedBeforeFailure=backend.callbackFailure;
            TVAppleServices *service = [[TVAppleServices alloc] initWithBackend:backend callbackQueue:dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0) verificationTimeout:0];
            dispatch_semaphore_t done = dispatch_semaphore_create(0);
            __block NSDictionary *result; __block NSError *error;
            [service signOutICloudAppleID:@" TEST@example.com " localDataPolicy:TVAppleLocalDataRemove completion:^(NSDictionary *r, NSError *e) {
                result=r; error=e; dispatch_semaphore_signal(done);
            }];
            assert(!dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 3*NSEC_PER_SEC)));
            if ([test isEqual:@"icloud_findmy"]) assert(error.code==TVAppleErrorFindMyEnabled && !backend.removed.count);
            else if (backend.callbackFailure) {
                assert(error.code==TVAppleErrorOutcomeUnknown && [result[@"outcome"]isEqual:@"unknown"]);
                if(backend.removedBeforeFailure) {
                    assert([result[@"target_signed_out"]boolValue]);
                    assert([result[@"state"][@"accounts"]count]==4);
                }
                NSError *fenced=nil; SignOut(service, @"test@example.com", TVAppleLocalDataRemove, &fenced);
                assert(!fenced || ![TVAppleDiagnosticMessage(fenced) containsString:@"previous"]);
            } else {
                assert(!error && [result[@"outcome"]isEqual:@"succeeded"]);
                assert(backend.records.count==(backend.stale?5:4));
                if ([test isEqual:@"icloud_empty"]) assert([result[@"already_signed_out"]boolValue] && !backend.removed.count);
                else assert([backend.removed isEqual:@[@"icloud"]]);
            }
            printf("PASS %s\n",argv[1]);return 0;
        }
        if([test isEqual:@"manual_invalidate_race"]) {
            for(NSUInteger i=0;i<100;i++) {
                TVAppleManualCodeProvider *provider=[[TVAppleManualCodeProvider alloc]initWithChallengeHandler:^(NSDictionary *event){(void)event;}];
                NSObject *lock=[NSObject new];__block NSUInteger replies=0;
                dispatch_group_t group=dispatch_group_create();dispatch_semaphore_t start=dispatch_semaphore_create(0);
                dispatch_group_async(group,dispatch_get_global_queue(QOS_CLASS_DEFAULT,0),^{
                    dispatch_semaphore_wait(start,DISPATCH_TIME_FOREVER);
                    [provider requestCodeForChallenge:@{} completion:^(NSString *code,NSError *error){assert(!code&&error);@synchronized(lock){replies++;}}];
                });
                dispatch_group_async(group,dispatch_get_global_queue(QOS_CLASS_DEFAULT,0),^{
                    dispatch_semaphore_wait(start,DISPATCH_TIME_FOREVER);[provider invalidate];
                });
                dispatch_semaphore_signal(start);dispatch_semaphore_signal(start);
                assert(!dispatch_group_wait(group,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC)));
                @synchronized(lock){assert(replies==1);}
                [provider requestCodeForChallenge:@{} completion:^(NSString *code,NSError *error){assert(!code&&error);@synchronized(lock){replies++;}}];
                @synchronized(lock){assert(replies==2);}
            }
            printf("PASS %s\n",argv[1]);return 0;
        }
        if ([test hasPrefix:@"manual_"]) {
            dispatch_semaphore_t challenged = dispatch_semaphore_create(0), completed = dispatch_semaphore_create(0);
            __block NSDictionary *event = nil;
            __block NSString *code = nil;
            __block NSError *received = nil;
            TVAppleManualCodeProvider *provider = [[TVAppleManualCodeProvider alloc] initWithChallengeHandler:^(NSDictionary *value) {
                event = value; dispatch_semaphore_signal(challenged);
            }];
            [provider prepareForAuthentication:^(NSError *error) { assert(!error); }];
            [provider requestCodeForChallenge:@{ @"kind":@"apple_two_factor" } completion:^(NSString *value, NSError *error) {
                code = value; received = error; dispatch_semaphore_signal(completed);
            }];
            assert(!dispatch_semaphore_wait(challenged, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)));
            NSError *error = nil;
            assert(![provider submitCode:@"123456" forChallengeID:@"wrong-challenge" error:&error]);
            assert(![provider submitCode:@"invalid" forChallengeID:event[@"challenge_id"] error:&error]);
            if ([test isEqual:@"manual_finish"]) [provider cancelAuthentication];
            else if ([test isEqual:@"manual_cancel"]) assert([provider cancelChallengeID:event[@"challenge_id"] error:&error]);
            else assert([provider submitCode:@"123456" forChallengeID:event[@"challenge_id"] error:&error]);
            assert(!dispatch_semaphore_wait(completed, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)));
            assert(![test isEqual:@"manual_code"] ? received != nil && !code : [code isEqual:@"123456"] && !received);
            assert(![provider submitCode:@"123456" forChallengeID:event[@"challenge_id"] error:&error]);
            // Ending an authentication stage remains reusable; ending an operation does not.
            [provider prepareForAuthentication:^(NSError *e){assert(!e);}];
            [provider invalidate];
            __block NSUInteger closedReplies=0;
            [provider prepareForAuthentication:^(NSError *e){assert(e);closedReplies++;}];
            [provider requestCodeForChallenge:@{} completion:^(NSString *v,NSError *e){assert(!v&&e);closedReplies++;}];
            assert(closedReplies==2);
            printf("PASS %s\n", argv[1]); return 0;
        }
        if ([test hasPrefix:@"login_"]) {
            FakeBackend *backend = [FakeBackend new]; backend.loginMode = [test substringFromIndex:6];
            if ([test isEqual:@"login_conflict"]) [backend.records addObject:Record(@"other", @"media", @"other@example.com", YES)];
            if ([test isEqual:@"login_other_cloud"]) {
                [backend.records addObject:Record(@"other-cloud", @"icloud", @"other@example.com", YES)];
                [backend.records addObject:Record(@"other-identity", @"identity", @"other@example.com", YES)];
            }
            TVAppleServices *service = [[TVAppleServices alloc] initWithBackend:backend callbackQueue:dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0) verificationTimeout:0];
            dispatch_semaphore_t done = dispatch_semaphore_create(0);
            __block NSError *error;
            __block NSDictionary *result;
            [service signInAppStoreAppleID:@" TEST@example.com " password:@"test-secret" verificationCodeProvider:[FakeCodeProvider new]
                completion:^(NSDictionary *r, NSError *e) { result = r; error = e; dispatch_semaphore_signal(done); }];
            assert(!dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC)));
            if ([@[@"login_conflict", @"login_rejected", @"login_timeout", @"login_trust_rejected", @"login_trust_read_failure"] containsObject:test]) {
                assert(error && ![result[@"outcome"] isEqual:@"succeeded"]);
                if ([test isEqual:@"login_conflict"]) assert(!backend.loginAttempts);
                if ([test isEqual:@"login_trust_rejected"]) assert([result[@"signed_in_domains"] isEqual:@[@"identity"]]);
                if ([test isEqual:@"login_trust_read_failure"]) assert(error.code == TVAppleErrorOutcomeUnknown);
                if (error.code == TVAppleErrorOutcomeUnknown) {
                    NSError *fenced = nil; NSUInteger attempts = backend.loginAttempts; (void)attempts;
                    SignOut(service, @"test@example.com", TVAppleLocalDataRemove, &fenced);
                    assert(!fenced || ![TVAppleDiagnosticMessage(fenced) containsString:@"previous"]);
                }
            } else {
                assert(!error && [result[@"outcome"] isEqual:@"succeeded"]);
                assert([result[@"signed_in_domains"] isEqual:@[@"media"]]);
                assert(backend.loginAttempts == ([test isEqual:@"login_trust"] ? 2 : 1));
                assert(backend.bootstraps == ([test isEqual:@"login_trust"] ? 1 : 0));
            }
            printf("PASS %s\n", argv[1]); return 0;
        }
        if ([test isEqual:@"dataclass_policy"]) {
            FakeAction *remove = Action(@"ACDataclassActionDeleteSyncData", YES);
            FakeAction *keep = Action(@"ACDataclassActionMergeSyncDataIntoLocalData", NO);
            NSDictionary *options = @{ @"keychain":@[remove, keep, Action(@"ACDataclassActionCancel", NO)] };
            NSError *error = nil;
            assert(TVAppleChooseDataclassActions(options, TVAppleLocalDataRemove, &error)[@"keychain"] == remove);
            assert(TVAppleChooseDataclassActions(options, TVAppleLocalDataKeep, &error)[@"keychain"] == keep);
            FakeAction *losePending = Action(@"ACDataclassActionLoseNonUploadedData", YES);
            NSDictionary *notes = @{ @"notes":@[losePending, Action(@"ACDataclassActionCancel", NO)] };
            assert(TVAppleChooseDataclassActions(notes, TVAppleLocalDataRemove, &error)[@"notes"] == losePending);
            assert(!TVAppleChooseDataclassActions(notes, TVAppleLocalDataKeep, &error));
            assert(!TVAppleChooseDataclassActions(@{ @"notes":@[losePending, remove] }, TVAppleLocalDataRemove, &error));
            assert(!TVAppleChooseDataclassActions(@{ @"keychain":@[Action(@"UnknownACDataclassActionDeleteSyncData", YES)] }, TVAppleLocalDataRemove, &error));
            assert(error.code == TVAppleErrorUnsupported);
            assert(!TVAppleChooseDataclassActions(@{ @"keychain":@[remove, remove] }, TVAppleLocalDataRemove, &error));
            assert(!TVAppleChooseDataclassActions(@{ @"keychain":@[Action(keep.name, YES)] }, TVAppleLocalDataKeep, &error));
            assert(!TVAppleChooseDataclassActions(@{ @"keychain":@"malformed" }, TVAppleLocalDataRemove, &error));
            assert(!TVAppleChooseDataclassActions(options, 0, &error));
            puts("PASS dataclass_policy"); return 0;
        }
        FakeBackend *backend = [FakeBackend new];
        [backend.records addObjectsFromArray:@[
            Record(@"cloud", @"icloud", @"test@example.com", YES),
            Record(@"identity", @"identity", @"test@example.com", YES),
            Record(@"media", @"media", @"test@example.com", YES),
            Record(@"other", @"identity", @"other@example.com", YES),
            Record(@"inactive", @"media", @"test@example.com", NO) ]];
        TVAppleServices *service = [[TVAppleServices alloc] initWithBackend:backend
            callbackQueue:dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0) verificationTimeout:0];
        NSError *error = nil;
        TVAppleLocalDataPolicy policy = TVAppleLocalDataRemove;
        NSString *target = @" TEST@example.com ";
        if ([test isEqual:@"findmy"]) backend.findMy = YES;
        if ([test isEqual:@"preflight"]) backend.prepareFailure = YES;
        if ([test isEqual:@"read"]) backend.readFailure = YES;
        if ([test isEqual:@"unknown"]) backend.callbackFailure = YES;
        if ([test isEqual:@"stale"]) backend.stale = YES;
        if ([test isEqual:@"verification_read"]) backend.failAfterRemoval = YES;
        if ([test isEqual:@"policy"]) policy = 0;
        if ([test isEqual:@"keep"]) policy = TVAppleLocalDataKeep;
        if ([test isEqual:@"invalid"]) target = @"bad\nidentity";
        if ([test isEqual:@"empty"]) [backend.records removeAllObjects];
        if ([test isEqual:@"store_signout"]) {
            dispatch_semaphore_t done=dispatch_semaphore_create(0);
            [service signOutAppStoreAppleID:target completion:^(NSDictionary *result,NSError *e){
                assert(!e&&[result[@"outcome"]isEqual:@"succeeded"]);
                assert(([backend.removed isEqual:@[@"media"]])&&backend.records.count==4);
                dispatch_semaphore_signal(done);
            }];
            assert(!dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,3*NSEC_PER_SEC)));
            puts("PASS Store-only signout preserves cloud, identity, inactive and other accounts");return 0;
        }
        if ([test isEqual:@"query"]) {
            dispatch_semaphore_t done = dispatch_semaphore_create(0);
            [service queryState:^(NSDictionary *state, NSError *e) {
                assert(!e && [state[@"accounts"] count] == 5);
                assert([NSJSONSerialization isValidJSONObject:state]); dispatch_semaphore_signal(done);
            }];
            assert(!dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC)));
            assert(!backend.removed.count);
        } else {
            NSDictionary *result = SignOut(service, target, policy, &error);
            if ([@[@"findmy", @"preflight", @"read", @"policy", @"invalid"] containsObject:test]) {
                assert(error && !result && !backend.removed.count);
            } else if ([@[@"unknown"] containsObject:test]) {
                assert(error.code == TVAppleErrorOutcomeUnknown && [result[@"outcome"] isEqual:@"unknown"]);
                NSUInteger count = backend.removed.count;
                SignOut(service, target, policy, &error);
                assert(!error || ![TVAppleDiagnosticMessage(error) containsString:@"previous"]);
                (void)count;
            } else if ([test isEqual:@"empty"]) {
                assert(!error && [result[@"already_signed_out"] boolValue] && !backend.removed.count);
            } else {
                assert(!error && [result[@"outcome"] isEqual:@"succeeded"]);
                assert(([backend.removed isEqual:@[@"icloud", @"identity", @"media"]]));
                assert(backend.records.count == (backend.stale?5:2));
                NSUInteger count = backend.removed.count;
                if(backend.stale||backend.failAfterRemoval){assert(!result[@"state"]);printf("PASS %s\n",argv[1]);return 0;}
                result = SignOut(service, target, policy, &error);
                assert(!error && [result[@"already_signed_out"] boolValue] && backend.removed.count == count);
            }
        }
        printf("PASS %s\n", argv[1]);
        return 0;
    }
}
