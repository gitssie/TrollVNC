#import "TVAppleEmailSettings.h"
#import <dlfcn.h>
@interface NSObject (TVAppleEmailSelectors)
+ (id)sharedInstance;
- (id)primaryAuthKitAccount;
- (NSString *)username;
- (NSString *)identifier;
- (NSString *)altDSIDForAccount:(id)account;
- (void)fetchUserInformationForAltDSID:(NSString *)altDSID completion:(void(^)(id,NSError *))completion;
- (id)initWithResponseBody:(NSDictionary *)body;
- (NSString *)accountName;
- (NSString *)primaryEmailAddress;
- (NSArray *)reachableEmails;
- (NSString *)forwardingEmail;
@end
@implementation TVAppleServices (EmailSettings)
- (void)queryAppleIDEmailSettings:(NSString *)appleID completion:(TVAppleCompletion)completion{
    [self enqueueEmailSettingsForAppleID:appleID completion:completion];
}
@end
static BOOL Supports(id object,NSArray *names){
    for(NSString *name in names)if(![object respondsToSelector:NSSelectorFromString(name)])return NO;
    return object!=nil;
}
NSDictionary *TVAppleEmailSettingsFromUserInfo(id info,NSError **error){
    // iOS15 fetchUserInformation returns a server dictionary, whereas getUserInformation
    // returns cached AKUserInformation. Let Apple's own parser decode its schema.
    if([info isKindOfClass:NSDictionary.class]){
        if(![info[@"reachableEmails"]isKindOfClass:NSArray.class]){
            *error=TVAppleError(TVAppleErrorBackendRead,@"Native server response has no verifiable reachable-email list.");return nil;
        }
        id parser=[NSClassFromString(@"AKUserInformation")alloc];
        if(!Supports(parser,@[@"initWithResponseBody:"])){*error=TVAppleError(TVAppleErrorUnsupported,@"Native email settings parser is unavailable.");return nil;}
        info=[parser initWithResponseBody:info];
    }
    if(!Supports(info,@[@"accountName",@"primaryEmailAddress",@"reachableEmails",@"forwardingEmail"])){
        *error=TVAppleError(TVAppleErrorBackendRead,@"Native email settings response is unavailable.");return nil;
    }
    id name=[info accountName],primary=[info primaryEmailAddress],reachable=[info reachableEmails],forward=[info forwardingEmail];
    if((name&&![name isKindOfClass:NSString.class])||
       (primary&&![primary isKindOfClass:NSString.class])||![reachable isKindOfClass:NSArray.class]||
       (forward&&![forward isKindOfClass:NSString.class])){
        *error=TVAppleError(TVAppleErrorBackendRead,@"Native email settings fields have an unsupported shape.");return nil;
    }
    for(id address in reachable)if(![address isKindOfClass:NSString.class]){
        *error=TVAppleError(TVAppleErrorBackendRead,@"Native reachable-email entries have an unsupported shape.");return nil;
    }
    return @{@"server_account_name":name?:NSNull.null,@"primary_email":primary?:NSNull.null,@"reachable_emails":[reachable copy],
             @"forwarding_email":forward?:NSNull.null,@"source":@"authkit_server"};
}
NSDictionary *TVAppleFetchEmailSettings(id manager,id controller,NSString *appleID,NSTimeInterval timeout,NSError **error){
    if(!Supports(manager,@[@"primaryAuthKitAccount",@"altDSIDForAccount:"])){
        *error=TVAppleError(TVAppleErrorUnsupported,@"Native primary identity interface is unavailable.");return nil;
    }
    id account=[manager primaryAuthKitAccount];
    if(!Supports(account,@[@"username",@"identifier"])||![[[account username]lowercaseString]isEqual:appleID]){
        *error=TVAppleError(TVAppleErrorConflict,@"Email settings require the matching primary phone identity.");return nil;
    }
    NSString *identifier=[[account identifier]copy],*altDSID=[manager altDSIDForAccount:account];
    if(!identifier.length||![altDSID isKindOfClass:NSString.class]||!altDSID.length){
        *error=TVAppleError(TVAppleErrorBackendRead,@"Primary phone identity is incomplete.");return nil;
    }
    if(!Supports(controller,@[@"fetchUserInformationForAltDSID:completion:"])){
        *error=TVAppleError(TVAppleErrorUnsupported,@"Fresh native email settings query is unavailable.");return nil;
    }
    NSMutableDictionary *ticket=[NSMutableDictionary new];dispatch_semaphore_t done=dispatch_semaphore_create(0);
    [controller fetchUserInformationForAltDSID:altDSID completion:^(id info,NSError *nativeError){
        @synchronized(ticket){if(ticket[@"closed"]||ticket[@"finished"])return;
            NSError *conversion=nil;NSDictionary *settings=nativeError?nil:TVAppleEmailSettingsFromUserInfo(info,&conversion);
            ticket[@"finished"]=@YES;if(settings)ticket[@"settings"]=settings;
            dispatch_semaphore_signal(done);
        }
    }];
    NSTimeInterval deadline=NSProcessInfo.processInfo.systemUptime+timeout;BOOL completed=NO;
    while(!(completed=dispatch_semaphore_wait(done,DISPATCH_TIME_NOW)==0)&&NSProcessInfo.processInfo.systemUptime<deadline)
        [[NSRunLoop currentRunLoop]runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    NSDictionary *settings=nil;
    @synchronized(ticket){ticket[@"closed"]=@YES;if(completed)settings=ticket[@"settings"];[ticket removeObjectForKey:@"settings"];}
    if(!settings){*error=TVAppleError(TVAppleErrorBackendRead,@"Fresh native email settings query failed or timed out.");return nil;}
    id fresh=[manager primaryAuthKitAccount];
    if(!Supports(fresh,@[@"username",@"identifier"])||![[fresh identifier]isEqual:identifier]||
       ![[[fresh username]lowercaseString]isEqual:appleID]||(settings[@"server_account_name"]!=NSNull.null&&![[settings[@"server_account_name"]lowercaseString]isEqual:appleID])){
        *error=TVAppleError(TVAppleErrorConflict,@"Phone identity changed or disagrees with the server email settings.");return nil;
    }
    NSMutableDictionary *result=[settings mutableCopy];result[@"apple_id"]=appleID;return result;
}

NSDictionary *TVAppleNativeEmailSettings(NSString *appleID,NSError **error){
    if(!dlopen("/System/Library/PrivateFrameworks/AuthKit.framework/AuthKit",RTLD_NOW)){
        *error=TVAppleError(TVAppleErrorUnsupported,@"Native email settings framework is unavailable.");return nil;
    }
    Class cls=NSClassFromString(@"AKAccountManager");
    if(!Supports(cls,@[@"sharedInstance"])){
        *error=TVAppleError(TVAppleErrorUnsupported,@"Native identity manager is unavailable.");return nil;
    }
    return TVAppleFetchEmailSettings([cls sharedInstance],[NSClassFromString(@"AKAppleIDAuthenticationController")new],appleID,30,error);
}
