#import "TVAppStateServices.h"
#import "TVASRuntime.h"
#import "TVASAppLifecycle.h"
#import "../adapters/PXASNative.h"
#include <sys/stat.h>
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
// Listener restarts must not bypass a still-running native call or its unknown outcome.
static BOOL LifecyclePending=NO, LifecycleUnknown=NO;
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
- (TVASAppLifecycle *)lifecycle { return [TVASAppLifecycle new]; }
- (NSTimeInterval)lifecycleTimeout { return 6; }
- (NSDictionary *)runLifecycle:(NSString *)method bundle:(NSString *)bundle error:(NSError **)error {
    BOOL mutation=![method isEqual:@"status"];
    @synchronized(LifecycleGate()) {
        if(LifecyclePending || (mutation && LifecycleUnknown)){if(error)*error=[NSError errorWithDomain:@"TVAppStateServices" code:mutation?4:1 userInfo:@{@"stateMayBePartial":@(mutation)}];return nil;}
        LifecyclePending=YES;
    }
    dispatch_semaphore_t done=dispatch_semaphore_create(0);NSMutableDictionary *outcome=[NSMutableDictionary new];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{@autoreleasepool {
        NSError *failure=nil;NSDictionary *result=nil;
        @try {result=[[self lifecycle]execute:method bundle:bundle error:&failure];}
        @catch(__unused NSException *exception){failure=[NSError errorWithDomain:@"TVAppStateServices" code:mutation?4:1 userInfo:@{@"stateMayBePartial":@(mutation)}];}
        @synchronized(outcome){if(result)outcome[@"result"]=result;if(failure)outcome[@"error"]=failure;}
        @synchronized(LifecycleGate()){if(mutation && [failure.domain isEqual:@"TVAppStateServices"] && failure.code>=3)LifecycleUnknown=YES;LifecyclePending=NO;}
        dispatch_semaphore_signal(done);
    }});
    if(dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,(int64_t)([self lifecycleTimeout]*NSEC_PER_SEC)))!=0) {
        @synchronized(LifecycleGate()){if(mutation)LifecycleUnknown=YES;}
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
    BOOL readOnly=[@[@"catalog",@"describe",@"status",@"profile"] containsObject:request[@"operation"]];
    @synchronized(LifecycleGate()) {
        if(!readOnly && (LifecyclePending || LifecycleUnknown)) {
            if(error)*error=[NSError errorWithDomain:@"TVAppStateServices" code:4 userInfo:@{@"stateMayBePartial":@YES}];return nil;
        }
    }
    if ([@[@"launch",@"stop",@"status"] containsObject:request[@"operation"]])
        return [self runLifecycle:request[@"operation"] bundle:bundleID error:error];
    NSDictionary *target=[[self resolver] resolve:bundleID error:error];
    NSDictionary *signedEntitlements=target[@"signedEntitlements"];
    if (!signedEntitlements) return nil;
    if ([request[@"operation"] isEqual:@"describe"]) return @{@"bundle_id":bundleID,@"version":target[@"version"],@"build":target[@"build"],@"idfv":target[@"IDFV"],@"container_ids":[target[@"containers"] allKeys],@"keychain_groups":target[@"keychainGroups"]};
    NSArray *groups=PXASKeychainGroupsFromEntitlements(signedEntitlements,bundleID,error); if (!groups) return nil;
    NSFileManager *fm=NSFileManager.defaultManager;
    NSDictionary *paths=[self operationPaths];
    NSString *logicalRoot=paths[@"root"];
    if (!logicalRoot.length) { FailService(error,@"RootHide app-state integration is unavailable"); return nil; }
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
        NSString *anchor=[directory stringByAppendingPathComponent:@".jbroot"];
        NSString *bootstrap=PhysicalPath(paths[@"bootstrap"]);
        BOOL prepared=bootstrap && [fm createSymbolicLinkAtPath:anchor withDestinationPath:bootstrap error:error];
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
        if (prepared && ![PhysicalPath(anchor) isEqual:bootstrap]) prepared=FailService(error,@"RootHide dependency anchor changed");
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
- (void)executeBundle:(NSString *)bundleID request:(NSDictionary *)request completion:(void (^)(NSDictionary *,NSError *))completion {
    [self executeBundle:bundleID request:request progress:nil completion:completion];
}
- (void)executeBundle:(NSString *)bundleID request:(NSDictionary *)request progress:(void (^)(NSDictionary *))progress completion:(void (^)(NSDictionary *,NSError *))completion {
    NSString *bundle=[bundleID copy]; NSDictionary *payload=[request copy];
    dispatch_async(OperationQueue(),^{ @autoreleasepool {
        self.operationProgress=progress;
        NSError *error=nil; NSDictionary *result=nil;
        @try { result=[self runBundle:bundle request:payload error:&error]; }
        @catch (NSException *exception) { (void)exception; FailService(&error,@"App-state operation could not be completed"); }
        if(result)result=TVASResult(result,bundle,&error);
        self.operationProgress=nil;
        dispatch_async(dispatch_get_main_queue(),^{completion(result,error);});
    }});
}
@end
