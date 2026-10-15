#import "TVAppProfile.h"
#import <CommonCrypto/CommonDigest.h>
#include <sys/stat.h>
#include <unistd.h>
static BOOL Bad(NSError **error) { if(error)*error=[NSError errorWithDomain:@"TVAppBusiness" code:1 userInfo:nil]; return NO; }
static NSString *Digest(NSData *data) {
    unsigned char bytes[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(data.bytes,(CC_LONG)data.length,bytes);
    NSMutableString *result=[NSMutableString new]; for(NSUInteger i=0;i<sizeof(bytes);i++)[result appendFormat:@"%02x",bytes[i]]; return result;
}
@implementation TVSessionSupplementStore { NSString *_root; }
- (instancetype)initWithRoot:(NSString *)root { if((self=[super init]))_root=[root copy]; return self; }
- (NSString *)pathBundle:(NSString *)bundle idfv:(NSString *)idfv error:(NSError **)error {
    NSUUID *uuid=[[NSUUID alloc]initWithUUIDString:idfv];
    if(!uuid || !bundle.length || [bundle rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_"]invertedSet]].location!=NSNotFound){Bad(error);return nil;}
    NSFileManager *fm=NSFileManager.defaultManager;
    if(![fm createDirectoryAtPath:_root withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:error])return nil;
    struct stat st;
    if(lstat(_root.fileSystemRepresentation,&st)!=0 || !S_ISDIR(st.st_mode) || st.st_uid!=getuid() || (st.st_mode&0777)!=0700){Bad(error);return nil;}
    return [_root stringByAppendingPathComponent:[NSString stringWithFormat:@"%@-%@.plist",bundle,uuid.UUIDString]];
}
- (NSDictionary *)loadBundle:(NSString *)bundle idfv:(NSString *)idfv error:(NSError **)error {
    NSString *path=[self pathBundle:bundle idfv:idfv error:error];if(!path)return nil;
    struct stat st;
    if(lstat(path.fileSystemRepresentation,&st)!=0){if(errno==ENOENT)return @{};Bad(error);return nil;}
    if(!S_ISREG(st.st_mode) || st.st_uid!=getuid() || (st.st_mode&077)!=0 || st.st_size>1024*1024){Bad(error);return nil;}
    NSDictionary *envelope=[NSDictionary dictionaryWithContentsOfFile:path];
    NSData *payload=envelope[@"payload"];
    if(![payload isKindOfClass:NSData.class] || ![Digest(payload)isEqual:envelope[@"sha256"]]){Bad(error);return nil;}
    NSDictionary *state=[NSPropertyListSerialization propertyListWithData:payload options:0 format:NULL error:error];
    if(![state isKindOfClass:NSDictionary.class] || ![state[@"bundle_id"]isEqual:bundle] || ![state[@"idfv"]isEqual:[[NSUUID alloc]initWithUUIDString:idfv].UUIDString]){Bad(error);return nil;}
    return state;
}
- (BOOL)saveState:(NSDictionary *)state bundle:(NSString *)bundle idfv:(NSString *)idfv error:(NSError **)error {
    NSString *path=[self pathBundle:bundle idfv:idfv error:error];if(!path)return NO;
    NSMutableDictionary *payload=[state mutableCopy];payload[@"bundle_id"]=bundle;payload[@"idfv"]=[[NSUUID alloc]initWithUUIDString:idfv].UUIDString;
    NSData *bytes=[NSPropertyListSerialization dataWithPropertyList:payload format:NSPropertyListBinaryFormat_v1_0 options:0 error:error];
    if(!bytes || bytes.length>1024*1024)return Bad(error);
    NSData *envelope=[NSPropertyListSerialization dataWithPropertyList:@{@"payload":bytes,@"sha256":Digest(bytes)} format:NSPropertyListBinaryFormat_v1_0 options:0 error:error];
    // Stage with 0600 before publishing; never expose newly refreshed credentials.
    NSString *stage=[_root stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    if(![NSFileManager.defaultManager createFileAtPath:stage contents:envelope attributes:@{NSFilePosixPermissions:@0600}])return Bad(error);
    if(rename(stage.fileSystemRepresentation,path.fileSystemRepresentation)!=0){unlink(stage.fileSystemRepresentation);return Bad(error);}
    NSDictionary *verified=[self loadBundle:bundle idfv:idfv error:error];return [verified isEqual:payload] || Bad(error);
}
- (NSArray *)mergeRecords:(NSArray *)records manifest:(NSDictionary *)manifest error:(NSError **)error {
    if(![manifest[@"bundleID"]isEqual:@"lt.manodrabuziai.fr"])return records;
    NSDictionary *state=[self loadBundle:manifest[@"bundleID"] idfv:manifest[@"idfv"] error:error];if(!state)return nil;
    NSDictionary *tokens=state[@"tokens"];if(!tokens)return records;
    return [self mergeRecords:records tokens:tokens error:error];
}
- (NSArray *)mergeRecords:(NSArray *)records tokens:(NSDictionary *)tokens error:(NSError **)error {
    if(![tokens isKindOfClass:NSDictionary.class] || tokens.count!=2){Bad(error);return nil;}
    NSMutableArray *result=[records mutableCopy];
    for(NSString *account in @[@"token",@"refresh_token"]) {
        NSData *data=tokens[account];if(![data isKindOfClass:NSData.class] || !data.length || data.length>65536){Bad(error);return nil;}
        NSMutableArray *matches=[NSMutableArray new];
        for(NSUInteger i=0;i<records.count;i++)if([records[i][@"svce"]isEqual:@"Vintedfr"] && [records[i][@"acct"]isEqual:account])[matches addObject:@(i)];
        if(matches.count!=1){Bad(error);return nil;}
        NSUInteger index=[matches[0]unsignedIntegerValue];NSMutableDictionary *record=[records[index]mutableCopy];
        record[@"v_Data"]=data;
        if(record[@"v_DataUTF8"])record[@"v_DataUTF8"]=[[NSString alloc]initWithData:data encoding:NSUTF8StringEncoding]?:@"";
        result[index]=record;
    }
    return result;
}
@end
