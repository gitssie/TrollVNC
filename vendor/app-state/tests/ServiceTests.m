#import "TVAppStateServices.h"
#import "../src/TVASRuntime.h"
#import "../src/TVASAppLifecycle.h"
#import "../adapters/PXASNative.h"
#include <sys/stat.h>
static NSUInteger checks=0;
static void Check(BOOL value,const char *message) { if (!value) { fprintf(stderr,"FAIL: %s\n",message); exit(1); } checks++; }
@interface TVAppStateServices (TestSeam)
- (BOOL)isMobile;
- (id<PXASResolver>)resolver;
- (id<TVASProcessRunning>)processRunner;
- (NSDictionary *)operationPaths;
- (NSDictionary *)runBundle:(NSString *)bundleID request:(NSDictionary *)request error:(NSError **)error;
@end
@interface BlockingLifecycle : TVASAppLifecycle
@property dispatch_semaphore_t gate;
@end
@implementation BlockingLifecycle
- (NSDictionary *)execute:(NSString *)method bundle:(NSString *)bundle error:(NSError **)error {
    (void)method;(void)error;dispatch_semaphore_wait(self.gate,DISPATCH_TIME_FOREVER);return @{@"bundle_id":bundle};
}
@end
@interface TimedService : TVAppStateServices
@property BlockingLifecycle *fake;
@end
@implementation TimedService
- (BOOL)isMobile{return YES;}
- (TVASAppLifecycle *)lifecycle{return self.fake;}
- (NSTimeInterval)lifecycleTimeout{return .05;}
@end
@interface Execution : NSObject <PXASResolver>
@property (nonatomic, copy) NSDictionary *entitlements;
@end
@implementation Execution
- (NSDictionary *)resolve:(NSString *)bundleIdentifier error:(NSError **)error {
    (void)error;return @{@"bundleID":bundleIdentifier,@"signedEntitlements":self.entitlements};
}
- (BOOL)assertStopped:(NSDictionary *)target error:(NSError **)error {(void)target;(void)error;return YES;}

