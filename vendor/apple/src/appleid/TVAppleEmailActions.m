#import "TVAppleEmailActions.h"
#import "TVAppleSignInWithApple.h"
#import "TVAppleICloudDevices.h"
#import <dlfcn.h>
#import <objc/runtime.h>

@interface NSObject (TVAppleEmailActionSelectors)
+ (id)sharedInstance;
- (id)primaryAuthKitAccount;
- (id)aa_primaryAppleAccount;
- (NSString *)username;
- (NSString *)identifier;
- (id)aa_grandSlamAccountForiCloudAccount:(id)account;
- (id)credentialForAccount:(id)account serviceID:(NSString *)service;
- (id)token;
- (id)aida_alternateDSID;
- (id)initWithAltDSID:(id)identifier;
- (NSURL *)privateEmailManageURL;
- (id)initWithGrandSlamAccount:(id)account accountStore:(id)store;
- (void)setForceGSToken:(BOOL)value;
- (NSURLRequest *)urlRequest;
- (void)setAltDSID:(id)value;
- (void)setAnticipateEscrowAttempt:(BOOL)value;
- (void)getServerUILoadDelegateWithContext:(id)context completion:(void(^)(id,NSError *))completion;
- (void)setServiceToken:(id)token;
- (void)signRequest:(NSMutableURLRequest *)request;
- (void)loadXMLUIWithRequest:(NSURLRequest *)request;
- (void)cancel;
- (id)attributes;
- (id)allPages;
- (id)primaryAlert;
- (NSString *)title;
- (NSString *)message;
- (id)uiObjectModel;
- (BOOL)succeeded;
- (void)setPrimaryAlert:(id)alert;
- (void)setSourceURL:(NSURL *)url;
- (NSURL *)sourceURL;
- (NSString *)inlineScript;
- (id)rightNavigationBarButtonItem;
- (id)passcodeViewOM;
- (id)subElementWithID:(NSString *)identifier;
- (id)tableViewOM;
- (id)sections;
- (id)rows;
- (NSString *)identifier;
- (void)setUpdateInfo:(NSDictionary *)values;
- (NSData *)postbackData;
- (void)_populateRequest:(NSMutableURLRequest *)request;
@end
@protocol TVAppleEmailLoader <NSObject>
- (void)setDelegate:(id)delegate;
- (void)loadXMLUIWithRequest:(NSURLRequest *)request;
- (void)cancel;
@end
static BOOL HasAll(id object,NSArray *selectors){
    if(!object)return NO;
    for(NSString *name in selectors)if(![object respondsToSelector:NSSelectorFromString(name)])return NO;
    return YES;
}
static BOOL SameOrigin(NSURL *url,NSURL *origin){
    return [url.scheme.lowercaseString isEqual:@"https"] && !url.user && !url.password &&
        [url.host.lowercaseString isEqual:origin.host.lowercaseString] &&
        [(url.port?:@443)isEqual:(origin.port?:@443)];
}
BOOL TVAppleValidEmailAddress(id value){
    if(![value isKindOfClass:NSString.class]||![value length]||[value length]>254)return NO;
    if([value rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location!=NSNotFound||
       [value rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location!=NSNotFound)return NO;
    NSArray *parts=[value componentsSeparatedByString:@"@"];
    return parts.count==2&&[parts[0]length]>0&&[parts[0]length]<=64&&[parts[1]length]>0&&
        [parts[1]rangeOfString:@"."].location!=NSNotFound;
}
NSMutableURLRequest *TVAppleEmailPostbackRequest(id model,id element,NSDictionary *values,NSURL *origin,NSString *expectedPath,NSError **error){
    if(!HasAll(model,@[@"sourceURL",@"setUpdateInfo:",@"postbackData",@"_populateRequest:"])||!HasAll(element,@[@"attributes"])){
        *error=TVAppleError(TVAppleErrorUnsupported,@"Native email postback interface is unavailable.");return nil;
    }
    NSDictionary *attrs=[element attributes];id link=attrs[@"url"];
    // Loader cleanup can clear model.sourceURL in a later callback. Resolve the
    // observed absolute action path against our immutable native service origin.
    NSURL *url=[link isKindOfClass:NSString.class]?[NSURL URLWithString:link relativeToURL:origin].absoluteURL:nil;
    if(![attrs[@"httpMethod"]isEqual:@"POST"]||!SameOrigin(url,origin)||![url.path isEqual:expectedPath]){
        *error=TVAppleError(TVAppleErrorUnsupported,@"Server email action has an unexpected method or destination.");return nil;
    }
    [model setUpdateInfo:values];NSData *body=[model postbackData];
    if(![body isKindOfClass:NSData.class]||!body.length){*error=TVAppleError(TVAppleErrorBackendRead,@"Native email postback is unavailable.");return nil;}
    NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:30];
    request.HTTPMethod=@"POST";request.HTTPBody=body;[model _populateRequest:request];
    // This is RemoteUIController's native transport content type. A missing type
    // causes HTTP415 even when AuthKit signing and the RUI postback are correct.
    [request setValue:@"application/x-plist" forHTTPHeaderField:@"Content-Type"];
    return request;
}
NSMutableURLRequest *TVAppleRelayForwardingRequest(id form,NSString *email,NSURL *origin,NSError **error){
    if(!HasAll(form,@[@"allPages"])||[[form allPages]count]!=1){*error=TVAppleError(TVAppleErrorUnsupported,@"Native relay forwarding form is unavailable.");return nil;}
    id page=[[form allPages]firstObject];
    if(!HasAll(page,@[@"tableViewOM",@"rightNavigationBarButtonItem"])){
        *error=TVAppleError(TVAppleErrorUnsupported,@"Native relay forwarding page is unavailable.");return nil;
    }
    NSDictionary *selection=nil;
    for(id section in [[page tableViewOM]sections])for(id row in [section rows]){
        NSDictionary *attrs=[row attributes];id label=attrs[@"label"],value=attrs[@"value"];
        if(![attrs[@"class"]isEqual:@"label"]||![attrs[@"radioGroup"]isEqual:@"forwardToEmail"]||
           ![label isKindOfClass:NSString.class]||![value isKindOfClass:NSString.class]||![value length]){
            *error=TVAppleError(TVAppleErrorUnsupported,@"Native forwarding destination fields have changed.");return nil;
        }
        if([label caseInsensitiveCompare:email]==NSOrderedSame){
            if(selection){*error=TVAppleError(TVAppleErrorUnsupported,@"Native forwarding destination is ambiguous.");return nil;}
            selection=@{@"forwardToEmail":value};
        }
    }
    id button=[page rightNavigationBarButtonItem];NSDictionary *attrs=HasAll(button,@[@"attributes"])?[button attributes]:nil;
    if(!selection||![attrs[@"name"]isEqual:@"ak-button"]||![attrs[@"ak-action"]isEqual:@"read"]){
        *error=TVAppleError(TVAppleErrorUnsupported,@"Native relay forwarding destination or save action is unavailable.");return nil;
    }
    return TVAppleEmailPostbackRequest(form,button,selection,origin,@"/appleid/settings/account/manage/forwardemail/put",error);
}

@implementation TVAppleEmailLoad
- (BOOL)complete{@synchronized(self){return self.nativeAlertError!=nil||self.failure!=nil||(self.finished&&self.model!=nil);}}
- (void)loader:(id)loader loadResourcesForObjectModel:(id)model completion:(void(^)(BOOL,NSError *))completion{
    (void)loader;
    @synchronized(self){
        if(!self.closed){TVAppleCaptureSIWAConfirmation(loader,model);TVAppleCaptureDeviceConfirmation(loader,model);if(!self.model)self.model=model;self.rejected=self.rejected||[model primaryAlert]!=nil;}
    }
    // Read an alert as a rejected response. Do not present a Settings alert or
    // wait for a UIKit button in a Foundation service process.
    if([model primaryAlert]){
        if([model respondsToSelector:@selector(setPrimaryAlert:)])[model setPrimaryAlert:nil];
        else if(class_getInstanceVariable([model class],"_primaryAlert"))[model setValue:nil forKey:@"primaryAlert"];
        else{
            @synchronized(self){if(!self.closed)self.failure=TVAppleError(TVAppleErrorUnsupported,@"Native alert cannot be handled without presentation.");}
            // Do not enter loader's alert-presentation continuation. The owner
            // observes failure and cancels this loader immediately.
            return;
        }
    }
    completion(YES,nil);
}
- (void)loader:(id)loader receivedObjectModel:(id)model topActionSignal:(id)signal{
    (void)loader;(void)signal;@synchronized(self){if(!self.closed){if(!self.model)self.model=model;self.rejected=self.rejected||[model primaryAlert]!=nil;}}
}
- (void)loader:(id)loader didReceiveHTTPResponse:(NSHTTPURLResponse *)response{
    (void)loader;@synchronized(self){if(!self.closed)self.status=response.statusCode;}
}
- (void)loader:(id)loader didFinishLoadWithError:(NSError *)error{
    (void)loader;@synchronized(self){if(!self.closed){self.finished=YES;if(error)self.failure=TVAppleError(TVAppleErrorBackendRead,@"Native email transport failed.");}}
}
@end

// Alert-only responses wait for a UIKit button before the loader delegate sees
// a model. Observe the already parsed native result without presenting that UI.
void TVAppleObserveEmailParserAlert(id loader,TVAppleEmailLoad *load,BOOL mutation){
    @synchronized(load){
        if(load.closed||load.status!=200||load.nativeAlertError)return;
        if(!NSThread.isMainThread){
            if(load.parserProbePending)return;
            load.parserProbePending=YES;
            dispatch_async(dispatch_get_main_queue(), ^{
                @synchronized(load){load.parserProbePending=NO;}
                TVAppleObserveEmailParserAlert(loader,load,mutation);
            });
            return;
        }
    }
    Ivar ivar=class_getInstanceVariable([loader class],"_parser");
    id parser=ivar?object_getIvar(loader,ivar):nil;
    if(!HasAll(parser,@[@"succeeded",@"uiObjectModel"])||![parser succeeded])return;
    id model=[parser uiObjectModel];
    if(!HasAll(model,@[@"allPages",@"primaryAlert"]))return;
    id pages=[model allPages],alert=[model primaryAlert];
    if(![pages isKindOfClass:NSArray.class]||[pages count]||!alert)return;
    NSString *title=HasAll(alert,@[@"title"])?[alert title]:nil;
    NSString *message=HasAll(alert,@[@"message"])?[alert message]:nil;
    NSError *error=nil;
    // Exact native rejection observed on iOS15; do not infer from HTTP 200.
    if([title isEqual:@"Invalid Email"]&&[message isEqual:@"This email address is not available. Choose a different address."])
        error=TVAppleError(TVAppleErrorInvalidRequest,@"Apple rejected this email address: it is not available. Choose a different address.");
    else error=TVAppleError(mutation?TVAppleErrorOutcomeUnknown:TVAppleErrorBackendRead,@"Apple returned a native alert instead of completing the email action; inspect the current account state.");
    @synchronized(load){if(!load.closed){load.rejected=YES;load.nativeAlertError=error;}}
}

id TVAppleFinishEmailLoad(TVAppleEmailLoad *load,BOOL terminalObserved,BOOL mutation,NSError **error){
    id model=nil;NSError *nativeAlertError=nil;BOOL rejected=NO,failed=NO,finished=NO;NSInteger status=0;
    @synchronized(load){load.closed=YES;nativeAlertError=load.nativeAlertError;model=load.model;rejected=load.rejected;failed=load.failure!=nil;finished=load.finished;status=load.status;load.model=nil;}
    if(nativeAlertError){*error=nativeAlertError;return nil;}
    if(!terminalObserved||!finished||!model||status!=200||failed){
        *error=TVAppleError(mutation?TVAppleErrorOutcomeUnknown:TVAppleErrorBackendRead,[NSString stringWithFormat:@"Native email response did not complete (HTTP %ld, terminal=%d, finished=%d, model=%d, transport_failed=%d).", (long)status, terminalObserved, finished, model!=nil, failed]);return nil;
    }
    if(rejected){*error=TVAppleError(mutation?TVAppleErrorOutcomeUnknown:TVAppleErrorBackendRead,@"Apple returned a native alert; email outcome needs a fresh server query.");return nil;}
    return model;
}

@interface TVAppleNativeSettingsSession ()
@property id manager;
@property id store;
@property id signer;
@property NSURL *origin;
@property NSURLRequest *initial;
@property NSString *target;
@property NSString *identity;
@property NSString *cloudIdentity;
@property id pendingModel;
@property NSString *pendingEmail;
@property NSString *challenge;
@property NSTimeInterval expires;
@end
@implementation TVAppleNativeSettingsSession
- (BOOL)beginSettingsOperation:(NSString *)appleID error:(NSError **)error{
    if(self.challenge&&NSProcessInfo.processInfo.systemUptime<self.expires){
        *error=TVAppleError(TVAppleErrorConflict,@"Complete the pending email verification before another Settings operation.");return NO;
    }
    [self clearPending];return [self prepare:appleID error:error];
}
- (void)finishSettingsOperation{if(!self.challenge)[self releaseAuthentication];}
- (void)clearPending{self.pendingModel=nil;self.pendingEmail=nil;self.challenge=nil;self.expires=0;}
- (void)releaseAuthentication{
    self.signer=nil;self.initial=nil;self.manager=nil;self.store=nil;self.origin=nil;
    self.target=nil;self.identity=nil;self.cloudIdentity=nil;
}
- (BOOL)identityMatches:(NSError **)error{
    id identity=[self.manager primaryAuthKitAccount],cloud=[self.store aa_primaryAppleAccount];
    if(!HasAll(identity,@[@"identifier",@"username"])||!HasAll(cloud,@[@"identifier",@"username"])||
       ![[identity identifier]isEqual:self.identity]||![[cloud identifier]isEqual:self.cloudIdentity]||
       ![[[identity username]lowercaseString]isEqual:self.target]||![[[cloud username]lowercaseString]isEqual:self.target]){
        *error=TVAppleError(TVAppleErrorConflict,@"Primary phone identity changed during the email operation.");return NO;
    }return YES;
}
- (BOOL)prepare:(NSString *)appleID error:(NSError **)error{
    for(NSString *name in @[@"Accounts",@"AppleAccount",@"AuthKit",@"RemoteUI"]){
        NSString *directory=[name isEqual:@"Accounts"]?@"Frameworks":@"PrivateFrameworks";
        NSString *path=[NSString stringWithFormat:@"/System/Library/%@/%@.framework/%@",directory,name,name];
        if(!dlopen(path.UTF8String,RTLD_NOW)){*error=TVAppleError(TVAppleErrorUnsupported,@"Native email settings framework is unavailable.");return NO;}
    }
    Class managerClass=NSClassFromString(@"AKAccountManager");
    if(!HasAll(managerClass,@[@"sharedInstance"])){*error=TVAppleError(TVAppleErrorUnsupported,@"Native Settings email interface is unavailable.");return NO;}
    self.manager=[managerClass sharedInstance];self.store=[NSClassFromString(@"ACAccountStore")new];
    if(!HasAll(self.manager,@[@"primaryAuthKitAccount"])||!HasAll(self.store,@[@"aa_primaryAppleAccount",@"aa_grandSlamAccountForiCloudAccount:",@"credentialForAccount:serviceID:"])){*error=TVAppleError(TVAppleErrorUnsupported,@"Native Settings email interface is unavailable.");return NO;}
    id identity=[self.manager primaryAuthKitAccount],cloud=[self.store aa_primaryAppleAccount];
    if(!HasAll(identity,@[@"identifier",@"username"])||!HasAll(cloud,@[@"identifier",@"username"])||
       ![[[identity username]lowercaseString]isEqual:appleID]||![[[cloud username]lowercaseString]isEqual:appleID]){
        *error=TVAppleError(TVAppleErrorConflict,@"Email settings require the matching primary iCloud and phone identity.");return NO;
    }
    self.target=appleID;self.identity=[[identity identifier]copy];self.cloudIdentity=[[cloud identifier]copy];
    if(!self.identity.length||!self.cloudIdentity.length){*error=TVAppleError(TVAppleErrorUnsupported,@"Native Settings email interface is unavailable.");return NO;}
    id gs=[self.store aa_grandSlamAccountForiCloudAccount:cloud];
    if(!HasAll(gs,@[@"aida_alternateDSID"])){*error=TVAppleError(TVAppleErrorUnsupported,@"Native Settings email interface is unavailable.");return NO;}
    id credential=[self.store credentialForAccount:gs serviceID:@"com.apple.gs.appleid.auth"];
    id token=HasAll(credential,@[@"token"])?[credential token]:nil;
    if(![token isKindOfClass:NSString.class]||![token length]){
        *error=TVAppleError(TVAppleErrorAuthenticationFailed,@"Native Settings service credentials are unavailable.");return NO;
    }
    id builder=[NSClassFromString(@"AAPersonalInfoUIRequest")alloc];
    if(!HasAll(builder,@[@"initWithGrandSlamAccount:accountStore:",@"setForceGSToken:",@"urlRequest"])){*error=TVAppleError(TVAppleErrorUnsupported,@"Native Settings email interface is unavailable.");return NO;}
    builder=[builder initWithGrandSlamAccount:gs accountStore:self.store];[builder setForceGSToken:NO];
    self.initial=[builder urlRequest];self.origin=self.initial.URL;
    if(!SameOrigin(self.origin,self.origin)){*error=TVAppleError(TVAppleErrorUnsupported,@"Native Settings email interface is unavailable.");return NO;}
    id context=[NSClassFromString(@"AKAppleIDAuthenticationContext")new],controller=[NSClassFromString(@"AKAppleIDAuthenticationController")new];
    if(!HasAll(context,@[@"setAltDSID:",@"setAnticipateEscrowAttempt:"])||!HasAll(controller,@[@"getServerUILoadDelegateWithContext:completion:"])){*error=TVAppleError(TVAppleErrorUnsupported,@"Native Settings email interface is unavailable.");return NO;}
    [context setAltDSID:[gs aida_alternateDSID]];[context setAnticipateEscrowAttempt:YES];
    NSMutableDictionary *ticket=[NSMutableDictionary new];
    [controller getServerUILoadDelegateWithContext:context completion:^(id signer,NSError *nativeError){
        @synchronized(ticket){if(ticket[@"closed"]||ticket[@"done"])return;ticket[@"done"]=@YES;if(!nativeError&&signer)ticket[@"signer"]=signer;}
    }];
    NSTimeInterval deadline=NSProcessInfo.processInfo.systemUptime+30;BOOL ready=NO;
    do{@synchronized(ticket){ready=[ticket[@"done"]boolValue];}if(ready||NSProcessInfo.processInfo.systemUptime>=deadline)break;
        [[NSRunLoop currentRunLoop]runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.02]];}while(YES);
    @synchronized(ticket){ticket[@"closed"]=@YES;self.signer=ticket[@"signer"];[ticket removeObjectForKey:@"signer"];}
    if(!HasAll(self.signer,@[@"setServiceToken:",@"signRequest:"])){
        *error=TVAppleError(TVAppleErrorAuthenticationFailed,@"Native Settings request signing is unavailable.");return NO;
    }
    [self.signer setServiceToken:token];return [self identityMatches:error];

}
- (id)load:(NSMutableURLRequest *)request mutation:(BOOL)mutation error:(NSError **)error{
    if(!SameOrigin(request.URL,self.origin)){*error=TVAppleError(TVAppleErrorUnsupported,@"Native email action changed its service origin.");return nil;}
    if(![self identityMatches:error])return nil;
    [self.signer signRequest:request];
    id<TVAppleEmailLoader> loader=[NSClassFromString(@"RUILoader")new];TVAppleEmailLoad *observer=[TVAppleEmailLoad new];
    [loader setDelegate:observer];[loader loadXMLUIWithRequest:request];
    NSTimeInterval deadline=NSProcessInfo.processInfo.systemUptime+40;BOOL done=NO;
    do{TVAppleObserveEmailParserAlert(loader,observer,mutation);done=[observer complete];if(done||NSProcessInfo.processInfo.systemUptime>=deadline)break;
        [[NSRunLoop currentRunLoop]runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.02]];}while(YES);
    id model=TVAppleFinishEmailLoad(observer,done,mutation,error);
    [loader cancel];[loader setDelegate:nil];
    if(!model)return nil;
    [model setSourceURL:request.URL];return model;
}
- (id)get:(NSString *)link error:(NSError **)error{
    NSMutableURLRequest *request=[self.initial mutableCopy];request.URL=[NSURL URLWithString:link relativeToURL:self.origin].absoluteURL;
    request.HTTPMethod=@"GET";request.HTTPBody=nil;request.cachePolicy=NSURLRequestReloadIgnoringLocalCacheData;return [self load:request mutation:NO error:error];
}
- (NSDictionary *)beginEmailUnlocked:(NSString *)email appleID:(NSString *)appleID error:(NSError **)error{
    if(self.challenge && ![self.target isEqual:appleID]) {
        *error=TVAppleError(TVAppleErrorConflict,@"The pending email challenge belongs to another phone account.");return nil;
    }
    // Each explicitly requested binding owns a new challenge and signing environment.
    [self clearPending];[self releaseAuthentication];
    if(![self prepare:appleID error:error])return nil;
    NSDictionary *fresh=TVAppleNativeEmailSettings(appleID,error);
    if(!fresh || *error || ![self identityMatches:error])return nil;
    for(NSString *address in fresh[@"reachable_emails"])if([address.lowercaseString isEqual:email.lowercaseString])
        return @{@"outcome":@"succeeded",@"already_verified":@YES,@"email":email,@"settings":fresh};
    id personal=[self load:[self.initial mutableCopy]mutation:NO error:error];if(!personal)return nil;
    NSString *path=@"/appleid/settings/account/manage/email/alternate/add";
    if(!HasAll(personal,@[@"inlineScript"])||[[personal inlineScript]rangeOfString:path].location==NSNotFound){
        *error=TVAppleError(TVAppleErrorUnsupported,@"Server does not advertise contact-email addition.");return nil;
    }
    id form=[self get:path error:error];if(!form)return nil;
    id field=[form subElementWithID:@"address"];
    if(!HasAll(field,@[@"attributes"])||![[field attributes][@"class"]isEqual:@"editableText"]){*error=TVAppleError(TVAppleErrorUnsupported,@"Native contact-email input has changed.");return nil;}
    id button=[[[form allPages]firstObject]rightNavigationBarButtonItem];
    NSMutableURLRequest *post=TVAppleEmailPostbackRequest(form,button,@{@"address":email},self.origin,@"/appleid/settings/account/manage/email/alternate/add/verification",error);
    if(!post)return nil;id verification=[self load:post mutation:YES error:error];if(!verification)return nil;
    id pin=[[[verification allPages]firstObject]passcodeViewOM];NSDictionary *attrs=HasAll(pin,@[@"attributes"])?[pin attributes]:nil;
    if(![attrs[@"id"]isEqual:@"verificationInfo.answer"]||![attrs[@"httpMethod"]isEqual:@"POST"]||
       ![[NSURLComponents componentsWithString:attrs[@"url"]].path isEqual:@"/appleid/settings/account/manage/email/alternate/verification/put"]){
        *error=TVAppleError(TVAppleErrorOutcomeUnknown,@"Email verification response has an unsupported shape.");return nil;
    }
    self.pendingModel=verification;self.pendingEmail=email;self.challenge=NSUUID.UUID.UUIDString;self.expires=NSProcessInfo.processInfo.systemUptime+300;
    NSString *identifier=self.challenge;__weak TVAppleNativeSettingsSession *weakSelf=self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,300*NSEC_PER_SEC),dispatch_get_global_queue(QOS_CLASS_DEFAULT,0),^{
        TVAppleNativeSettingsSession *owner=weakSelf;if(!owner)return;
        @synchronized(owner){if([owner.challenge isEqual:identifier]&&NSProcessInfo.processInfo.systemUptime>=owner.expires){[owner clearPending];[owner releaseAuthentication];}}
    });
    return @{@"outcome":@"requires_email_verification",@"challenge_id":self.challenge,@"email":email,@"expires_in":@300};
}
- (NSDictionary *)freshEmailSettings:(NSString *)appleID error:(NSError **)error{
    return TVAppleNativeEmailSettings(appleID,error);
}
- (NSDictionary *)verifyChallengeUnlocked:(NSString *)challenge code:(NSString *)code appleID:(NSString *)appleID error:(NSError **)error{
    if(![self.challenge isEqual:challenge]||![self.target isEqual:appleID]||NSProcessInfo.processInfo.systemUptime>=self.expires){
        if(NSProcessInfo.processInfo.systemUptime>=self.expires)[self clearPending];
        *error=TVAppleError(TVAppleErrorVerificationCode,@"The email verification challenge is unavailable or expired.");return nil;
    }
    id model=self.pendingModel;NSString *email=self.pendingEmail;
    id pin=[[[model allPages]firstObject]passcodeViewOM];
    NSMutableURLRequest *post=TVAppleEmailPostbackRequest(model,pin,@{@"verificationInfo.answer":code},self.origin,@"/appleid/settings/account/manage/email/alternate/verification/put",error);
    if(!post)return nil;[self clearPending];
    if(![self load:post mutation:YES error:error])return nil;
    *error=nil;
    return @{@"outcome":@"succeeded",@"email":email};
}
- (NSDictionary *)setForwardingEmailUnlocked:(NSString *)email appleID:(NSString *)appleID error:(NSError **)error{
    if(self.challenge&&NSProcessInfo.processInfo.systemUptime<self.expires){*error=TVAppleError(TVAppleErrorConflict,@"Complete the pending email verification before changing forwarding.");return nil;}
    [self clearPending];if(![self prepare:appleID error:error])return nil;
    NSDictionary *fresh=TVAppleNativeEmailSettings(appleID,error);if(!fresh)return nil;
    if([fresh[@"forwarding_email"]isKindOfClass:NSString.class]&&[fresh[@"forwarding_email"]caseInsensitiveCompare:email]==NSOrderedSame)
        return @{@"outcome":@"succeeded",@"already_configured":@YES,@"settings":fresh};
    BOOL reachable=NO;for(NSString *address in fresh[@"reachable_emails"])if([address.lowercaseString isEqual:email.lowercaseString])reachable=YES;
    if(!reachable){*error=TVAppleError(TVAppleErrorInvalidRequest,@"Add and verify the destination as an Apple ID contact email first.");return nil;}
    id gs=[self.store aa_grandSlamAccountForiCloudAccount:[self.store aa_primaryAppleAccount]];
    id bag=[NSClassFromString(@"AKURLBag")alloc];
    if(!HasAll(bag,@[@"initWithAltDSID:",@"privateEmailManageURL"])){*error=TVAppleError(TVAppleErrorUnsupported,@"Native private-email URL bag is unavailable.");return nil;}
    bag=[bag initWithAltDSID:[gs aida_alternateDSID]];NSURL *manage=[bag privateEmailManageURL];
    if(!SameOrigin(manage,self.origin)||![manage.path isEqual:@"/appleid/settings/account/manage/email/private"]){
        *error=TVAppleError(TVAppleErrorUnsupported,@"Native private-email service URL has changed.");return nil;
    }
    id listing=[self get:manage.absoluteString error:error];if(!listing)return nil;
    NSString *link=nil;
    for(id page in [listing allPages]){
        id table=[page tableViewOM];if(![[table identifier]isEqual:@"privateEmailView"])continue;
        for(id section in [table sections])for(id row in [section rows]){
            NSDictionary *attrs=[row attributes];id candidate=attrs[@"url"];
            if([attrs[@"class"]isEqual:@"link"]&&[candidate isKindOfClass:NSString.class]&&
               [[NSURLComponents componentsWithString:candidate].path isEqual:@"/appleid/settings/account/manage/forwardemail"]&&
               (!attrs[@"httpMethod"]||[attrs[@"httpMethod"]isEqual:@"GET"])){
                if(link){*error=TVAppleError(TVAppleErrorUnsupported,@"Native relay forwarding entry is ambiguous.");return nil;}link=candidate;
            }
        }
    }
    if(!link){*error=TVAppleError(TVAppleErrorUnsupported,@"Native relay forwarding entry is unavailable.");return nil;}
    id form=[self get:link error:error];if(!form)return nil;
    NSMutableURLRequest *post=TVAppleRelayForwardingRequest(form,email,self.origin,error);if(!post)return nil;
    if(![self load:post mutation:YES error:error])return nil;
    *error=nil;
    return @{@"outcome":@"succeeded",@"already_configured":@NO};
}
- (NSDictionary *)beginEmail:(NSString *)email appleID:(NSString *)appleID error:(NSError **)error{
    @synchronized(self){NSDictionary *result=[self beginEmailUnlocked:email appleID:appleID error:error];if(!self.challenge)[self releaseAuthentication];return result;}
}
- (NSDictionary *)verifyChallenge:(NSString *)challenge code:(NSString *)code appleID:(NSString *)appleID error:(NSError **)error{
    @synchronized(self){NSDictionary *result=[self verifyChallengeUnlocked:challenge code:code appleID:appleID error:error];if(!self.challenge)[self releaseAuthentication];return result;}
}
- (NSDictionary *)setForwardingEmail:(NSString *)email appleID:(NSString *)appleID error:(NSError **)error{
    @synchronized(self){NSDictionary *result=[self setForwardingEmailUnlocked:email appleID:appleID error:error];if(!self.challenge)[self releaseAuthentication];return result;}
}
@end

@implementation TVAppleServices (EmailActions)
- (void)beginAddingContactEmail:(NSString *)email appleID:(NSString *)appleID completion:(TVAppleCompletion)completion{
    [self enqueueEmailAction:@"begin" appleID:appleID value:email code:nil completion:completion];
}
- (void)verifyContactEmailChallenge:(NSString *)challengeID code:(NSString *)code appleID:(NSString *)appleID completion:(TVAppleCompletion)completion{
    [self enqueueEmailAction:@"verify" appleID:appleID value:challengeID code:code completion:completion];
}
- (void)setSignInWithAppleForwardingEmail:(NSString *)email appleID:(NSString *)appleID completion:(TVAppleCompletion)completion{
    [self enqueueEmailAction:@"forward" appleID:appleID value:email code:nil completion:completion];
}
@end
