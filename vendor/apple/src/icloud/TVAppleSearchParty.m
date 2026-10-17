#import "TVAppleSearchParty.h"
#if defined(TVAPPLE_DOPAMINE3)
#import <rootless.h>
#endif
#import <dlfcn.h>
#import <spawn.h>
#import <sys/stat.h>
#import <sys/wait.h>
#import <fcntl.h>
#import <signal.h>
#import <unistd.h>
#import <errno.h>
#import <limits.h>
extern char **environ;
@interface NSObject (TVAppleSPSelectors)
- (void)start;
- (void)invalidate;
- (dispatch_queue_t)queue;
- (id)proxy;
- (id)serviceDescription;
- (id)initWithServiceDescription:(id)description;
- (void)resume;
- (dispatch_queue_t)serialQueue;
- (void)beaconingStateWithCompletion:(void (^)(long long))completion;
@end
TVAppleServiceHealth TVAppleSearchPartyProbeManager(id manager,NSTimeInterval timeout) {
    for(NSString *name in @[@"start",@"invalidate",@"queue",@"proxy"])
        if(![manager respondsToSelector:NSSelectorFromString(name)])return TVAppleServiceUnavailable;
    dispatch_queue_t queue=[manager queue];if(!queue)return TVAppleServiceUnavailable;
    NSMutableDictionary *ticket=[NSMutableDictionary new];dispatch_semaphore_t signal=dispatch_semaphore_create(0);
    dispatch_async(queue, ^{
        @synchronized(ticket){if(ticket[@"closed"])return;}
        [manager start];
        // The native proxy getter asserts this exact SPBeaconManager queue.
        id proxy=[manager proxy];
        if(!proxy)return;
        [proxy beaconingStateWithCompletion:^(long long state){
            (void)state; // Read-only liveness response, no beacon/account data is exported.
            @synchronized(ticket){if(ticket[@"closed"]||ticket[@"finished"])return;
                ticket[@"finished"]=@YES;dispatch_semaphore_signal(signal);}
        }];
    });
    NSTimeInterval deadline=NSProcessInfo.processInfo.systemUptime+timeout;BOOL completed=NO;
    while(!(completed=dispatch_semaphore_wait(signal,DISPATCH_TIME_NOW)==0)&&NSProcessInfo.processInfo.systemUptime<deadline)
        [[NSRunLoop currentRunLoop]runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    @synchronized(ticket){ticket[@"closed"]=@YES;}
    // Cleanup stays off the account worker even if a native getter/cleanup stalls.
    dispatch_async(queue,^{[manager invalidate];});
    return completed?TVAppleServiceHealthy:TVAppleServiceUnresponsive;
}
// Use only the native XPC session, not SPBeaconManager.start: the latter also
// starts beacon/activation-lock observers unrelated to a liveness query.
@interface TVAppleSPSessionAdapter : NSObject
@property NSObject *session;
@property dispatch_queue_t queue;
@end
@implementation TVAppleSPSessionAdapter
- (void)start{[self.session resume];}
- (void)invalidate{[self.session invalidate];}
- (instancetype)init{if((self=[super init]))_queue=dispatch_queue_create("apple.searchparty.probe",DISPATCH_QUEUE_SERIAL);return self;}
- (id)proxy{return [self.session proxy];}
@end
@interface TVAppleNativeSPDriver : NSObject <TVAppleSearchPartyDriver>
@end
@implementation TVAppleNativeSPDriver
- (TVAppleServiceHealth)probeWithTimeout:(NSTimeInterval)timeout {
    if(!dlopen("/System/Library/PrivateFrameworks/SPOwner.framework/SPOwner",RTLD_NOW))return TVAppleServiceUnavailable;
    // The framework's description object supplies its own protocol and service
    // options. Keep its owner resident: native notification observers can retain
    // raw owner pointers even after SPBeaconManager.invalidate on iOS 15.
    static id owner;static dispatch_once_t once;
    dispatch_once(&once,^{owner=[NSClassFromString(@"SPBeaconManager")new];});
    if(![owner respondsToSelector:@selector(serviceDescription)])return TVAppleServiceUnavailable;
    id session=[NSClassFromString(@"FMXPCSession")alloc];
    if(![session respondsToSelector:@selector(initWithServiceDescription:)])return TVAppleServiceUnavailable;
    session=[session initWithServiceDescription:[owner serviceDescription]];
    for(NSString *name in @[@"resume",@"invalidate",@"serialQueue",@"proxy"])
        if(![session respondsToSelector:NSSelectorFromString(name)])return TVAppleServiceUnavailable;
    TVAppleSPSessionAdapter *adapter=[TVAppleSPSessionAdapter new];adapter.session=session;
    return TVAppleSearchPartyProbeManager(adapter,timeout);
}
- (BOOL)restartWithTimeout:(NSTimeInterval)timeout error:(NSError **)error {
    // Optional fixed-purpose root helper. No shell, arguments from callers, password,
    // sudo, or daemon kill from this library. Provision it separately under root.
    NSString *helper=@"/usr/bin/cazer-apple-searchparty-recover";
#if defined(TVAPPLE_DOPAMINE3)
    helper=ROOT_PATH_NS_VAR(helper);
#endif
    const char *path=helper.fileSystemRepresentation;
    struct stat info;
    if(lstat(path,&info)!=0||!S_ISREG(info.st_mode)||info.st_uid!=0||
       (info.st_mode&(S_IWGRP|S_IWOTH))||!(info.st_mode&S_ISUID)) {
        if(error)*error=TVAppleError(TVAppleErrorPermissionDenied,@"SearchParty is unresponsive; the trusted root recovery helper is unavailable.");return NO;
    }
    posix_spawn_file_actions_t actions;
    if(posix_spawn_file_actions_init(&actions)){
        if(error)*error=TVAppleError(TVAppleErrorBackendRead,@"SearchParty recovery setup failed.");return NO;
    }
    int setup=posix_spawn_file_actions_addopen(&actions,0,"/dev/null",O_RDONLY,0);
    if(!setup)setup=posix_spawn_file_actions_addopen(&actions,1,"/dev/null",O_WRONLY,0);
    if(!setup)setup=posix_spawn_file_actions_addopen(&actions,2,"/dev/null",O_WRONLY,0);
    if(setup){posix_spawn_file_actions_destroy(&actions);
        if(error)*error=TVAppleError(TVAppleErrorBackendRead,@"SearchParty recovery setup failed.");return NO;
    }
    pid_t child=0;char *argv[]={(char *)path,NULL};
    int spawned=posix_spawn(&child,path,&actions,NULL,argv,environ);posix_spawn_file_actions_destroy(&actions);
    if(spawned){if(error)*error=TVAppleError(TVAppleErrorBackendRead,@"SearchParty recovery helper could not start.");return NO;}
    int status=0;NSTimeInterval deadline=NSProcessInfo.processInfo.systemUptime+timeout;
    do {
        pid_t result=waitpid(child,&status,WNOHANG);
        if(result==child){
            if(WIFEXITED(status)&&WEXITSTATUS(status)==0)return YES;
            if(error)*error=TVAppleError(TVAppleErrorBackendRead,@"SearchParty recovery helper failed.");
            return NO; // Already reaped: never signal a potentially recycled PID.
        }
        if(result<0&&errno!=EINTR){
            if(error)*error=TVAppleError(TVAppleErrorBackendRead,@"SearchParty recovery helper status is unavailable.");
            return NO;
        }
        [[NSRunLoop currentRunLoop]runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    }while(NSProcessInfo.processInfo.systemUptime<deadline);
    // Reap asynchronously after killing only our owned helper process; never block
    // the account worker waiting on a stuck launchctl process.
    int stopped=kill(child,SIGKILL);int stopError=errno;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
        int ignored;NSTimeInterval reapDeadline=NSProcessInfo.processInfo.systemUptime+1;
        while(NSProcessInfo.processInfo.systemUptime<reapDeadline){
            pid_t result=waitpid(child,&ignored,WNOHANG);
            if(result==child||(result<0&&errno!=EINTR))break;
            usleep(10000);
        }
    });
    if(stopped&&stopError!=ESRCH){
        if(error)*error=TVAppleError(TVAppleErrorBackendRead,@"SearchParty recovery could not be terminated.");return NO;
    }
    if(error)*error=TVAppleError(TVAppleErrorBackendRead,@"SearchParty recovery failed or exceeded its deadline.");return NO;
}
@end
@implementation TVAppleSearchPartyGuard {
    id<TVAppleSearchPartyDriver> _driver;
    BOOL _recovered;
}
- (instancetype)initWithDriver:(id<TVAppleSearchPartyDriver>)driver{if((self=[super init]))_driver=driver;return self;}
- (BOOL)recovered{return _recovered;}
- (BOOL)prepare:(NSError **)error {
    _recovered=NO;
    TVAppleServiceHealth health=[_driver probeWithTimeout:5];
    if(health==TVAppleServiceHealthy)return YES;
    if(health!=TVAppleServiceUnresponsive){if(error)*error=TVAppleError(TVAppleErrorUnsupported,@"Native SearchParty health interface is unavailable.");return NO;}
    if(![_driver restartWithTimeout:5 error:error])return NO;
    if([_driver probeWithTimeout:10]!=TVAppleServiceHealthy){if(error)*error=TVAppleError(TVAppleErrorBackendRead,@"SearchParty did not recover; no account removal was submitted.");return NO;}
    _recovered=YES;return YES;
}
@end
BOOL TVApplePrepareSearchParty(BOOL *recovered,NSError **error) {
    TVAppleSearchPartyGuard *guard=[[TVAppleSearchPartyGuard alloc]initWithDriver:[TVAppleNativeSPDriver new]];
    BOOL ready=[guard prepare:error];if(recovered)*recovered=guard.recovered;return ready;
}
