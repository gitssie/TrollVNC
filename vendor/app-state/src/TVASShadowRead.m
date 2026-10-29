#import "../include/TVAppStateServices.h"
#include <sys/stat.h>
#include <sys/file.h>
#include <fcntl.h>
#include <unistd.h>
static NSData *Fail(NSError **error,NSString *message) {
    if(error)*error=[NSError errorWithDomain:@"TVASShadowRead" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];return nil;
}
static NSData *Read(int parent,NSString *name,off_t maximum,NSError **error) {
    int fd=openat(parent,name.fileSystemRepresentation,O_RDONLY|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC);
    if(fd<0)return Fail(error,@"Shadow state 文件不可读取");
    NSData *result=nil;
    @try {
        struct stat before,after;
        if(fstat(fd,&before) || !S_ISREG(before.st_mode) || before.st_nlink!=1 || before.st_size<0 || before.st_size>maximum)return Fail(error,@"Shadow state 文件类型或大小无效");
        NSMutableData *data=[NSMutableData dataWithLength:(NSUInteger)before.st_size];NSUInteger offset=0;
        while(offset<data.length) {
            ssize_t n=read(fd,(char *)data.mutableBytes+offset,data.length-offset);
            if(n<0 && errno==EINTR)continue;
            if(n<=0)return Fail(error,@"Shadow state 文件读取失败");offset+=(NSUInteger)n;
        }
        if(fstat(fd,&after) || before.st_size!=after.st_size || before.st_mtimespec.tv_sec!=after.st_mtimespec.tv_sec || before.st_mtimespec.tv_nsec!=after.st_mtimespec.tv_nsec)return Fail(error,@"Shadow state 在读取期间改变");
        result=data;
    } @finally {close(fd);}
    return result;
}
NSData *TVASReadShadowPart(NSString *root,NSDictionary *params,NSError **error) {
    if(error)*error=nil;
    if(![params isKindOfClass:NSDictionary.class] || ![root isKindOfClass:NSString.class])return Fail(error,@"state 请求无效");
    for(id key in params)if(![@[@"bundle_id",@"backup_id",@"part",@"state_sha256"]containsObject:key])return Fail(error,@"state 请求字段无效");
    NSString *bundle=params[@"bundle_id"],*backup=params[@"backup_id"],*part=params[@"part"];
    if(!TVASRequest(@"profile",@{@"bundle_id":bundle?:@"",@"backup_id":backup?:@""},NULL) || ![@[@"manifest",@"state"]containsObject:part])return Fail(error,@"state 备份选择无效");
    NSString *idfv=[backup substringFromIndex:@"snapshot:".length];
    if(![idfv isEqual:[[NSUUID alloc]initWithUUIDString:idfv].UUIDString])return Fail(error,@"state IDFV 无效");
    int rootFD=-1,appFD=-1,snapshotsFD=-1,snapshotFD=-1,lockFD=-1;NSData *result=nil;
    @try {
        rootFD=open(root.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
        if(rootFD<0)return Fail(error,@"Shadow 备份目录不可读取");
        appFD=openat(rootFD,bundle.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
        if(appFD<0)return Fail(error,@"Shadow App 目录不可读取");
        lockFD=openat(appFD,".lock",O_RDONLY|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC);
        struct stat lockInfo;
        if(lockFD<0 || fstat(lockFD,&lockInfo) || !S_ISREG(lockInfo.st_mode) || lockInfo.st_nlink!=1 || flock(lockFD,LOCK_SH|LOCK_NB))return Fail(error,@"Shadow 正在使用此备份");
        snapshotsFD=openat(appFD,"snapshots",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
        if(snapshotsFD<0)return Fail(error,@"Shadow 快照目录不可读取");
        snapshotFD=openat(snapshotsFD,idfv.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
        if(snapshotFD<0)return Fail(error,@"Shadow 快照不可读取");
        NSData *manifest=Read(snapshotFD,@"manifest.plist",16*1024*1024,error);if(!manifest)return nil;
        id value=[NSPropertyListSerialization propertyListWithData:manifest options:NSPropertyListImmutable format:NULL error:NULL];
        if(![value isKindOfClass:NSDictionary.class] || ![value[@"format"]isEqual:@"ShadowAppState2"] || ![value[@"bundleID"]isEqual:bundle] || ![value[@"idfv"]isEqual:idfv])return Fail(error,@"Shadow state 格式或身份不匹配");
        if([part isEqual:@"manifest"])result=manifest;
        else {
            id expected=params[@"state_sha256"];
            if(![expected isKindOfClass:NSString.class] || ![expected length] || ![expected isEqual:value[@"stateArchiveInfo"][@"sha256"]])return Fail(error,@"Shadow state 已改变，请重新读取清单");
            result=Read(snapshotFD,@"state.tar.zst",64*1024*1024,error);
        }
    } @finally {
        if(snapshotFD>=0)close(snapshotFD);if(snapshotsFD>=0)close(snapshotsFD);
        if(lockFD>=0){flock(lockFD,LOCK_UN);close(lockFD);}if(appFD>=0)close(appFD);if(rootFD>=0)close(rootFD);
    }
    return result;
}
