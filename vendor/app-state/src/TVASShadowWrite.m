#import "../include/TVAppStateServices.h"
#import <CommonCrypto/CommonDigest.h>
#include <sys/stat.h>
#include <sys/file.h>
#include <fcntl.h>
#include <unistd.h>

static NSDictionary *WriteFail(NSError **error, NSString *message) {
    if(error)*error=[NSError errorWithDomain:@"TVASShadowWrite" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];
    return nil;
}
static NSString *HashFD(int fd) {
    if(lseek(fd,0,SEEK_SET)<0)return nil;
    CC_SHA256_CTX context;CC_SHA256_Init(&context);unsigned char buffer[65536];
    for(;;){ssize_t count=read(fd,buffer,sizeof(buffer));if(count<0 && errno==EINTR)continue;if(count<0)return nil;if(!count)break;CC_SHA256_Update(&context,buffer,(CC_LONG)count);}
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];CC_SHA256_Final(digest,&context);
    NSMutableString *value=[NSMutableString new];for(NSUInteger i=0;i<sizeof(digest);i++)[value appendFormat:@"%02x",digest[i]];return value;
}
static NSDictionary *ManifestAt(int directory) {
    int fd=openat(directory,"manifest.plist",O_RDONLY|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC);
    if(fd<0)return nil;struct stat info;NSMutableData *bytes=nil;
    if(!fstat(fd,&info) && S_ISREG(info.st_mode) && info.st_nlink==1 && info.st_size>0 && info.st_size<=16*1024*1024){
        bytes=[NSMutableData dataWithLength:(NSUInteger)info.st_size];NSUInteger offset=0;
        while(offset<bytes.length){ssize_t n=read(fd,(char *)bytes.mutableBytes+offset,bytes.length-offset);if(n<0 && errno==EINTR)continue;if(n<=0){bytes=nil;break;}offset+=(NSUInteger)n;}
    }
    close(fd);id value=bytes?[NSPropertyListSerialization propertyListWithData:bytes options:NSPropertyListImmutable format:NULL error:NULL]:nil;
    return [value isKindOfClass:NSDictionary.class]?value:nil;
}
// Each file is written separately. RV reads both files back after publishing the
// manifest; this endpoint never restores live Keychain, preferences or app data.
NSDictionary *TVASWriteShadowPart(NSString *root, NSDictionary *params, NSError **error) {
    if(error)*error=nil;
    if(![params isKindOfClass:NSDictionary.class])return WriteFail(error,@"state 回写请求无效");
    NSArray *keys=@[@"bundle_id",@"backup_id",@"part",@"transfer_id",@"offset",@"total",@"sha256",@"data_sha256",@"data"];
    for(id key in params)if(![keys containsObject:key])return WriteFail(error,@"state 回写字段无效");
    NSString *bundle=params[@"bundle_id"],*backup=params[@"backup_id"],*part=params[@"part"],*transfer=params[@"transfer_id"],*sha=params[@"sha256"];
    if(!TVASRequest(@"profile",@{@"bundle_id":bundle?:@"",@"backup_id":backup?:@""},NULL) || ![@[@"state",@"manifest"]containsObject:part])return WriteFail(error,@"state 回写目标无效");
    NSString *idfv=[backup substringFromIndex:@"snapshot:".length];
    if(![idfv isEqual:[[NSUUID alloc]initWithUUIDString:idfv].UUIDString] || ![transfer isKindOfClass:NSString.class] || ![transfer isEqual:[[NSUUID alloc]initWithUUIDString:transfer].UUIDString])return WriteFail(error,@"state 回写标识无效");
    if(![sha isKindOfClass:NSString.class] || sha.length!=64 || [sha rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"]invertedSet]].location!=NSNotFound)return WriteFail(error,@"state 回写哈希无效");
    id offsetValue=params[@"offset"],totalValue=params[@"total"];
    if(![offsetValue isKindOfClass:NSNumber.class] || ![totalValue isKindOfClass:NSNumber.class] || [offsetValue doubleValue]!=[offsetValue longLongValue] || [totalValue doubleValue]!=[totalValue longLongValue])return WriteFail(error,@"state 回写长度无效");
    long long offset=[offsetValue longLongValue],total=[totalValue longLongValue],maximum=[part isEqual:@"state"]?64LL*1024*1024:16LL*1024*1024;
    if(offset<0 || total<=0 || total>maximum || offset>=total || ![params[@"data"]isKindOfClass:NSString.class] || [params[@"data"]length]>350000)return WriteFail(error,@"state 回写大小无效");
    NSData *data=[[NSData alloc]initWithBase64EncodedString:params[@"data"] options:0];
    if(!data.length || data.length>256*1024 || (unsigned long long)offset+data.length>(unsigned long long)total)return WriteFail(error,@"state 回写数据无效");
    int rootFD=-1,appFD=-1,lockFD=-1,snapshotsFD=-1,snapshotFD=-1,fileFD=-1,stateFD=-1;NSDictionary *result=nil;
    @try {
        rootFD=open(root.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
        if(rootFD<0)return WriteFail(error,@"Shadow 备份目录不可访问");
        appFD=openat(rootFD,bundle.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
        if(appFD<0)return WriteFail(error,@"Shadow App 目录不可访问");
        lockFD=openat(appFD,".lock",O_RDWR|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC);struct stat info;
        if(lockFD<0 || fstat(lockFD,&info) || !S_ISREG(info.st_mode) || info.st_nlink!=1 || flock(lockFD,LOCK_EX|LOCK_NB))return WriteFail(error,@"Shadow 正在使用此备份");
        snapshotsFD=openat(appFD,"snapshots",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
        if(snapshotsFD<0)return WriteFail(error,@"Shadow 快照目录不可访问");
        snapshotFD=openat(snapshotsFD,idfv.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
        if(snapshotFD<0)return WriteFail(error,@"Shadow 快照不可访问");
        struct stat directoryInfo;
        if(fstat(snapshotFD,&directoryInfo))return WriteFail(error,@"Shadow 快照信息不可读取");
        NSDictionary *original=ManifestAt(snapshotFD);
        if(![original[@"format"]isEqual:@"ShadowAppState2"] || ![original[@"bundleID"]isEqual:bundle] || ![original[@"idfv"]isEqual:idfv])return WriteFail(error,@"Shadow 备份身份不匹配");
        if(![original[@"archiveInfo"]isKindOfClass:NSDictionary.class])return WriteFail(error,@"手机数据清单无效");
        if(![params[@"data_sha256"]isKindOfClass:NSString.class] || [params[@"data_sha256"]length]!=64 || ![original[@"archiveInfo"][@"sha256"]isEqual:params[@"data_sha256"]])return WriteFail(error,@"手机数据备份已改变，未回写 state");
        NSString *stage=[NSString stringWithFormat:@".rv-%@-%@",transfer,part];
        fileFD=openat(snapshotFD,stage.fileSystemRepresentation,O_RDWR|O_CREAT|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC,0600);
        if(fileFD<0 || fstat(fileFD,&info) || !S_ISREG(info.st_mode) || info.st_nlink!=1 || (info.st_uid!=geteuid() && info.st_uid!=directoryInfo.st_uid))return WriteFail(error,@"state 临时文件不可写");
        if(offset==0){if(ftruncate(fileFD,0))return WriteFail(error,@"state 回写初始化失败");}
        else if(info.st_size!=offset)return WriteFail(error,@"state 回写位置不匹配，请重新同步");
        if(lseek(fileFD,offset,SEEK_SET)<0)return WriteFail(error,@"state 回写位置无效");
        NSUInteger written=0;while(written<data.length){ssize_t n=write(fileFD,(const char *)data.bytes+written,data.length-written);if(n<0 && errno==EINTR)continue;if(n<=0)return WriteFail(error,@"state 文件写入失败");written+=(NSUInteger)n;}
        if(fsync(fileFD))return WriteFail(error,@"state 文件保存失败");
        BOOL complete=offset+(long long)data.length==total;
        if(complete){
            if(![HashFD(fileFD)isEqual:sha])return WriteFail(error,@"state 回写哈希不匹配");
            if([part isEqual:@"manifest"]){
                NSMutableData *bytes=[NSMutableData dataWithLength:(NSUInteger)total];if(lseek(fileFD,0,SEEK_SET)<0)return WriteFail(error,@"清单读取失败");
                NSUInteger readBytes=0;while(readBytes<bytes.length){ssize_t n=read(fileFD,(char *)bytes.mutableBytes+readBytes,bytes.length-readBytes);if(n<0 && errno==EINTR)continue;if(n<=0)return WriteFail(error,@"清单读取失败");readBytes+=(NSUInteger)n;}
                id value=[NSPropertyListSerialization propertyListWithData:bytes options:NSPropertyListImmutable format:NULL error:NULL];
                if(![value isKindOfClass:NSDictionary.class] || ![value[@"format"]isEqual:@"ShadowAppState2"] || ![value[@"bundleID"]isEqual:bundle] || ![value[@"idfv"]isEqual:idfv] || ![value[@"archiveInfo"]isEqual:original[@"archiveInfo"]])return WriteFail(error,@"回写清单与手机数据备份不匹配");
                id stateInfo=value[@"stateArchiveInfo"];
                if(![stateInfo isKindOfClass:NSDictionary.class] || ![stateInfo[@"sha256"]isKindOfClass:NSString.class] || [stateInfo[@"sha256"]length]!=64 || ![stateInfo[@"archiveSize"]isKindOfClass:NSNumber.class])return WriteFail(error,@"回写 state 清单无效");
                stateFD=openat(snapshotFD,"state.tar.zst",O_RDONLY|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC);
                if(stateFD<0 || fstat(stateFD,&info) || !S_ISREG(info.st_mode) || info.st_nlink!=1 || info.st_size<=0 || info.st_size>64*1024*1024 || [stateInfo[@"archiveSize"]longLongValue]!=info.st_size || ![HashFD(stateFD)isEqual:stateInfo[@"sha256"]])return WriteFail(error,@"回写清单与 state 不匹配");
            }
            const char *name=[part isEqual:@"state"]?"state.tar.zst":"manifest.plist";
            if(fstatat(snapshotFD,name,&info,AT_SYMLINK_NOFOLLOW) || !S_ISREG(info.st_mode) || info.st_nlink!=1)return WriteFail(error,@"回写目标不是普通文件");
            if(info.st_uid!=directoryInfo.st_uid || info.st_gid!=directoryInfo.st_gid)return WriteFail(error,@"回写目标属主与快照不匹配");
            struct stat staged;if(fstat(fileFD,&staged))return WriteFail(error,@"无法读取回写文件属主");
            if((staged.st_uid!=info.st_uid || staged.st_gid!=info.st_gid) && fchown(fileFD,info.st_uid,info.st_gid))return WriteFail(error,@"无法保留备份文件属主");
            if(fchmod(fileFD,0600) || fsync(fileFD))return WriteFail(error,@"无法保存备份文件权限");
            if(renameat(snapshotFD,stage.fileSystemRepresentation,snapshotFD,name) || fsync(snapshotFD))return WriteFail(error,@"state 发布失败");
        }
        result=@{@"ok":@YES,@"complete":@(complete),@"received":@(offset+data.length)};
    } @finally {
        if(stateFD>=0)close(stateFD);if(fileFD>=0)close(fileFD);if(snapshotFD>=0)close(snapshotFD);if(snapshotsFD>=0)close(snapshotsFD);
        if(lockFD>=0){flock(lockFD,LOCK_UN);close(lockFD);}if(appFD>=0)close(appFD);if(rootFD>=0)close(rootFD);
    }
    return result;
}
