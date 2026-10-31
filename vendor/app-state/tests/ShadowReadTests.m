#import "../include/TVAppStateServices.h"
static NSUInteger calls; static NSString *expectedRequester;
NSDictionary *TVASInvokeShadow(NSString *action,NSString *bundle,NSDictionary *request,NSError **error) {
    (void)bundle;(void)error;NSCAssert([action isEqual:@"exportState"],@"export delegation");
    NSCAssert([request[@"idfv"]isEqual:@"C65D96D4-7BD2-4FFF-BF95-0CB2930CAB53"],@"opaque ID mapping");NSCAssert(!expectedRequester || [request[@"requester"]isEqual:expectedRequester],@"requester forwarded");calls++;return @{@"data":[@"payload"dataUsingEncoding:NSUTF8StringEncoding]};
}
int main(void){@autoreleasepool {
    NSDictionary *params=@{@"bundle_id":@"test.app",@"backup_id":@"snapshot:C65D96D4-7BD2-4FFF-BF95-0CB2930CAB53",@"part":@"manifest"};
    NSCAssert(TVASReadShadowPart(@"ignored",params,NULL).length==7 && calls==1,@"helper data forwarded");
    NSCAssert(!TVASReadShadowPart(@"ignored",@{@"bundle_id":@"../escape"},NULL) && calls==1,@"invalid target rejected before helper");
    NSMutableDictionary *rv=[params mutableCopy];rv[@"requester"]=@"rv";expectedRequester=@"rv";
    NSCAssert(TVASReadShadowPart(@"ignored",rv,NULL).length==7 && calls==2,@"RV requester forwarded");
    rv[@"requester"]=@"invalid";NSCAssert(!TVASReadShadowPart(@"ignored",rv,NULL) && calls==2,@"invalid requester rejected");
    puts("PASS Shadow export delegation");
}return 0;}
