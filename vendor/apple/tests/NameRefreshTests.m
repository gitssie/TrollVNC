#import "TVAppleNameSettings.h"
#include <assert.h>
@interface NAccount:NSObject
@property NSString *username,*identifier,*givenName,*familyName;
@end
@implementation NAccount @end
@interface NManager:NSObject
@property NAccount *phone,*cloud;
@end
@implementation NManager
- (id)primaryAuthKitAccount{return self.phone;}
- (id)primaryiCloudAccount{return self.cloud;}
- (NSString *)altDSIDForAccount:(id)a{assert(a==self.phone);return @"fixture-alt";}
- (NSString *)givenNameForAccount:(NAccount *)a{return a.givenName;}
- (NSString *)familyNameForAccount:(NAccount *)a{return a.familyName;}
@end
@interface NController:NSObject
@property NManager *manager;@property NSUInteger fetches,gets;
@property NSString *scenario;@property(copy)void(^late)(id,NSError *);
@end
@implementation NController
- (void)fetchUserInformationForAltDSID:(NSString *)alt completion:(void(^)(id,NSError *))reply{assert([alt isEqual:@"fixture-alt"]);self.fetches++;
 if([self.scenario isEqual:@"timeout"]){self.late=reply;return;}
 if([self.scenario isEqual:@"failure"]){reply(nil,[NSError errorWithDomain:@"native"code:1 userInfo:nil]);return;}
 if([self.scenario isEqual:@"wrong_server"]){reply(@{@"firstName":@"Alex",@"lastName":@"Morgan",@"accountName":@"other@example.com"},nil);return;}
 if([self.scenario isEqual:@"malformed"]){reply(@{@"firstName":@"Alex"},nil);return;}
 if([self.scenario isEqual:@"changed"]){self.manager.phone.identifier=@"new-account";}
 if(![self.scenario isEqual:@"stale"]){self.manager.phone.givenName=@"Alex";self.manager.phone.familyName=@"Morgan";self.manager.cloud.givenName=@"Alex";self.manager.cloud.familyName=@"Morgan";}
 reply(@{@"firstName":@"Alex",@"lastName":@"Morgan",@"accountName":@"test@example.com"},nil);
 reply(@{@"firstName":@"Old",@"lastName":@"Ignored"},nil); // duplicate must not replace accepted response
}
- (void)getUserInformationForAltDSID:(NSString *)alt completion:(void(^)(id,NSError *))reply{assert([alt isEqual:@"fixture-alt"]);self.gets++;
 if([self.scenario isEqual:@"cached_timeout"]){self.late=reply;return;}
 if([self.scenario isEqual:@"cached_changed"])self.manager.phone.identifier=@"changed-on-get";
 NAccount *info=[NAccount new];info.givenName=([self.scenario isEqual:@"stale_cache"]||([self.scenario isEqual:@"delayed"]&&self.gets==1))?@"Old":self.manager.phone.givenName;info.familyName=self.manager.phone.familyName;reply(info,nil);}
@end
static NAccount *Account(NSString *identifier){NAccount *a=[NAccount new];a.username=@"test@example.com";a.identifier=identifier;a.givenName=@"Old";a.familyName=@"Name";return a;}
int main(void){@autoreleasepool{
 for(NSString *scenario in @[@"success",@"delayed",@"cached_timeout",@"cached_changed",@"stale",@"stale_cache",@"failure",@"timeout",@"wrong_server",@"malformed",@"changed"]){NManager *m=[NManager new];m.phone=Account(@"phone");m.cloud=Account(@"cloud");NController *c=[NController new];c.manager=m;c.scenario=scenario;NSError *e=nil;BOOL ok=TVAppleRefreshAuthKitName(m,c,@"test@example.com",@"Alex",@"Morgan",[scenario isEqual:@"delayed"]?.3:.03,&e);assert(c.fetches==1);if([scenario isEqual:@"success"]||[scenario isEqual:@"delayed"]){assert(ok&&!e&&c.gets==([scenario isEqual:@"delayed"]?2:1)&&[m.phone.givenName isEqual:@"Alex"]&&[m.cloud.familyName isEqual:@"Morgan"]);}else assert(!ok&&e);if(c.late)c.late(@{@"firstName":@"Alex",@"lastName":@"Morgan"},nil);}
 NManager *m=[NManager new];m.phone=Account(@"phone");m.cloud=Account(@"cloud");m.cloud.username=@"different@example.com";NController *c=[NController new];c.manager=m;NSError *e=nil;assert(!TVAppleRefreshAuthKitName(m,c,@"test@example.com",@"Alex",@"Morgan",.03,&e)&&c.fetches==0);puts("PASS native name refresh: fresh before cached, both identities, stale/malformed/error/timeout/duplicate/late boundaries");return 0;
}}
