#import "SHDWAppStateClient.h"
#import "../src/TVASShadowBridge.h"
static id capability,result;static NSError *failure;
NSDictionary *TVASRuntimePaths(void){return @{@"shadow_helper":@"/fixture/shadow-cleaner"};}
@implementation SHDWAppStateClient
- (instancetype)initWithHelperPath:(NSString *)path {(void)path;return [super init];}
- (id)invokeAction:(NSString *)action bundleIdentifier:(NSString *)bundle request:(NSDictionary *)request progress:(SHDWAppStateClientProgress)progress error:(NSError **)error {
    (void)bundle;(void)request;(void)progress;
    if([action isEqual:@"capabilities"])return capability;
    if(progress)progress(@{@"phase":@"backup",@"stage":@"capture",@"bytes":@4096,@"entries":@2});
    if(error)*error=failure;return result;
}
@end
int main(void){@autoreleasepool {
    NSDictionary *valid=@{@"apiVersion":@1,@"format":@"ShadowAppState2",@"operations":@[@"importState"]};
    capability=valid;result=@{@"imported":@YES};NSError *error=nil;
    NSCAssert(TVASInvokeShadow(@"importState",@"test.app",@{},&error)!=nil && !error,@"compatible helper accepted");
    for(id value in @[@{},@{@"apiVersion":@1,@"format":@"wrong",@"operations":@[@"importState"]},@{@"apiVersion":@1,@"format":@"ShadowAppState2",@"operations":@"invalid"}]) {
        capability=value;error=nil;NSCAssert(!TVASInvokeShadow(@"importState",@"test.app",@{},&error) && error.code==2,@"incompatible helper explicit error");
    }
    capability=valid;result=@[];error=nil;NSCAssert(!TVASInvokeShadow(@"importState",@"test.app",@{},&error) && error.code==3,@"malformed result error");
    result=nil;failure=[NSError errorWithDomain:@"Shadow" code:4 userInfo:@{@"outcomeUnknown":@YES}];error=nil;
    NSCAssert(!TVASInvokeShadow(@"importState",@"test.app",@{},&error) && error==failure && [error.userInfo[@"outcomeUnknown"]boolValue],@"unknown completion propagated unchanged");
    result=@{@"saved":@YES};failure=nil;__block NSUInteger events=0;
    NSCAssert(TVASInvokeShadowWithProgress(@"importState",@"test.app",@{},^(NSDictionary *event){NSCAssert([event[@"entries"]integerValue]==2,@"helper entry progress retained");events++;},&error)!=nil && events==1,@"helper progress forwarded");
    puts("PASS Shadow capability negotiation and helper error propagation");
}return 0;}
