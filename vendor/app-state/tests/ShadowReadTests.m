#import "../include/TVAppStateServices.h"
#include <sys/stat.h>
#include <unistd.h>
#define CHECK(x) do{if(!(x)){fprintf(stderr,"Shadow read test failed at %d\n",__LINE__);return 1;}}while(0)
int main(void){@autoreleasepool {
    NSString *root=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    NSString *bundle=@"test.app",*idfv=@"C65D96D4-7BD2-4FFF-BF95-0CB2930CAB53";
    NSString *app=[root stringByAppendingPathComponent:bundle],*snapshot=[[app stringByAppendingPathComponent:@"snapshots"]stringByAppendingPathComponent:idfv];
    CHECK([NSFileManager.defaultManager createDirectoryAtPath:snapshot withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:NULL]);
    CHECK([NSData.data writeToFile:[app stringByAppendingPathComponent:@".lock"] atomically:YES]);
    NSString *sha=[@"a" stringByPaddingToLength:64 withString:@"a" startingAtIndex:0];
    NSDictionary *manifest=@{@"format":@"ShadowAppState2",@"bundleID":bundle,@"idfv":idfv,@"stateArchiveInfo":@{@"sha256":sha}};
    CHECK([manifest writeToFile:[snapshot stringByAppendingPathComponent:@"manifest.plist"] atomically:YES]);
    NSData *archive=[@"opaque compressed bytes" dataUsingEncoding:NSUTF8StringEncoding];
    NSString *archivePath=[snapshot stringByAppendingPathComponent:@"state.tar.zst"];
    CHECK([archive writeToFile:archivePath atomically:YES]);
    NSDictionary *params=@{@"bundle_id":bundle,@"backup_id":[@"snapshot:" stringByAppendingString:idfv],@"part":@"manifest"};
    NSError *error=nil;NSData *data=TVASReadShadowPart(root,params,&error);
    CHECK(data && !error);
    CHECK(([[NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:NULL] isEqual:manifest]));
    NSMutableDictionary *request=[params mutableCopy];request[@"part"]=@"state";request[@"state_sha256"]=sha;
    CHECK([TVASReadShadowPart(root,request,&error)isEqual:archive]);
    request[@"state_sha256"]=@"wrong";CHECK(!TVASReadShadowPart(root,request,&error));
    request[@"state_sha256"]=sha;request[@"part"]=@"../state";CHECK(!TVASReadShadowPart(root,request,&error));
    request[@"part"]=@"state";request[@"backup_id"]=@"snapshot:../../outside";CHECK(!TVASReadShadowPart(root,request,&error));
    request[@"backup_id"]=params[@"backup_id"];
    CHECK(unlink(archivePath.fileSystemRepresentation)==0);CHECK(symlink("/etc/hosts",archivePath.fileSystemRepresentation)==0);
    CHECK(!TVASReadShadowPart(root,request,&error));
    CHECK(unlink(archivePath.fileSystemRepresentation)==0);CHECK(mkfifo(archivePath.fileSystemRepresentation,0600)==0);
    CHECK(!TVASReadShadowPart(root,request,&error));
    NSString *lock=[app stringByAppendingPathComponent:@".lock"];
    CHECK(unlink(lock.fileSystemRepresentation)==0);CHECK(mkfifo(lock.fileSystemRepresentation,0600)==0);
    CHECK(!TVASReadShadowPart(root,params,&error));
    CHECK([NSFileManager.defaultManager removeItemAtPath:root error:NULL]);
    puts("Shadow raw manifest/state download, source matching and read-only path tests PASS");
}return 0;}
