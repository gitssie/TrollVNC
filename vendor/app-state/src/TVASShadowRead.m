#import "../include/TVAppStateServices.h"
#import "TVASShadowBridge.h"
NSData *TVASReadShadowPart(NSString *root,NSDictionary *params,NSError **error) {
    (void)root;if(error)*error=nil;
    if(![params isKindOfClass:NSDictionary.class])return nil;
    for(id key in params)if(![@[@"bundle_id",@"backup_id",@"part",@"state_sha256"]containsObject:key])return nil;
    NSString *bundle=params[@"bundle_id"],*backup=params[@"backup_id"],*part=params[@"part"];
    if(!TVASRequest(@"profile",@{@"bundle_id":bundle?:@"",@"backup_id":backup?:@""},error) || ![@[@"manifest",@"state"]containsObject:part])return nil;
    NSMutableDictionary *request=[@{@"idfv":[backup substringFromIndex:9],@"part":part}mutableCopy];
    if(params[@"state_sha256"])request[@"stateSHA"]=params[@"state_sha256"];
    return TVASInvokeShadow(@"exportState",bundle,request,error)[@"data"];
}
