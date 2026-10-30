#import "TVAppStateServices.h"
#import "TVASRuntime.h"
#import "TVASAppLifecycle.h"
#import "../adapters/PXASNative.h"
#include <sys/stat.h>
#include <sys/file.h>
#include <fcntl.h>
#include <unistd.h>

static BOOL FailService(NSError **error, NSString *message) {
    if (error) *error=[NSError errorWithDomain:@"TVAppStateServices" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];
    return NO;
}
static NSString *PhysicalPath(NSString *path) {
    char *canonical=realpath(path.fileSystemRepresentation,NULL); if (!canonical) return nil;
    NSString *result=@(canonical); free(canonical); return result;
}
static NSDictionary *ReadProgress(NSString *directory,struct stat pinned) {
    NSString *path=[directory stringByAppendingPathComponent:@"progress.plist"];
    struct stat parent,file;
    if(lstat(directory.fileSystemRepresentation,&parent)!=0 || parent.st_dev!=pinned.st_dev || parent.st_ino!=pinned.st_ino ||
       lstat(path.fileSystemRepresentation,&file)!=0 || !S_ISREG(file.st_mode) || file.st_uid!=getuid() || (file.st_mode&077)!=0 || file.st_size>16384)return nil;
    NSDictionary *event=[NSDictionary dictionaryWithContentsOfFile:path];
    return [event[@"phase"] isKindOfClass:NSString.class] && [event[@"stage"] isKindOfClass:NSString.class]?event:nil;
}
static dispatch_queue_t OperationQueue(void) {
    static dispatch_queue_t queue; static dispatch_once_t once;
    dispatch_once(&once,^{queue=dispatch_queue_create("com.weaponx.app-state",DISPATCH_QUEUE_SERIAL);});
    return queue;
}
// Only actual outstanding native work owns the process-wide execution gate.
static BOOL LifecyclePending=NO;
static NSObject *LifecycleGate(void) {
    static NSObject *gate;static dispatch_once_t once;dispatch_once(&once,^{gate=[NSObject new];});return gate;
}
@interface TVAppStateServices ()
@property (nonatomic, copy) void (^operationProgress)(NSDictionary *event);

