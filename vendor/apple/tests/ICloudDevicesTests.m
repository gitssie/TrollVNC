#import "TVAppleICloudDevices.h"
#import "TVAppleEmailActions.h"
#include <assert.h>
@interface DNode:NSObject
@property NSDictionary *attributes,*clientInfo,*elements,*values;@property NSArray *allPages,*sections,*rows;@property id tableViewOM,primaryAlert;
@property NSURL *sourceURL;
@end
@implementation DNode
- (id)subElementWithID:(NSString *)s{return self.elements[s];}
- (void)setUpdateInfo:(NSDictionary *)d{self.values=d;}
- (NSData *)postbackData{return [NSPropertyListSerialization dataWithPropertyList:@{@"serverInfo":@{@"opaque":@"retained"},@"inputs":self.values}format:NSPropertyListXMLFormat_v1_0 options:0 error:NULL];}
- (void)_populateRequest:(NSMutableURLRequest *)r{[r setValue:@"native"forHTTPHeaderField:@"X-Test"];}
@end
@interface RUIParser:NSObject @property NSData *xmlData;@end
@implementation RUIParser @end
@interface DLoader:NSObject @property RUIParser *parser;@end
@implementation DLoader @end
static NSString *const Current=@"11111111111111111111111111111111",*const Other=@"22222222222222222222222222222222",*const Third=@"33333333333333333333333333333333";
static NSURL *Origin(void){return [NSURL URLWithString:@"https://native.apple.com/appleid/settings/account/manage"];}
static DNode *N(NSDictionary *a){DNode *n=[DNode new];n.attributes=a;return n;}
static DNode *M(NSArray *rows){DNode *s=[DNode new];s.rows=rows;DNode *t=[DNode new];t.sections=@[s];DNode *p=[DNode new];p.tableViewOM=t;DNode *m=[DNode new];m.allPages=@[p];return m;}
static NSDictionary *Info(NSString *identifier,BOOL current){return @{@"deviceId":identifier,@"isCurrentDevice":current?@"true":@"false",@"deviceFmipEnabled":@"false",@"deviceName":@"Any device",@"deviceModelName":@"Any model"};}
static NSData *XML(NSString *identifier){NSString *x=[NSString stringWithFormat:@"<xmlui><serverInfo token='fixture'/><alert id='removeDevice%@'><button destructive='true' httpMethod='POST' url='/appleid/account/manage/security/devices/%@/delete?native-context=fixture'>Remove</button><button>Cancel</button></alert></xmlui>",identifier,identifier];return [x dataUsingEncoding:NSUTF8StringEncoding];}
static DNode *Detail(NSString *identifier,BOOL current){NSString *alert=[@"removeDevice"stringByAppendingString:identifier];DNode *m=M(@[N(@{@"class":@"link",@"url":[@"#"stringByAppendingString:alert],@"disabled":@"false"})]);m.clientInfo=Info(identifier,current);m.elements=@{alert:N(@{@"id":alert})};DLoader *l=[DLoader new];l.parser=[RUIParser new];l.parser.xmlData=XML(identifier);TVAppleEmailLoad *observer=[TVAppleEmailLoad new];[observer loader:l loadResourcesForObjectModel:m completion:^(BOOL ok,NSError *e){assert(ok&&!e);}];return m;}
@interface TVAppleNativeSettingsSession(DTest)
- (NSArray *)readDeviceRecords:(NSError **)error;
@end
@interface DTransport:TVAppleNativeSettingsSession
@property NSMutableArray *records;@property NSUInteger posts;@property BOOL remaining,readFailure,changed,failedSecond;
@end
@implementation DTransport
- (BOOL)beginSettingsOperation:(NSString *)s error:(NSError **)e{(void)s;(void)e;return YES;}
- (void)finishSettingsOperation{}
- (NSURL *)origin{return Origin();}
- (NSArray *)readDeviceRecords:(NSError **)e{if(self.posts&&self.readFailure){*e=TVAppleError(TVAppleErrorBackendRead,@"fixture");return nil;}if(self.posts&&self.changed)return @[@{@"info":@{@"device_id":Third,@"current_device":@YES}}];return [self.records copy];}
- (id)load:(NSMutableURLRequest *)r mutation:(BOOL)mutation error:(NSError **)e{assert(mutation);self.posts++;if(self.failedSecond&&self.posts==2){*e=TVAppleError(TVAppleErrorOutcomeUnknown,@"fixture");return nil;}if(!self.remaining){NSArray *parts=[r.URL.path componentsSeparatedByString:@"/"];NSString *identifier=parts[parts.count-2];assert(![identifier isEqual:Current]);NSIndexSet *indices=[self.records indexesOfObjectsPassingTest:^BOOL(NSDictionary *record,NSUInteger idx,BOOL *stop){(void)idx;(void)stop;return [record[@"info"][@"device_id"]isEqual:identifier];}];[self.records removeObjectsAtIndexes:indices];}return [NSObject new];}
@end
static NSDictionary *Record(NSString *identifier,BOOL current){DNode *d=Detail(identifier,current);NSError *e=nil;return @{@"info":TVAppleDeviceInfo(d,identifier,&e),@"model":d};}
@interface DBackend:NSObject<TVAppleBackend,TVAppleICloudDevicesBackend>
@property NSUInteger writes,reads;@property BOOL unknown;
@end
@implementation DBackend
- (NSDictionary *)snapshot:(NSError **)e{(void)e;return @{@"accounts":@[],@"find_my_enabled":@NO};}
- (id)prepareAccount:(NSDictionary *)a policy:(TVAppleLocalDataPolicy)p error:(NSError **)e{(void)a;(void)p;(void)e;assert(NO);return nil;}
- (BOOL)removePreparedAccount:(id)a error:(NSError **)e{(void)a;(void)e;assert(NO);return NO;}
- (NSDictionary *)iCloudDevicesForAppleID:(NSString *)a error:(NSError **)e{(void)e;self.reads++;assert([a isEqual:@"test@example.com"]);return @{@"apple_id":a,@"devices":@[]};}
- (NSDictionary *)removeOtherICloudDevicesForAppleID:(NSString *)a error:(NSError **)e{self.writes++;assert([a isEqual:@"test@example.com"]);if(self.unknown){*e=TVAppleError(TVAppleErrorOutcomeUnknown,@"fixture");return nil;}return @{@"outcome":@"succeeded"};}
@end
static void Wait(dispatch_semaphore_t done){assert(!dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,3*NSEC_PER_SEC)));}
int main(void){@autoreleasepool{NSError *e=nil;DNode *row=N(@{@"class":@"link",@"label":@"Any",@"url":[@"/appleid/account/manage/security/devices/"stringByAppendingString:Other]});DNode *list=M(@[row]);assert(TVAppleDeviceLinks(list,Origin(),&e).count==1);assert(!TVAppleDeviceLinks(M(@[row,row]),Origin(),&e));assert(!TVAppleDeviceLinks(M(@[]),Origin(),&e));row.attributes=@{@"class":@"link",@"label":@"Any",@"url":@"https://other.example.com/appleid/account/manage/security/devices/22222222222222222222222222222222"};assert(!TVAppleDeviceLinks(list,Origin(),&e));
 DNode *d=Detail(Other,NO);e=nil;NSMutableURLRequest *request=TVAppleDeviceRemovalRequest(d,Other,Origin(),&e);assert(request&&!e&&[request.HTTPMethod isEqual:@"POST"]&&[request.URL.query isEqual:@"native-context=fixture"]);NSDictionary *body=[NSPropertyListSerialization propertyListWithData:request.HTTPBody options:0 format:NULL error:NULL];assert([body[@"serverInfo"][@"opaque"]isEqual:@"retained"]);assert(!TVAppleDeviceRemovalRequest(Detail(Current,YES),Current,Origin(),&e));assert(!TVAppleDeviceRemovalRequest(d,Third,Origin(),&e));
 NSMutableDictionary *bad=[d.clientInfo mutableCopy];bad[@"isCurrentDevice"]=@"unknown";d.clientInfo=bad;assert(!TVAppleDeviceInfo(d,Other,&e));d.clientInfo=Info(Other,NO);NSDictionary *button=TVAppleDeviceConfirmationFromXML(XML(Other),Other);assert(button.count==3&&!button[@"token"]);assert(!TVAppleDeviceConfirmationFromXML(XML(Other),Third));assert(!TVAppleDeviceConfirmationFromXML([@"<bad>"dataUsingEncoding:NSUTF8StringEncoding],Other));NSMutableDictionary *b=[button mutableCopy];b[@"url"]=@"https://other.example.com/appleid/account/manage/security/devices/22222222222222222222222222222222/delete";TVAppleAttachDeviceConfirmation(d,b);assert(!TVAppleDeviceRemovalRequest(d,Other,Origin(),&e));
 assert(!TVAppleCurrentDeviceID(@[@{@"device_id":Other,@"current_device":@NO}],&e));assert(!TVAppleCurrentDeviceID(@[@{@"device_id":Current,@"current_device":@YES},@{@"device_id":Other,@"current_device":@YES}],&e));
 for(NSString *scenario in @[@"success",@"remaining",@"read_failure",@"changed",@"failed_second"]){DTransport *t=[DTransport new];t.records=[@[Record(Current,YES),Record(Other,NO),Record(Third,NO)]mutableCopy];t.remaining=[scenario isEqual:@"remaining"];t.readFailure=[scenario isEqual:@"read_failure"];t.changed=[scenario isEqual:@"changed"];t.failedSecond=[scenario isEqual:@"failed_second"];e=nil;NSDictionary *r=[t removeOtherICloudDevices:@"test@example.com"error:&e];if([scenario isEqual:@"success"]){assert(!e&&[r[@"outcome"]isEqual:@"succeeded"]&&t.posts==2&&[r[@"removed_device_ids"]count]==2&&t.records.count==1);r=[t removeOtherICloudDevices:@"test@example.com"error:&e];assert(!e&&[r[@"already_removed"]boolValue]&&t.posts==2);r=[t queryICloudDevices:@"test@example.com"error:&e];assert([r[@"devices"]count]==1&&!r[@"devices"][0][@"model_object"]&&!r[@"devices"][0][@"detail_url"]);}else{assert(e.code==TVAppleErrorOutcomeUnknown&&[r[@"outcome"]isEqual:@"unknown"]);if(t.failedSecond)assert([r[@"removed_device_ids"]count]==1&&t.posts==2);else assert(t.posts==1);}}
 TVAppleNativeSettingsSession *pending=[TVAppleNativeSettingsSession new];[pending setValue:@"challenge"forKey:@"challenge"];[pending setValue:@(NSProcessInfo.processInfo.systemUptime+60)forKey:@"expires"];assert(![pending removeOtherICloudDevices:@"test@example.com"error:&e]&&e.code==TVAppleErrorConflict);DBackend *backend=[DBackend new];TVAppleServices *service=[[TVAppleServices alloc]initWithBackend:backend callbackQueue:dispatch_get_global_queue(QOS_CLASS_DEFAULT,0)verificationTimeout:0];dispatch_semaphore_t done=dispatch_semaphore_create(0);
 [service removeOtherICloudDevices:@""completion:^(NSDictionary *r,NSError *e){assert(!r&&e.code==TVAppleErrorInvalidRequest);dispatch_semaphore_signal(done);}];Wait(done);assert(backend.writes==0);
 [service queryICloudDevices:@" TEST@Example.COM "completion:^(NSDictionary *r,NSError *e){assert(r&&!e);dispatch_semaphore_signal(done);}];Wait(done);
 backend.unknown=YES;[service removeOtherICloudDevices:@"test@example.com"completion:^(NSDictionary *r,NSError *e){assert(!r&&e.code==TVAppleErrorOutcomeUnknown);dispatch_semaphore_signal(done);}];Wait(done);
 [service removeOtherICloudDevices:@"test@example.com"completion:^(NSDictionary *r,NSError *e){assert(!r&&e.code==TVAppleErrorOutcomeUnknown);dispatch_semaphore_signal(done);}];Wait(done);assert(backend.writes==1);
 [service queryICloudDevices:@"test@example.com"completion:^(NSDictionary *r,NSError *e){assert(r&&!e);dispatch_semaphore_signal(done);}];Wait(done);assert(backend.reads==2);
 puts("PASS iCloud devices: native targets, current-device protection, confirmation capture, batch verification and partial unknown");return 0;}}
