#import "TVAppleStateAggregation.h"
#import "TVAppleEmailSettings.h"
#import "TVAppleNameSettings.h"
#import "TVAppleSignInWithApple.h"
#import "TVAppleICloudDevices.h"
#include <assert.h>
static NSDictionary *Record(NSString *key,NSString *domain,NSString *appleID,BOOL selected){
    return @{@"identifier":key,@"domain":domain,@"apple_id":appleID,@"selected":@(selected),@"primary":@([domain isEqual:@"icloud"]),@"authenticated":@YES};
}
@interface AggregateBackend:NSObject<TVAppleBackend,TVAppleEmailSettingsBackend,TVAppleNameSettingsBackend,TVAppleSignInWithAppleBackend,TVAppleICloudDevicesBackend>
@property NSArray *accounts,*finalAccounts;
@property NSUInteger reads,names,emails,siwaReads,deviceReads;
@property BOOL nameFailure,emailFailure,readFailure,finalReadFailure,noName,wrongProfile,findMy,siwaFailure,deviceFailure,noDevices,wrongDevices;
@end
@implementation AggregateBackend
- (BOOL)conformsToProtocol:(Protocol *)protocol{
    if(protocol==@protocol(TVAppleICloudDevicesBackend)&&self.noDevices)return NO;
    if(protocol==@protocol(TVAppleNameSettingsBackend)&&self.noName)return NO;
    return [super conformsToProtocol:protocol];
}
- (NSDictionary *)snapshot:(NSError **)error{
    self.reads++;
    if(self.readFailure||(self.finalReadFailure&&self.reads>1)){*error=TVAppleError(TVAppleErrorBackendRead,@"fixture");return nil;}
    return @{@"schema_version":@1,@"accounts":self.reads>1&&self.finalAccounts?self.finalAccounts:self.accounts,@"find_my_enabled":@(self.findMy),@"capabilities":@{@"query":@YES}};
}
- (NSDictionary *)nameSettingsForAppleID:(NSString *)appleID error:(NSError **)error{
    self.names++;assert([appleID isEqual:@"phone@example.com"]);
    if(self.nameFailure){*error=[NSError errorWithDomain:@"native-sensitive"code:99 userInfo:@{NSLocalizedDescriptionKey:@"secret-token"}];return nil;}
    return @{@"apple_id":self.wrongProfile?@"wrong@example.com":appleID,@"first_name":@"jack",@"last_name":@"ma",@"middle_name":@""};
}
- (NSDictionary *)emailSettingsForAppleID:(NSString *)appleID error:(NSError **)error{
    self.emails++;assert([appleID isEqual:@"phone@example.com"]);
    if(self.emailFailure){*error=TVAppleError(TVAppleErrorBackendRead,@"fixture");return nil;}
    return @{@"apple_id":appleID,@"reachable_emails":@[@"relay@example.net"],@"forwarding_email":@"relay@example.net"};
}
- (NSDictionary *)signInWithAppleAppsForAppleID:(NSString *)appleID error:(NSError **)error{
    self.siwaReads++;assert([appleID isEqual:@"phone@example.com"]);
    if(self.siwaFailure){*error=TVAppleError(TVAppleErrorBackendRead,@"fixture");return nil;}
    return @{@"apple_id":appleID,@"bundle_ids":@[@"com.example.target"],@"apps":@[]};
}
- (NSDictionary *)iCloudDevicesForAppleID:(NSString *)appleID error:(NSError **)error{self.deviceReads++;if(self.deviceFailure){*error=TVAppleError(TVAppleErrorBackendRead,@"fixture");return nil;}return @{@"apple_id":self.wrongDevices?@"other@example.com":appleID,@"devices":@[@{@"current_device":@YES}]};}
- (NSDictionary *)removeOtherICloudDevicesForAppleID:(NSString *)appleID error:(NSError **)error{(void)appleID;(void)error;assert(NO);return nil;}
- (NSDictionary *)stopUsingAppleIDForBundleID:(NSString *)bundleID appleID:(NSString *)appleID error:(NSError **)error{(void)bundleID;(void)appleID;(void)error;assert(NO);return nil;}
- (NSDictionary *)setFirstName:(NSString *)first lastName:(NSString *)last appleID:(NSString *)appleID error:(NSError **)error{(void)first;(void)last;(void)appleID;(void)error;assert(NO);return nil;}
- (id)prepareAccount:(NSDictionary *)account policy:(TVAppleLocalDataPolicy)policy error:(NSError **)error{(void)account;(void)policy;(void)error;assert(NO);return nil;}
- (BOOL)removePreparedAccount:(id)prepared error:(NSError **)error{(void)prepared;(void)error;assert(NO);return NO;}
@end
int main(void){@autoreleasepool{
    for(NSString *scenario in @[@"success",@"device_failure",@"device_unsupported",@"device_wrong",@"siwa_failure",@"find_my_enabled",@"signed_out",@"media_only",@"identity_only",@"name_failure",@"email_failure",@"unsupported",@"wrong_profile",@"ambiguous",@"different_cloud",@"changed",@"read_failure",@"final_read_failure"]){
        AggregateBackend *backend=[AggregateBackend new];
        NSDictionary *phone=Record(@"idms",@"identity",@"phone@example.com",YES),*cloud=Record(@"cloud",@"icloud",@"phone@example.com",YES),
            *media=Record(@"media",@"media",@"store@example.com",YES),*old=Record(@"history",@"media",@"old@example.com",NO);
        backend.accounts=@[phone,cloud,media,old];
        backend.findMy=[scenario isEqual:@"find_my_enabled"];
        backend.noDevices=[scenario isEqual:@"device_unsupported"];backend.wrongDevices=[scenario isEqual:@"device_wrong"];
        backend.deviceFailure=[scenario isEqual:@"device_failure"];
        backend.siwaFailure=[scenario isEqual:@"siwa_failure"];
        if([scenario isEqual:@"signed_out"])backend.accounts=@[old];
        if([scenario isEqual:@"media_only"])backend.accounts=@[media,old];
        if([scenario isEqual:@"identity_only"])backend.accounts=@[phone,media];
        if([scenario isEqual:@"name_failure"])backend.nameFailure=YES;
        if([scenario isEqual:@"email_failure"])backend.emailFailure=YES;
        if([scenario isEqual:@"unsupported"])backend.noName=YES;
        if([scenario isEqual:@"wrong_profile"])backend.wrongProfile=YES;
        if([scenario isEqual:@"ambiguous"])backend.accounts=@[phone,Record(@"other",@"identity",@"other@example.com",YES),media];
        if([scenario isEqual:@"different_cloud"])backend.accounts=@[phone,Record(@"different",@"icloud",@"other@example.com",YES),media];
        if([scenario isEqual:@"changed"])backend.finalAccounts=@[Record(@"new-idms",@"identity",@"new@example.com",YES),media];
        if([scenario isEqual:@"read_failure"])backend.readFailure=YES;
        if([scenario isEqual:@"final_read_failure"])backend.finalReadFailure=YES;
        NSError *error=nil;NSDictionary *state=TVAppleAggregateState(backend,&error);
        if([scenario isEqual:@"success"])assert([state[@"icloud"][@"devices"][@"status"]isEqual:@"available"]&&backend.deviceReads==1);
        if([scenario isEqual:@"device_failure"]||[scenario isEqual:@"device_unsupported"]||[scenario isEqual:@"device_wrong"]||[scenario isEqual:@"changed"])assert([state[@"icloud"][@"devices"][@"status"]isEqual:@"error"]);
        if([scenario isEqual:@"identity_only"])assert([state[@"icloud"][@"devices"][@"status"]isEqual:@"not_signed_in"]&&backend.deviceReads==0);
        if(backend.readFailure||backend.finalReadFailure){assert(!state&&error.code==TVAppleErrorBackendRead);continue;}
        assert(state&&!error&&[NSJSONSerialization isValidJSONObject:state]);
        assert(!state[@"find_my_enabled"]);
        assert(!state[@"collection_status"]&&!state[@"collection_consistent"]);
        assert([state[@"icloud"][@"find_my_enabled"]isEqual:@(backend.findMy)]);
        assert([state[@"accounts"]isEqual:backend.finalAccounts?:backend.accounts]);
        assert([state[@"schema_version"]isEqual:@1]&&state[@"capabilities"]);
        NSDictionary *settings=state[@"apple_settings"],*name=settings[@"name"],*email=settings[@"email"];
        if([scenario isEqual:@"signed_out"]||[scenario isEqual:@"media_only"]){
            assert([settings[@"status"]isEqual:@"not_signed_in"]&&settings[@"apple_id"]==NSNull.null);
            assert(!backend.names&&!backend.emails&&!backend.siwaReads&&[name[@"status"]isEqual:@"not_signed_in"]);
            assert([state[@"app_store"][@"status"]isEqual:[scenario isEqual:@"signed_out"]?@"not_signed_in":@"signed_in"]);continue;
        }
        if([scenario isEqual:@"ambiguous"]||[scenario isEqual:@"different_cloud"]){
            assert(!backend.names&&!backend.emails&&!backend.siwaReads&&[settings[@"status"]isEqual:@"conflict"]&&[name[@"status"]isEqual:@"error"]);continue;
        }
        // App Store may have a different identity; Settings queries must target the phone.
        assert([state[@"app_store"][@"account"][@"apple_id"]isEqual:@"store@example.com"]);
        if([scenario isEqual:@"changed"]){
            assert([settings[@"apple_id"]isEqual:@"new@example.com"]);
            assert(name[@"data"]==NSNull.null&&email[@"data"]==NSNull.null&&settings[@"sign_in_with_apple"][@"data"]==NSNull.null);continue;
        }
        if(backend.siwaFailure)assert([settings[@"sign_in_with_apple"][@"status"]isEqual:@"error"]&&settings[@"sign_in_with_apple"][@"data"]==NSNull.null);
        else assert([settings[@"sign_in_with_apple"][@"data"][@"bundle_ids"]containsObject:@"com.example.target"]);
        if(backend.nameFailure||backend.noName||backend.wrongProfile){
            assert([name[@"status"]isEqual:@"error"]&&name[@"data"]==NSNull.null&&[email[@"status"]isEqual:@"available"]);
            assert(![name description]||[[name description]rangeOfString:@"secret-token"].location==NSNotFound);
        }else if(backend.emailFailure){assert([email[@"status"]isEqual:@"error"]&&[name[@"status"]isEqual:@"available"]);}
        else{assert([name[@"data"][@"first_name"]isEqual:@"jack"]&&[email[@"data"][@"forwarding_email"]isEqual:@"relay@example.net"]);}
    }
    puts("PASS state aggregation: profiles, partial errors, signed out, split accounts, identity changes, read failure");return 0;
}}
