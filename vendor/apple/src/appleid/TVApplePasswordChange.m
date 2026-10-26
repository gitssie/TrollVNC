#import "TVApplePasswordChange.h"
#import "TVAppleStoreLogin.h"
#import "TVAppleICloud.h"
#import <objc/runtime.h>
#import <dlfcn.h>

// RemoteUI remains owned by Apple. All model/controller operations run on main;
// authentication, local-secret validation and completion waits run off main.
@interface NSObject (TVApplePasswordRuntime)
+ (id)sharedInstance;
- (id)primaryAuthKitAccount;
- (id)mostRecentlyUsedAuthKitAccount;
- (id)altDSIDForAccount:(id)account;
- (id)username;
- (id)aida_dsid;
- (id)aa_grandSlamAccountForAltDSID:(id)alt;
- (id)initWithAccountStore:(id)store;
- (id)initWithAccountManager:(id)manager presenter:(id)presenter;
- (id)initWithRootViewController:(id)controller;
- (id)initWithGrandSlamAccount:(id)account accountStore:(id)store;
- (id)initWithAttributes:(id)attributes parent:(id)parent;
- (void)setAltDSID:(id)alt;
- (void)setForceGSToken:(BOOL)force;
- (id)urlRequest;
- (void)loadRequest:(id)request;
- (void)setNavigationController:(id)navigation;
- (id)loader;
- (void)cancel;
- (id)allPages;
- (id)tableViewOM;
- (id)sections;
- (id)rows;
- (id)attributes;
- (id)clientInfo;
- (id)passcodeViewOM;
- (id)passcodeView;
- (id)passcodeField;
- (void)setStringValue:(id)value;
- (void)setSubmittedPIN:(id)value;
- (void)submitPIN;
- (void)activateElement:(id)element completion:(void (^)(void))completion;
- (void)alertView:(id)alert pressedButton:(id)button completion:(void (^)(void))completion;
- (id)postbackData;
- (id)postbackDictionary;
- (void)_loadURL:(id)url fromObjectModel:(id)model postBody:(id)body;
- (id)tableCell;
- (void)setValueFromString:(id)value notify:(BOOL)notify;
- (void)setEditableTextFieldValue:(id)value;
- (id)rightNavigationBarButtonItem;
- (BOOL)validateWithFunction:(id)function;
@end

