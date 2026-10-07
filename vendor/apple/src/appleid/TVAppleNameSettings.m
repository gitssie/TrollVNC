#import "TVAppleNameSettings.h"
#import "TVAppleEmailActions.h"
@interface NSObject (TVAppleNameSelectors)
- (id)primaryAuthKitAccount; - (id)primaryiCloudAccount; - (NSString *)username; - (NSString *)identifier;
- (NSString *)altDSIDForAccount:(id)account; - (NSString *)givenNameForAccount:(id)account; - (NSString *)familyNameForAccount:(id)account;
- (void)fetchUserInformationForAltDSID:(NSString *)altDSID completion:(void(^)(id,NSError *))completion;
- (void)getUserInformationForAltDSID:(NSString *)altDSID completion:(void(^)(id,NSError *))completion;
- (NSString *)givenName; - (NSString *)familyName;
- (id)clientInfo;
- (id)allPages;
- (id)attributes;
- (id)tableViewOM;
- (id)sections;
- (id)rows;
- (id)rightNavigationBarButtonItem;
@end
static BOOL Supports(id object,NSArray *selectors){
    if(!object)return NO;for(NSString *s in selectors)if(![object respondsToSelector:NSSelectorFromString(s)])return NO;return YES;
}
static BOOL NameIdentity(id manager,NSString *target,NSString *identityID,NSString *cloudID){
    id identity=[manager primaryAuthKitAccount],cloud=[manager primaryiCloudAccount];
    return Supports(identity,@[@"username",@"identifier"])&&Supports(cloud,@[@"username",@"identifier"])&&
        [[[identity username]lowercaseString]isEqual:target]&&[[[cloud username]lowercaseString]isEqual:target]&&
        [[identity identifier]isEqual:identityID]&&[[cloud identifier]isEqual:cloudID];
}
static id NativeNameInfo(id controller,NSString *altDSID,BOOL fetch,NSTimeInterval deadline){
    NSMutableDictionary *ticket=[NSMutableDictionary new];
    void(^reply)(id,NSError *)=^(id info,NSError *error){@synchronized(ticket){if(ticket[@"closed"]||ticket[@"done"])return;ticket[@"done"]=@YES;if(!error&&info)ticket[@"info"]=info;}};
    if(fetch)[controller fetchUserInformationForAltDSID:altDSID completion:reply];else [controller getUserInformationForAltDSID:altDSID completion:reply];
    BOOL done=NO;do{@synchronized(ticket){done=[ticket[@"done"]boolValue];}if(done||NSProcessInfo.processInfo.systemUptime>=deadline)break;
        [[NSRunLoop currentRunLoop]runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.02]];}while(YES);
    id result=nil;@synchronized(ticket){ticket[@"closed"]=@YES;if(done&&NSProcessInfo.processInfo.systemUptime<=deadline)result=ticket[@"info"];[ticket removeObjectForKey:@"info"];}return result;
}
BOOL TVAppleRefreshAuthKitName(id manager,id controller,NSString *appleID,NSString *first,NSString *last,NSTimeInterval timeout,NSError **error){
    if(!Supports(manager,@[@"primaryAuthKitAccount",@"primaryiCloudAccount",@"altDSIDForAccount:",@"givenNameForAccount:",@"familyNameForAccount:"])||
       !Supports(controller,@[@"fetchUserInformationForAltDSID:completion:",@"getUserInformationForAltDSID:completion:"])){*error=TVAppleError(TVAppleErrorUnsupported,@"Native AuthKit name refresh is unavailable.");return NO;}
    id identity=[manager primaryAuthKitAccount],cloud=[manager primaryiCloudAccount];
    if(!Supports(identity,@[@"username",@"identifier"])||!Supports(cloud,@[@"username",@"identifier"])){
        *error=TVAppleError(TVAppleErrorConflict,@"Matching native name identities are required.");return NO;
    }
    NSString *identityID=[[identity identifier]copy],*cloudID=[[cloud identifier]copy],*altDSID=[manager altDSIDForAccount:identity];
    if(!identityID.length||!cloudID.length||![altDSID isKindOfClass:NSString.class]||!altDSID.length||!NameIdentity(manager,appleID,identityID,cloudID)){
        *error=TVAppleError(TVAppleErrorConflict,@"Matching native name identities are required.");return NO;
    }
    NSTimeInterval deadline=NSProcessInfo.processInfo.systemUptime+timeout;
    // iOS15's native fresh fetch synchronizes account/user-information caches.
    // A cached get alone does not refresh them. Do not manually overwrite an
    // account property or submit a partial user-information update dictionary.
    id info=NativeNameInfo(controller,altDSID,YES,deadline);
    if(![info isKindOfClass:NSDictionary.class]||![info[@"firstName"]isEqual:first]||![info[@"lastName"]isEqual:last]||
       (info[@"accountName"]&&(![info[@"accountName"]isKindOfClass:NSString.class]||[info[@"accountName"]caseInsensitiveCompare:appleID]!=NSOrderedSame))){
        *error=TVAppleError(TVAppleErrorBackendRead,@"Fresh AuthKit name did not match the verified Settings name.");return NO;
    }
    do{
        if(NSProcessInfo.processInfo.systemUptime>=deadline)break;
        if(!NameIdentity(manager,appleID,identityID,cloudID)){*error=TVAppleError(TVAppleErrorConflict,@"Native name identity changed during refresh.");return NO;}
        id cached=NativeNameInfo(controller,altDSID,NO,deadline);
        if(!NameIdentity(manager,appleID,identityID,cloudID)){*error=TVAppleError(TVAppleErrorConflict,@"Native name identity changed during refresh.");return NO;}
        id phone=[manager primaryAuthKitAccount],primary=[manager primaryiCloudAccount];
        BOOL names=Supports(cached,@[@"givenName",@"familyName"])&&[[cached givenName]isEqual:first]&&[[cached familyName]isEqual:last]&&
            [[manager givenNameForAccount:phone]isEqual:first]&&[[manager familyNameForAccount:phone]isEqual:last]&&
            [[manager givenNameForAccount:primary]isEqual:first]&&[[manager familyNameForAccount:primary]isEqual:last];
        if(names){*error=nil;return YES;}
        if(!cached||NSProcessInfo.processInfo.systemUptime>=deadline)break;
        [[NSRunLoop currentRunLoop]runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.1]];
    }while(YES);
    *error=TVAppleError(TVAppleErrorBackendRead,@"Native AuthKit name cache did not converge to the verified Settings name.");return NO;
}
BOOL TVAppleValidName(id value){
    if(![value isKindOfClass:NSString.class]||![value length]||[value length]>128)return NO;
    return [[value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]length]>0&&
        [value rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location==NSNotFound;
}
NSDictionary *TVAppleNameFromPersonalInfo(id model,NSString *appleID,NSError **error){
    id info=Supports(model,@[@"clientInfo"])?[model clientInfo]:nil;
    if(![info isKindOfClass:NSDictionary.class]||![info[@"firstName"]isKindOfClass:NSString.class]||
       ![info[@"lastName"]isKindOfClass:NSString.class]||![info[@"middleName"]isKindOfClass:NSString.class]){
        *error=TVAppleError(TVAppleErrorBackendRead,@"Native Settings name information is unavailable.");return nil;
    }
    id account=info[@"accountName"];
    if(account&&(![account isKindOfClass:NSString.class]||[account caseInsensitiveCompare:appleID]!=NSOrderedSame)){
        *error=TVAppleError(TVAppleErrorConflict,@"Server name information belongs to another Apple ID.");return nil;
    }
    return @{@"apple_id":appleID,@"first_name":info[@"firstName"],@"last_name":info[@"lastName"],
        @"middle_name":info[@"middleName"],@"source":@"native_settings_server"};
}
NSMutableURLRequest *TVAppleNamePostback(id form,NSString *first,NSString *last,NSURL *origin,NSString **preservedMiddle,NSError **error){
    if(!TVAppleValidName(first)||!TVAppleValidName(last)){
        *error=TVAppleError(TVAppleErrorInvalidRequest,@"First Name and Last Name must be nonblank text without control characters (up to 128 UTF-16 units each).");return nil;
    }
    if(!Supports(form,@[@"allPages"])||![[form allPages]isKindOfClass:NSArray.class]||[[form allPages]count]!=1){
        *error=TVAppleError(TVAppleErrorUnsupported,@"Native name form is unavailable.");return nil;
    }
    id page=[[form allPages]firstObject];
    if(!Supports(page,@[@"tableViewOM",@"rightNavigationBarButtonItem"])||!Supports([page tableViewOM],@[@"sections"])){
        *error=TVAppleError(TVAppleErrorUnsupported,@"Native name fields are unavailable.");return nil;
    }
    NSMutableDictionary *fields=[NSMutableDictionary new];
    for(id section in [[page tableViewOM]sections]){
        if(!Supports(section,@[@"rows"])){*error=TVAppleError(TVAppleErrorUnsupported,@"Native name section has changed.");return nil;}
        for(id row in [section rows]){
            NSDictionary *attrs=Supports(row,@[@"attributes"])?[row attributes]:nil;
            id key=attrs[@"id"];
            if(![attrs[@"class"]isEqual:@"editableText"]||![@[@"firstName",@"middleName",@"lastName"]containsObject:key]||fields[key]||
               ![attrs[@"value"]isKindOfClass:NSString.class]){
                *error=TVAppleError(TVAppleErrorUnsupported,@"Native name input schema has changed.");return nil;
            }
            fields[key]=attrs[@"value"];
        }
    }
    if(fields.count!=3){*error=TVAppleError(TVAppleErrorUnsupported,@"Native name inputs are incomplete.");return nil;}
    id button=[page rightNavigationBarButtonItem];NSDictionary *attrs=Supports(button,@[@"attributes"])?[button attributes]:nil;
    if(![attrs[@"name"]isEqual:@"ak-button"]||![attrs[@"ak-action"]isEqual:@"read"]){
        *error=TVAppleError(TVAppleErrorUnsupported,@"Native name save action has changed.");return nil;
    }
    NSString *middle=fields[@"middleName"];
    NSMutableURLRequest *request=TVAppleEmailPostbackRequest(form,button,@{@"firstName":first,@"lastName":last,@"middleName":middle},origin,
        @"/appleid/settings/account/manage/person/name/put",error);
    if(request&&preservedMiddle)*preservedMiddle=middle;return request;
}
@implementation TVAppleNativeSettingsSession (NameSettings)
- (BOOL)refreshName:(NSDictionary *)name appleID:(NSString *)appleID error:(NSError **)error{
    if(![self identityMatches:error])return NO;
    id manager=[self valueForKey:@"manager"],controller=[NSClassFromString(@"AKAppleIDAuthenticationController")new];
    return TVAppleRefreshAuthKitName(manager,controller,appleID,name[@"first_name"],name[@"last_name"],30,error)&&[self identityMatches:error];
}
- (NSDictionary *)readName:(NSString *)appleID error:(NSError **)error{
    id model=[self get:@"/appleid/settings/account/manage" error:error];if(!model)return nil;
    NSDictionary *name=TVAppleNameFromPersonalInfo(model,appleID,error);
    if(!name||![self identityMatches:error])return nil;return name;
}
- (NSDictionary *)queryName:(NSString *)appleID error:(NSError **)error{
    @synchronized(self){
        NSDictionary *result=nil;
        if([self beginSettingsOperation:appleID error:error])result=[self readName:appleID error:error];
        [self finishSettingsOperation];return result;
    }
}
- (NSDictionary *)setFirstName:(NSString *)first lastName:(NSString *)last appleID:(NSString *)appleID error:(NSError **)error{
    @synchronized(self){
        NSDictionary *result=[self setNameUnlocked:first lastName:last appleID:appleID error:error];
        [self finishSettingsOperation];return result;
    }
}
- (NSDictionary *)setNameUnlocked:(NSString *)first lastName:(NSString *)last appleID:(NSString *)appleID error:(NSError **)error{
    if(!TVAppleValidName(first)||!TVAppleValidName(last)){*error=TVAppleError(TVAppleErrorInvalidRequest,@"Valid First Name and Last Name are required.");return nil;}
    if(![self beginSettingsOperation:appleID error:error])return nil;
    NSDictionary *before=[self readName:appleID error:error];if(!before)return nil;
    if([before[@"first_name"]isEqual:first]&&[before[@"last_name"]isEqual:last]){
        if(![self refreshName:before appleID:appleID error:error]){*error=TVAppleError(TVAppleErrorOutcomeUnknown,@"Settings name matches, but native AuthKit synchronization was not verified.");return nil;}
        return @{@"outcome":@"succeeded",@"already_configured":@YES,@"settings":before};
    }
    // Follow the exact server-advertised Settings link, without using a guessed write URL.
    id personal=[self get:@"/appleid/settings/account/manage" error:error];if(!personal)return nil;
    NSString *link=nil;
    if(!Supports(personal,@[@"allPages"])){*error=TVAppleError(TVAppleErrorUnsupported,@"Native personal information entry is unavailable.");return nil;}
    for(id page in [personal allPages]){
        if(!Supports(page,@[@"tableViewOM"])||!Supports([page tableViewOM],@[@"sections"]))continue;
        for(id section in [[page tableViewOM]sections]){
            if(!Supports(section,@[@"rows"]))continue;
            for(id row in [section rows]){
                NSDictionary *attrs=Supports(row,@[@"attributes"])?[row attributes]:nil;id candidate=attrs[@"url"];
                if([attrs[@"class"]isEqual:@"link"]&&[candidate isKindOfClass:NSString.class]&&
                   [[NSURLComponents componentsWithString:candidate].path isEqual:@"/appleid/settings/account/manage/name"]&&
                   (!attrs[@"httpMethod"]||[attrs[@"httpMethod"]isEqual:@"GET"])){
                    if(link){*error=TVAppleError(TVAppleErrorUnsupported,@"Native name entry is ambiguous.");return nil;}link=candidate;
                }
            }
        }
    }
    if(!link){*error=TVAppleError(TVAppleErrorUnsupported,@"Server did not advertise the native name entry.");return nil;}
    id form=[self get:link error:error];if(!form)return nil;NSString *middle=nil;
    NSMutableURLRequest *post=TVAppleNamePostback(form,first,last,[self origin],&middle,error);if(!post)return nil;
    if(![self load:post mutation:YES error:error])return nil;
    NSDictionary *fresh=[self readName:appleID error:error];
    if(![fresh[@"first_name"]isEqual:first]||![fresh[@"last_name"]isEqual:last]||![fresh[@"middle_name"]isEqual:middle]){
        *error=TVAppleError(TVAppleErrorOutcomeUnknown,@"Saved name was not confirmed by a fresh native Settings query.");return nil;
    }
    if(![self refreshName:fresh appleID:appleID error:error]){*error=TVAppleError(TVAppleErrorOutcomeUnknown,@"Settings name was saved, but native AuthKit synchronization was not verified.");return nil;}
    return @{@"outcome":@"succeeded",@"already_configured":@NO,@"settings":fresh};
}
@end
@implementation TVAppleServices (NameSettings)
- (void)queryAppleIDNameSettings:(NSString *)appleID completion:(TVAppleCompletion)completion{
    [self enqueueNameSettings:appleID firstName:nil lastName:nil mutation:NO completion:completion];
}
- (void)setAppleIDFirstName:(NSString *)firstName lastName:(NSString *)lastName appleID:(NSString *)appleID completion:(TVAppleCompletion)completion{
    [self enqueueNameSettings:appleID firstName:firstName lastName:lastName mutation:YES completion:completion];
}
@end
