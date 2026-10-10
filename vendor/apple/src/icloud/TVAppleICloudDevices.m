#import "TVAppleICloudDevices.h"
#import "TVAppleEmailActions.h"
#import <objc/runtime.h>
@interface NSObject(TVAppleDeviceSelectors)
- (id)allPages; - (id)tableViewOM; - (id)sections; - (id)rows; - (id)attributes; - (id)clientInfo; - (id)subElementWithID:(NSString *)key;
+ (id)sharedBag; - (NSURL *)trustedDevicesURL;
@end
static NSString *const DevicePath=@"/appleid/account/manage/security/devices";
static BOOL Has(id o,NSArray *selectors){if(!o)return NO;for(NSString *s in selectors)if(![o respondsToSelector:NSSelectorFromString(s)])return NO;return YES;}
static id Invalid(NSError **error){*error=TVAppleError(TVAppleErrorUnsupported,@"Native account device structure or identity is unavailable.");return nil;}
static BOOL IDValid(id s){return [s isKindOfClass:NSString.class]&&[s length]==32&&[s rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"]invertedSet]].location==NSNotFound;}
static BOOL Origin(NSURL *u,NSURL *o){return [u.scheme.lowercaseString isEqual:@"https"]&&!u.user&&!u.password&&[u.host.lowercaseString isEqual:o.host.lowercaseString]&&[(u.port?:@443)isEqual:o.port?:@443]&&!u.fragment;}
static NSArray *Rows(id model,NSError **error){
    if(!Has(model,@[@"allPages"])||![[model allPages]isKindOfClass:NSArray.class]||[[model allPages]count]!=1)return Invalid(error);
    id page=[[model allPages]firstObject];if(!Has(page,@[@"tableViewOM"]))return Invalid(error);
    id table=[page tableViewOM];if(!Has(table,@[@"sections"])||![[table sections]isKindOfClass:NSArray.class])return Invalid(error);
    NSMutableArray *rows=[NSMutableArray new];for(id section in [table sections]){if(!Has(section,@[@"rows"])||![[section rows]isKindOfClass:NSArray.class])return Invalid(error);[rows addObjectsFromArray:[section rows]];}return rows;

}
NSArray *TVAppleDeviceLinks(id model,NSURL *origin,NSError **error){
    NSArray *rows=Rows(model,error);if(!rows||!rows.count){if(rows)*error=TVAppleError(TVAppleErrorUnsupported,@"The current device could not be identified.");return nil;}
    NSMutableArray *links=[NSMutableArray new];NSMutableSet *seen=[NSMutableSet new];NSString *prefix=[DevicePath stringByAppendingString:@"/"];
    for(id row in rows){if(!Has(row,@[@"attributes"]))return Invalid(error);NSDictionary *a=[row attributes];if(![a isKindOfClass:NSDictionary.class])return Invalid(error);
        NSURL *url=[a[@"url"]isKindOfClass:NSString.class]?[NSURL URLWithString:a[@"url"]relativeToURL:origin].absoluteURL:nil;
        NSString *identifier=[url.path hasPrefix:prefix]?[url.path substringFromIndex:prefix.length]:nil;
        if(![a[@"class"]isEqual:@"link"]||![a[@"label"]isKindOfClass:NSString.class]||![a[@"label"]length]||
           (a[@"httpMethod"]&&![a[@"httpMethod"]isEqual:@"GET"])||!Origin(url,origin)||!IDValid(identifier)||[seen containsObject:identifier])return Invalid(error);
        [seen addObject:identifier];[links addObject:@{@"device_id":identifier,@"detail_url":url.absoluteString}];
    }return links;

}
static id NativeBool(id value){if([value isEqual:@"true"])return @YES;if([value isEqual:@"false"])return @NO;return nil;}
NSDictionary *TVAppleDeviceInfo(id model,NSString *deviceID,NSError **error){
    NSDictionary *a=Has(model,@[@"clientInfo"])?[model clientInfo]:nil;
    if(![a isKindOfClass:NSDictionary.class])return Invalid(error);
    id current=NativeBool(a[@"isCurrentDevice"]),findMy=NativeBool(a[@"deviceFmipEnabled"]);
    if(![a isKindOfClass:NSDictionary.class]||!IDValid(deviceID)||![a[@"deviceId"]isEqual:deviceID]||!current||!findMy||
       ![a[@"deviceName"]isKindOfClass:NSString.class]||![a[@"deviceName"]length]||![a[@"deviceModelName"]isKindOfClass:NSString.class]||![a[@"deviceModelName"]length]){
        *error=TVAppleError(TVAppleErrorUnsupported,@"Native device identity or current-device marker is unavailable.");return nil;
    }
    return @{@"device_id":deviceID,@"name":a[@"deviceName"],@"model":a[@"deviceModelName"],@"current_device":current,@"find_my_enabled":findMy};
}
NSString *TVAppleCurrentDeviceID(NSArray *devices,NSError **error){NSString *current=nil;NSMutableSet *seen=[NSMutableSet new];
    for(NSDictionary *d in devices){if(!IDValid(d[@"device_id"])||![d[@"current_device"]isKindOfClass:NSNumber.class]||[seen containsObject:d[@"device_id"]])return Invalid(error);[seen addObject:d[@"device_id"]];if([d[@"current_device"]boolValue]){if(current)return Invalid(error);current=d[@"device_id"];}}
    if(!current)return Invalid(error);return current;

}
static char DeviceConfirmationKey;
@interface TVAppleDeviceXML:NSObject<NSXMLParserDelegate>
@property NSString *alertID;@property NSUInteger depth,alertDepth,alerts,buttons;@property NSMutableArray *posts;@property BOOL cancel;
@end
@implementation TVAppleDeviceXML
- (void)parser:(NSXMLParser *)p didStartElement:(NSString *)element namespaceURI:(NSString *)u qualifiedName:(NSString *)q attributes:(NSDictionary *)a{
    (void)p;(void)u;(void)q;self.depth++;
    if([element isEqual:@"alert"]&&[a[@"id"]isEqual:self.alertID]){self.alerts++;self.alertDepth=self.depth;}
    else if(self.alertDepth&&self.depth==self.alertDepth+1&&[element isEqual:@"button"]){self.buttons++;
        if([a[@"httpMethod"]isEqual:@"POST"]&&[a[@"destructive"]isEqual:@"true"]){NSMutableDictionary *post=[NSMutableDictionary new];for(NSString *k in @[@"url",@"httpMethod",@"destructive"])if(a[k])post[k]=a[k];[self.posts addObject:post];}
        else if(!a[@"httpMethod"]&&!a[@"url"])self.cancel=YES;
    }
}
- (void)parser:(NSXMLParser *)p didEndElement:(NSString *)e namespaceURI:(NSString *)u qualifiedName:(NSString *)q{(void)p;(void)e;(void)u;(void)q;if(self.depth==self.alertDepth)self.alertDepth=0;if(self.depth)self.depth--;}
@end
NSDictionary *TVAppleDeviceConfirmationFromXML(NSData *xml,NSString *deviceID){
    if(!IDValid(deviceID)||![xml isKindOfClass:NSData.class]||!xml.length||xml.length>2*1024*1024)return nil;
    TVAppleDeviceXML *o=[TVAppleDeviceXML new];o.alertID=[@"removeDevice"stringByAppendingString:deviceID];o.posts=[NSMutableArray new];
    NSXMLParser *p=[[NSXMLParser alloc]initWithData:xml];p.delegate=o;p.shouldResolveExternalEntities=NO;
    return [p parse]&&o.alerts==1&&o.buttons==2&&o.posts.count==1&&o.cancel?o.posts.firstObject:nil;
}
void TVAppleAttachDeviceConfirmation(id model,NSDictionary *button){objc_setAssociatedObject(model,&DeviceConfirmationKey,[button copy],OBJC_ASSOCIATION_RETAIN_NONATOMIC);}
void TVAppleCaptureDeviceConfirmation(id loader,id model){
    NSDictionary *info=Has(model,@[@"clientInfo"])?[model clientInfo]:nil;if(![info isKindOfClass:NSDictionary.class])return;NSString *deviceID=info[@"deviceId"];
    if(!IDValid(deviceID)||!class_getInstanceVariable([loader class],"_parser"))return;
    id parser=[loader valueForKey:@"parser"];Class c=NSClassFromString(@"RUIParser");if(!c||![parser isKindOfClass:c]||![parser respondsToSelector:NSSelectorFromString(@"xmlData")])return;
    NSDictionary *button=TVAppleDeviceConfirmationFromXML([parser valueForKey:@"xmlData"],deviceID);if(button)TVAppleAttachDeviceConfirmation(model,button);
}
@interface TVAppleDeviceButton:NSObject @property NSDictionary *attributes;@end
@implementation TVAppleDeviceButton @end
NSMutableURLRequest *TVAppleDeviceRemovalRequest(id model,NSString *deviceID,NSURL *origin,NSError **error){
    NSDictionary *info=TVAppleDeviceInfo(model,deviceID,error);if(!info)return nil;
    if([info[@"current_device"]boolValue]){*error=TVAppleError(TVAppleErrorConflict,@"Removing the current device is forbidden.");return nil;}
    NSString *alertID=[@"removeDevice"stringByAppendingString:deviceID];BOOL link=NO;NSArray *rows=Rows(model,error);if(!rows)return nil;
    for(id row in rows){NSDictionary *a=Has(row,@[@"attributes"])?[row attributes]:nil;if([a[@"class"]isEqual:@"link"]&&[a[@"url"]isEqual:[@"#"stringByAppendingString:alertID]]){if(link||![a[@"disabled"]isEqual:@"false"]){*error=TVAppleError(TVAppleErrorUnsupported,@"Native device removal action is unavailable.");return nil;}link=YES;}}
    id alert=Has(model,@[@"subElementWithID:"])?[model subElementWithID:alertID]:nil;NSDictionary *a=Has(alert,@[@"attributes"])?[alert attributes]:nil;
    NSDictionary *button=objc_getAssociatedObject(model,&DeviceConfirmationKey);NSURL *url=[button[@"url"]isKindOfClass:NSString.class]?[NSURL URLWithString:button[@"url"]relativeToURL:origin].absoluteURL:nil;
    NSString *path=[DevicePath stringByAppendingFormat:@"/%@/delete",deviceID];
    if(!link||![a[@"id"]isEqual:alertID]||![button[@"httpMethod"]isEqual:@"POST"]||![button[@"destructive"]isEqual:@"true"]||!Origin(url,origin)||![url.path isEqual:path]){*error=TVAppleError(TVAppleErrorUnsupported,@"Native device removal confirmation does not match its target.");return nil;}
    TVAppleDeviceButton *element=[TVAppleDeviceButton new];element.attributes=button;return TVAppleEmailPostbackRequest(model,element,@{},origin,path,error);
}
static NSDictionary *Result(NSArray *records,NSString *target){NSMutableArray *public=[NSMutableArray new];for(NSDictionary *d in records)[public addObject:d[@"info"]];return @{@"apple_id":target,@"devices":public,@"source":@"native_settings_server"};}
@implementation TVAppleNativeSettingsSession(ICloudDevices)
- (NSArray *)readDeviceRecords:(NSError **)error{
    Class bag=NSClassFromString(@"AKURLBag");if(!Has(bag,@[@"sharedBag"])){*error=TVAppleError(TVAppleErrorUnsupported,@"Native devices URL bag is unavailable.");return nil;}
    id owner=[bag sharedBag];NSURL *url=Has(owner,@[@"trustedDevicesURL"])?[owner trustedDevicesURL]:nil;
    if(!Origin(url,[self origin])||![url.path isEqual:DevicePath]){*error=TVAppleError(TVAppleErrorUnsupported,@"Native device list origin or route is unavailable.");return nil;}
    id list=[self get:url.absoluteString error:error];if(!list)return nil;NSArray *links=TVAppleDeviceLinks(list,[self origin],error);if(!links)return nil;
    NSMutableArray *records=[NSMutableArray new],*infos=[NSMutableArray new];
    for(NSDictionary *link in links){id model=[self get:link[@"detail_url"]error:error];if(!model)return nil;NSDictionary *info=TVAppleDeviceInfo(model,link[@"device_id"],error);if(!info)return nil;[infos addObject:info];[records addObject:@{@"info":info,@"model":model}];}
    if(!TVAppleCurrentDeviceID(infos,error)||![self identityMatches:error])return nil;return records;
}
- (NSDictionary *)queryICloudDevices:(NSString *)appleID error:(NSError **)error{@synchronized(self){NSDictionary *result=nil;if([self beginSettingsOperation:appleID error:error]){NSArray *records=[self readDeviceRecords:error];if(records)result=Result(records,appleID);}[self finishSettingsOperation];return result;}}
- (NSDictionary *)removeOtherICloudDevices:(NSString *)appleID error:(NSError **)error{@synchronized(self){NSDictionary *result=[self removeOtherDevicesUnlocked:appleID error:error];[self finishSettingsOperation];return result;}}
- (NSDictionary *)removeOtherDevicesUnlocked:(NSString *)appleID error:(NSError **)error{
    if(![self beginSettingsOperation:appleID error:error])return nil;NSArray *records=[self readDeviceRecords:error];if(!records)return nil;
    NSString *current=TVAppleCurrentDeviceID([records valueForKey:@"info"],error);if(!current)return nil;NSMutableArray *targets=[NSMutableArray new];
    for(NSDictionary *record in records)if(![record[@"info"][@"current_device"]boolValue]){
        NSString *identifier=record[@"info"][@"device_id"];NSMutableURLRequest *request=TVAppleDeviceRemovalRequest(record[@"model"],identifier,[self origin],error);if(!request)return nil;
        [targets addObject:@{@"device_id":identifier,@"request":request}];
    }
    NSMutableArray *removed=[NSMutableArray new];
    for(NSDictionary *target in targets){
        // Refresh and bind the action just before every write. Do not use an old
        // prepared form after another device removal changed server state.
        NSArray *fresh=[self readDeviceRecords:error];if(!fresh||![TVAppleCurrentDeviceID([fresh valueForKey:@"info"],error)isEqual:current])goto unknown;
        NSDictionary *matched=nil;for(NSDictionary *record in fresh)if([record[@"info"][@"device_id"]isEqual:target[@"device_id"]])matched=record;
        if(!matched)continue;
        NSMutableURLRequest *request=TVAppleDeviceRemovalRequest(matched[@"model"],target[@"device_id"],[self origin],error);if(!request){if(!removed.count)return nil;goto unknown;}
        if(![self load:request mutation:YES error:error])goto unknown;
        [removed addObject:target[@"device_id"]];
    }
    *error=nil;return @{@"outcome":@"succeeded",@"already_removed":@(targets.count==0),@"removed_device_ids":removed};
unknown:*error=TVAppleError(TVAppleErrorOutcomeUnknown,@"Non-current device removal did not complete.");return @{@"outcome":@"unknown",@"removed_device_ids":removed};
}
@end
@implementation TVAppleServices(ICloudDevices)
- (void)queryICloudDevices:(NSString *)appleID completion:(TVAppleCompletion)completion{[self enqueueICloudDevices:appleID mutation:NO completion:completion];}
- (void)removeOtherICloudDevices:(NSString *)appleID completion:(TVAppleCompletion)completion{[self enqueueICloudDevices:appleID mutation:YES completion:completion];}
@end