BOOL TVAppleValidNewPassword(NSString *value) {
    if(![value isKindOfClass:NSString.class] || value.length!=8)return NO;
    NSCharacterSet *allowed=[NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"];
    return [value rangeOfCharacterFromSet:allowed.invertedSet].location==NSNotFound &&
        [value rangeOfCharacterFromSet:NSCharacterSet.uppercaseLetterCharacterSet].location!=NSNotFound &&
        [value rangeOfCharacterFromSet:NSCharacterSet.lowercaseLetterCharacterSet].location!=NSNotFound &&
        [value rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet].location!=NSNotFound;
}
static NSString *const PasswordPath=@"/appleid/settings/account/manage/security/password";
static NSString *const PutPath=@"/appleid/settings/account/manage/security/password/put";
static NSString *const TrustedPath=@"/auth/verify/trusteddevice/securitycode";
static BOOL Supports(id object,NSString *selector){return object&&[object respondsToSelector:NSSelectorFromString(selector)];}
static BOOL TrueFlag(id value){
    if([value isKindOfClass:NSNumber.class])return [value isEqual:@YES];
    return [value isKindOfClass:NSString.class]&&[@[@"true",@"1",@"YES"]containsObject:value];
}
@interface TVApplePasswordXML:NSObject<NSXMLParserDelegate>
@property NSDictionary *keepButton;
@property NSString *resend;
@property BOOL inSignoutAlert,duplicateKeep;
@end
@implementation TVApplePasswordXML
- (void)parser:(NSXMLParser *)parser didStartElement:(NSString *)name namespaceURI:(NSString *)ns qualifiedName:(NSString *)q attributes:(NSDictionary *)a {
    (void)parser;(void)ns;(void)q;
    if([name isEqual:@"alert"])self.inSignoutAlert=[a[@"id"]isEqual:@"signoutDevices"];
    if(![name isEqual:@"button"]||![a[@"httpMethod"]isEqual:@"POST"])return;
    NSString *path=[NSURLComponents componentsWithString:a[@"url"]?:@""].path;
    if(self.inSignoutAlert&&[path isEqual:PutPath]&&[a[@"name"]isEqual:@"ak-button"]&&[a[@"ak-action"]isEqual:@"read"]){if(self.keepButton)self.duplicateKeep=YES;else self.keepButton=[a copy];}
    if([a[@"id"]isEqual:@"preferredResendButton"]&&[path isEqual:[TrustedPath stringByAppendingString:@"/put"]])self.resend=a[@"url"];
}
- (void)parser:(NSXMLParser *)parser didEndElement:(NSString *)name namespaceURI:(NSString *)ns qualifiedName:(NSString *)q {
    (void)parser;(void)ns;(void)q;if([name isEqual:@"alert"])self.inSignoutAlert=NO;
}
@end

@interface TVApplePasswordSession:NSObject
@property NSString *appleID,*oldPassword,*candidate,*passcode;
@property id<TVAppleVerificationCodeProvider> provider;
@property id identity,gs,store,presenter,host,navigation,remote,model;
@property NSString *alt;
@property NSURL *origin;
@property NSData *raw;
@property NSString *phase;
@property BOOL closed,submitted;
@property NSUInteger challenges;
@property NSDictionary *result;
@property NSError *failure;
@property dispatch_semaphore_t done;
- (void)receive:(id)model;
- (void)fail:(NSError *)error;
- (void)start;
@end
static char SessionKey;
static IMP ParentReceive,ParentPresent,ParentFinish,ParentParse;
static id ContextValue(id object,SEL selector){
    TVApplePasswordSession *s=objc_getAssociatedObject(object,&SessionKey);
    NSString *name=NSStringFromSelector(selector);
    if([name isEqual:@"_appleAccount"])return s.identity;
    if([name isEqual:@"_grandSlamAccount"])return s.gs;
    if([name isEqual:@"_accountStore"])return s.store;
    id context=[NSClassFromString(@"AKAppleIDAuthenticationContext")new];[context setAltDSID:s.alt];return context;
}
static void Received(id object,SEL selector,id controller,id model,unsigned long long *signal){
    ((void(*)(id,SEL,id,id,unsigned long long *))ParentReceive)(object,selector,controller,model,signal);
    TVApplePasswordSession *s=objc_getAssociatedObject(object,&SessionKey);
    dispatch_async(dispatch_get_main_queue(),^{[s receive:model];});
}
static void Presented(id object,SEL selector,id controller,id model,BOOL modal){
    ((void(*)(id,SEL,id,id,BOOL))ParentPresent)(object,selector,controller,model,modal);
    TVApplePasswordSession *s=objc_getAssociatedObject(object,&SessionKey);
    dispatch_async(dispatch_get_main_queue(),^{[s receive:model];});
}
static void Finished(id object,SEL selector,id controller,NSError *error,id request){
    ((void(*)(id,SEL,id,id,id))ParentFinish)(object,selector,controller,error,request);
    TVApplePasswordSession *s=objc_getAssociatedObject(object,&SessionKey);
    if(error)dispatch_async(dispatch_get_main_queue(),^{[s fail:TVAppleError(s.submitted?TVAppleErrorOutcomeUnknown:TVAppleErrorNativeFailure,@"Native password request failed.")];});
}
static void Parsed(id object,SEL selector,NSData *data){
    TVApplePasswordSession *s=objc_getAssociatedObject(object,&SessionKey);
    if([data isKindOfClass:NSData.class]&&data.length<=262144)s.raw=[data copy];else s.raw=nil;
    ((void(*)(id,SEL,id))ParentParse)(object,selector,data);
}
static Class PresenterSubclass(void){
    static Class subclass;static dispatch_once_t once;dispatch_once(&once,^{
        Class base=NSClassFromString(@"AAUIGrandSlamRemoteUIPresenter");if(!base)return;
        NSDictionary *selectors=@{@"_appleAccount":[NSValue valueWithPointer:(IMP)ContextValue],@"_grandSlamAccount":[NSValue valueWithPointer:(IMP)ContextValue],@"_accountStore":[NSValue valueWithPointer:(IMP)ContextValue],@"_authContext":[NSValue valueWithPointer:(IMP)ContextValue],@"remoteUIController:didReceiveObjectModel:actionSignal:":[NSValue valueWithPointer:(IMP)Received],@"remoteUIController:didPresentObjectModel:modally:":[NSValue valueWithPointer:(IMP)Presented],@"remoteUIController:didFinishLoadWithError:forRequest:":[NSValue valueWithPointer:(IMP)Finished]};
        for(NSString *key in selectors)if(!class_getInstanceMethod(base,NSSelectorFromString(key)))return;
        subclass=objc_allocateClassPair(base,"TVApplePasswordPresenter",0);if(!subclass)return;
        ParentReceive=method_getImplementation(class_getInstanceMethod(base,NSSelectorFromString(@"remoteUIController:didReceiveObjectModel:actionSignal:")));
        ParentPresent=method_getImplementation(class_getInstanceMethod(base,NSSelectorFromString(@"remoteUIController:didPresentObjectModel:modally:")));
        ParentFinish=method_getImplementation(class_getInstanceMethod(base,NSSelectorFromString(@"remoteUIController:didFinishLoadWithError:forRequest:")));
        for(NSString *key in selectors){SEL selector=NSSelectorFromString(key);class_addMethod(subclass,selector,(IMP)[selectors[key]pointerValue],method_getTypeEncoding(class_getInstanceMethod(base,selector)));}
        objc_registerClassPair(subclass);
    });return subclass;
}
static BOOL CaptureLoader(id loader,TVApplePasswordSession *session){
    static Class subclass;static dispatch_once_t once;dispatch_once(&once,^{
        Class base=[loader class];Method method=class_getInstanceMethod(base,NSSelectorFromString(@"parseData:"));if(!method)return;
        subclass=objc_allocateClassPair(base,"TVApplePasswordLoader",0);if(!subclass)return;
        ParentParse=method_getImplementation(method);class_addMethod(subclass,NSSelectorFromString(@"parseData:"),(IMP)Parsed,method_getTypeEncoding(method));objc_registerClassPair(subclass);
    });
    if(!subclass||![loader isKindOfClass:class_getSuperclass(subclass)])return NO;
    objc_setAssociatedObject(loader,&SessionKey,session,OBJC_ASSOCIATION_RETAIN_NONATOMIC);object_setClass(loader,subclass);return YES;
}
@implementation TVApplePasswordSession
- (void)complete:(NSDictionary *)result error:(NSError *)error {
    if(self.closed)return;self.closed=YES;self.result=result;self.failure=error;
    id loader=Supports(self.remote,@"loader")?[self.remote loader]:nil;
    if(Supports(loader,@"cancel"))[loader cancel];
    if(loader)objc_setAssociatedObject(loader,&SessionKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self.presenter,&SessionKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if([self.provider respondsToSelector:@selector(cancelAuthentication)])[self.provider cancelAuthentication];
    self.oldPassword=nil;self.candidate=nil;self.passcode=nil;self.raw=nil;self.model=nil;
    self.presenter=nil;self.navigation=nil;self.host=nil;self.remote=nil;
    dispatch_semaphore_signal(self.done);
}
- (void)fail:(NSError *)error {[self complete:nil error:error];}
- (void)unsupported { [self fail:TVAppleError(self.submitted?TVAppleErrorOutcomeUnknown:TVAppleErrorUnsupported,@"Unsupported native password form or continuation.")]; }
- (NSURL *)allowedURL:(NSString *)value path:(NSString *)path {
    if(![value isKindOfClass:NSString.class])return nil;
    NSURL *url=[NSURL URLWithString:value relativeToURL:self.origin].absoluteURL;
    if(![url.scheme isEqual:@"https"]||![url.host isEqual:self.origin.host]||url.user.length||url.password.length||![url.path isEqual:path])return nil;return url;
}
- (TVApplePasswordXML *)xml {
    if(!self.raw)return nil;TVApplePasswordXML *observer=[TVApplePasswordXML new];NSXMLParser *parser=[[NSXMLParser alloc]initWithData:self.raw];parser.delegate=observer;return [parser parse]&&!observer.duplicateKeep?observer:nil;
}
- (void)start {
    @try{
        Class presenterClass=PresenterSubclass();if(!presenterClass){[self unsupported];return;}
        id aida=[[NSClassFromString(@"AIDAAccountManager")alloc]initWithAccountStore:self.store];
        self.host=[NSClassFromString(@"UIViewController")new];self.navigation=[[NSClassFromString(@"UINavigationController")alloc]initWithRootViewController:self.host];
        id presenter=[presenterClass alloc];objc_setAssociatedObject(presenter,&SessionKey,self,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        self.presenter=[presenter initWithAccountManager:aida presenter:self.host];
        Ivar ivar=class_getInstanceVariable(presenterClass,"_remoteUIController");self.remote=ivar?object_getIvar(self.presenter,ivar):nil;
        if(!Supports(self.remote,@"setNavigationController:")||!Supports(self.remote,@"loader")||!CaptureLoader([self.remote loader],self)){[self unsupported];return;}
        [self.remote setNavigationController:self.navigation];
        id builder=[[NSClassFromString(@"AAPasswordSecurityUIRequest")alloc]initWithGrandSlamAccount:self.gs accountStore:self.store];[builder setForceGSToken:NO];NSURLRequest *entry=[builder urlRequest];self.origin=entry.URL;
        if(![self.origin.scheme isEqual:@"https"]||!self.origin.host.length){[self unsupported];return;}
        self.phase=@"entry";[self.presenter loadRequest:entry];
        __weak TVApplePasswordSession *weakSelf=self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,300*NSEC_PER_SEC),dispatch_get_main_queue(),^{TVApplePasswordSession *s=weakSelf;if(s&&!s.closed)[s fail:TVAppleError(TVAppleErrorOutcomeUnknown,@"Native password operation timed out; query its original result before retrying.")];});
    }@catch(__unused NSException *exception){[self unsupported];}
}
- (void)requestCode:(id)model {
    if(!self.provider||++self.challenges>1){[self fail:TVAppleError(TVAppleErrorVerificationCode,@"Native password verification requires a fresh trusted-device code.")];return;}
    self.phase=@"code_input";
    [self.provider requestCodeForChallenge:@{@"verification_method":@"trusted_device",@"code_type":@"trusted_device",@"purpose":@"change_password",@"length":@6}completion:^(NSString *code,NSError *error){
        dispatch_async(dispatch_get_main_queue(),^{
            if(self.closed||self.model!=model||![self.phase isEqual:@"code_input"])return;
            if(error||code.length!=6||[code rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789"]invertedSet]].location!=NSNotFound){[self fail:TVAppleError(TVAppleErrorVerificationCode,@"Native password verification code was unavailable.")];return;}
            @try{id pin=[[[model allPages]firstObject]passcodeViewOM];(void)[pin passcodeView];id field=[pin passcodeField];if(!field){[self unsupported];return;}
                self.phase=@"verified";[field setStringValue:code];[pin submitPIN];
            }@catch(__unused NSException *exception){[self unsupported];}
        });
    }];
}
- (void)submit:(id)model {
    id info=[model clientInfo];if(![info[@"newPasswordRowId"]isEqual:@"newPassword.password"]){[self unsupported];return;}
    NSMutableDictionary *values=[@{@"newPassword.password":self.candidate,@"newPassword.confirmedPassword":self.candidate}mutableCopy];
    if(info[@"currentPasswordRowId"]){if(![info[@"currentPasswordRowId"]isEqual:@"password"]){[self unsupported];return;}values[@"password"]=self.oldPassword;}
    NSUInteger filled=0;id save=nil;
    for(id page in [model allPages]){
        for(id section in [[page tableViewOM]sections])for(id row in [section rows]){id attrs=[row attributes];id value=values[attrs[@"id"]];if(value){if(![attrs[@"class"]isEqual:@"editableText"]){[self unsupported];return;}(void)[row tableCell];[row setValueFromString:value notify:YES];[row setEditableTextFieldValue:value];filled++;}}
        if([page rightNavigationBarButtonItem])save=[page rightNavigationBarButtonItem];
    }
    if(filled!=values.count){[self unsupported];return;}
    NSDictionary *body=[model postbackDictionary];for(NSString *key in values)if(![body[key]isEqual:values[key]]){[self unsupported];return;}
    NSDictionary *attrs=[save attributes];if(![attrs[@"url"]isEqual:@"#signoutDevices"]||![attrs[@"name"]isEqual:@"ak-button"]||![attrs[@"ak-action"]isEqual:@"read"]){[self unsupported];return;}
    if(![attrs[@"validationFunction"]isKindOfClass:NSString.class]||![model validateWithFunction:attrs[@"validationFunction"]]){[self fail:TVAppleError(TVAppleErrorInvalidRequest,@"Native password form validation failed.")];return;}
    TVApplePasswordXML *xml=[self xml];if(![self allowedURL:xml.keepButton[@"url"]path:PutPath]){[self unsupported];return;}
    Ivar alerts=class_getInstanceVariable([model class],"_namedAlerts");id alert=alerts?object_getIvar(model,alerts)[@"signoutDevices"]:nil;
    if(!alert){[self unsupported];return;}
    // Reconstruct exactly the RUIElement that RUIAlertView's native button handler
    // creates from its server attributes; choose the keep-other-devices action.
    id button=[[NSClassFromString(@"RUIElement")alloc]initWithAttributes:xml.keepButton parent:alert];
    if(!button){[self unsupported];return;}
    self.phase=@"submitted";self.submitted=YES;
    [model alertView:alert pressedButton:button completion:^{}];
}
- (void)receive:(id)model {
    if(self.closed||!model||model==self.model)return;
    self.model=model;
    @try{
        if([self.phase isEqual:@"submitted"]){
            if(TrueFlag([model clientInfo][@"passwordUpdated"])){
                [self complete:@{@"outcome":@"succeeded",@"password_changed":@YES,@"other_devices_signed_out":@NO}error:nil];return;
            }
            // Some native responses represent the completion flag differently.
            // Validate the new credential with native AuthKit authentication,
            // preserving a different media account. Never retry the mutation POST.
            self.phase=@"verifying_password";NSString *appleID=self.appleID,*password=self.candidate;
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
                NSError *error=nil;NSDictionary *auth=TVAppleNativeAuthenticateAutomatic(appleID,password,self.provider,&error);
                BOOL accepted=auth&&!error&&[[auth[@"AKUsername"]lowercaseString]isEqual:appleID.lowercaseString]&&[[auth[@"AKAltDSID"]description]isEqual:self.alt];
                dispatch_async(dispatch_get_main_queue(),^{if(self.closed)return;
                    if(accepted)[self complete:@{@"outcome":@"succeeded",@"password_changed":@YES,@"new_password_authenticated":@YES,@"other_devices_signed_out":@NO}error:nil];
                    else [self fail:TVAppleError(TVAppleErrorOutcomeUnknown,@"Password was submitted but new-credential confirmation did not complete; retain both passwords.")];
                });
            });return;
        }
        if([self.phase isEqual:@"entry"]){
            id link=nil;for(id page in [model allPages])for(id section in [[page tableViewOM]sections])for(id row in [section rows])if([self allowedURL:[row attributes][@"url"]path:PasswordPath]){if(link&&![[link attributes][@"url"]isEqual:[row attributes][@"url"]]){[self unsupported];return;}link=row;}
            // Some native models expose the same page twice. Resolve a matching
            // server-provided row without interpreting hidden account controls.
            if(!link){[self unsupported];return;}self.phase=@"password";[model activateElement:link completion:^{}];return;
        }
        id pin=[[[model allPages]firstObject]passcodeViewOM];NSDictionary *a=[pin attributes];NSString *path=[NSURLComponents componentsWithString:a[@"url"]?:@""].path;
        if([path isEqual:@"/auth/verify/passcode"]){
            if(![self.phase isEqual:@"password"]){[self unsupported];return;}
            if(!self.passcode.length){[self fail:TVAppleError(TVAppleErrorInvalidRequest,@"A saved device passcode is required for native local verification.")];return;}
            self.phase=@"local_secret";NSString *passcode=self.passcode;
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{NSError *error=nil;BOOL valid=TVAppleValidateLocalPasscode(passcode,&error);
                dispatch_async(dispatch_get_main_queue(),^{if(self.closed||self.model!=model)return;if(!valid){[self fail:TVAppleError(TVAppleErrorAuthenticationFailed,@"Saved device passcode validation failed.")];return;}
                    @try{self.passcode=nil;self.phase=@"verified";[pin setSubmittedPIN:nil];[model activateElement:pin completion:^{}];}@catch(__unused NSException *exception){[self unsupported];}
                });
            });return;
        }
        if([path isEqual:TrustedPath]){
            if([self.phase isEqual:@"resending"]){[self requestCode:model];return;}
            if(![self.phase isEqual:@"password"]){[self fail:TVAppleError(TVAppleErrorVerificationCode,@"Native password verification did not accept the code.")];return;}
            TVApplePasswordXML *xml=[self xml];NSURL *resend=[self allowedURL:xml.resend path:[TrustedPath stringByAppendingString:@"/put"]];
            if(!resend){[self unsupported];return;}self.phase=@"resending";[self.remote _loadURL:resend fromObjectModel:model postBody:[model postbackData]];return;
        }
        if([self.phase isEqual:@"verified"]||[self.phase isEqual:@"password"]){[self submit:model];return;}
        [self unsupported];
    }@catch(__unused NSException *exception){[self unsupported];}
}
@end

