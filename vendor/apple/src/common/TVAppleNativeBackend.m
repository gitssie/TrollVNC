#import "TVAppleBackend.h"
#import "TVAppleNativeSelectors.h"
#import "TVApplePolicy.h"
#import "TVAppleStoreLogin.h"
#import "TVAppleStoreSignIn.h"
#import "TVAppleFindMy.h"
#import "TVAppleICloud.h"
#import "TVAppleSearchParty.h"
#import "TVAppleEmailSettings.h"
#import "TVAppleEmailActions.h"
#import "TVAppleNameSettings.h"
#import "TVAppleSignInWithApple.h"
#import "TVAppleICloudDevices.h"
#import <dlfcn.h>

static NSString *const CloudType = @"com.apple.account.AppleAccount";
static NSString *const IdentityType = @"com.apple.account.idms";
static NSString *const MediaType = @"com.apple.account.iTunesStore";
static NSString *const LocatorType = @"com.apple.account.DeviceLocator";
static NSString *const LocatorClass = @"com.apple.Dataclass.DeviceLocator";
static BOOL Has(id object, SEL selector) { return object && [object respondsToSelector:selector]; }
static NSDictionary *ActionSignature(NSDictionary *options) {
    if (![options isKindOfClass:NSDictionary.class]) return nil;
    NSMutableDictionary *signature = [NSMutableDictionary new];
    for (id key in options) {
        if (![key isKindOfClass:NSString.class] || ![options[key] isKindOfClass:NSArray.class]) return nil;
        NSMutableArray *names = [NSMutableArray new];
        for (id action in options[key]) {
            if (!Has(action, @selector(isDestructive))) return nil;
            [names addObject:[NSString stringWithFormat:@"%@:%d", [action description], [action isDestructive]]];
        }
        signature[key] = [names sortedArrayUsingSelector:@selector(compare:)];
    }
    return [signature copy];
}
static BOOL Entitled(NSString *key) {
    void *handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_NOW);
    if (!handle) return NO;
    CFTypeRef (*create)(CFAllocatorRef) = dlsym(handle, "SecTaskCreateFromSelf");
    CFTypeRef (*copy)(CFTypeRef, CFStringRef, CFErrorRef *) = dlsym(handle, "SecTaskCopyValueForEntitlement");
    BOOL entitled = NO;
    if (create && copy) {
        CFTypeRef task = create(NULL);
        if (task) {
            CFTypeRef value = copy(task, (__bridge CFStringRef)key, NULL);
            entitled = value && CFGetTypeID(value) == CFBooleanGetTypeID() && CFBooleanGetValue(value);
            if (value) CFRelease(value);
            CFRelease(task);
        }
    }
    dlclose(handle);
    return entitled;
}
@interface TVAppleNativeBackend : NSObject <TVAppleBackend, TVAppleStoreLoginBackend, TVAppleFindMyBackend, TVAppleICloudBackend, TVAppleEmailSettingsBackend, TVAppleEmailActionsBackend, TVAppleNameSettingsBackend, TVAppleSignInWithAppleBackend, TVAppleICloudDevicesBackend>
@property NSMutableDictionary<NSString *, TVAppleNativeSettingsSession *> *settingsSessions;
@end
@implementation TVAppleNativeBackend
- (TVAppleNativeSettingsSession *)settingsSessionForDomain:(NSString *)domain error:(NSError **)error {
    if(!Entitled(@"com.apple.authkit.client.private")||!Entitled(@"com.apple.private.accounts.allaccounts")){
        *error=TVAppleError(TVAppleErrorPermissionDenied,@"Effective native Settings entitlement is missing.");return nil;
    }
    @synchronized(self) {
        if(!self.settingsSessions) self.settingsSessions=[NSMutableDictionary new];
        if(!self.settingsSessions[domain]) self.settingsSessions[domain]=[TVAppleNativeSettingsSession new];
        return self.settingsSessions[domain];
    }
}
- (NSDictionary *)iCloudDevicesForAppleID:(NSString *)appleID error:(NSError **)error{return [[self settingsSessionForDomain:@"devices" error:error]queryICloudDevices:appleID error:error];}
- (NSDictionary *)removeOtherICloudDevicesForAppleID:(NSString *)appleID error:(NSError **)error{return [[self settingsSessionForDomain:@"devices" error:error]removeOtherICloudDevices:appleID error:error];}
- (NSDictionary *)signInWithAppleAppsForAppleID:(NSString *)appleID error:(NSError **)error{
    return [[self settingsSessionForDomain:@"authorizations" error:error]querySignInWithAppleApps:appleID error:error];
}
- (NSDictionary *)stopUsingAppleIDForBundleID:(NSString *)bundleID appleID:(NSString *)appleID error:(NSError **)error{
    return [[self settingsSessionForDomain:@"authorizations" error:error]stopUsingAppleIDForBundleID:bundleID appleID:appleID error:error];
}
- (NSDictionary *)nameSettingsForAppleID:(NSString *)appleID error:(NSError **)error{
    return [[self settingsSessionForDomain:@"name" error:error]queryName:appleID error:error];
}
- (NSDictionary *)setFirstName:(NSString *)first lastName:(NSString *)last appleID:(NSString *)appleID error:(NSError **)error{
    return [[self settingsSessionForDomain:@"name" error:error]setFirstName:first lastName:last appleID:appleID error:error];
}
- (NSDictionary *)beginContactEmail:(NSString *)email appleID:(NSString *)appleID error:(NSError **)error{
    return [[self settingsSessionForDomain:@"email" error:error]beginEmail:email appleID:appleID error:error];
}
- (NSDictionary *)verifyContactEmail:(NSString *)challenge code:(NSString *)code appleID:(NSString *)appleID error:(NSError **)error{
    return [[self settingsSessionForDomain:@"email" error:error]verifyChallenge:challenge code:code appleID:appleID error:error];
}
- (NSDictionary *)setRelayEmail:(NSString *)email appleID:(NSString *)appleID error:(NSError **)error{
    return [[self settingsSessionForDomain:@"email" error:error]setForwardingEmail:email appleID:appleID error:error];
}
- (NSDictionary *)emailSettingsForAppleID:(NSString *)appleID error:(NSError **)error {
    if(!Entitled(@"com.apple.authkit.client.private")){
        *error=TVAppleError(TVAppleErrorPermissionDenied,@"Effective native email settings entitlement is missing.");return nil;
    }
    return TVAppleNativeEmailSettings(appleID,error);
}
- (id)store:(NSError **)error {
    static BOOL loaded;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Keep loaded frameworks resident: live Objective-C classes refer to their code.
        loaded = dlopen("/System/Library/Frameworks/Accounts.framework/Accounts", RTLD_NOW) &&
                 dlopen("/System/Library/PrivateFrameworks/AppleAccount.framework/AppleAccount", RTLD_NOW) &&
                 dlopen("/System/Library/PrivateFrameworks/FindMyDevice.framework/FindMyDevice", RTLD_NOW) &&
                 dlopen("/System/Library/PrivateFrameworks/StoreServices.framework/StoreServices", RTLD_NOW);
    });
    if (!loaded) { *error = TVAppleError(TVAppleErrorUnsupported, @"Required iOS account frameworks are unavailable."); return nil; }
    if (!Entitled(@"com.apple.private.accounts.allaccounts") || !Entitled(@"com.apple.itunesstored.private")) {
        *error = TVAppleError(TVAppleErrorPermissionDenied, @"Effective account entitlements are missing."); return nil;
    }
    id store = [NSClassFromString(@"ACAccountStore") new];
    for (NSString *name in @[@"accountsWithAccountTypeIdentifiers:error:", @"aa_primaryAppleAccount",
                            @"dataclassActionsForAccountDeletion:error:", @"removeAccount:withDataclassActions:completion:",
                            @"removeAccount:withCompletionHandler:"]) {
        if (!Has(store, NSSelectorFromString(name))) { *error = TVAppleError(TVAppleErrorUnsupported, @"An account selector is unavailable."); return nil; }
    }
    return store;
}
- (id)mediaStore:(NSError **)error {
    Class cls = NSClassFromString(@"SSAccountStore");
    if (!Has(cls, @selector(defaultStore))) { *error = TVAppleError(TVAppleErrorUnsupported, @"Media account store is unavailable."); return nil; }
    id store = [cls defaultStore];
    for (NSString *name in @[@"activeAccount", @"reloadAccounts", @"removeAccount:completion:"]) {
        if (!Has(store, NSSelectorFromString(name))) { *error = TVAppleError(TVAppleErrorUnsupported, @"A media account selector is unavailable."); return nil; }
    }
    [store reloadAccounts];
    return store;
}
- (NSArray *)accounts:(id)store error:(NSError **)error {
    NSError *nativeError = nil;
    NSArray *accounts = [store accountsWithAccountTypeIdentifiers:@[CloudType, IdentityType, MediaType, LocatorType] error:&nativeError];
    if (nativeError || ![accounts isKindOfClass:NSArray.class]) {
        *error = TVAppleError(TVAppleErrorBackendRead, @"The system account query failed."); return nil;
    }
    return accounts;
}
- (NSDictionary *)snapshot:(NSError **)error {
    id store = [self store:error]; if (!store) return nil;
    NSArray *accounts = [self accounts:store error:error]; if (!accounts) return nil;
    id mediaStore = [self mediaStore:error]; if (!mediaStore) return nil;
    id active = [mediaStore activeAccount];
    NSString *activeID = nil;
    BOOL authenticated = NO;
    if (active) {
        for (NSString *name in @[@"backingAccount", @"isLocalAccount", @"isAuthenticated", @"accountName"]) {
            if (!Has(active, NSSelectorFromString(name))) { *error = TVAppleError(TVAppleErrorUnsupported, @"Media account identity cannot be verified."); return nil; }
        }
        if (![active isLocalAccount]) {
            activeID = [[active backingAccount] identifier]; authenticated = [active isAuthenticated];
            if (![activeID isKindOfClass:NSString.class] || !activeID.length) {
                *error = TVAppleError(TVAppleErrorBackendRead, @"The active media account has no verifiable backing identity."); return nil;
            }
        }
    }
    id primary = [store aa_primaryAppleAccount];
    NSString *primaryID = [primary identifier];
    NSMutableArray *records = [NSMutableArray new];
    Class fmipClass = NSClassFromString(@"FMDFMIPSharedStateManager");
    if (!Has(fmipClass, @selector(sharedInstance))) {
        *error = TVAppleError(TVAppleErrorUnsupported, @"Find My shared state is unavailable."); return nil;
    }
    id fmip = [fmipClass sharedInstance];
    if (!Has(fmip, @selector(fmipActive))) {
        *error = TVAppleError(TVAppleErrorUnsupported, @"Find My shared state cannot be checked."); return nil;
    }
    // DeviceLocator dataclasses alone can disagree with the state used by signout.
    BOOL daemonEnabled=NO;
    if (!TVAppleNativeReadFindMyState(&daemonEnabled, error)) return nil;
    BOOL findMy = daemonEnabled || [fmip fmipActive], primaryFound = !primary;
    for (id account in accounts) {
        NSString *type = [[account accountType] identifier];
        NSString *identifier = [account identifier];
        NSString *username = [account username];
        if (!identifier.length || !type.length) { *error = TVAppleError(TVAppleErrorBackendRead, @"The account query returned an incomplete identity."); return nil; }
        BOOL cloud = [type isEqual:CloudType], locator = [type isEqual:LocatorType];
        NSArray *dataclasses = @[];
        if (cloud || locator) {
            if (!Has(account, @selector(enabledDataclasses))) { *error = TVAppleError(TVAppleErrorUnsupported, @"Find My state cannot be checked."); return nil; }
            NSSet *enabled = [account enabledDataclasses];
            if (!enabled || ![enabled isKindOfClass:NSSet.class]) { *error = TVAppleError(TVAppleErrorBackendRead, @"Find My state is unknown."); return nil; }
            dataclasses = [enabled.allObjects sortedArrayUsingSelector:@selector(compare:)];
            findMy |= [enabled containsObject:LocatorClass];
        }
        if (locator) continue;
        NSString *domain = cloud ? @"icloud" : ([type isEqual:IdentityType] ? @"identity" : @"media");
        BOOL isPrimary = cloud && [identifier isEqual:primaryID];
        primaryFound |= isPrimary;
        BOOL selected = isPrimary || [domain isEqual:@"identity"] || [identifier isEqual:activeID];
        if (selected && !username.length) { *error = TVAppleError(TVAppleErrorBackendRead, @"An active account has no verifiable Apple ID."); return nil; }
        [records addObject:@{ @"identifier":identifier, @"apple_id":username ?: @"", @"domain":domain,
                              @"selected":@(selected), @"primary":@(isPrimary), @"enabled_dataclasses":dataclasses,
                              @"authenticated":@((BOOL)([identifier isEqual:activeID] && authenticated)) }];
    }
    if (!primaryFound) { *error = TVAppleError(TVAppleErrorBackendRead, @"Primary iCloud account disagrees with the fresh system query."); return nil; }
    // A cached StoreServices active account absent from this fresh query is stale.
    return @{ @"schema_version":@1, @"accounts":[records copy], @"find_my_enabled":@(findMy),
              @"capabilities":@{ @"query_state":@YES, @"sign_out_apple_id":@YES,
                                  @"sign_in_app_store":@(NSClassFromString(@"SSAuthenticateRequest") != Nil),
                                  @"sign_out_icloud":@YES, @"disable_find_my":@(Entitled(@"com.apple.icloud.findmydeviced.access")), @"sign_in_apple_id":@NO, @"enable_icloud":@(Entitled(@"com.apple.authkit.client.private") && Entitled(@"com.apple.cdp.statemachine") && Entitled(@"com.apple.managedconfiguration.profiled-access") && Entitled(@"com.apple.keystore.device")) } };
}
- (id)prepareAccount:(NSDictionary *)record policy:(TVAppleLocalDataPolicy)policy error:(NSError **)error {
    NSDictionary *state = [self snapshot:error]; if (!state) return nil;
    if (![record[@"domain"] isEqual:@"media"] && [state[@"find_my_enabled"] boolValue]) { *error = TVAppleError(TVAppleErrorFindMyEnabled, @"Find My must be disabled using the authenticated system flow first."); return nil; }
    id store = [self store:error]; if (!store) return nil;
    NSArray *accounts = [self accounts:store error:error]; if (!accounts) return nil;
    id account = nil;
    for (id candidate in accounts) if ([[candidate identifier] isEqual:record[@"identifier"]]) account = candidate;
    if (!account || ![[[account username] lowercaseString] isEqual:[record[@"apple_id"] lowercaseString]]) {
        *error = TVAppleError(TVAppleErrorConflict, @"Account identity changed during preflight."); return nil;
    }
    NSMutableDictionary *prepared = [@{ @"record":record, @"store":store, @"account":account } mutableCopy];
    if ([record[@"domain"] isEqual:@"icloud"]) {
        if (![[[store aa_primaryAppleAccount] identifier] isEqual:record[@"identifier"]]) {
            *error = TVAppleError(TVAppleErrorConflict, @"Only the primary iCloud account can be signed out."); return nil;
        }
        NSError *nativeError = nil;
        NSDictionary *options = [store dataclassActionsForAccountDeletion:account error:&nativeError];
        if (nativeError || ![options isKindOfClass:NSDictionary.class]) { *error = TVAppleError(TVAppleErrorUnsupported, @"The system did not supply deletion actions."); return nil; }
        NSDictionary *chosen = TVAppleChooseDataclassActions(options, policy, error);
        if (!chosen) return nil;
        prepared[@"actions"] = chosen;
        NSDictionary *signature = ActionSignature(options);
        if (!signature) { *error = TVAppleError(TVAppleErrorUnsupported, @"Dataclass action identity cannot be checked."); return nil; }
        prepared[@"action_signature"] = signature;
        prepared[@"policy"] = @(policy);
        if(!Entitled(@"com.apple.icloud.searchpartyd.beaconmanager")) {
            *error=TVAppleError(TVAppleErrorPermissionDenied,@"Effective SearchParty health entitlement is missing.");return nil;
        }
        BOOL recovered=NO;
        if(!TVApplePrepareSearchParty(&recovered,error))return nil;
        if(recovered)prepared[@"service_recovery"]=@{@"service":@"searchpartyd",@"stage":@"before_account_removal"};
    }
    return prepared;
}
- (BOOL)removePreparedAccount:(NSDictionary *)prepared error:(NSError **)error {
    NSDictionary *record = prepared[@"record"];
    NSDictionary *state = [self snapshot:error]; if (!state) return NO;
    if (![record[@"domain"] isEqual:@"media"] && [state[@"find_my_enabled"] boolValue]) { *error = TVAppleError(TVAppleErrorFindMyEnabled, @"Find My became enabled."); return NO; }
    NSDictionary *current = nil;
    for (NSDictionary *candidate in state[@"accounts"]) if ([candidate[@"identifier"] isEqual:record[@"identifier"]]) current = candidate;
    if (!current || ![current[@"apple_id"] isEqual:record[@"apple_id"]] || ![current[@"selected"] boolValue] ||
        ([record[@"domain"] isEqual:@"icloud"] && (! [current[@"primary"] boolValue] ||
          ![current[@"enabled_dataclasses"] isEqual:record[@"enabled_dataclasses"]]))) {
        *error = TVAppleError(TVAppleErrorConflict, @"Account identity or role changed before removal."); return NO;
    }
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    NSMutableDictionary *ticket=[NSMutableDictionary new];
    void (^completion)(BOOL, NSError *) = ^(BOOL ok, NSError *e) {
        @synchronized(ticket) {
            if(ticket[@"closed"]||ticket[@"finished"])return;
            ticket[@"finished"]=@YES;ticket[@"ok"]=@(ok&&!e);
            ticket[@"native_ok"]=@(ok);ticket[@"error_domain"]=e.domain?:@"";ticket[@"error_code"]=@(e.code);
            dispatch_semaphore_signal(done);
        }
    };
    if ([record[@"domain"] isEqual:@"media"]) {
        id store = [self mediaStore:error]; if (!store) return NO;
        id active = [store activeAccount];
        if (!active || [active isLocalAccount] || ![[[active backingAccount] identifier] isEqual:record[@"identifier"]]) {
            *error = TVAppleError(TVAppleErrorConflict, @"The active media account changed."); return NO;
        }
        [store removeAccount:active completion:completion];
    } else if ([record[@"domain"] isEqual:@"icloud"]) {
        NSError *nativeError = nil;
        NSDictionary *options = [prepared[@"store"] dataclassActionsForAccountDeletion:prepared[@"account"] error:&nativeError];
        if (nativeError || ![ActionSignature(options) isEqual:prepared[@"action_signature"]]) {
            *error = TVAppleError(TVAppleErrorConflict, @"Dataclass deletion options changed before removal."); return NO;
        }
        NSDictionary *actions = TVAppleChooseDataclassActions(options, [prepared[@"policy"] integerValue], error);
        if (!actions) return NO;
        [prepared[@"store"] removeAccount:prepared[@"account"] withDataclassActions:actions completion:completion];
    } else {
        [prepared[@"store"] removeAccount:prepared[@"account"] withCompletionHandler:completion];
    }
    long timedOut=dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC));
    BOOL success=NO;
    @synchronized(ticket){ticket[@"closed"]=@YES;success=!timedOut&&[ticket[@"ok"]boolValue];}
    // On the validated iOS15 path, success + Accounts/17 means the account was
    // removed but a dataclass action failed. Do not suppress that data warning.
    // False callbacks, other errors and timeouts never enter this reconciliation.
    if (!success && !timedOut && [record[@"domain"] isEqual:@"icloud"] &&
        [ticket[@"native_ok"] boolValue] && [ticket[@"error_domain"] isEqual:@"com.apple.accounts"] &&
        [ticket[@"error_code"] integerValue] == 17 && [prepared isKindOfClass:NSMutableDictionary.class]) {
        ((NSMutableDictionary *)prepared)[@"removal_warning"]=@{@"domain":@"icloud",@"kind":@"dataclass_action_failed",@"error_domain":@"com.apple.accounts",@"code":@17};
        NSError *readError=nil;
        NSDictionary *observed=[self snapshot:&readError];
        BOOL absent=observed && !readError && [observed[@"accounts"] isKindOfClass:NSArray.class] &&
            [observed[@"find_my_enabled"] isKindOfClass:NSNumber.class] && ![observed[@"find_my_enabled"] boolValue];
        for (NSDictionary *candidate in observed[@"accounts"]) {
            if ([candidate[@"identifier"] isEqual:record[@"identifier"]] ||
                ([candidate[@"domain"] isEqual:@"icloud"] && [candidate[@"selected"] boolValue] &&
                 [candidate[@"apple_id"] caseInsensitiveCompare:record[@"apple_id"]] == NSOrderedSame)) absent=NO;
        }
        if (absent) {
            success=YES;
        }
    }
    if (!success) {
        *error = TVAppleError(TVAppleErrorOutcomeUnknown, timedOut?@"Native removal timed out.":@"Native removal reported failure."); return NO;
    }
    return YES;
}
- (BOOL)enableICloudAppleID:(NSString *)appleID password:(NSString *)password devicePasscode:(NSString *)passcode provider:(id<TVAppleVerificationCodeProvider>)provider error:(NSError **)error {
    if(!Entitled(@"com.apple.cdp.statemachine")||!Entitled(@"com.apple.managedconfiguration.profiled-access")||!Entitled(@"com.apple.keystore.device")){*error=TVAppleError(TVAppleErrorPermissionDenied,@"Effective native CDP/passcode entitlement is missing.");return NO;}
    return TVAppleNativeEnableICloud(appleID,password,passcode,provider,error);
}
- (BOOL)disableFindMyAppleID:(NSString *)appleID password:(NSString *)password error:(NSError **)error {
    return TVAppleNativeDisableFindMy(appleID, password, error);
}
- (TVAppleStoreAttempt)authenticateStoreAppleID:(NSString *)appleID password:(NSString *)password error:(NSError **)error {
    return TVAppleNativeStoreLogin(appleID, password, error);
}
- (NSDictionary *)signInStoreAppleID:(NSString *)appleID password:(NSString *)password
    provider:(id<TVAppleVerificationCodeProvider>)provider error:(NSError **)error {
    return [[TVAppleNativeStoreSignIn new] signIn:appleID password:password provider:provider error:error];
}
- (BOOL)establishTrustForAppleID:(NSString *)appleID password:(NSString *)password provider:(id<TVAppleVerificationCodeProvider>)provider error:(NSError **)error {
    return TVAppleNativeEstablishTrust(appleID, password, provider, error);
}
@end
id<TVAppleBackend> TVAppleCreateNativeBackend(void) { return [TVAppleNativeBackend new]; }
