#import "TVAppleSignInWithApple.h"
#import "TVAppleEmailActions.h"
#include <assert.h>
@interface SIWANode:NSObject
@property NSDictionary *attributes,*elements,*values;
@property NSArray *allPages,*sections,*rows;
@property id tableViewOM,primaryAlert;
@property NSURL *sourceURL;
@end
@implementation SIWANode
- (id)subElementWithID:(NSString *)identifier{return self.elements[identifier];}
- (void)setUpdateInfo:(NSDictionary *)values{self.values=values;}
- (NSData *)postbackData{return [NSPropertyListSerialization dataWithPropertyList:@{@"serverInfo":@{@"opaque":@"native"},@"inputs":self.values}format:NSPropertyListXMLFormat_v1_0 options:0 error:NULL];}
- (void)_populateRequest:(NSMutableURLRequest *)request{[request setValue:@"native"forHTTPHeaderField:@"X-Native-Test"];}
@end
// Native parser fixture exercises the actual production loadResources capture path.
@interface RUIParser:NSObject
@property NSData *xmlData;
@end
@implementation RUIParser
@end
@interface ParserLoader:NSObject
@property RUIParser *parser;
@end
@implementation ParserLoader
@end
static SIWANode *Node(NSDictionary *attrs){SIWANode *node=[SIWANode new];node.attributes=attrs;return node;}
static SIWANode *Model(NSArray *sections){
    SIWANode *table=Node(@{@"id":@"connectedAppView"});table.sections=sections;
    SIWANode *page=[SIWANode new];page.tableViewOM=table;
    SIWANode *model=[SIWANode new];model.allPages=@[page];return model;
}
static NSString *const Bundle=@"com.example.target";
static NSString *const Client=@"com.example.target.app";
static NSString *const Detail=@"/appleid/settings/account/manage/security/apps/com.example.target.app";
static NSString *const Delete=@"/appleid/settings/account/manage/security/apps/com.example.target.app/delete";
static NSData *XML(void){return [@"<xmlui><serverInfo token='fixture-secret'/><alert id='revokeConnectedApp' preferredButton='removeButton'><button id='removeButton' destructive='true' httpMethod='POST' url='/appleid/settings/account/manage/security/apps/com.example.target.app/delete'>Stop</button><cancelButton>Cancel</cancelButton></alert></xmlui>"dataUsingEncoding:NSUTF8StringEncoding];}
@interface SIWATransport:TVAppleNativeSettingsSession
@property SIWANode *listing,*detail;
@property SIWANode *listSection;
@property NSUInteger posts;
@property BOOL posted,remain,readFailure,identityChanged,timeout,nativeEmpty;
@end
@implementation SIWATransport
- (BOOL)beginSettingsOperation:(NSString *)appleID error:(NSError **)error{(void)appleID;(void)error;return YES;}
- (void)finishSettingsOperation{}
- (NSURL *)origin{return [NSURL URLWithString:@"https://native.apple.com/appleid/settings/account/manage"];}
- (BOOL)identityMatches:(NSError **)error{
    if(self.posted&&self.identityChanged){*error=TVAppleError(TVAppleErrorConflict,@"changed");return NO;}return YES;
}
- (id)get:(NSString *)link error:(NSError **)error{
    if([link hasSuffix:@".app"])return self.detail;
    if(self.posted&&self.readFailure){*error=TVAppleError(TVAppleErrorBackendRead,@"fixture");return nil;}return self.listing;
}
- (id)load:(NSMutableURLRequest *)request mutation:(BOOL)mutation error:(NSError **)error{
    assert(mutation&&[request.URL.path isEqual:Delete]);self.posts++;self.posted=YES;
    if(self.timeout){*error=TVAppleError(TVAppleErrorOutcomeUnknown,@"timeout");return nil;}
    if(!self.remain){self.listSection.rows=@[];if(self.nativeEmpty)self.listSection.attributes=@{};}return self.listing;
}
@end
@interface SIWABackend:NSObject<TVAppleBackend,TVAppleSignInWithAppleBackend>
@property NSUInteger stops,queries;
@property BOOL unknown;
@end
@implementation SIWABackend
- (NSDictionary *)snapshot:(NSError **)error{(void)error;return @{@"accounts":@[],@"find_my_enabled":@NO};}
- (id)prepareAccount:(NSDictionary *)account policy:(TVAppleLocalDataPolicy)policy error:(NSError **)error{(void)account;(void)policy;(void)error;assert(NO);return nil;}
- (BOOL)removePreparedAccount:(id)prepared error:(NSError **)error{(void)prepared;(void)error;assert(NO);return NO;}
- (NSDictionary *)signInWithAppleAppsForAppleID:(NSString *)appleID error:(NSError **)error{(void)error;self.queries++;assert([appleID isEqual:@"test@example.com"]);return @{@"apple_id":appleID,@"apps":@[],@"bundle_ids":@[]};}
- (NSDictionary *)stopUsingAppleIDForBundleID:(NSString *)bundleID appleID:(NSString *)appleID error:(NSError **)error{
    assert([bundleID isEqual:Bundle]&&[appleID isEqual:@"test@example.com"]);self.stops++;
    if(self.unknown){*error=TVAppleError(TVAppleErrorOutcomeUnknown,@"fixture");return nil;}return @{@"outcome":@"succeeded"};
}
@end
static void Wait(dispatch_semaphore_t done){assert(!dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,3*NSEC_PER_SEC)));}
int main(void){@autoreleasepool{
    NSURL *origin=[NSURL URLWithString:@"https://native.apple.com/appleid/settings/account/manage"];
    SIWANode *row=Node(@{@"id":Bundle,@"label":@"Target",@"class":@"link",@"url":Detail});
    SIWANode *section=Node(@{@"id":@"connectApplicationSection"});section.rows=@[row];SIWANode *listing=Model(@[section]);NSError *error=nil;
    NSArray *apps=TVAppleSIWAApplications(listing,origin,&error);assert(apps.count==1&&!error&&[apps[0][@"bundle_id"]isEqual:Bundle]);
    section.rows=@[];assert(TVAppleSIWAApplications(listing,origin,&error).count==0);
    // Actual iOS15 response after removing the final grant: identified table,
    // one anonymous empty section, no connectApplicationSection.
    SIWANode *emptySection=Node(@{});emptySection.rows=@[];
    error=nil;NSArray *emptyApps=TVAppleSIWAApplications(Model(@[emptySection]),origin,&error);
    assert(emptyApps&&emptyApps.count==0&&!error);
    emptySection.rows=@[row];assert(!TVAppleSIWAApplications(Model(@[emptySection]),origin,&error));emptySection.rows=@[];
    emptySection.attributes=@{@"id":@"other"};assert(!TVAppleSIWAApplications(Model(@[emptySection]),origin,&error));emptySection.attributes=@{};
    assert(!TVAppleSIWAApplications(Model(@[emptySection,emptySection]),origin,&error));
    section.rows=@[row,row];assert(!TVAppleSIWAApplications(listing,origin,&error));section.rows=@[row];
    NSDictionary *attrs=row.attributes;
    for(NSString *url in @[@"https://other.example.com/appleid/settings/account/manage/security/apps/com.example.target.app",@"/appleid/settings/account/manage/security/apps/other.app",@"/appleid/settings/account/manage/security/apps/com.example.target.app#unexpected"]){
        NSMutableDictionary *changed=[attrs mutableCopy];changed[@"url"]=url;row.attributes=changed;assert(!TVAppleSIWAApplications(listing,origin,&error));
    }
    NSMutableDictionary *queryAttrs=[attrs mutableCopy];queryAttrs[@"url"]=[Detail stringByAppendingString:@"?native-context=fixture"];
    row.attributes=queryAttrs;assert(TVAppleSIWAApplications(listing,origin,&error).count==1);
    row.attributes=attrs;section.attributes=@{@"id":@"other"};assert(!TVAppleSIWAApplications(listing,origin,&error));section.attributes=@{@"id":@"connectApplicationSection"};
    for(id bad in @[@"",@"single",@"a..b",@"x/y.z",@"com.example x",@"x.y\n",@1])assert(!TVAppleValidBundleID(bad));
    NSDictionary *confirmation=TVAppleSIWAConfirmationFromXML(XML());assert(confirmation.count==4&&!confirmation[@"token"]);
    for(NSString *xml in @[@"<xmlui><alert id='other'/></xmlui>",@"<xmlui><alert id='revokeConnectedApp' preferredButton='removeButton'><button/><button/><cancelButton/></alert></xmlui>",@"<xmlui><alert id='revokeConnectedApp' preferredButton='removeButton'><button/><cancelButton/></alert><alert id='revokeConnectedApp' preferredButton='removeButton'><button/><cancelButton/></alert></xmlui>",@"<bad>"])
        assert(!TVAppleSIWAConfirmationFromXML([xml dataUsingEncoding:NSUTF8StringEncoding]));
    SIWANode *target=Node(@{@"id":Bundle,@"class":@"label"});SIWANode *targetSection=Node(@{@"id":@"connectApplicationSection"});targetSection.rows=@[target];
    SIWANode *stop=Node(@{@"class":@"link",@"url":@"#revokeConnectedApp"});SIWANode *stopSection=Node(@{@"id":@"revokeApp"});stopSection.rows=@[stop];
    SIWANode *detail=Model(@[targetSection,stopSection]);SIWANode *alert=Node(@{@"id":@"revokeConnectedApp",@"preferredButton":@"removeButton"});detail.elements=@{@"revokeConnectedApp":alert};
    ParserLoader *loader=[ParserLoader new];loader.parser=[RUIParser new];loader.parser.xmlData=XML();TVAppleEmailLoad *observer=[TVAppleEmailLoad new];
    [observer loader:loader loadResourcesForObjectModel:detail completion:^(BOOL ok,NSError *e){assert(ok&&!e);}];
    error=nil;NSMutableURLRequest *request=TVAppleSIWARevokeRequest(detail,apps[0],origin,&error);assert(request&&!error&&[request.URL.path isEqual:Delete]);
    NSDictionary *body=[NSPropertyListSerialization propertyListWithData:request.HTTPBody options:0 format:NULL error:NULL];assert([body[@"serverInfo"][@"opaque"]isEqual:@"native"]&&[body[@"inputs"]count]==0);
    for(NSString *path in @[@"/appleid/settings/account/manage/security/apps/other.app/delete",@"/appleid/settings/account/manage/security/apps/com.example.target.app/email/private/disable/put",@"https://other.example.com/appleid/settings/account/manage/security/apps/com.example.target.app/delete"]){
        NSMutableDictionary *changed=[confirmation mutableCopy];changed[@"url"]=path;TVAppleAttachSIWAConfirmation(detail,changed);assert(!TVAppleSIWARevokeRequest(detail,apps[0],origin,&error));
    }
    NSMutableDictionary *nativeQuery=[confirmation mutableCopy];nativeQuery[@"url"]=[Delete stringByAppendingString:@"?native-context=fixture"];
    TVAppleAttachSIWAConfirmation(detail,nativeQuery);error=nil;assert([TVAppleSIWARevokeRequest(detail,apps[0],origin,&error).URL.query isEqual:@"native-context=fixture"]&&!error);
    TVAppleAttachSIWAConfirmation(detail,confirmation);target.attributes=@{@"id":@"com.example.other",@"class":@"label"};assert(!TVAppleSIWARevokeRequest(detail,apps[0],origin,&error));target.attributes=@{@"id":Bundle,@"class":@"label"};
    for(NSString *scenario in @[@"success",@"native_empty",@"remaining",@"read_failure",@"identity_changed",@"timeout"]){
        section.attributes=@{@"id":@"connectApplicationSection"};section.rows=@[row];SIWATransport *transport=[SIWATransport new];transport.listing=listing;transport.detail=detail;transport.listSection=section;
        transport.nativeEmpty=[scenario isEqual:@"native_empty"];
        transport.remain=[scenario isEqual:@"remaining"];transport.readFailure=[scenario isEqual:@"read_failure"];transport.identityChanged=[scenario isEqual:@"identity_changed"];transport.timeout=[scenario isEqual:@"timeout"];
        error=nil;NSDictionary *result=[transport stopUsingAppleIDForBundleID:Bundle appleID:@"test@example.com"error:&error];assert(transport.posts==1);
        if([scenario isEqual:@"success"]||[scenario isEqual:@"native_empty"]){
            assert(result&&!error&&![result[@"already_stopped"]boolValue]);
            result=[transport stopUsingAppleIDForBundleID:Bundle appleID:@"test@example.com"error:&error];assert(result&&[result[@"already_stopped"]boolValue]&&transport.posts==1);
            result=[transport querySignInWithAppleApps:@"test@example.com"error:&error];assert(result&&[result[@"bundle_ids"]count]==0);
        }else if(transport.timeout)assert(!result&&error.code==TVAppleErrorOutcomeUnknown);
        else assert(result&&!error&&[result[@"outcome"]isEqual:@"succeeded"]);
    }
    section.rows=@[row];SIWATransport *transport=[SIWATransport new];transport.listing=listing;error=nil;
    NSDictionary *query=[transport querySignInWithAppleApps:@"test@example.com"error:&error];assert(query&&!error&&[query[@"apps"]count]==1&&!query[@"apps"][0][@"detail_url"]);
    TVAppleNativeSettingsSession *pending=[TVAppleNativeSettingsSession new];[pending setValue:@"challenge"forKey:@"challenge"];[pending setValue:@(NSProcessInfo.processInfo.systemUptime+60)forKey:@"expires"];
    assert(![pending stopUsingAppleIDForBundleID:Bundle appleID:@"test@example.com"error:&error]&&error.code==TVAppleErrorConflict&&[[pending valueForKey:@"challenge"]isEqual:@"challenge"]);
    SIWABackend *backend=[SIWABackend new];TVAppleServices *service=[[TVAppleServices alloc]initWithBackend:backend callbackQueue:dispatch_get_global_queue(QOS_CLASS_DEFAULT,0)verificationTimeout:0];dispatch_semaphore_t done=dispatch_semaphore_create(0);
    [service querySignInWithAppleApps:@" TEST@Example.COM "completion:^(NSDictionary *r,NSError *e){assert(r&&!e);dispatch_semaphore_signal(done);}];Wait(done);
    [service stopUsingAppleIDForBundleID:@"bad/path"appleID:@"test@example.com"completion:^(NSDictionary *r,NSError *e){assert(!r&&e.code==TVAppleErrorInvalidRequest);dispatch_semaphore_signal(done);}];Wait(done);assert(!backend.stops);
    [service stopUsingAppleIDForBundleID:Bundle appleID:@" TEST@Example.COM "completion:^(NSDictionary *r,NSError *e){assert(r&&!e);dispatch_semaphore_signal(done);}];Wait(done);assert(backend.stops==1);
    backend.unknown=YES;
    [service stopUsingAppleIDForBundleID:Bundle appleID:@"test@example.com"completion:^(NSDictionary *r,NSError *e){assert(!r&&e.code==TVAppleErrorOutcomeUnknown);dispatch_semaphore_signal(done);}];Wait(done);
    [service stopUsingAppleIDForBundleID:Bundle appleID:@"test@example.com"completion:^(NSDictionary *r,NSError *e){assert(!r&&e.code==TVAppleErrorOutcomeUnknown);dispatch_semaphore_signal(done);}];Wait(done);assert(backend.stops==3);
    [service querySignInWithAppleApps:@"test@example.com"completion:^(NSDictionary *r,NSError *e){assert(r&&!e);dispatch_semaphore_signal(done);}];Wait(done);assert(backend.queries==2);
    puts("PASS Sign in with Apple: server list, native confirmation capture, targeted revoke, fresh verification, fence");return 0;
}}