NSDictionary *TVAppleNativeChangePassword(NSString *appleID,NSString *password,NSString *newPassword,NSString *passcode,id<TVAppleVerificationCodeProvider> provider,NSError **error){
    if(NSThread.isMainThread){*error=TVAppleError(TVAppleErrorUnsupported,@"Native password operation must run on the account worker.");return nil;}
    for(NSString *name in @[@"Accounts",@"AppleAccount",@"AuthKit",@"RemoteUI",@"AppleAccountUI",@"CoreCDP",@"ManagedConfiguration"]){
        NSString *directory=[name isEqual:@"Accounts"]?@"Frameworks":@"PrivateFrameworks";
        if(!dlopen([[NSString stringWithFormat:@"/System/Library/%@/%@.framework/%@",directory,name,name]UTF8String],RTLD_NOW)){*error=TVAppleError(TVAppleErrorUnsupported,@"Native password framework unavailable.");return nil;}
    }
    NSDictionary *authentication=TVAppleNativeAuthenticateAutomatic(appleID,password,provider,error);if(!authentication)return nil;
    id manager=[NSClassFromString(@"AKAccountManager")sharedInstance];id identity=[manager primaryAuthKitAccount]?:[manager mostRecentlyUsedAuthKitAccount];
    id alt=[manager altDSIDForAccount:identity];id store=[NSClassFromString(@"ACAccountStore")new];id gs=[store aa_grandSlamAccountForAltDSID:alt];
    if(![[[identity username]lowercaseString]isEqual:appleID.lowercaseString]||![[authentication[@"AKUsername"]lowercaseString]isEqual:appleID.lowercaseString]||![[authentication[@"AKAltDSID"]description]isEqual:[alt description]]||![[authentication[@"AKDSID"]description]isEqual:[[gs aida_dsid]description]]){*error=TVAppleError(TVAppleErrorConflict,@"Native password account identity does not match.");return nil;}
    TVApplePasswordSession *session=[TVApplePasswordSession new];session.appleID=appleID;session.oldPassword=password;session.candidate=newPassword;session.passcode=passcode;session.provider=provider;session.identity=identity;session.alt=alt;session.gs=gs;session.store=store;session.done=dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_main_queue(),^{[session start];});
    if(dispatch_semaphore_wait(session.done,dispatch_time(DISPATCH_TIME_NOW,310*NSEC_PER_SEC))!=0){dispatch_async(dispatch_get_main_queue(),^{[session fail:TVAppleError(TVAppleErrorOutcomeUnknown,@"Native password completion timed out.")];});*error=TVAppleError(TVAppleErrorOutcomeUnknown,@"Native password result unavailable; retain both passwords.");return nil;}
    *error=session.failure;return session.result;
}
