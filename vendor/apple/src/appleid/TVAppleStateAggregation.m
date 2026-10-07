#import "TVAppleStateAggregation.h"
#import "TVAppleEmailSettings.h"
#import "TVAppleNameSettings.h"
#import "TVAppleSignInWithApple.h"

static NSDictionary *SectionError(TVAppleErrorCode code){
    // Do not export native error descriptions/userInfo or arbitrary error domains.
    return @{@"status":@"error",@"data":NSNull.null,@"error":@{@"domain":TVAppleErrorDomain,@"code":@(code)}};
}
static NSDictionary *NoProfile(void){return @{@"status":@"not_signed_in",@"data":NSNull.null};}
static NSArray *Selected(NSDictionary *state,NSString *domain){
    NSMutableArray *selected=[NSMutableArray new];
    for(NSDictionary *record in state[@"accounts"])
        if([record[@"selected"]boolValue]&&[record[@"domain"]isEqual:domain]&&
           (![domain isEqual:@"icloud"]||[record[@"primary"]boolValue]))[selected addObject:record];
    return selected;
}
static NSDictionary *DomainSummary(NSArray *records){
    if(records.count>1)return @{@"status":@"conflict",@"account":NSNull.null};
    return @{@"status":records.count?@"signed_in":@"not_signed_in",@"account":records.firstObject?:NSNull.null};
}
static NSString *SettingsTarget(NSDictionary *state,BOOL *conflict){
    NSArray *identity=Selected(state,@"identity"),*cloud=Selected(state,@"icloud");
    *conflict=identity.count>1||cloud.count>1;
    NSString *phone=[identity.firstObject[@"apple_id"]lowercaseString],*icloud=[cloud.firstObject[@"apple_id"]lowercaseString];
    if(phone&&icloud&&![phone isEqual:icloud])*conflict=YES;
    NSString *target=phone?:icloud;
    if((identity.count||cloud.count)&&!target.length)*conflict=YES;
    return *conflict?nil:target;
}
static NSSet *IdentitySignature(NSDictionary *state){
    NSMutableSet *signature=[NSMutableSet new];
    for(NSDictionary *record in state[@"accounts"]){
        if(![record[@"selected"]boolValue])continue;
        [signature addObject:@{@"identifier":record[@"identifier"]?:NSNull.null,@"apple_id":record[@"apple_id"]?:NSNull.null,
            @"domain":record[@"domain"]?:NSNull.null,@"primary":record[@"primary"]?:@NO}];
    }
    return signature;
}
static NSDictionary *ProfileResult(NSDictionary *data,NSError *error,NSString *target){
    if(error){
        TVAppleErrorCode code=[error.domain isEqual:TVAppleErrorDomain]?(TVAppleErrorCode)error.code:TVAppleErrorBackendRead;
        return SectionError(code);
    }
    if(![data isKindOfClass:NSDictionary.class]||![data[@"apple_id"]isKindOfClass:NSString.class])return SectionError(TVAppleErrorBackendRead);
    if([data[@"apple_id"]caseInsensitiveCompare:target]!=NSOrderedSame)return SectionError(TVAppleErrorConflict);
    return @{@"status":@"available",@"data":data};
}
NSDictionary *TVAppleAggregateState(id<TVAppleBackend> backend,NSError **error){
    NSDictionary *before=[backend snapshot:error];
    if(!before||*error){if(!*error)*error=TVAppleError(TVAppleErrorBackendRead,@"Account state is unavailable.");return nil;}
    BOOL conflict=NO;NSString *target=SettingsTarget(before,&conflict);
    NSDictionary *name=NoProfile(),*email=NoProfile(),*siwa=NoProfile();
    if(conflict){name=SectionError(TVAppleErrorConflict);email=SectionError(TVAppleErrorConflict);siwa=SectionError(TVAppleErrorConflict);}
    else if(target){
        NSError *readError=nil;NSDictionary *data=nil;
        if([backend conformsToProtocol:@protocol(TVAppleNameSettingsBackend)]){
            data=[(id<TVAppleNameSettingsBackend>)backend nameSettingsForAppleID:target error:&readError];
            name=ProfileResult(data,readError,target);
        }else name=SectionError(TVAppleErrorUnsupported);
        readError=nil;data=nil;
        if([backend conformsToProtocol:@protocol(TVAppleEmailSettingsBackend)]){
            data=[(id<TVAppleEmailSettingsBackend>)backend emailSettingsForAppleID:target error:&readError];
            email=ProfileResult(data,readError,target);
        }else email=SectionError(TVAppleErrorUnsupported);
        readError=nil;data=nil;
        if([backend conformsToProtocol:@protocol(TVAppleSignInWithAppleBackend)]){
            data=[(id<TVAppleSignInWithAppleBackend>)backend signInWithAppleAppsForAppleID:target error:&readError];
            siwa=ProfileResult(data,readError,target);
        }else siwa=SectionError(TVAppleErrorUnsupported);
    }
    // Recheck after server reads. Never combine an old profile with a new identity.
    NSDictionary *after=[backend snapshot:error];
    if(!after||*error){if(!*error)*error=TVAppleError(TVAppleErrorBackendRead,@"Final account state is unavailable.");return nil;}
    BOOL consistent=[IdentitySignature(before)isEqual:IdentitySignature(after)];
    BOOL finalConflict=NO;NSString *finalTarget=SettingsTarget(after,&finalConflict);
    if(!consistent){name=SectionError(TVAppleErrorConflict);email=SectionError(TVAppleErrorConflict);siwa=SectionError(TVAppleErrorConflict);}
    NSMutableDictionary *result=[after mutableCopy];
    result[@"app_store"]=DomainSummary(Selected(after,@"media"));
    NSMutableDictionary *cloud=[DomainSummary(Selected(after,@"icloud"))mutableCopy];
    cloud[@"find_my_enabled"]=after[@"find_my_enabled"];
    result[@"icloud"]=cloud;
    [result removeObjectForKey:@"find_my_enabled"];
    result[@"identity"]=DomainSummary(Selected(after,@"identity"));
    result[@"apple_settings"]=@{@"status":finalConflict?@"conflict":(finalTarget?@"signed_in":@"not_signed_in"),
        @"apple_id":finalTarget?:NSNull.null,@"name":name,@"email":email,@"sign_in_with_apple":siwa};
    return result;
}
