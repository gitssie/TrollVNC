#import "../include/TVAppStateServices.h"
#import "TVASShadowBridge.h"
#import <CommonCrypto/CommonDigest.h>
static NSString *Hash(NSData *data) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];CC_SHA256(data.bytes,(CC_LONG)data.length,digest);
    NSMutableString *s=[NSMutableString new];for(NSUInteger i=0;i<sizeof(digest);i++)[s appendFormat:@"%02x",digest[i]];return s;
}
static NSDictionary *FailCode(NSError **error,NSString *code,NSString *message) {
    if(error)*error=[NSError errorWithDomain:@"TVASShadowWrite" code:1 userInfo:@{@"errorCode":code,NSLocalizedDescriptionKey:message}];return nil;
}
static NSDictionary *Fail(NSError **error,NSString *message) {return FailCode(error,@"invalid_request",message);}
// Transport staging only. Shadow validates and publishes the complete pair.
NSDictionary *TVASWriteShadowPart(NSString *root,NSDictionary *params,NSError **error) {
    (void)root;if(error)*error=nil;
    if(![params isKindOfClass:NSDictionary.class])return Fail(error,@"Invalid transfer request");
    static NSMutableDictionary *transfer;static NSObject *gate;static dispatch_once_t once;
    dispatch_once(&once,^{gate=[NSObject new];});
    @synchronized(gate) {
        NSString *bundle=params[@"bundle_id"],*backup=params[@"backup_id"],*part=params[@"part"],*identifier=params[@"transfer_id"];
        if(!TVASRequest(@"profile",@{@"bundle_id":bundle?:@"",@"backup_id":backup?:@""},NULL) || ![@[@"state",@"manifest"]containsObject:part] || ![identifier isKindOfClass:NSString.class] || ![identifier isEqual:[[NSUUID alloc]initWithUUIDString:identifier].UUIDString])return Fail(error,@"Invalid transfer target");
        for(id key in params)if(![@[@"bundle_id",@"backup_id",@"part",@"transfer_id",@"offset",@"total",@"sha256",@"data_sha256",@"data"]containsObject:key])return Fail(error,@"Invalid transfer field");
        id ov=params[@"offset"],tv=params[@"total"];
        if(![ov isKindOfClass:NSNumber.class] || ![tv isKindOfClass:NSNumber.class] || [ov doubleValue]!=[ov longLongValue] || [tv doubleValue]!=[tv longLongValue])return Fail(error,@"Invalid transfer length");
        long long offset=[ov longLongValue],total=[tv longLongValue],maximum=[part isEqual:@"state"]?64LL*1024*1024:16LL*1024*1024;
        if(offset<0 || total<=0 || total>maximum || offset>=total || ![params[@"data"]isKindOfClass:NSString.class] || [params[@"data"]length]>350000)return Fail(error,@"Invalid transfer size");
        NSData *chunk=[[NSData alloc]initWithBase64EncodedString:params[@"data"] options:0];
        if(!chunk.length || chunk.length>256*1024 || offset+(long long)chunk.length>total)return Fail(error,@"Invalid transfer chunk");
        double now=NSProcessInfo.processInfo.systemUptime;
        if(transfer && now-[transfer[@"time"]doubleValue]>600)transfer=nil;
        NSString *key=[NSString stringWithFormat:@"%@/%@/%@",bundle,backup,identifier];
        if(!transfer) {
            if(offset || ![part isEqual:@"state"])return Fail(error,@"Start with state offset zero");
            NSDictionary *original=TVASInvokeShadow(@"exportState",bundle,@{@"idfv":[backup substringFromIndex:9],@"part":@"manifest"},error);
            if(!original)return nil;
            if(![original[@"dataSHA"]isEqual:params[@"data_sha256"]])return FailCode(error,@"snapshot_changed",@"Snapshot data changed");
            transfer=[@{@"key":key,@"baseline":original[@"manifestSHA"],@"dataSHA":params[@"data_sha256"],@"time":@(now)}mutableCopy];
        }
        if(![transfer[@"key"]isEqual:key]){if(error)*error=[NSError errorWithDomain:@"TVASShadowWrite" code:1 userInfo:@{@"errorCode":@"busy",NSLocalizedDescriptionKey:@"Another transfer is staged"}];return nil;};
        if(![transfer[@"dataSHA"]isEqual:params[@"data_sha256"]])return FailCode(error,@"snapshot_changed",@"Transfer data identity changed");
        if([part isEqual:@"manifest"] && !transfer[@"stateComplete"])return Fail(error,@"Complete state first");
        NSString *infoKey=[part stringByAppendingString:@"Info"];
        NSDictionary *info=@{@"total":@(total),@"sha":params[@"sha256"]?:@""};
        NSMutableData *bytes=transfer[part];
        if(!bytes){if(offset)return Fail(error,@"Transfer offset mismatch");bytes=[NSMutableData new];transfer[part]=bytes;transfer[infoKey]=info;}
        if(![transfer[infoKey]isEqual:info] || bytes.length!=(NSUInteger)offset)return Fail(error,@"Transfer offset or metadata changed");
        [bytes appendData:chunk];transfer[@"time"]=@(now);
        BOOL complete=bytes.length==(NSUInteger)total;
        if(complete) {
            if(![Hash(bytes)isEqual:params[@"sha256"]]){transfer=nil;return FailCode(error,@"invalid_archive",@"Transfer checksum mismatch");}
            if([part isEqual:@"state"])transfer[@"stateComplete"]=@YES;
            else {
                NSDictionary *result=TVASInvokeShadow(@"importState",bundle,@{@"idfv":[backup substringFromIndex:9],@"manifest":bytes,@"state":transfer[@"state"],@"expectedManifestSHA":transfer[@"baseline"]},error);
                transfer=nil;if(!result)return nil;
            }
        }
        return @{@"ok":@YES,@"complete":@(complete),@"received":@(offset+chunk.length)};
    }
}
