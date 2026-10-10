#import "TVASAppLifecycle.h"
#include <dlfcn.h>
#include <sys/sysctl.h>
#include <signal.h>
#include <unistd.h>
@interface NSObject (TVASLaunchServices)
+ (id)applicationProxyForIdentifier:(NSString *)identifier;
+ (id)defaultWorkspace;
- (NSURL *)bundleURL;
- (NSString *)bundleExecutable;
- (BOOL)openApplicationWithBundleID:(NSString *)identifier;
@end
static id Failure(NSError **error, BOOL partial) {
    if(error)*error=[NSError errorWithDomain:@"TVASAppLifecycle" code:partial?2:1 userInfo:@{NSLocalizedDescriptionKey:@"App lifecycle operation failed",@"stateMayBePartial":@(partial)}];
    return nil;
}
static NSString *Canonical(NSString *path) {
    char *p=realpath(path.fileSystemRepresentation,NULL);if(!p)return nil;NSString *s=@(p);free(p);return s;
}
@implementation TVASAppLifecycle
- (NSDictionary *)target:(NSString *)bundle error:(NSError **)error {
    dlopen("/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices",RTLD_LAZY);
    Class cls=NSClassFromString(@"LSApplicationProxy");
    if(![cls respondsToSelector:@selector(applicationProxyForIdentifier:)])return Failure(error,NO);
    id proxy=[cls applicationProxyForIdentifier:bundle];
    NSString *root=Canonical([proxy bundleURL].path);
    if(!root)return @{@"installed":@NO};
    NSString *executable=Canonical([root stringByAppendingPathComponent:[proxy bundleExecutable]?:@""]);
    if(!executable || ![executable hasPrefix:[root stringByAppendingString:@"/"]])return Failure(error,NO);
    return @{@"installed":@YES,@"root":root,@"executable":executable};
}
- (NSArray *)processes:(NSDictionary *)target error:(NSError **)error {
    int (*pathfn)(int,void *,uint32_t)=dlsym(RTLD_DEFAULT,"proc_pidpath");
    if(!pathfn)return Failure(error,NO);
    int mib[]={CTL_KERN,KERN_PROC,KERN_PROC_ALL,0};size_t size=0;NSMutableData *data=nil;BOOL read=NO;
    for(int i=0;i<3;i++) {
        if(sysctl(mib,4,NULL,&size,NULL,0)!=0 || size>16*1024*1024)break;
        size+=sizeof(struct kinfo_proc)*32;data=[NSMutableData dataWithLength:size];
        if(sysctl(mib,4,data.mutableBytes,&size,NULL,0)==0){read=YES;break;}
        if(errno!=ENOMEM)break;
    }
    if(!read)return Failure(error,NO);
    NSMutableArray *result=[NSMutableArray new];const struct kinfo_proc *p=data.bytes;
    NSString *prefix=[target[@"root"] stringByAppendingString:@"/"];
    for(NSUInteger i=0;i<size/sizeof(*p);i++) {
        pid_t pid=p[i].kp_proc.p_pid;if(pid<=1 || pid==getpid() || p[i].kp_eproc.e_ucred.cr_uid!=501)continue;
        char path[4096]={0};
        if(pathfn(pid,path,sizeof(path))<=0){if(kill(pid,0)<0 && errno==ESRCH)continue;return Failure(error,NO);}
        NSString *canonical=Canonical(@(path));if(!canonical){if(kill(pid,0)<0 && errno==ESRCH)continue;return Failure(error,NO);}
        if([canonical hasPrefix:prefix])[result addObject:@{@"pid":@(pid),@"seconds":@(p[i].kp_proc.p_starttime.tv_sec),@"micros":@(p[i].kp_proc.p_starttime.tv_usec),@"path":canonical,@"main":@([canonical isEqual:target[@"executable"]])}];
    }
    return result;
}
- (NSDictionary *)identityForPID:(pid_t)pid error:(NSError **)error {
    int mib[]={CTL_KERN,KERN_PROC,KERN_PROC_PID,pid};struct kinfo_proc p={0};size_t size=sizeof(p);
    if(sysctl(mib,4,&p,&size,NULL,0)!=0){if(errno==ESRCH)return @{};return Failure(error,YES);}
    if(!size)return @{};
    if(size!=sizeof(p))return Failure(error,YES);
    return @{@"uid":@(p.kp_eproc.e_ucred.cr_uid),@"seconds":@(p.kp_proc.p_starttime.tv_sec),@"micros":@(p.kp_proc.p_starttime.tv_usec)};
}
- (NSString *)executableForPID:(pid_t)pid {
    int (*pathfn)(int,void *,uint32_t)=dlsym(RTLD_DEFAULT,"proc_pidpath");char path[4096]={0};
    return pathfn && pathfn(pid,path,sizeof(path))>0?Canonical(@(path)):nil;
}
- (BOOL)sendSignal:(int)sig pid:(pid_t)pid {return kill(pid,sig)==0 || errno==ESRCH;}
- (BOOL)signalProcess:(NSDictionary *)identity signal:(int)sig error:(NSError **)error {
    pid_t pid=[identity[@"pid"]intValue];NSDictionary *current=[self identityForPID:pid error:error];
    if(!current)return NO;
    if(!current.count || [current[@"uid"]intValue]!=501 || ![current[@"seconds"]isEqual:identity[@"seconds"]] || ![current[@"micros"]isEqual:identity[@"micros"]])return YES;
    NSString *path=[self executableForPID:pid];if(!path){Failure(error,YES);return NO;}
    if(![path isEqual:identity[@"path"]])return YES;
    if([self sendSignal:sig pid:pid])return YES;
    Failure(error,YES);return NO;
}
- (BOOL)launch:(NSString *)bundle {
    Class cls=NSClassFromString(@"LSApplicationWorkspace");
    if(![cls respondsToSelector:@selector(defaultWorkspace)])return NO;
    id workspace=[cls defaultWorkspace];
    return [workspace respondsToSelector:@selector(openApplicationWithBundleID:)] && [workspace openApplicationWithBundleID:bundle];
}
- (void)pause {usleep(50000);}
- (NSDictionary *)state:(NSArray *)processes bundle:(NSString *)bundle installed:(BOOL)installed {
    NSMutableArray *pids=[NSMutableArray new];NSUInteger mainCount=0;
    for(NSDictionary *p in processes){[pids addObject:p[@"pid"]];if([p[@"main"]boolValue])mainCount++;}
    return @{@"bundle_id":bundle,@"installed":@(installed),@"running":processes.count>0?@YES:@NO,@"main_running":mainCount>0?@YES:@NO,@"extension_process_count":@(processes.count-mainCount),@"pids":pids};
}
- (NSDictionary *)execute:(NSString *)method bundle:(NSString *)bundle error:(NSError **)error {
    if(error)*error=nil;
    if(![@[@"launch",@"stop",@"status"]containsObject:method])return Failure(error,NO);
    NSDictionary *target=[self target:bundle error:error];if(!target)return nil;
    BOOL installed=[target[@"installed"]boolValue];
    if(!installed)return [method isEqual:@"status"]?[self state:@[] bundle:bundle installed:NO]:Failure(error,NO);
    if(![method isEqual:@"status"] && ([bundle hasPrefix:@"com.apple."] || [bundle isEqual:@"com.82flex.TrollVNCApp"]))return Failure(error,NO);
    NSArray *processes=[self processes:target error:error];if(!processes)return nil;
    if([method isEqual:@"status"])return [self state:processes bundle:bundle installed:YES];
    if([method isEqual:@"launch"]) {
        if(![self launch:bundle])return Failure(error,YES);
    } else for(NSDictionary *p in processes)if(![self signalProcess:p signal:SIGTERM error:error])return nil;
    for(int tick=0;tick<80;tick++) {
        NSArray *current=[self processes:target error:error];if(!current)return Failure(error,YES);
        NSDictionary *state=[self state:current bundle:bundle installed:YES];
        if(([method isEqual:@"launch"] && [state[@"main_running"]boolValue]) || ([method isEqual:@"stop"] && !current.count))return state;
        if([method isEqual:@"stop"] && tick==10)for(NSDictionary *p in processes)if(![self signalProcess:p signal:SIGKILL error:error])return nil;
        [self pause];
    }
    return Failure(error,YES);
}
@end