@end
@implementation TVAppStateServices
- (BOOL)isMobile { return getuid()==501 && geteuid()==501; }
- (id<PXASResolver>)resolver { return [PXASLaunchServicesResolver new]; }
- (id<TVASProcessRunning>)processRunner { return [TVASProcessRunner new]; }
- (NSDictionary *)operationPaths { return TVASRuntimePaths(); }
- (id)shadowSettingsForBundle:(NSString *)bundle {
    NSUserDefaults *defaults=[[NSUserDefaults alloc]initWithSuiteName:@"/var/mobile/Library/Preferences/me.jjolano.shadow.plist"];
    [defaults synchronize];return [defaults objectForKey:bundle];
}
- (NSString *)currentShadowIDFV:(NSString *)bundle error:(NSError **)error {
    id settings=[self shadowSettingsForBundle:bundle];
    if(!settings)return nil;
    if(![settings isKindOfClass:NSDictionary.class]){FailService(error,@"Shadow current environment settings are invalid");return nil;}
    id fingerprint=settings[@"Fingerprint_Data"];
    if(!fingerprint)return nil;
    if(![fingerprint isKindOfClass:NSDictionary.class]){FailService(error,@"Shadow current fingerprint is invalid");return nil;}
    id value=fingerprint[@"VendorIdentifier"];
    if(!value)return nil;
    NSString *idfv=[value isKindOfClass:NSString.class]?[[NSUUID alloc]initWithUUIDString:value].UUIDString:nil;
    if(!idfv.length){FailService(error,@"Shadow current IDFV is invalid");return nil;}
    return idfv;
}
- (NSDictionary *)shadowCatalog:(NSString *)bundle error:(NSError **)error {
    NSString *root=[self operationPaths][@"shadow_backups"];
    if(!root.length){FailService(error,@"Shadow backup directory is unavailable");return nil;}
    NSString *app=[root stringByAppendingPathComponent:bundle];
    NSString *snapshots=[app stringByAppendingPathComponent:@"snapshots"];
    NSError *listingError=nil;
    NSArray *names=[NSFileManager.defaultManager contentsOfDirectoryAtPath:snapshots error:&listingError];
    if(!names && !([listingError.domain isEqual:NSCocoaErrorDomain] && listingError.code==NSFileReadNoSuchFileError)) {
        if(error)*error=listingError;return nil;
    }
    NSMutableArray *backups=[NSMutableArray new];
    NSISO8601DateFormatter *formatter=[NSISO8601DateFormatter new];
    // Shadow publishes manifests atomically. Listing reads metadata only;
    // neither archive is opened, verified, extracted or modified here.
    for(NSString *name in [names sortedArrayUsingSelector:@selector(compare:)]) {
        NSString *idfv=[[NSUUID alloc]initWithUUIDString:name].UUIDString;
        if(![idfv isEqual:name])continue;
        NSDictionary *manifest=[NSDictionary dictionaryWithContentsOfFile:[[snapshots stringByAppendingPathComponent:name] stringByAppendingPathComponent:@"manifest.plist"]];
        if(![manifest[@"format"]isEqual:@"ShadowAppState2"] || ![manifest[@"bundleID"]isEqual:bundle] || ![manifest[@"idfv"]isEqual:idfv])continue;
        [backups addObject:@{@"backup_id":[@"snapshot:" stringByAppendingString:idfv],@"kind":@"snapshot",@"idfv":idfv,
            @"display_name":[manifest[@"title"]isKindOfClass:NSString.class]?manifest[@"title"]:idfv,
            @"note":[manifest[@"note"]isKindOfClass:NSString.class]?manifest[@"note"]:@"",
            @"version":[manifest[@"version"]isKindOfClass:NSString.class]?manifest[@"version"]:@"",
            @"build":[manifest[@"build"]isKindOfClass:NSString.class]?manifest[@"build"]:@"",
            @"date":[manifest[@"date"]isKindOfClass:NSDate.class]?[formatter stringFromDate:manifest[@"date"]]:(id)NSNull.null}];
    }
    NSError *identityError=nil;
    NSString *current=[self currentShadowIDFV:bundle error:&identityError];
    if(identityError){if(error)*error=identityError;return nil;}
    if(error)*error=nil;
    // Current identity is read independently of installed app/keychain contents.
    return @{@"bundle_id":bundle,@"format":@"ShadowAppState2",@"backups":backups,
        @"current_idfv":current?:NSNull.null};
}
// Metadata edits share Shadow's directory lock but never inspect payload archives.
- (BOOL)editShadow:(NSString *)bundle request:(NSDictionary *)request error:(NSError **)error {
    NSString *reference=request[@"reference"], *prefix=[bundle stringByAppendingString:@"/snapshots/"];
    if(![reference isKindOfClass:NSString.class] || ![reference hasPrefix:prefix])return FailService(error,@"请选择 Shadow 快照");
    NSString *idfv=[reference substringFromIndex:prefix.length];
    NSDictionary *account=request[@"account"];
    if(![account isKindOfClass:NSDictionary.class])return FailService(error,@"备份名称或备注无效");
    NSString *title=account[@"displayName"], *note=account[@"note"];
    if(![idfv isEqual:[[NSUUID alloc]initWithUUIDString:idfv].UUIDString] ||
       ![title isKindOfClass:NSString.class] || ![title stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length || title.length>100 ||
       ![note isKindOfClass:NSString.class] || note.length>1000)return FailService(error,@"备份名称或备注无效");
    if(!TVASRequest(@"edit",@{@"bundle_id":bundle,@"backup_id":[@"snapshot:" stringByAppendingString:idfv],@"display_name":title,@"note":note},NULL))return FailService(error,@"备份编辑请求无效");
    int rootFD=-1,appFD=-1,lockFD=-1,snapshotsFD=-1,snapshotFD=-1,manifestFD=-1,stageFD=-1;
    NSString *stage=[@".rv-metadata-" stringByAppendingString:NSUUID.UUID.UUIDString];
    @try {
        rootFD=open([[self operationPaths][@"shadow_backups"] fileSystemRepresentation],O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
        if(rootFD<0)return FailService(error,@"Shadow 备份目录不可访问");
        appFD=openat(rootFD,bundle.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
        if(appFD<0)return FailService(error,@"Shadow App 目录不可访问");
        lockFD=openat(appFD,".lock",O_RDWR|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC);struct stat info,original;
        if(lockFD<0 || fstat(lockFD,&info) || !S_ISREG(info.st_mode) || info.st_nlink!=1 || flock(lockFD,LOCK_EX|LOCK_NB))return FailService(error,@"Shadow 正在使用此备份");
        snapshotsFD=openat(appFD,"snapshots",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
        if(snapshotsFD<0)return FailService(error,@"Shadow 快照目录不可访问");
        snapshotFD=openat(snapshotsFD,idfv.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
        if(snapshotFD<0)return FailService(error,@"Shadow 快照不可访问");
        manifestFD=openat(snapshotFD,"manifest.plist",O_RDONLY|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC);
        if(manifestFD<0 || fstat(manifestFD,&original) || !S_ISREG(original.st_mode) || original.st_nlink!=1 || original.st_size<=0 || original.st_size>16*1024*1024)return FailService(error,@"Shadow 清单不可读取");
        NSMutableData *bytes=[NSMutableData dataWithLength:(NSUInteger)original.st_size];NSUInteger offset=0;
        while(offset<bytes.length){ssize_t n=read(manifestFD,(char *)bytes.mutableBytes+offset,bytes.length-offset);if(n<0 && errno==EINTR)continue;if(n<=0)return FailService(error,@"Shadow 清单读取失败");offset+=(NSUInteger)n;}
        id value=[NSPropertyListSerialization propertyListWithData:bytes options:NSPropertyListMutableContainers format:NULL error:NULL];
        if(![value isKindOfClass:NSMutableDictionary.class] || ![value[@"format"]isEqual:@"ShadowAppState2"] || ![value[@"bundleID"]isEqual:bundle] || ![value[@"idfv"]isEqual:idfv])return FailService(error,@"Shadow 备份身份不匹配");
        value[@"title"]=title;value[@"note"]=note;
        NSData *encoded=[NSPropertyListSerialization dataWithPropertyList:value format:NSPropertyListBinaryFormat_v1_0 options:0 error:error];if(!encoded)return NO;
        stageFD=openat(snapshotFD,stage.fileSystemRepresentation,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);
        if(stageFD<0)return FailService(error,@"无法保存备份名称与备注");
        if(fstat(stageFD,&info) || ((info.st_uid!=original.st_uid || info.st_gid!=original.st_gid) && fchown(stageFD,original.st_uid,original.st_gid)) || fchmod(stageFD,0600))return FailService(error,@"无法保留备份清单权限");
        offset=0;while(offset<encoded.length){ssize_t n=write(stageFD,(const char *)encoded.bytes+offset,encoded.length-offset);if(n<0 && errno==EINTR)continue;if(n<=0)return FailService(error,@"备份清单写入失败");offset+=(NSUInteger)n;}
        if(fsync(stageFD) || fstatat(snapshotFD,"manifest.plist",&info,AT_SYMLINK_NOFOLLOW) || info.st_dev!=original.st_dev || info.st_ino!=original.st_ino)return FailService(error,@"备份清单已改变，未保存修改");
        if(renameat(snapshotFD,stage.fileSystemRepresentation,snapshotFD,"manifest.plist") || fsync(snapshotFD))return FailService(error,@"备份清单发布失败");
        if(error)*error=nil;return YES;
    } @finally {
        if(stageFD>=0)close(stageFD);if(snapshotFD>=0){unlinkat(snapshotFD,stage.fileSystemRepresentation,0);close(snapshotFD);}
        if(manifestFD>=0)close(manifestFD);if(snapshotsFD>=0)close(snapshotsFD);if(lockFD>=0){flock(lockFD,LOCK_UN);close(lockFD);}if(appFD>=0)close(appFD);if(rootFD>=0)close(rootFD);
    }
}
- (TVASAppLifecycle *)lifecycle { return [TVASAppLifecycle new]; }
- (NSTimeInterval)lifecycleTimeout { return 6; }
- (NSDictionary *)runLifecycle:(NSString *)method bundle:(NSString *)bundle error:(NSError **)error {
    BOOL mutation=![method isEqual:@"status"];
    @synchronized(LifecycleGate()) {
        if(LifecyclePending){FailService(error,@"App operation is still running");return nil;}
        LifecyclePending=YES;
    }
    dispatch_semaphore_t done=dispatch_semaphore_create(0);NSMutableDictionary *outcome=[NSMutableDictionary new];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{@autoreleasepool {
        NSError *failure=nil;NSDictionary *result=nil;
        @try {result=[[self lifecycle]execute:method bundle:bundle error:&failure];}
        @catch(__unused NSException *exception){failure=[NSError errorWithDomain:@"TVAppStateServices" code:mutation?4:1 userInfo:@{@"stateMayBePartial":@(mutation)}];}
        @synchronized(outcome){if(result)outcome[@"result"]=result;if(failure)outcome[@"error"]=failure;}
        @synchronized(LifecycleGate()){LifecyclePending=NO;}
        dispatch_semaphore_signal(done);
    }});
    if(dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,(int64_t)([self lifecycleTimeout]*NSEC_PER_SEC)))!=0) {
        if(error)*error=[NSError errorWithDomain:@"TVAppStateServices" code:mutation?4:1 userInfo:@{@"stateMayBePartial":@(mutation)}];return nil;
    }
    @synchronized(outcome){if(error)*error=outcome[@"error"];return outcome[@"result"];}
}
- (BOOL)writePlist:(NSDictionary *)plist path:(NSString *)path error:(NSError **)error {
    NSData *data=[NSPropertyListSerialization dataWithPropertyList:plist format:NSPropertyListBinaryFormat_v1_0 options:0 error:error];
    if (!data || ![data writeToFile:path options:NSDataWritingWithoutOverwriting error:error]) return NO;
    return chmod(path.fileSystemRepresentation,0600)==0 || FailService(error,@"Cannot secure operation file");
}
- (BOOL)sign:(NSString *)worker entitlements:(NSDictionary *)entitlements runner:(id<TVASProcessRunning>)runner error:(NSError **)error {
    NSString *entPath=[worker stringByAppendingPathExtension:@"entitlements.plist"];
    if (![self writePlist:entitlements path:entPath error:error]) return NO;
    NSString *ldid=[self operationPaths][@"ldid"];
    if (![runner runExecutable:ldid arguments:@[@"-Cadhoc",[@"-S" stringByAppendingString:entPath],worker] timeout:30 standardOutput:NULL error:error]) return NO;
    NSData *data=nil;
    if (![runner runExecutable:ldid arguments:@[@"-e",worker] timeout:30 standardOutput:&data error:error]) return NO;
    id actual=[NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:error];
    return [actual isEqual:entitlements] || FailService(error,@"Worker signature does not match the target's exact scope");
}
- (NSDictionary *)runBundle:(NSString *)bundleID request:(NSDictionary *)request error:(NSError **)error {
    if (![self isMobile]) { FailService(error,@"App-state operations must run as mobile"); return nil; }
    BOOL readOnly=[@[@"catalog",@"describe",@"status",@"profile",@"accessToken"] containsObject:request[@"operation"]];
    @synchronized(LifecycleGate()) {
        if(!readOnly && LifecyclePending) {
            FailService(error,@"App operation is still running");return nil;
        }
    }
    if ([@[@"launch",@"stop",@"status"] containsObject:request[@"operation"]])
        return [self runLifecycle:request[@"operation"] bundle:bundleID error:error];
    if ([request[@"operation"]isEqual:@"catalog"])
        return [self shadowCatalog:bundleID error:error];
    if ([request[@"operation"]isEqual:@"switch"]) {
        FailService(error,@"RV 不再提供环境切换，请使用 Shadow 恢复备份");return nil;
    }
    if ([request[@"operation"]isEqual:@"edit"]) {
        if(![self editShadow:bundleID request:request error:error])return nil;
        return [self shadowCatalog:bundleID error:error];
    }
    NSDictionary *target=[[self resolver] resolve:bundleID error:error];
    NSDictionary *signedEntitlements=target[@"signedEntitlements"];
    if (!signedEntitlements) return nil;
    if ([request[@"operation"] isEqual:@"describe"]) return @{@"bundle_id":bundleID,@"version":target[@"version"],@"build":target[@"build"],@"idfv":target[@"IDFV"],@"container_ids":[target[@"containers"] allKeys],@"keychain_groups":target[@"keychainGroups"]};
    NSArray *groups=PXASKeychainGroupsFromEntitlements(signedEntitlements,bundleID,error); if (!groups) return nil;
    NSFileManager *fm=NSFileManager.defaultManager;
    NSDictionary *paths=[self operationPaths];
    NSString *logicalRoot=paths[@"root"];
    if (!logicalRoot.length) { FailService(error,@"Dopamine 3 app-state integration is unavailable"); return nil; }
    if (![fm createDirectoryAtPath:logicalRoot withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:error]) return nil;
    NSString *root=PhysicalPath(logicalRoot); struct stat rootInfo;
    if (!root || lstat(logicalRoot.fileSystemRepresentation,&rootInfo)!=0 || !S_ISDIR(rootInfo.st_mode) ||
        rootInfo.st_uid!=getuid() || (rootInfo.st_mode&0777)!=0700) { FailService(error,@"App-state operation directory is unsafe"); return nil; }
    NSString *directory=[root stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    if (mkdir(directory.fileSystemRepresentation,0700)!=0) { FailService(error,@"Cannot create a private operation directory"); return nil; }
    struct stat directoryInfo; lstat(directory.fileSystemRepresentation,&directoryInfo);
    NSDictionary *result=nil; BOOL executionStarted=NO,completionKnown=NO;
    dispatch_source_t progressTimer=nil;
    NSMutableDictionary *progressState=[NSMutableDictionary dictionary];
    @try {
        // Standard rootless rpaths resolve dependencies after copying the worker.
        BOOL prepared=YES;
        NSString *worker=[directory stringByAppendingPathComponent:@"worker"];
        if (prepared) prepared=[fm copyItemAtPath:paths[@"worker"] toPath:worker error:error];
        if (prepared) prepared=chmod(worker.fileSystemRepresentation,0700)==0;
        NSMutableDictionary *base=[@{@"platform-application":@YES,@"com.apple.private.security.no-container":@YES,
            @"com.apple.private.security.container-required":@NO,@"com.apple.private.security.no-sandbox":@YES} mutableCopy];
        NSMutableDictionary *authority=[base mutableCopy];
        authority[@"com.apple.private.security.storage.AppDataContainers"]=@YES;
        authority[@"com.apple.private.security.storage.AppBundles"]=@YES;
        authority[@"com.apple.lsapplicationproxy.deviceidentifierforvendor"]=@YES;
        authority[@"application-identifier"]=signedEntitlements[@"application-identifier"]?:signedEntitlements[@"com.apple.application-identifier"];
        authority[@"keychain-access-groups"]=groups;
        if (signedEntitlements[@"com.apple.security.application-groups"])
            authority[@"com.apple.security.application-groups"]=signedEntitlements[@"com.apple.security.application-groups"];
        id<TVASProcessRunning> runner=[self processRunner];
        if (prepared) prepared=[self sign:worker entitlements:authority runner:runner error:error];
        NSMutableDictionary *payload=[request mutableCopy]; payload[@"bundleID"]=bundleID;
        NSString *requestPath=[directory stringByAppendingPathComponent:@"request.plist"];
        if (prepared) prepared=[self writePlist:payload path:requestPath error:error];
        NSString *progressPath=[directory stringByAppendingPathComponent:@"progress.plist"];
        if (prepared) prepared=[self writePlist:@{@"phase":@"prepare",@"stage":@"prepare"} path:progressPath error:error];
        if (prepared && self.operationProgress) {
            void (^progress)(NSDictionary *)=[self.operationProgress copy];
            dispatch_async(dispatch_get_main_queue(),^{progress(@{@"phase":@"prepare",@"stage":@"prepare"});});
            progressTimer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,dispatch_get_global_queue(QOS_CLASS_UTILITY,0));
            dispatch_source_set_timer(progressTimer,dispatch_time(DISPATCH_TIME_NOW,0),150*NSEC_PER_MSEC,30*NSEC_PER_MSEC);
            dispatch_source_set_event_handler(progressTimer,^{
                @synchronized(progressState) {
                    if ([progressState[@"stopped"] boolValue]) return;
                    NSDictionary *event=ReadProgress(directory,directoryInfo);
                    if(!event || [event isEqual:progressState[@"last"]])return;
                    progressState[@"last"]=event;
                    dispatch_async(dispatch_get_main_queue(),^{
                        @synchronized(progressState) { if(![progressState[@"stopped"] boolValue])progress(event); }
                    });
                }
            }); dispatch_resume(progressTimer);
        }
        NSData *data=nil;
        executionStarted=prepared;
        if (prepared && [runner runExecutable:worker arguments:@[requestPath] timeout:600 standardOutput:&data error:error]) {
            id response=[NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:error];
            if (![response isKindOfClass:NSDictionary.class] || ![response[@"ok"] isKindOfClass:NSNumber.class])
                FailService(error,@"App-state worker returned an invalid response");
            else if ([response[@"ok"] boolValue] && [response[@"result"] isKindOfClass:NSDictionary.class]) { result=response[@"result"]; completionKnown=YES; }
            else if (![response[@"ok"] boolValue] && error) {
                completionKnown=YES;
                NSMutableDictionary *info=[@{NSLocalizedDescriptionKey:
                [response[@"message"] isKindOfClass:NSString.class]?response[@"message"]:@"App-state operation failed",
                @"stateMayBePartial":@([response[@"stateMayBePartial"] boolValue]),@"archiveMayBePartial":@([response[@"archiveMayBePartial"] boolValue])} mutableCopy];
                if ([response[@"pendingCaptureReference"] isKindOfClass:NSString.class]) info[@"pendingCaptureReference"]=response[@"pendingCaptureReference"];
                if([response[@"posixCode"] isKindOfClass:NSNumber.class])info[@"posixCode"]=response[@"posixCode"];
                if([response[@"errorDomain"] isKindOfClass:NSString.class])info[@"sourceDomain"]=response[@"errorDomain"];
                if([response[@"errorCode"] isKindOfClass:NSNumber.class])info[@"sourceCode"]=response[@"errorCode"];
                *error=[NSError errorWithDomain:@"TVAppStateServices" code:2 userInfo:info];
            } else FailService(error,@"App-state worker returned an incomplete response");
        }
        if (!result && error && !*error) FailService(error,@"Cannot prepare the scoped app-state worker");
    } @finally {
        NSDictionary *finalEvent=nil;
        @synchronized(progressState) {
            progressState[@"stopped"]=@YES;
            if(self.operationProgress && executionStarted)finalEvent=ReadProgress(directory,directoryInfo);
        }
        if(progressTimer)dispatch_source_cancel(progressTimer);
        // The last stage may finish between polls. Deliver its immutable snapshot
        // before completion so a fast verification failure retains the correct step.
        if(finalEvent) {
            void (^progress)(NSDictionary *)=[self.operationProgress copy];
            dispatch_async(dispatch_get_main_queue(),^{progress(finalEvent);});
        }
        struct stat currentRoot,currentDirectory;
        BOOL pinned=lstat(root.fileSystemRepresentation,&currentRoot)==0 && currentRoot.st_dev==rootInfo.st_dev && currentRoot.st_ino==rootInfo.st_ino &&
            lstat(directory.fileSystemRepresentation,&currentDirectory)==0 && S_ISDIR(currentDirectory.st_mode) &&
            currentDirectory.st_dev==directoryInfo.st_dev && currentDirectory.st_ino==directoryInfo.st_ino;
        NSError *cleanupError=nil;
        if (!pinned || ![fm removeItemAtPath:directory error:&cleanupError]) {
            result=nil;
            NSMutableDictionary *info=(error&&*error)?[(*error).userInfo mutableCopy]:[NSMutableDictionary dictionary];
            NSString *prior=info[NSLocalizedDescriptionKey];
            info[NSLocalizedDescriptionKey]=prior.length?[prior stringByAppendingString:@"; private worker cleanup failed"]:@"Operation finished, but private worker cleanup failed";
            if (cleanupError) info[NSUnderlyingErrorKey]=cleanupError;
            if (error) *error=[NSError errorWithDomain:@"TVAppStateServices" code:3 userInfo:info];
        }
        if (!completionKnown && executionStarted && error) {
            NSMutableDictionary *info=*error?[(*error).userInfo mutableCopy]:[NSMutableDictionary dictionary];
            info[NSLocalizedDescriptionKey]=info[NSLocalizedDescriptionKey]?:@"Worker completion could not be verified";
            if ([request[@"operation"] isEqual:@"switch"]) info[@"stateMayBePartial"]=@YES;
            if ([@[@"save",@"switch",@"edit",@"delete",@"baseline"] containsObject:request[@"operation"]]) info[@"archiveMayBePartial"]=@YES;
            *error=[NSError errorWithDomain:@"TVAppStateServices" code:4 userInfo:info];
        }
    }
    return result;
}
- (NSDictionary *)accessTokenForBundle:(NSString *)bundleID error:(NSError **)error {
    if(![bundleID isEqual:@"lt.manodrabuziai.fr"]){FailService(error,@"Access token reader is unavailable for this app");return nil;}
    return [self runBundle:bundleID request:@{@"operation":@"accessToken"} error:error];
}
- (void)executeBundle:(NSString *)bundleID request:(NSDictionary *)request completion:(void (^)(NSDictionary *,NSError *))completion {
    [self executeBundle:bundleID request:request progress:nil completion:completion];
}
- (void)executeBundle:(NSString *)bundleID request:(NSDictionary *)request progress:(void (^)(NSDictionary *))progress completion:(void (^)(NSDictionary *,NSError *))completion {
    NSString *bundle=[bundleID copy]; NSDictionary *payload=[request copy];
    dispatch_async(OperationQueue(),^{ @autoreleasepool {
        self.operationProgress=progress;
        NSError *error=nil; NSDictionary *result=nil;
        @try {
            if(![@[@"catalog",@"edit",@"launch",@"stop",@"status"]containsObject:payload[@"operation"]])
                FailService(&error,@"此旧 App-state 接口已移除，备份创建与恢复请使用 Shadow");
            else result=[self runBundle:bundle request:payload error:&error];
        }
        @catch (NSException *exception) { (void)exception; FailService(&error,@"App-state operation could not be completed"); }
        if(result)result=TVASResult(result,bundle,&error);
        self.operationProgress=nil;
        dispatch_async(dispatch_get_main_queue(),^{completion(result,error);});
    }});
}
@end
