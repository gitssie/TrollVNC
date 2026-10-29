#import "../include/TVAppStateServices.h"
#import <CommonCrypto/CommonDigest.h>
#include <sys/stat.h>
#include <unistd.h>
#define CHECK(x) do{if(!(x)){fprintf(stderr,"Shadow write test failed at %d\n",__LINE__);return 1;}}while(0)
static NSString *SHA(NSData *data){unsigned char bytes[CC_SHA256_DIGEST_LENGTH];CC_SHA256(data.bytes,(CC_LONG)data.length,bytes);NSMutableString *s=[NSMutableString new];for(NSUInteger i=0;i<sizeof(bytes);i++)[s appendFormat:@"%02x",bytes[i]];return s;}
int main(void){@autoreleasepool {
    NSString *root=[NSTemporaryDirectory()stringByAppendingPathComponent:NSUUID.UUID.UUIDString],*bundle=@"test.app",*idfv=@"C65D96D4-7BD2-4FFF-BF95-0CB2930CAB53";
    NSString *app=[root stringByAppendingPathComponent:bundle],*snapshot=[[app stringByAppendingPathComponent:@"snapshots"]stringByAppendingPathComponent:idfv];
    CHECK([NSFileManager.defaultManager createDirectoryAtPath:snapshot withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:NULL]);
    CHECK([NSData.data writeToFile:[app stringByAppendingPathComponent:@".lock"] atomically:YES]);
    NSData *old=[@"old state"dataUsingEncoding:NSUTF8StringEncoding],*new=[@"updated state containing credentials"dataUsingEncoding:NSUTF8StringEncoding],*data=[@"application data must stay unchanged"dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *archiveInfo=@{@"sha256":SHA(data)};
    NSDictionary *manifest=@{@"format":@"ShadowAppState2",@"bundleID":bundle,@"idfv":idfv,@"archiveInfo":archiveInfo,@"stateArchiveInfo":@{@"sha256":SHA(old),@"archiveSize":@(old.length)}};
    NSString *statePath=[snapshot stringByAppendingPathComponent:@"state.tar.zst"],*manifestPath=[snapshot stringByAppendingPathComponent:@"manifest.plist"],*dataPath=[snapshot stringByAppendingPathComponent:@"data.tar.zst"];
    CHECK([manifest writeToFile:manifestPath atomically:YES] && [old writeToFile:statePath atomically:YES] && [data writeToFile:dataPath atomically:YES]);
    NSString *transfer=NSUUID.UUID.UUIDString;
    NSMutableDictionary *request=[@{@"bundle_id":bundle,@"backup_id":[@"snapshot:"stringByAppendingString:idfv],@"part":@"state",@"transfer_id":transfer,@"offset":@0,@"total":@(new.length),@"sha256":SHA(new),@"data_sha256":SHA(data),@"data":[[new subdataWithRange:NSMakeRange(0,5)]base64EncodedStringWithOptions:0]}mutableCopy];
    NSError *error=nil;NSDictionary *reply=TVASWriteShadowPart(root,request,&error);
    CHECK(reply && !error && ![reply[@"complete"]boolValue]);
    CHECK([[NSData dataWithContentsOfFile:statePath]isEqual:old]);
    request[@"offset"]=@4;CHECK(!TVASWriteShadowPart(root,request,&error));
    request[@"offset"]=@5;request[@"data"]=[[new subdataWithRange:NSMakeRange(5,new.length-5)]base64EncodedStringWithOptions:0];
    CHECK([TVASWriteShadowPart(root,request,&error)[@"complete"]boolValue]);
    CHECK([[NSData dataWithContentsOfFile:statePath]isEqual:new]);
    CHECK([[NSDictionary dictionaryWithContentsOfFile:manifestPath][@"stateArchiveInfo"]isEqual:manifest[@"stateArchiveInfo"]]);
    NSMutableDictionary *updated=[manifest mutableCopy];updated[@"stateArchiveInfo"]=@{@"sha256":SHA(new),@"archiveSize":@(new.length)};
    NSData *encoded=[NSPropertyListSerialization dataWithPropertyList:updated format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
    request[@"part"]=@"manifest";request[@"offset"]=@0;request[@"total"]=@(encoded.length);request[@"sha256"]=SHA(encoded);request[@"data"]=[encoded base64EncodedStringWithOptions:0];
    CHECK([TVASWriteShadowPart(root,request,&error)[@"complete"]boolValue]);
    NSDictionary *selection=@{@"bundle_id":bundle,@"backup_id":request[@"backup_id"],@"part":@"manifest"};
    CHECK([TVASReadShadowPart(root,selection,&error)isEqual:encoded]);
    CHECK([TVASReadShadowPart(root,@{@"bundle_id":bundle,@"backup_id":request[@"backup_id"],@"part":@"state",@"state_sha256":SHA(new)},&error)isEqual:new]);
    CHECK([[NSData dataWithContentsOfFile:dataPath]isEqual:data]);
    struct stat snapshotInfo,stateInfo,manifestInfo;
    CHECK(!stat(snapshot.fileSystemRepresentation,&snapshotInfo) && !stat(statePath.fileSystemRepresentation,&stateInfo) && !stat(manifestPath.fileSystemRepresentation,&manifestInfo));
    CHECK(stateInfo.st_uid==snapshotInfo.st_uid && stateInfo.st_gid==snapshotInfo.st_gid && (stateInfo.st_mode&0777)==0600);
    CHECK(manifestInfo.st_uid==snapshotInfo.st_uid && manifestInfo.st_gid==snapshotInfo.st_gid && (manifestInfo.st_mode&0777)==0600);
    request[@"data_sha256"]=[@"f"stringByPaddingToLength:64 withString:@"f"startingAtIndex:0];CHECK(!TVASWriteShadowPart(root,request,&error));
    request[@"data_sha256"]=SHA(data);
    request[@"part"]=@"../state";CHECK(!TVASWriteShadowPart(root,request,&error));
    request[@"part"]=@"manifest";request[@"backup_id"]=@"snapshot:../../outside";CHECK(!TVASWriteShadowPart(root,request,&error));
    request[@"backup_id"]=selection[@"backup_id"];request[@"sha256"]=[@"0"stringByPaddingToLength:64 withString:@"0"startingAtIndex:0];CHECK(!TVASWriteShadowPart(root,request,&error));
    CHECK([[NSData dataWithContentsOfFile:manifestPath]isEqual:encoded]);
    NSMutableDictionary *malformed=[updated mutableCopy];malformed[@"stateArchiveInfo"]=@"invalid";
    NSData *bad=[NSPropertyListSerialization dataWithPropertyList:malformed format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
    request[@"sha256"]=SHA(bad);request[@"total"]=@(bad.length);request[@"data"]=[bad base64EncodedStringWithOptions:0];
    CHECK(!TVASWriteShadowPart(root,request,&error));
    CHECK([[NSData dataWithContentsOfFile:manifestPath]isEqual:encoded]);
    CHECK([NSFileManager.defaultManager removeItemAtPath:root error:NULL]);
    puts("Sequential Shadow state/manifest write, readback, invalid chunk/hash/target and data preservation PASS");
}return 0;}