@end
@interface Runner : NSObject <TVASProcessRunning>
@property (nonatomic, copy) NSString *mode;
@property (nonatomic, assign) NSUInteger launches;
@end
@implementation Runner
- (BOOL)runExecutable:(NSString *)executable arguments:(NSArray *)arguments timeout:(NSTimeInterval)timeout standardOutput:(NSData **)output error:(NSError **)error {
    (void)timeout;
    if ([executable.lastPathComponent isEqual:@"ldid"]) {
        if ([arguments.firstObject isEqual:@"-e"] && output) *output=[NSData dataWithContentsOfFile:[arguments.lastObject stringByAppendingPathExtension:@"entitlements.plist"]];
        return YES;
    }
    self.launches++;
    if([self.mode isEqual:@"progress-final"]) {
        NSString *path=[executable.stringByDeletingLastPathComponent stringByAppendingPathComponent:@"progress.plist"];
        Check([@{@"phase":@"restore",@"stage":@"verify_preferences",@"savedCurrent":@YES} writeToFile:path atomically:YES],"write fast final verification event");
        chmod(path.fileSystemRepresentation,0600);
    }
    NSDictionary *ent=[NSDictionary dictionaryWithContentsOfFile:[executable stringByAppendingPathExtension:@"entitlements.plist"]];
    Check([ent[@"keychain-access-groups"] isEqual:@[@"TEAM.custom",@"TEAM.test.app",@"group.test.app"]],"worker receives all exact effective groups");
    Check([ent[@"application-identifier"] isEqual:@"TEAM.test.app"],"worker uses target application identifier");
    if ([self.mode isEqual:@"timeout"]) { if (error) *error=[NSError errorWithDomain:@"runner" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Timed out"}]; return NO; }
    if ([self.mode isEqual:@"invalid"]) { if (output) *output=[@"invalid response" dataUsingEncoding:NSUTF8StringEncoding]; return YES; }
    NSMutableDictionary *response=[@{@"ok":@YES,@"result":@{@"entries":@[],@"currentReference":@""}} mutableCopy];
    if([self.mode isEqual:@"copy-failure"])response=[@{@"ok":@NO,@"message":@"Container copy failed",@"stateMayBePartial":@YES,@"posixCode":@28,@"errorDomain":@"PXAppState",@"errorCode":@1}mutableCopy];
    if ([self.mode isEqual:@"partial"] || [self.mode isEqual:@"cleanup"]) {
        response=[@{@"ok":@NO,@"message":@"Publication failed",@"archiveMayBePartial":@YES,@"stateMayBePartial":@NO,
            @"pendingCaptureReference":@"test.app/snapshots/.capture-test"} mutableCopy];
    }
    if ([self.mode isEqual:@"cleanup"]) {
        NSString *directory=executable.stringByDeletingLastPathComponent;
        Check([NSFileManager.defaultManager moveItemAtPath:directory toPath:[directory stringByAppendingString:@"-moved"] error:NULL],"simulate operation directory replacement");
        Check([@"foreign occupant" writeToFile:directory atomically:NO encoding:NSUTF8StringEncoding error:NULL],"occupy original worker directory path");
    }
    if (output) *output=[NSPropertyListSerialization dataWithPropertyList:response format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL]; return YES;
}
@end
@interface Service : TVAppStateServices
@property (nonatomic, strong) Execution *execution;
@property (nonatomic, strong) Runner *runner;
@property (nonatomic, copy) NSDictionary *paths;
@end
@implementation Service
- (BOOL)isMobile { return YES; }
- (id<PXASResolver>)resolver { return self.execution; }
- (id<TVASProcessRunning>)processRunner { return self.runner; }
- (NSDictionary *)operationPaths { return self.paths; }
@end
int main(void) { @autoreleasepool {
    NSString *temp=[NSTemporaryDirectory() stringByAppendingPathComponent:[@"px-app-state-service-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    Check([NSFileManager.defaultManager createDirectoryAtPath:temp withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:NULL],"create private fixture");
    NSString *template=[temp stringByAppendingPathComponent:@"template"];
    Check([@"unsigned fixture" writeToFile:template atomically:NO encoding:NSUTF8StringEncoding error:NULL],"create fixture worker template");
    Service *service=[Service new]; service.execution=[Execution new]; service.runner=[Runner new];
    service.execution.entitlements=@{@"application-identifier":@"TEAM.test.app",@"keychain-access-groups":@[@"TEAM.custom"],@"com.apple.security.application-groups":@[@"group.test.app"]};
    service.paths=@{@"root":[temp stringByAppendingPathComponent:@"operations"],@"worker":template,@"vendor":template,@"bootstrap":temp,@"ldid":[temp stringByAppendingPathComponent:@"ldid"]};
    NSError *error=nil;
    NSDictionary *result=[service runBundle:@"test.app" request:@{@"operation":@"catalog"} error:&error];
    Check(result!=nil && error==nil,"scoped worker success is parsed");
    service.runner.mode=@"copy-failure";error=nil;
    Check(![service runBundle:@"test.app" request:@{@"operation":@"switch"} error:&error] && error.code==2 && [error.userInfo[@"posixCode"]intValue]==28 && [error.userInfo[@"sourceDomain"]isEqual:@"PXAppState"] && [error.userInfo[@"sourceCode"]intValue]==1,"known copy failure preserves finite file error metadata without becoming an unknown outcome");error=nil;
    Check([NSFileManager.defaultManager contentsOfDirectoryAtPath:service.paths[@"root"] error:NULL].count==0,"operation artifacts removed after success");
    service.runner.mode=@"progress-final";
    __block BOOL finished=NO;NSMutableArray *events=[NSMutableArray array];
    [service executeBundle:@"test.app" request:@{@"operation":@"switch"} progress:^(NSDictionary *event){
        Check(!finished,"progress precedes operation completion");[events addObject:event];
    } completion:^(NSDictionary *value,NSError *failure){
        Check(value!=nil && failure==nil,"progress operation completes");finished=YES;
    }];
    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:5];
    while(!finished && deadline.timeIntervalSinceNow>0)[NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    Check(finished && [events.lastObject[@"stage"] isEqual:@"verify_preferences"] && [events.lastObject[@"savedCurrent"] boolValue],"final verification stage survives a worker faster than polling");
    service.runner.mode=@"timeout";
    Check([service runBundle:@"test.app" request:@{@"operation":@"switch"} error:&error]==nil && [error.userInfo[@"stateMayBePartial"] boolValue] && [error.userInfo[@"archiveMayBePartial"] boolValue],"unknown switch completion conservatively reports partial live and archive state"); error=nil;
    Check([service runBundle:@"test.app" request:@{@"operation":@"baseline"} error:&error]==nil && [error.userInfo[@"archiveMayBePartial"]boolValue],"unknown baseline worker marks archive uncertainty");error=nil;
    service.runner.mode=@"invalid";
    Check([service runBundle:@"test.app" request:@{@"operation":@"save"} error:&error]==nil && [error.userInfo[@"archiveMayBePartial"] boolValue] && ![error.userInfo[@"stateMayBePartial"] boolValue],"invalid capture response marks archive uncertainty only"); error=nil;
    service.runner.mode=@"partial";
    Check([service runBundle:@"test.app" request:@{@"operation":@"save"} error:&error]==nil && [error.userInfo[@"pendingCaptureReference"] isEqual:@"test.app/snapshots/.capture-test"],"replacement failure preserves completed capture recovery reference"); error=nil;
    service.runner.mode=@"cleanup";
    Check([service runBundle:@"test.app" request:@{@"operation":@"save"} error:&error]==nil && [error.userInfo[@"archiveMayBePartial"] boolValue] && [error.userInfo[@"pendingCaptureReference"] isEqual:@"test.app/snapshots/.capture-test"],"cleanup failure preserves original partial flags and recovery reference");
    error=nil; NSUInteger launched=service.runner.launches;
    service.execution.entitlements=@{@"application-identifier":@"TEAM.test.app",@"keychain-access-groups":@[@"*"]};
    Check([service runBundle:@"test.app" request:@{@"operation":@"save"} error:&error]==nil && service.runner.launches==launched,"unsafe entitlement rejected before any worker launch");
    Check([NSFileManager.defaultManager removeItemAtPath:temp error:NULL],"remove isolated fixture");
    TimedService *timed=[TimedService new];timed.fake=[BlockingLifecycle new];timed.fake.gate=dispatch_semaphore_create(0);NSError *timeoutError=nil;
    Check(![timed runBundle:@"test.app" request:@{@"operation":@"launch"} error:&timeoutError] && timeoutError.code==4 && [timeoutError.userInfo[@"stateMayBePartial"]boolValue],"blocked LaunchServices returns unknown rather than holding command queue");
    Check(![timed runBundle:@"test.app" request:@{@"operation":@"status"} error:&timeoutError] && timeoutError.code==1,"no second native lifecycle call while previous call remains outstanding");
    TimedService *second=[TimedService new];second.fake=timed.fake;
    Check(![second runBundle:@"test.app" request:@{@"operation":@"status"} error:&timeoutError] && timeoutError.code==1,"new facade cannot launch another read while native call remains outstanding");
    Check(![second runBundle:@"test.app" request:@{@"operation":@"switch"} error:&timeoutError] && timeoutError.code==1,"only actual outstanding native work prevents a concurrent mutation");
    dispatch_semaphore_signal(timed.fake.gate);
    second.fake=[BlockingLifecycle new];second.fake.gate=dispatch_semaphore_create(0);dispatch_semaphore_signal(second.fake.gate);
    NSDate *releaseDeadline=[NSDate dateWithTimeIntervalSinceNow:2];NSDictionary *ready=nil;
    while(!ready && releaseDeadline.timeIntervalSinceNow>0) {
        timeoutError=nil;ready=[second runBundle:@"test.app" request:@{@"operation":@"status"} error:&timeoutError];
        if(!ready)[NSThread sleepForTimeInterval:.005];
    }
    Check(ready!=nil,"late native completion releases the execution gate");
    dispatch_semaphore_signal(second.fake.gate);timeoutError=nil;
    Check([second runBundle:@"test.app" request:@{@"operation":@"launch"} error:&timeoutError]!=nil && !timeoutError,"past timeout does not permanently block the next explicit mutation");
    printf("%lu app-state service assertions passed; no device authority used.\n",(unsigned long)checks);
} return 0; }
