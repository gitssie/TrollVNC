#import "TVAppleSignInWithApple.h"
#import "TVAppleEmailActions.h"
#import <objc/runtime.h>
@interface NSObject (TVAppleSIWASelectors)
- (id)allPages;
- (id)tableViewOM;
- (id)sections;
- (id)rows;
- (id)attributes;
- (id)subElementWithID:(NSString *)identifier;
@end
static BOOL SIWASupports(id object,NSArray *selectors){
    if(!object)return NO;for(NSString *selector in selectors)if(![object respondsToSelector:NSSelectorFromString(selector)])return NO;return YES;
}
static BOOL SIWAOrigin(NSURL *url,NSURL *origin){
    return [url.scheme.lowercaseString isEqual:@"https"]&&!url.user&&!url.password&&[url.host.lowercaseString isEqual:origin.host.lowercaseString]&&[(url.port?:@443)isEqual:origin.port?:@443];
}
BOOL TVAppleValidBundleID(id value){
    if(![value isKindOfClass:NSString.class]||![value length]||[value length]>255)return NO;
    if([value rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-"]invertedSet]].location!=NSNotFound)return NO;
    NSArray *parts=[value componentsSeparatedByString:@"."];if(parts.count<2)return NO;
    for(NSString *part in parts)if(!part.length)return NO;return YES;
}
NSArray *TVAppleSIWAApplications(id model,NSURL *origin,NSError **error){
    if(!SIWASupports(model,@[@"allPages"])||![[model allPages]isKindOfClass:NSArray.class]||[[model allPages]count]!=1){
        *error=TVAppleError(TVAppleErrorUnsupported,@"Native connected application list is unavailable.");return nil;
    }
    NSMutableArray *applications=[NSMutableArray new];NSMutableSet *seen=[NSMutableSet new];BOOL found=NO;
    for(id page in [model allPages]){
        if(!SIWASupports(page,@[@"tableViewOM"]))continue;id table=[page tableViewOM];
        if(!SIWASupports(table,@[@"attributes",@"sections"])||![[table attributes][@"id"]isEqual:@"connectedAppView"]||![[table sections]isKindOfClass:NSArray.class])continue;
        // iOS15 omits connectApplicationSection after the final grant is
        // removed. Accept only the observed single anonymous empty section
        // under the recognized table; missing or unknown pages are errors.
        NSArray *sections=[table sections];
        if(sections.count==1){
            id empty=sections.firstObject;
            if(SIWASupports(empty,@[@"attributes",@"rows"])&&[[empty attributes]isKindOfClass:NSDictionary.class]&&
               [[empty attributes]count]==0&&[[empty rows]isKindOfClass:NSArray.class]&&[[empty rows]count]==0)return @[];
        }
        for(id section in [table sections]){
            if(!SIWASupports(section,@[@"attributes",@"rows"])||![[section attributes][@"id"]isEqual:@"connectApplicationSection"])continue;
            if(found||![[section rows]isKindOfClass:NSArray.class]){*error=TVAppleError(TVAppleErrorUnsupported,@"Connected application section is ambiguous.");return nil;}found=YES;
            for(id row in [section rows]){
                id attrs=SIWASupports(row,@[@"attributes"])?[row attributes]:nil;
                if(![attrs isKindOfClass:NSDictionary.class]){*error=TVAppleError(TVAppleErrorUnsupported,@"Connected application row is unavailable.");return nil;}
                NSString *bundle=attrs[@"id"],*label=attrs[@"label"],*link=attrs[@"url"];
                NSURL *url=[link isKindOfClass:NSString.class]?[NSURL URLWithString:link relativeToURL:origin].absoluteURL:nil;
                NSString *prefix=@"/appleid/settings/account/manage/security/apps/";
                NSString *client=[url.path hasPrefix:prefix]?[url.path substringFromIndex:prefix.length]:nil;
                if(!TVAppleValidBundleID(bundle)||![label isKindOfClass:NSString.class]||!label.length||![attrs[@"class"]isEqual:@"link"]||
                   (attrs[@"httpMethod"]&&![attrs[@"httpMethod"]isEqual:@"GET"])||!SIWAOrigin(url,origin)||url.fragment||
                   ![client isEqual:[bundle stringByAppendingString:@".app"]]||[seen containsObject:bundle]){
                    *error=TVAppleError(TVAppleErrorUnsupported,@"Connected application identifiers or detail route have changed.");return nil;
                }
                [seen addObject:bundle];[applications addObject:@{@"bundle_id":bundle,@"client_id":client,@"name":label,@"detail_url":url.absoluteString}];
            }
        }
    }
    if(!found){*error=TVAppleError(TVAppleErrorUnsupported,@"Connected application list structure was not recognized.");return nil;}
    return applications;
}
static NSDictionary *SIWAResult(NSArray *applications,NSString *appleID){
    NSMutableArray *apps=[NSMutableArray new],*bundles=[NSMutableArray new];
    for(NSDictionary *app in applications){[apps addObject:@{@"bundle_id":app[@"bundle_id"],@"client_id":app[@"client_id"],@"name":app[@"name"]}];[bundles addObject:app[@"bundle_id"]];}
    return @{@"apple_id":appleID,@"apps":apps,@"bundle_ids":bundles,@"source":@"native_settings_server"};
}
static char SIWAConfirmationKey;
@interface TVAppleSIWAConfirmationParser:NSObject<NSXMLParserDelegate>
@property NSUInteger depth,alertDepth,alerts,cancels;
@property NSString *preferredButton;
@property NSMutableArray *buttons;
@end
@implementation TVAppleSIWAConfirmationParser
- (void)parser:(NSXMLParser *)parser didStartElement:(NSString *)element namespaceURI:(NSString *)uri qualifiedName:(NSString *)qualified attributes:(NSDictionary *)attrs{
    (void)parser;(void)uri;(void)qualified;self.depth++;
    if([element isEqual:@"alert"]&&[attrs[@"id"]isEqual:@"revokeConnectedApp"]){self.alerts++;self.alertDepth=self.depth;self.preferredButton=attrs[@"preferredButton"];}
    else if(self.alertDepth&&self.depth==self.alertDepth+1){
        if([element isEqual:@"button"]){
            NSMutableDictionary *button=[NSMutableDictionary new];
            for(NSString *key in @[@"id",@"url",@"httpMethod",@"destructive"])if(attrs[key])button[key]=attrs[key];
            [self.buttons addObject:button];
        }else if([element isEqual:@"cancelButton"])self.cancels++;
    }
}
- (void)parser:(NSXMLParser *)parser didEndElement:(NSString *)element namespaceURI:(NSString *)uri qualifiedName:(NSString *)qualified{
    (void)parser;(void)element;(void)uri;(void)qualified;if(self.depth==self.alertDepth)self.alertDepth=0;if(self.depth)self.depth--;
}
@end
NSDictionary *TVAppleSIWAConfirmationFromXML(NSData *xml){
    if(![xml isKindOfClass:NSData.class]||!xml.length||xml.length>2*1024*1024)return nil;
    TVAppleSIWAConfirmationParser *observer=[TVAppleSIWAConfirmationParser new];observer.buttons=[NSMutableArray new];
    NSXMLParser *parser=[[NSXMLParser alloc]initWithData:xml];parser.delegate=observer;parser.shouldResolveExternalEntities=NO;
    if(![parser parse]||observer.alerts!=1||observer.buttons.count!=1||observer.cancels!=1||![observer.preferredButton isEqual:@"removeButton"])return nil;
    return observer.buttons.firstObject;
}
void TVAppleAttachSIWAConfirmation(id model,NSDictionary *confirmation){
    objc_setAssociatedObject(model,&SIWAConfirmationKey,[confirmation copy],OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
void TVAppleCaptureSIWAConfirmation(id loader,id model){
    // RUILoader has no public parser getter. Verify the observed ivar and native
    // parser type before KVC; unsupported layouts leave no usable action.
    if(!class_getInstanceVariable([loader class],"_parser"))return;
    id parser=[loader valueForKey:@"parser"];Class native=NSClassFromString(@"RUIParser");
    if(!native||![parser isKindOfClass:native]||![parser respondsToSelector:NSSelectorFromString(@"xmlData")])return;
    NSData *xml=[parser valueForKey:@"xmlData"];NSDictionary *button=TVAppleSIWAConfirmationFromXML(xml);
    if(button)TVAppleAttachSIWAConfirmation(model,button);
}
@interface TVAppleSIWAButton:NSObject
@property NSDictionary *attributes;
@end
@implementation TVAppleSIWAButton
@end
NSMutableURLRequest *TVAppleSIWARevokeRequest(id model,NSDictionary *application,NSURL *origin,NSError **error){
    NSString *bundle=application[@"bundle_id"],*client=application[@"client_id"];
    if(!TVAppleValidBundleID(bundle)||![client isEqual:[bundle stringByAppendingString:@".app"]]||
       !SIWASupports(model,@[@"allPages",@"subElementWithID:"])||![[model allPages]isKindOfClass:NSArray.class]||[[model allPages]count]!=1){
        *error=TVAppleError(TVAppleErrorUnsupported,@"Native revoke application identity is unavailable.");return nil;
    }
    BOOL targetFound=NO,stopFound=NO;
    for(id page in [model allPages]){
        if(!SIWASupports(page,@[@"tableViewOM"]))continue;id table=[page tableViewOM];
        if(!SIWASupports(table,@[@"attributes",@"sections"])||![[table attributes][@"id"]isEqual:@"connectedAppView"]||![[table sections]isKindOfClass:NSArray.class])continue;
        for(id section in [table sections]){
            if(!SIWASupports(section,@[@"attributes",@"rows"])||![[section rows]isKindOfClass:NSArray.class])continue;
            NSString *key=[section attributes][@"id"];
            for(id row in [section rows]){
                NSDictionary *attrs=SIWASupports(row,@[@"attributes"])?[row attributes]:nil;
                if([key isEqual:@"connectApplicationSection"]&&[attrs[@"id"]isEqual:bundle]&&[attrs[@"class"]isEqual:@"label"]){
                    if(targetFound){*error=TVAppleError(TVAppleErrorUnsupported,@"Revoke application identity is ambiguous.");return nil;}targetFound=YES;
                }
                if([key isEqual:@"revokeApp"]&&[attrs[@"class"]isEqual:@"link"]&&[attrs[@"url"]isEqual:@"#revokeConnectedApp"]){
                    if(stopFound){*error=TVAppleError(TVAppleErrorUnsupported,@"Revoke application action is ambiguous.");return nil;}stopFound=YES;
                }
            }
        }
    }
    id alert=[model subElementWithID:@"revokeConnectedApp"];
    NSDictionary *alertAttrs=SIWASupports(alert,@[@"attributes"])?[alert attributes]:nil;
    NSDictionary *button=objc_getAssociatedObject(model,&SIWAConfirmationKey);
    NSURL *url=[button[@"url"]isKindOfClass:NSString.class]?[NSURL URLWithString:button[@"url"]relativeToURL:origin].absoluteURL:nil;
    NSString *path=[@"/appleid/settings/account/manage/security/apps/"stringByAppendingFormat:@"%@/delete",client];
    if(!targetFound||!stopFound||![alertAttrs[@"id"]isEqual:@"revokeConnectedApp"]||![alertAttrs[@"preferredButton"]isEqual:@"removeButton"]||
       ![button[@"id"]isEqual:@"removeButton"]||![button[@"destructive"]isEqual:@"true"]||![button[@"httpMethod"]isEqual:@"POST"]||
       !SIWAOrigin(url,origin)||url.fragment||![url.path isEqual:path]){
        *error=TVAppleError(TVAppleErrorUnsupported,@"Native revoke confirmation does not match the selected application.");return nil;
    }
    TVAppleSIWAButton *element=[TVAppleSIWAButton new];element.attributes=button;
    return TVAppleEmailPostbackRequest(model,element,@{},origin,path,error);
}
@implementation TVAppleNativeSettingsSession (SignInWithApple)
- (NSArray *)readSIWAApps:(NSError **)error{
    id model=[self get:@"/appleid/settings/account/manage/security/apps" error:error];if(!model)return nil;
    NSArray *apps=TVAppleSIWAApplications(model,[self origin],error);
    if(!apps||![self identityMatches:error])return nil;return apps;
}
- (NSDictionary *)querySignInWithAppleApps:(NSString *)appleID error:(NSError **)error{
    @synchronized(self){
        NSDictionary *result=nil;
        if([self beginSettingsOperation:appleID error:error]){NSArray *apps=[self readSIWAApps:error];if(apps)result=SIWAResult(apps,appleID);}
        [self finishSettingsOperation];return result;
    }
}
- (NSDictionary *)stopUsingAppleIDForBundleID:(NSString *)bundleID appleID:(NSString *)appleID error:(NSError **)error{
    @synchronized(self){
        NSDictionary *result=[self stopSIWAUnlocked:bundleID appleID:appleID error:error];[self finishSettingsOperation];return result;
    }
}
- (NSDictionary *)stopSIWAUnlocked:(NSString *)bundleID appleID:(NSString *)appleID error:(NSError **)error{
    if(!TVAppleValidBundleID(bundleID)){*error=TVAppleError(TVAppleErrorInvalidRequest,@"An explicit application bundle ID is required.");return nil;}
    if(![self beginSettingsOperation:appleID error:error])return nil;
    NSArray *before=[self readSIWAApps:error];if(!before)return nil;NSDictionary *target=nil;
    for(NSDictionary *app in before)if([app[@"bundle_id"]isEqual:bundleID])target=app;
    if(!target)return @{@"outcome":@"succeeded",@"already_stopped":@YES,@"bundle_id":bundleID,@"settings":SIWAResult(before,appleID)};
    id model=[self get:target[@"detail_url"]error:error];if(!model)return nil;
    NSMutableURLRequest *post=TVAppleSIWARevokeRequest(model,target,[self origin],error);if(!post)return nil;
    if(![self load:post mutation:YES error:error])return nil;
    NSArray *after=[self readSIWAApps:error];BOOL absent=after!=nil;
    for(NSDictionary *app in after)if([app[@"bundle_id"]isEqual:bundleID])absent=NO;
    if(!absent){*error=TVAppleError(TVAppleErrorOutcomeUnknown,@"Application authorization removal was not confirmed by a fresh server list.");return nil;}
    return @{@"outcome":@"succeeded",@"already_stopped":@NO,@"bundle_id":bundleID,@"settings":SIWAResult(after,appleID)};
}
@end
@implementation TVAppleServices (SignInWithApple)
- (void)querySignInWithAppleApps:(NSString *)appleID completion:(TVAppleCompletion)completion{
    [self enqueueSignInWithApple:appleID bundleID:nil mutation:NO completion:completion];
}
- (void)stopUsingAppleIDForBundleID:(NSString *)bundleID appleID:(NSString *)appleID completion:(TVAppleCompletion)completion{
    [self enqueueSignInWithApple:appleID bundleID:bundleID mutation:YES completion:completion];
}
@end
