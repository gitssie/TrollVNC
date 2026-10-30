#import "../include/TVAppStateServices.h"
#import <CommonCrypto/CommonDigest.h>
static NSUInteger imports;
static BOOL unknown;
static NSString *SHA(NSData *data){unsigned char d[32];CC_SHA256(data.bytes,(CC_LONG)data.length,d);NSMutableString *s=[NSMutableString new];for(int i=0;i<32;i++)[s appendFormat:@"%02x",d[i]];return s;}
NSDictionary *TVASInvokeShadow(NSString *action,NSString *bundle,NSDictionary *request,NSError **error) {
    (void)bundle;(void)error;
    if([action isEqual:@"exportState"])return @{@"manifestSHA":@"baseline",@"dataSHA":@"data"};
    NSCAssert([action isEqual:@"importState"] && [request[@"expectedManifestSHA"]isEqual:@"baseline"],@"commit uses captured revision");
    NSCAssert([request[@"state"]length]==5 && [request[@"manifest"]length]==8,@"both complete parts passed");imports++;if(unknown){if(error)*error=[NSError errorWithDomain:@"Shadow" code:4 userInfo:@{@"outcomeUnknown":@YES}];return nil;}return @{@"imported":@YES};
}
int main(void){@autoreleasepool {
    NSString *transfer=NSUUID.UUID.UUIDString;
    NSMutableDictionary *params=[@{@"bundle_id":@"test.app",@"backup_id":@"snapshot:C65D96D4-7BD2-4FFF-BF95-0CB2930CAB53",@"part":@"state",@"transfer_id":transfer,@"offset":@0,@"total":@5,@"data_sha256":@"data"}mutableCopy];
    NSData *state=[@"state"dataUsingEncoding:NSUTF8StringEncoding];params[@"sha256"]=SHA(state);params[@"data"]=[state base64EncodedStringWithOptions:0];
    NSCAssert([TVASWriteShadowPart(@"ignored",params,NULL)[@"complete"]boolValue] && imports==0,@"state completion only stages");
    NSMutableDictionary *wrong=[params mutableCopy];wrong[@"transfer_id"]=NSUUID.UUID.UUIDString;
    NSCAssert(!TVASWriteShadowPart(@"ignored",wrong,NULL) && imports==0,@"other transfer cannot overwrite staged state");
    NSData *manifest=[@"manifest"dataUsingEncoding:NSUTF8StringEncoding];params[@"part"]=@"manifest";params[@"total"]=@8;params[@"sha256"]=SHA(manifest);params[@"data"]=[manifest base64EncodedStringWithOptions:0];
    NSCAssert([TVASWriteShadowPart(@"ignored",params,NULL)[@"complete"]boolValue] && imports==1,@"manifest completion commits pair once");
    NSCAssert(!TVASWriteShadowPart(@"ignored",params,NULL) && imports==1,@"completed import never automatically replayed");
    params[@"transfer_id"]=NSUUID.UUID.UUIDString;params[@"part"]=@"state";params[@"total"]=@5;params[@"sha256"]=SHA(state);params[@"data"]=[state base64EncodedStringWithOptions:0];
    NSCAssert(TVASWriteShadowPart(@"ignored",params,NULL)!=nil,@"new transfer after completion");
    params[@"part"]=@"manifest";params[@"total"]=@8;params[@"sha256"]=SHA(manifest);params[@"data"]=[manifest base64EncodedStringWithOptions:0];unknown=YES;NSError *error=nil;
    NSCAssert(!TVASWriteShadowPart(@"ignored",params,&error) && [error.userInfo[@"outcomeUnknown"]boolValue] && imports==2,@"uncertain helper completion preserved");
    NSCAssert(!TVASWriteShadowPart(@"ignored",params,NULL) && imports==2,@"uncertain import never replayed");
    puts("PASS Shadow transactional transport staging");
}return 0;}
