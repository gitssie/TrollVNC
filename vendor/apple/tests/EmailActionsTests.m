#import "TVAppleEmailActions.h"
#import "TVAppleNameSettings.h"
#include <assert.h>
@interface PostbackModel : NSObject
@property NSURL *sourceURL;
@property NSDictionary *values;
@property BOOL empty;
@property NSArray *allPages;
@property NSDictionary *clientInfo;
@end
@implementation PostbackModel
- (void)setUpdateInfo:(NSDictionary *)values{self.values=values;}
- (NSData *)postbackData{
    return self.empty?nil:[NSPropertyListSerialization dataWithPropertyList:@{@"serverInfo":@{@"opaque":@"native-session"},@"inputs":self.values}format:NSPropertyListXMLFormat_v1_0 options:0 error:nil];
}
- (void)_populateRequest:(NSMutableURLRequest *)request{[request setValue:@"native" forHTTPHeaderField:@"X-Native-Test"];}
@end
@interface PostbackElement : NSObject
@property NSDictionary *attributes;
@end
@implementation PostbackElement
@end
@interface HeadlessModel : NSObject
@property id primaryAlert;
@end
@implementation HeadlessModel
@end
@interface AlertOnlyModel:HeadlessModel
@property NSArray *allPages;
@end
@implementation AlertOnlyModel
@end
@interface NativeAlert:NSObject
@property NSString *title,*message;
@end
@implementation NativeAlert
@end
@interface NativeParser:NSObject
@property BOOL succeeded;
@property id uiObjectModel;
@end
@implementation NativeParser
@end
@interface NativeLoader:NSObject
@property NativeParser *parser;
@end
@implementation NativeLoader
@end
@interface ForwardPage : NSObject
@property id tableViewOM,rightNavigationBarButtonItem,passcodeViewOM;
@end
@implementation ForwardPage
@end
@interface ForwardTable : NSObject
@property NSArray *sections;
@end
@implementation ForwardTable
@end
@interface ForwardSection : NSObject
@property NSArray *rows;
@end
@implementation ForwardSection
@end
@interface EmailBackend : NSObject <TVAppleBackend,TVAppleEmailActionsBackend,TVAppleEmailSettingsBackend,TVAppleNameSettingsBackend>
@property NSUInteger begins,verifications,forwards,names;
@property BOOL unknown;
@end
@implementation EmailBackend
- (NSDictionary *)nameSettingsForAppleID:(NSString *)appleID error:(NSError **)error{(void)error;return @{@"apple_id":appleID,@"first_name":@"jack",@"last_name":@"ma"};}
- (NSDictionary *)setFirstName:(NSString *)first lastName:(NSString *)last appleID:(NSString *)appleID error:(NSError **)error{
    assert([appleID isEqual:@"test@example.com"]&&[first isEqual:@"jack"]&&[last isEqual:@"ma"]);self.names++;
    if(self.unknown){*error=TVAppleError(TVAppleErrorOutcomeUnknown,@"fixture");return nil;}return @{@"outcome":@"succeeded"};
}
- (NSDictionary *)snapshot:(NSError **)error{(void)error;return @{@"accounts":@[]};}
- (id)prepareAccount:(NSDictionary *)account policy:(TVAppleLocalDataPolicy)policy error:(NSError **)error{(void)account;(void)policy;(void)error;assert(NO);return nil;}
- (BOOL)removePreparedAccount:(id)prepared error:(NSError **)error{(void)prepared;(void)error;assert(NO);return NO;}
- (NSDictionary *)emailSettingsForAppleID:(NSString *)appleID error:(NSError **)error{(void)error;return @{@"apple_id":appleID};}
- (NSDictionary *)beginContactEmail:(NSString *)email appleID:(NSString *)appleID error:(NSError **)error{
    assert([appleID isEqual:@"test@example.com"]);assert([email isEqual:@"contact@example.net"]);self.begins++;
    if(self.unknown){*error=TVAppleError(TVAppleErrorOutcomeUnknown,@"fixture");return nil;}
    return @{@"outcome":@"requires_email_verification",@"challenge_id":@"session"};
}
- (NSDictionary *)verifyContactEmail:(NSString *)challenge code:(NSString *)code appleID:(NSString *)appleID error:(NSError **)error{
    (void)error;assert([appleID isEqual:@"test@example.com"]);assert([challenge isEqual:@"session"]);assert([code isEqual:@"001234"]);self.verifications++;return @{@"outcome":@"succeeded"};
}
- (NSDictionary *)setRelayEmail:(NSString *)email appleID:(NSString *)appleID error:(NSError **)error{
    (void)error;assert([appleID isEqual:@"test@example.com"]);assert([email isEqual:@"contact@example.net"]);self.forwards++;return @{@"outcome":@"succeeded"};
}
@end
// Exercise production name pipeline, substituting only native transport and identity.
@interface NameTransport : TVAppleNativeSettingsSession
@property id personal,form;
@property BOOL posted,mismatch,readFailure,identityChanged,refreshFailure;
@property NSUInteger posts,refreshes,transientReads;
@property BOOL postUnknown,transientMismatch;
@end
@implementation NameTransport
- (BOOL)refreshName:(NSDictionary *)name appleID:(NSString *)appleID error:(NSError **)error{(void)name;(void)appleID;self.refreshes++;if(self.refreshFailure){*error=TVAppleError(TVAppleErrorBackendRead,@"fixture refresh failure");return NO;}return YES;}
- (BOOL)beginSettingsOperation:(NSString *)appleID error:(NSError **)error{(void)appleID;(void)error;return YES;}
- (void)finishSettingsOperation{}
- (BOOL)identityMatches:(NSError **)error{
    if(self.posted&&self.identityChanged){*error=TVAppleError(TVAppleErrorConflict,@"fixture changed identity");return NO;}return YES;
}
- (NSURL *)origin{return [NSURL URLWithString:@"https://native.apple.com/appleid/settings/account/manage"];}
- (id)get:(NSString *)link error:(NSError **)error{
    if([link isEqual:@"/appleid/settings/account/manage/name"])return self.form;
    if(self.posted&&self.readFailure){*error=TVAppleError(TVAppleErrorBackendRead,@"fixture");return nil;}
    return self.personal;
}
- (id)load:(NSMutableURLRequest *)request mutation:(BOOL)mutation error:(NSError **)error{
    (void)request;assert(mutation);self.posts++;self.posted=YES;
    if(!self.mismatch)[self.personal setClientInfo:@{@"firstName":@"jack",@"lastName":@"ma",@"middleName":@"preserved",@"accountName":@"test@example.com"}];
    if(self.postUnknown){*error=TVAppleError(TVAppleErrorOutcomeUnknown,@"fixture post timeout");return nil;}
    return self.personal;
}
@end
// A verification POST can commit even when RemoteUI never delivers its model.
@interface EmailVerificationTransport : TVAppleNativeSettingsSession
@property BOOL absent,readFailure,changed,completed;
@property NSUInteger posts,reads;
@end
@implementation EmailVerificationTransport
- (id)load:(NSMutableURLRequest *)request mutation:(BOOL)mutation error:(NSError **)error{
    (void)request;assert(mutation);self.posts++;
    if(self.completed)return [NSObject new];
    *error=TVAppleError(TVAppleErrorOutcomeUnknown,@"Native email response did not complete (HTTP 200, terminal=0, finished=0, model=0, transport_failed=0).");return nil;
}
- (NSDictionary *)freshEmailSettings:(NSString *)appleID error:(NSError **)error{
    self.reads++;if(self.readFailure){*error=TVAppleError(TVAppleErrorBackendRead,@"fixture fresh read failure");return nil;}
    return @{@"apple_id":appleID,@"reachable_emails":self.absent?@[]:@[@"CONTACT@example.net"]};
}
- (BOOL)identityMatches:(NSError **)error{
    if(self.changed){*error=TVAppleError(TVAppleErrorConflict,@"fixture changed identity");return NO;}return YES;
}
@end
static void Wait(dispatch_semaphore_t done){assert(!dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,3*NSEC_PER_SEC)));}
int main(void){@autoreleasepool{
    NSURL *origin=[NSURL URLWithString:@"https://native.apple.com/appleid/settings/account/manage"];
    NSString *path=@"/appleid/settings/account/manage/email/alternate/verification/put";
    PostbackModel *model=[PostbackModel new];model.sourceURL=origin;
    PostbackElement *element=[PostbackElement new];element.attributes=@{@"url":path,@"httpMethod":@"POST"};NSError *error=nil;
    NSMutableURLRequest *request=TVAppleEmailPostbackRequest(model,element,@{@"verificationInfo.answer":@"001234"},origin,path,&error);
    assert(request&&!error);assert([[request valueForHTTPHeaderField:@"Content-Type"]isEqual:@"application/x-plist"]);
    assert([[request valueForHTTPHeaderField:@"X-Native-Test"]isEqual:@"native"]);
    NSDictionary *body=[NSPropertyListSerialization propertyListWithData:request.HTTPBody options:0 format:nil error:nil];
    assert([body[@"serverInfo"][@"opaque"]isEqual:@"native-session"]);assert([body[@"inputs"][@"verificationInfo.answer"]isEqual:@"001234"]);
    model.sourceURL=nil;error=nil;
    assert(TVAppleEmailPostbackRequest(model,element,@{@"verificationInfo.answer":@"001234"},origin,path,&error)&&!error);
    for(NSString *url in @[@"https://other.example.com/appleid/settings/account/manage/email/alternate/verification/put",@"http://native.apple.com/appleid/settings/account/manage/email/alternate/verification/put",@"https://native.apple.com:444/appleid/settings/account/manage/email/alternate/verification/put",@"https://secret@native.apple.com/appleid/settings/account/manage/email/alternate/verification/put",@"/appleid/settings/account/manage/security/put"]){
        error=nil;element.attributes=@{@"url":url,@"httpMethod":@"POST"};assert(!TVAppleEmailPostbackRequest(model,element,@{},origin,path,&error));assert(error.code==TVAppleErrorUnsupported);
    }
    element.attributes=@{@"url":path,@"httpMethod":@"GET"};assert(!TVAppleEmailPostbackRequest(model,element,@{},origin,path,&error));
    element.attributes=@{@"url":path,@"httpMethod":@"POST"};model.empty=YES;assert(!TVAppleEmailPostbackRequest(model,element,@{},origin,path,&error));
    for(id invalid in @[@"",@"bad",@"x@@example.com",@"x@example",@"x\n@example.com",@" x@example.com",@12])assert(!TVAppleValidEmailAddress(invalid));
    assert(TVAppleValidEmailAddress(@"contact@example.net"));
    model.empty=NO;
    ForwardPage *page=[ForwardPage new];ForwardTable *table=[ForwardTable new];ForwardSection *section=[ForwardSection new];
    PostbackElement *option=[PostbackElement new];option.attributes=@{@"class":@"label",@"radioGroup":@"forwardToEmail",@"label":@"contact@example.net",@"value":@"contact@example.net"};
    section.rows=@[option];table.sections=@[section];page.tableViewOM=table;page.rightNavigationBarButtonItem=element;model.allPages=@[page];
    NSString *save=@"/appleid/settings/account/manage/forwardemail/put";
    element.attributes=@{@"url":save,@"httpMethod":@"POST",@"name":@"ak-button",@"ak-action":@"read"};error=nil;
    assert(TVAppleRelayForwardingRequest(model,@"CONTACT@EXAMPLE.NET",origin,&error)&&!error);
    assert([model.values[@"forwardToEmail"]isEqual:@"contact@example.net"]);
    for(NSString *other in @[@"/appleid/settings/account/manage/mail/forwardemail/put",@"/appleid/settings/account/manage/security/forwardemail/put",@"/appleid/settings/account/manage/forwardemail/put-again"]){
        element.attributes=@{@"url":other,@"httpMethod":@"POST",@"name":@"ak-button",@"ak-action":@"read"};assert(!TVAppleRelayForwardingRequest(model,@"contact@example.net",origin,&error));
    }
    element.attributes=@{@"url":save,@"httpMethod":@"POST",@"name":@"ak-button",@"ak-action":@"read"};
    assert(!TVAppleRelayForwardingRequest(model,@"other@example.net",origin,&error));
    option.attributes=@{@"class":@"label",@"radioGroup":@"mailForwardTo",@"label":@"contact@example.net",@"value":@"contact@example.net"};
    assert(!TVAppleRelayForwardingRequest(model,@"contact@example.net",origin,&error));
    option.attributes=@{@"class":@"label",@"radioGroup":@"forwardToEmail",@"label":@"contact@example.net",@"value":@"contact@example.net"};section.rows=@[option,option];
    assert(!TVAppleRelayForwardingRequest(model,@"contact@example.net",origin,&error));
    // Name form schema is exact, native postback preserves the middle name and opaque state.
    PostbackElement *firstRow=[PostbackElement new],*middleRow=[PostbackElement new],*lastRow=[PostbackElement new];
    firstRow.attributes=@{@"id":@"firstName",@"class":@"editableText",@"value":@"before"};
    middleRow.attributes=@{@"id":@"middleName",@"class":@"editableText",@"value":@"preserved"};
    lastRow.attributes=@{@"id":@"lastName",@"class":@"editableText",@"value":@"old"};
    section.rows=@[firstRow,middleRow,lastRow];
    NSString *namePath=@"/appleid/settings/account/manage/person/name/put";
    element.attributes=@{@"url":namePath,@"httpMethod":@"POST",@"name":@"ak-button",@"ak-action":@"read"};
    NSString *middle=nil;error=nil;
    assert(TVAppleNamePostback(model,@"jack",@"ma",origin,&middle,&error)&&!error&&[middle isEqual:@"preserved"]);
    assert(([model.values isEqual:@{@"firstName":@"jack",@"lastName":@"ma",@"middleName":@"preserved"}]));
    assert(TVAppleValidName(@"李")&&TVAppleValidName(@"O’Connor")&&TVAppleValidName(@"Mary Jane"));
    for(id invalid in @[@"",@" ",@"a\nb",@"a\tb",@1,[@"a" stringByPaddingToLength:129 withString:@"a"startingAtIndex:0]])assert(!TVAppleValidName(invalid));
    for(NSString *other in @[@"/appleid/settings/account/manage/name/put",@"/appleid/settings/account/manage/person/name/put-again",@"https://other.example.com/appleid/settings/account/manage/person/name/put"]){
        element.attributes=@{@"url":other,@"httpMethod":@"POST",@"name":@"ak-button",@"ak-action":@"read"};assert(!TVAppleNamePostback(model,@"jack",@"ma",origin,NULL,&error));
    }
    element.attributes=@{@"url":namePath,@"httpMethod":@"POST",@"name":@"ak-button",@"ak-action":@"read"};
    section.rows=@[firstRow,lastRow];assert(!TVAppleNamePostback(model,@"jack",@"ma",origin,NULL,&error));
    section.rows=@[firstRow,middleRow,lastRow,middleRow];assert(!TVAppleNamePostback(model,@"jack",@"ma",origin,NULL,&error));
    section.rows=@[firstRow,middleRow,lastRow];
    middleRow.attributes=@{@"id":@"middleName",@"class":@"editableText",@"value":NSNull.null};assert(!TVAppleNamePostback(model,@"jack",@"ma",origin,NULL,&error));
    middleRow.attributes=@{@"id":@"middleName",@"class":@"editableText",@"value":@"preserved"};
    model.clientInfo=@{@"firstName":@"before",@"lastName":@"old",@"middleName":@"preserved",@"accountName":@"test@example.com",@"token":@"do-not-export"};
    error=nil;NSDictionary *name=TVAppleNameFromPersonalInfo(model,@"test@example.com",&error);assert(name&&!error&&name.count==5&&!name[@"token"]);
    assert(!TVAppleNameFromPersonalInfo(model,@"other@example.com",&error)&&error.code==TVAppleErrorConflict);
    PostbackModel *personal=[PostbackModel new];personal.clientInfo=model.clientInfo;
    ForwardPage *personalPage=[ForwardPage new];ForwardTable *personalTable=[ForwardTable new];ForwardSection *personalSection=[ForwardSection new];PostbackElement *nameLink=[PostbackElement new];
    nameLink.attributes=@{@"class":@"link",@"url":@"/appleid/settings/account/manage/name",@"httpMethod":@"GET"};
    personalSection.rows=@[nameLink];personalTable.sections=@[personalSection];personalPage.tableViewOM=personalTable;personal.allPages=@[personalPage];
    NameTransport *transport=[NameTransport new];transport.personal=personal;transport.form=model;error=nil;
    NSDictionary *saved=[transport setFirstName:@"jack"lastName:@"ma"appleID:@"test@example.com"error:&error];assert(saved&&!error&&transport.posts==1&&transport.refreshes==0&&![saved[@"already_configured"]boolValue]);
    saved=[transport setFirstName:@"jack"lastName:@"ma"appleID:@"test@example.com"error:&error];assert(saved&&[saved[@"already_configured"]boolValue]&&transport.posts==1&&transport.refreshes==0);
    for(NSNumber *scenario in @[@0,@1,@2,@3]){
        personal.clientInfo=model.clientInfo;transport=[NameTransport new];transport.personal=personal;transport.form=model;
        transport.mismatch=YES;transport.readFailure=scenario.intValue==1;transport.identityChanged=scenario.intValue==2;transport.refreshFailure=scenario.intValue==3;error=nil;
        saved=[transport setFirstName:@"jack"lastName:@"ma"appleID:@"test@example.com"error:&error];
        assert(saved&&!error&&transport.posts==1&&transport.refreshes==0);
    }
    personal.clientInfo=model.clientInfo;transport=[NameTransport new];transport.personal=personal;transport.form=model;transport.postUnknown=YES;error=nil;
    assert(![transport setFirstName:@"jack"lastName:@"ma"appleID:@"test@example.com"error:&error]&&error.code==TVAppleErrorOutcomeUnknown&&transport.posts==1);
    // Exercise production challenge checks without touching any Apple service.
    TVAppleNativeSettingsSession *native=[TVAppleNativeSettingsSession new];
    [native setValue:@"session" forKey:@"challenge"];[native setValue:@"test@example.com" forKey:@"target"];
    [native setValue:@(NSProcessInfo.processInfo.systemUptime+60)forKey:@"expires"];
    [native setValue:model forKey:@"pendingModel"];[native setValue:@"contact@example.net"forKey:@"pendingEmail"];
    [native setValue:origin forKey:@"origin"];page.passcodeViewOM=element;
    assert(![native verifyChallenge:@"wrong"code:@"001234"appleID:@"test@example.com"error:&error]);
    assert([[native valueForKey:@"challenge"]isEqual:@"session"]);
    error=nil;assert(![native queryName:@"test@example.com"error:&error]&&error.code==TVAppleErrorConflict);
    assert([[native valueForKey:@"challenge"]isEqual:@"session"]&&[native valueForKey:@"pendingModel"]);
    error=nil;assert(![native setFirstName:@"jack"lastName:@"ma"appleID:@"test@example.com"error:&error]&&error.code==TVAppleErrorConflict);
    assert([[native valueForKey:@"challenge"]isEqual:@"session"]&&[native valueForKey:@"pendingModel"]);


    // The wrong action path fails before consuming the challenge or sending OTP.
    assert(![native verifyChallenge:@"session"code:@"001234"appleID:@"test@example.com"error:&error]);
    assert(error.code==TVAppleErrorUnsupported&&[[native valueForKey:@"challenge"]isEqual:@"session"]);
    [native setValue:@(NSProcessInfo.processInfo.systemUptime-1)forKey:@"expires"];
    assert(![native verifyChallenge:@"session"code:@"001234"appleID:@"test@example.com"error:&error]);
    assert(error.code==TVAppleErrorVerificationCode&&![native valueForKey:@"pendingModel"]);
    element.attributes=@{@"url":path,@"httpMethod":@"POST"};
    for(NSNumber *scenario in @[@0,@1,@2,@3,@4]){
        EmailVerificationTransport *verification=[EmailVerificationTransport new];
        verification.completed=scenario.intValue!=4;
        verification.absent=scenario.intValue==1;verification.readFailure=scenario.intValue==2;verification.changed=scenario.intValue==3;
        [verification setValue:@"session"forKey:@"challenge"];[verification setValue:@"test@example.com"forKey:@"target"];
        [verification setValue:@(NSProcessInfo.processInfo.systemUptime+60)forKey:@"expires"];
        [verification setValue:model forKey:@"pendingModel"];[verification setValue:@"contact@example.net"forKey:@"pendingEmail"];
        [verification setValue:origin forKey:@"origin"];error=nil;
        NSDictionary *result=[verification verifyChallenge:@"session"code:@"001234"appleID:@"test@example.com"error:&error];
        assert(verification.posts==1&&verification.reads==0&&![verification valueForKey:@"challenge"]);
        if(scenario.intValue!=4)assert([result[@"outcome"]isEqual:@"succeeded"]&&!error);
        else assert(!result&&error.code==TVAppleErrorOutcomeUnknown);
    }
    NativeLoader *alertLoader=[NativeLoader new];alertLoader.parser=[NativeParser new];
    AlertOnlyModel *alertModel=[AlertOnlyModel new];alertModel.allPages=@[];
    NativeAlert *alert=[NativeAlert new];alert.title=@"Invalid Email";alert.message=@"This email address is not available. Choose a different address.";
    alertModel.primaryAlert=alert;alertLoader.parser.uiObjectModel=alertModel;
    TVAppleEmailLoad *alertLoad=[TVAppleEmailLoad new];alertLoad.status=200;
    TVAppleObserveEmailParserAlert(alertLoader,alertLoad,YES);assert(![alertLoad complete]);
    alertLoader.parser.succeeded=YES;alertModel.allPages=@[NSNull.null];
    TVAppleObserveEmailParserAlert(alertLoader,alertLoad,YES);assert(![alertLoad complete]);
    alertModel.allPages=@[];TVAppleObserveEmailParserAlert(alertLoader,alertLoad,YES);assert([alertLoad complete]);
    error=nil;assert(!TVAppleFinishEmailLoad(alertLoad,YES,YES,&error)&&error.code==TVAppleErrorInvalidRequest);
    assert([TVAppleDiagnosticMessage(error) containsString:@"not available"]);
    alertLoad=[TVAppleEmailLoad new];alertLoad.status=200;alert.title=@"Unknown alert";
    TVAppleObserveEmailParserAlert(alertLoader,alertLoad,YES);error=nil;
    assert(!TVAppleFinishEmailLoad(alertLoad,YES,YES,&error)&&error.code==TVAppleErrorOutcomeUnknown);
    // Model arrival is not terminal, and errors remain errors even after a model.
    TVAppleEmailLoad *load=[TVAppleEmailLoad new];HeadlessModel *headless=[HeadlessModel new];
    [load loader:NSNull.null receivedObjectModel:headless topActionSignal:nil];assert(![load complete]);
    [load loader:NSNull.null didFinishLoadWithError:[NSError errorWithDomain:@"native" code:9 userInfo:@{@"token":@"private"}]];
    assert([load complete]&&load.failure);assert(!load.failure.userInfo[@"token"]);
    load=[TVAppleEmailLoad new];headless.primaryAlert=NSNull.null;
    // A prior model cannot hide the rejection found by the resource callback.
    [load loader:NSNull.null receivedObjectModel:headless topActionSignal:nil];
    __block NSUInteger resources=0;
    [load loader:NSNull.null loadResourcesForObjectModel:headless completion:^(BOOL ok,NSError *e){assert(ok&&!e);resources++;}];
    assert(load.rejected&&!headless.primaryAlert&&resources==1&&![load complete]);
    [load loader:NSNull.null didFinishLoadWithError:nil];assert([load complete]);
    load.closed=YES;load.model=nil;
    [load loader:NSNull.null receivedObjectModel:[HeadlessModel new]topActionSignal:nil];
    [load loader:NSNull.null didFinishLoadWithError:[NSError errorWithDomain:@"late" code:1 userInfo:nil]];
    assert(!load.model&&!load.failure);
    // Exercise the same production deadline/result boundary as native load.
    load=[TVAppleEmailLoad new];load.status=200;load.model=[HeadlessModel new];error=nil;
    assert(!TVAppleFinishEmailLoad(load,NO,YES,&error));assert(error.code==TVAppleErrorOutcomeUnknown&&load.closed);
    load=[TVAppleEmailLoad new];load.status=200;load.model=[HeadlessModel new];error=nil;
    assert(!TVAppleFinishEmailLoad(load,YES,YES,&error));assert(error.code==TVAppleErrorOutcomeUnknown);
    load=[TVAppleEmailLoad new];load.status=200;load.model=[HeadlessModel new];load.finished=YES;error=nil;
    assert(TVAppleFinishEmailLoad(load,YES,YES,&error)&&!error);
    load=[TVAppleEmailLoad new];load.status=200;load.model=[HeadlessModel new];load.finished=YES;load.rejected=YES;error=nil;
    assert(!TVAppleFinishEmailLoad(load,YES,YES,&error)&&error.code==TVAppleErrorOutcomeUnknown);
    EmailBackend *backend=[EmailBackend new];TVAppleServices *service=[[TVAppleServices alloc]initWithBackend:backend callbackQueue:dispatch_get_global_queue(QOS_CLASS_DEFAULT,0)verificationTimeout:0];
    dispatch_semaphore_t done=dispatch_semaphore_create(0);
    [service beginAddingContactEmail:@"contact@example.net" appleID:@" Test@Example.COM " completion:^(NSDictionary *r,NSError *e){assert(!e&&[r[@"outcome"]isEqual:@"requires_email_verification"]);dispatch_semaphore_signal(done);}];Wait(done);
    [service verifyContactEmailChallenge:@"session" code:@"001234" appleID:@"test@example.com" completion:^(NSDictionary *r,NSError *e){assert(r&&!e);dispatch_semaphore_signal(done);}];Wait(done);
    [service verifyContactEmailChallenge:@"session" code:@"12345x" appleID:@"test@example.com" completion:^(NSDictionary *r,NSError *e){assert(!r&&e.code==TVAppleErrorInvalidRequest);dispatch_semaphore_signal(done);}];Wait(done);
    [service setSignInWithAppleForwardingEmail:@"bad\n@example.net" appleID:@"test@example.com" completion:^(NSDictionary *r,NSError *e){assert(!r&&e.code==TVAppleErrorInvalidRequest);dispatch_semaphore_signal(done);}];Wait(done);
    [service setSignInWithAppleForwardingEmail:@"contact@example.net" appleID:@"test@example.com" completion:^(NSDictionary *r,NSError *e){assert(r&&!e);dispatch_semaphore_signal(done);}];Wait(done);
    assert(backend.begins==1&&backend.verifications==1&&backend.forwards==1);
    // Unknown email/name outcomes cannot block independent explicit commands.
    backend.unknown=YES;
    [service beginAddingContactEmail:@"contact@example.net" appleID:@"test@example.com" completion:^(NSDictionary *r,NSError *e){assert(!r&&e.code==TVAppleErrorOutcomeUnknown);dispatch_semaphore_signal(done);}];Wait(done);
    backend.unknown=NO;
    [service setSignInWithAppleForwardingEmail:@"contact@example.net" appleID:@"test@example.com" completion:^(NSDictionary *r,NSError *e){assert(r&&!e);dispatch_semaphore_signal(done);}];Wait(done);
    [service beginAddingContactEmail:@"contact@example.net" appleID:@"test@example.com" completion:^(NSDictionary *r,NSError *e){assert(!e&&[r[@"outcome"]isEqual:@"requires_email_verification"]);dispatch_semaphore_signal(done);}];Wait(done);
    assert(backend.begins==3&&backend.forwards==2);
    [service setAppleIDFirstName:@"jack"lastName:@"ma"appleID:@" Test@Example.COM "completion:^(NSDictionary *r,NSError *e){assert(r&&!e);dispatch_semaphore_signal(done);}];Wait(done);
    [service setAppleIDFirstName:@" "lastName:@"ma"appleID:@"test@example.com"completion:^(NSDictionary *r,NSError *e){assert(!r&&e.code==TVAppleErrorInvalidRequest);dispatch_semaphore_signal(done);}];Wait(done);
    assert(backend.names==1);
    backend.unknown=YES;
    [service setAppleIDFirstName:@"jack"lastName:@"ma"appleID:@"test@example.com"completion:^(NSDictionary *r,NSError *e){assert(!r&&e.code==TVAppleErrorOutcomeUnknown);dispatch_semaphore_signal(done);}];Wait(done);
    [service setSignInWithAppleForwardingEmail:@"contact@example.net" appleID:@"test@example.com" completion:^(NSDictionary *r,NSError *e){assert(r&&!e);dispatch_semaphore_signal(done);}];Wait(done);
    [service queryAppleIDEmailSettings:@"test@example.com" completion:^(NSDictionary *r,NSError *e){assert(r&&!e);dispatch_semaphore_signal(done);}];Wait(done);
    [service setAppleIDFirstName:@"jack"lastName:@"ma"appleID:@"test@example.com"completion:^(NSDictionary *r,NSError *e){assert(!r&&e.code==TVAppleErrorOutcomeUnknown);dispatch_semaphore_signal(done);}];Wait(done);
    [service queryAppleIDNameSettings:@"test@example.com"completion:^(NSDictionary *r,NSError *e){assert(r&&!e);dispatch_semaphore_signal(done);}];Wait(done);
    assert(backend.names==3);
    assert(backend.forwards==3);puts("PASS email and name actions: native postback boundaries, input, separate code, unknown write fence");return 0;
}}
