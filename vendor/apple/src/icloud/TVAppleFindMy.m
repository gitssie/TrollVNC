#import "TVAppleFindMy.h"
#import "TVAppleScopedSignOut.h"
#import "TVAppleNativeSelectors.h"
#import "TVAppleStoreLogin.h"
#import <dlfcn.h>
@interface NSObject (TVAppleFindMySelectors)
- (id)initWithPassword:(NSString *)password;
- (void)setCredential:(id)credential;
- (NSString *)aa_password;
- (id)initWithAccount:(id)account;
- (void)performRequestWithHandler:(void (^)(id, id, NSError *))handler;
- (NSHTTPURLResponse *)httpResponse;
- (NSString *)fmipWipeToken;
- (NSString *)fmipDsid;
- (NSString *)fmipUrl;
- (NSError *)error;
- (void)fmipStateWithCompletion:(void (^)(NSUInteger, NSError *))completion;
- (void)disableFMIPUsingToken:(NSString *)token inContext:(NSUInteger)context completion:(void (^)(NSError *))completion;
@end
@implementation TVAppleServices (FindMy)
- (void)disableFindMyAppleID:(NSString *)appleID password:(NSString *)password completion:(TVAppleCompletion)completion {
    [self enqueueDisableFindMyAppleID:appleID password:password completion:completion];
}
@end
static BOOL Supports(id object, NSArray<NSString *> *names) {
    for (NSString *name in names) if (![object respondsToSelector:NSSelectorFromString(name)]) return NO;
    return object != nil;
}
BOOL TVAppleNativeReadFindMyState(BOOL *enabled, NSError **error) {
    Class managerClass=NSClassFromString(@"FMDFMIPManager");
    if (!Supports(managerClass,@[@"sharedInstance"])) { *error=TVAppleError(TVAppleErrorUnsupported,@"Find My daemon client is unavailable.");return NO; }
    id manager=[managerClass sharedInstance];
    if (!Supports(manager,@[@"fmipStateWithCompletion:"])) { *error=TVAppleError(TVAppleErrorUnsupported,@"Find My daemon state is unavailable.");return NO; }
    dispatch_semaphore_t done=dispatch_semaphore_create(0);
    NSMutableDictionary *ticket=[NSMutableDictionary new];
    [manager fmipStateWithCompletion:^(NSUInteger state,NSError *nativeError){
        @synchronized(ticket){
            if(ticket[@"closed"]||ticket[@"finished"])return;
            // iOS 15: Settings treats 0/1 as on; native disable produces 3 (off).
            // State 2 was not validated and state 4 is used by the XPC failure path.
            ticket[@"finished"]=@YES;ticket[@"valid"]=@(!nativeError&&(state==0||state==1||state==3));ticket[@"enabled"]=@(state==0||state==1);dispatch_semaphore_signal(done);
        }
    }];
    long timedOut=dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,10*NSEC_PER_SEC));
    BOOL valid=NO;
    @synchronized(ticket){ticket[@"closed"]=@YES;valid=!timedOut&&[ticket[@"valid"]boolValue];if(valid)*enabled=[ticket[@"enabled"]boolValue];}
    if(!valid)*error=TVAppleError(TVAppleErrorBackendRead,@"Find My daemon state could not be verified.");
    return valid;
}
BOOL TVAppleNativeDisableFindMy(NSString *appleID, NSString *password, NSError **error) {
    // Only AppleAccount authenticates; only FindMyDevice submits the issued token.
    if (!dlopen("/System/Library/Frameworks/Accounts.framework/Accounts",RTLD_NOW) ||
        !dlopen("/System/Library/PrivateFrameworks/AppleAccount.framework/AppleAccount",RTLD_NOW) ||
        !dlopen("/System/Library/PrivateFrameworks/FindMyDevice.framework/FindMyDevice",RTLD_NOW)) {
        *error=TVAppleError(TVAppleErrorUnsupported,@"Find My frameworks are unavailable.");return NO;
    }
    id store=[NSClassFromString(@"ACAccountStore")new];
    if (!Supports(store,@[@"aa_primaryAppleAccount"])) { *error=TVAppleError(TVAppleErrorUnsupported,@"Primary account lookup is unavailable.");return NO; }
    id primary=[store aa_primaryAppleAccount];
    if (!primary || ![[[primary username]lowercaseString]isEqual:appleID]) { *error=TVAppleError(TVAppleErrorConflict,@"Find My requires the matching primary iCloud account.");return NO; }
    id account=[primary copy];
    id credential=[NSClassFromString(@"ACAccountCredential")alloc];
    id request=[NSClassFromString(@"AAFMIPAuthenticateRequest")alloc];
    Class managerClass=NSClassFromString(@"FMDFMIPManager");
    if (!Supports(managerClass,@[@"sharedInstance"])) { *error=TVAppleError(TVAppleErrorUnsupported,@"Find My daemon client is unavailable.");return NO; }
    id manager=[managerClass sharedInstance];
    if (!Supports(account,@[@"setCredential:",@"aa_password"]) || !Supports(credential,@[@"initWithPassword:"]) ||
        !Supports(request,@[@"initWithAccount:",@"performRequestWithHandler:"]) ||
        !Supports(manager,@[@"disableFMIPUsingToken:inContext:completion:"])) {
        *error=TVAppleError(TVAppleErrorUnsupported,@"A native Find My authentication selector is unavailable.");return NO;
    }
    NSDictionary *authentication=TVAppleNativeAuthenticate(appleID,password,nil,NO,error);
    if (!authentication) return NO;
    NSString *nativePassword=authentication[@"AKPassword"];
    if (![nativePassword isKindOfClass:NSString.class] || !nativePassword.length) { *error=TVAppleError(TVAppleErrorOutcomeUnknown,@"Native authentication returned no Find My password token.");return NO; }
    credential=[credential initWithPassword:nativePassword];[account setCredential:credential];
    authentication=nil;
    if (![[account aa_password]isEqual:nativePassword]) { *error=TVAppleError(TVAppleErrorUnsupported,@"Find My password binding is unsupported.");return NO; }
    request=[request initWithAccount:account];
    dispatch_semaphore_t authenticated=dispatch_semaphore_create(0);
    NSMutableDictionary *ticket=[NSMutableDictionary new];
    [request performRequestWithHandler:^(id completedRequest,id response,NSError *nativeError){
        @synchronized(ticket) {
            if (ticket[@"closed"] || ticket[@"finished"]) return;
            ticket[@"finished"]=@YES;
            // AARequest passes (request, AAResponse, NSError), not an HTTP response.
            BOOL responseShaped=Supports(response,@[@"httpResponse",@"fmipWipeToken",@"fmipDsid",@"fmipUrl",@"error"]);
            NSHTTPURLResponse *http=responseShaped?[response httpResponse]:nil;
            BOOL shaped=completedRequest==request && responseShaped && [http isKindOfClass:NSHTTPURLResponse.class];
            BOOL valid=shaped && http.statusCode==200 && !nativeError && ![response error];
            ticket[@"ok"]=@(valid);
            // A valid HTTP rejection is distinct from malformed, contradictory or timed-out results.
            ticket[@"rejected"]=@(shaped && http.statusCode>=400 && http.statusCode<500);
            if (valid) ticket[@"response"]=response;
            dispatch_semaphore_signal(authenticated);
        }
    }];
    long timedOut=dispatch_semaphore_wait(authenticated,dispatch_time(DISPATCH_TIME_NOW,90*NSEC_PER_SEC));
    id response=nil;BOOL rejected=NO;
    @synchronized(ticket) {
        ticket[@"closed"]=@YES;rejected=[ticket[@"rejected"]boolValue];
        if (!timedOut && [ticket[@"ok"]boolValue]) response=ticket[@"response"];
        [ticket removeObjectForKey:@"response"];
    }
    [account setCredential:nil];credential=nil;nativePassword=nil;
    if (timedOut) { *error=TVAppleError(TVAppleErrorOutcomeUnknown,@"Find My authentication timed out.");return NO; }
    if (!response) { *error=TVAppleError(rejected?TVAppleErrorAuthenticationFailed:TVAppleErrorOutcomeUnknown,@"Native Find My authentication did not return a verified token.");return NO; }
    NSString *token=[response fmipWipeToken],*dsid=[response fmipDsid],*url=[response fmipUrl];
    if (![token isKindOfClass:NSString.class] || !token.length || ![dsid isKindOfClass:NSString.class] || !dsid.length ||
        (url && ![url isKindOfClass:NSString.class])) {
        *error=TVAppleError(TVAppleErrorOutcomeUnknown,@"Find My authentication returned incomplete account data.");return NO;
    }
    id fresh=[store aa_primaryAppleAccount];
    if (![[fresh identifier]isEqual:[primary identifier]] || ![[[fresh username]lowercaseString]isEqual:appleID]) {
        *error=TVAppleError(TVAppleErrorConflict,@"Primary iCloud account changed during authentication.");return NO;
    }
    dispatch_semaphore_t disabled=dispatch_semaphore_create(0);
    NSMutableDictionary *removal=[NSMutableDictionary new];
    // Context 1 is the native Settings switch path on the validated iOS 15 device.
    [manager disableFMIPUsingToken:token inContext:1 completion:^(NSError *nativeError){
        @synchronized(removal) {
            if (removal[@"closed"] || removal[@"finished"]) return;
            removal[@"finished"]=@YES;removal[@"ok"]=@(nativeError==nil);dispatch_semaphore_signal(disabled);
        }
    }];
    timedOut=dispatch_semaphore_wait(disabled,dispatch_time(DISPATCH_TIME_NOW,90*NSEC_PER_SEC));
    BOOL ok=NO;
    @synchronized(removal){removal[@"closed"]=@YES;ok=!timedOut&&[removal[@"ok"]boolValue];}
    if (!ok) *error=TVAppleError(TVAppleErrorOutcomeUnknown,@"Native Find My disable did not complete successfully.");
    return ok;
}
