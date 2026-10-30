#import "TVAppStateServices.h"
#import "../src/TVASRuntime.h"
#import "../src/TVASAppLifecycle.h"
#import "../adapters/PXASNative.h"
#include <sys/stat.h>
#include <sys/file.h>
#include <fcntl.h>
#include <unistd.h>
static NSUInteger checks=0;
static void Check(BOOL value,const char *message) { if (!value) { fprintf(stderr,"FAIL: %s\n",message); exit(1); } checks++; }
@interface TVAppStateServices (TestSeam)
- (BOOL)isMobile;
- (id<PXASResolver>)resolver;
- (id<TVASProcessRunning>)processRunner;
- (NSDictionary *)operationPaths;
- (id)shadowSettingsForBundle:(NSString *)bundle;
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
    Check(![NSFileManager.defaultManager fileExistsAtPath:[executable.stringByDeletingLastPathComponent stringByAppendingPathComponent:@".jbroot"]],"copied worker has no RootHide dependency anchor");
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
@property (nonatomic, strong) id liveIDFV;
@end
@implementation Service
- (BOOL)isMobile { return YES; }
- (id<PXASResolver>)resolver { return self.execution; }
- (id<TVASProcessRunning>)processRunner { return self.runner; }
- (NSDictionary *)operationPaths { return self.paths; }
- (id)shadowSettingsForBundle:(NSString *)bundle {(void)bundle;return self.liveIDFV?@{@"Fingerprint_Data":@{@"VendorIdentifier":self.liveIDFV}}:@{};}
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
    NSString *shadow=[temp stringByAppendingPathComponent:@"ShadowBackups"];
    NSString *idfv=@"C65D96D4-7BD2-4FFF-BF95-0CB2930CAB53";
    NSString *snapshot=[[[shadow stringByAppendingPathComponent:@"test.app/snapshots"] stringByAppendingPathComponent:idfv] stringByAppendingPathComponent:@"manifest.plist"];
    Check([NSFileManager.defaultManager createDirectoryAtPath:snapshot.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:NULL],"create Shadow catalog fixture");
    Check([@{@"format":@"ShadowAppState2",@"bundleID":@"test.app",@"idfv":idfv,@"title":@"Shadow account",@"note":@"metadata only",@"date":NSDate.date,@"version":@"26.41.1",@"build":@"30253"} writeToFile:snapshot atomically:YES],"write Shadow manifest without archives");
    service.paths=@{@"shadow_backups":shadow};
    service.liveIDFV=idfv;
    NSDictionary *catalog=[service runBundle:@"test.app" request:@{@"operation":@"catalog"} error:&error];
    Check([catalog[@"backups"]count]==1 && [catalog[@"backups"][0][@"display_name"]isEqual:@"Shadow account"] && [catalog[@"backups"][0][@"idfv"]isEqual:idfv],"list maps Shadow manifest metadata");
    Check(service.runner.launches==0,"catalog never launches a worker or verifies archives");
    Check([catalog[@"current_idfv"]isEqual:idfv],"active identity does not require access token or a keychain worker");
    service.liveIDFV=@"7A70B21A-2F9D-4F66-81C4-6D21355758D7";
    Check([[[service runBundle:@"test.app" request:@{@"operation":@"catalog"} error:&error]objectForKey:@"current_idfv"]isEqual:service.liveIDFV],"a different current environment is reported even without credentials");
    service.liveIDFV=nil;
    Check([service runBundle:@"test.app" request:@{@"operation":@"catalog"} error:&error][@"current_idfv"]==NSNull.null,"no Shadow identity is explicit null, not a token error");
    Check(service.runner.launches==0,"current identity never launches a privileged keychain worker");
    for(id invalid in @[@"invalid-idfv",@42,NSNull.null,@""]) {
        service.liveIDFV=invalid;error=nil;
        Check(![service runBundle:@"test.app" request:@{@"operation":@"catalog"} error:&error] && error!=nil,"invalid current IDFV is an error, never inactive null");
    }
    service.liveIDFV=nil;error=nil;
    Check([NSFileManager.defaultManager contentsOfDirectoryAtPath:snapshot.stringByDeletingLastPathComponent error:NULL].count==1,"catalog leaves snapshot untouched");
    Check([[service runBundle:@"missing.app" request:@{@"operation":@"catalog"} error:&error][@"backups"]count]==0,"missing Shadow catalog is empty without creating directories");
    NSString *lockPath=[[shadow stringByAppendingPathComponent:@"test.app"] stringByAppendingPathComponent:@".lock"];
    Check([NSData.data writeToFile:lockPath atomically:NO],"create existing Shadow lock");
    NSDictionary *beforeEdit=[NSDictionary dictionaryWithContentsOfFile:snapshot];
    NSDictionary *edit=TVASRequest(@"edit",@{@"bundle_id":@"test.app",@"backup_id":[@"snapshot:" stringByAppendingString:idfv],@"display_name":@"New title",@"note":@""},&error);
    NSDictionary *edited=[service runBundle:@"test.app" request:edit error:&error];
    Check(edited!=nil && error==nil && [edited[@"backups"][0][@"display_name"]isEqual:@"New title"] && [edited[@"backups"][0][@"note"]isEqual:@""],"Shadow edit returns refreshed metadata and accepts empty note");
    NSMutableDictionary *expectedEdit=[beforeEdit mutableCopy];expectedEdit[@"title"]=@"New title";expectedEdit[@"note"]=@"";
    Check([[NSDictionary dictionaryWithContentsOfFile:snapshot]isEqual:expectedEdit],"edit changes only title and note, preserving all manifest fields");
    Check(service.runner.launches==0 && [NSFileManager.defaultManager contentsOfDirectoryAtPath:snapshot.stringByDeletingLastPathComponent error:NULL].count==1,"metadata edit never launches legacy worker, opens archives or leaves staging files");
    struct stat editedInfo;Check(!stat(snapshot.fileSystemRepresentation,&editedInfo) && (editedInfo.st_mode&0777)==0600 && editedInfo.st_uid==getuid(),"metadata edit preserves owner and private permissions");
    int held=open(lockPath.fileSystemRepresentation,O_RDWR);Check(held>=0 && !flock(held,LOCK_EX|LOCK_NB),"hold Shadow directory lock");
    error=nil;Check(![service runBundle:@"test.app" request:edit error:&error] && error!=nil,"metadata edit refuses busy Shadow lock");flock(held,LOCK_UN);close(held);
    NSMutableDictionary *bad=[edit mutableCopy];bad[@"reference"]=@"test.app/snapshots/../escape";error=nil;Check(![service runBundle:@"test.app" request:bad error:&error],"metadata edit rejects noncanonical identity");
    NSString *savedManifest=[snapshot stringByAppendingString:@".saved"];Check([NSFileManager.defaultManager moveItemAtPath:snapshot toPath:savedManifest error:NULL],"pin original manifest for link check");
    Check(!symlink(savedManifest.fileSystemRepresentation,snapshot.fileSystemRepresentation),"create symlink fixture");error=nil;Check(![service runBundle:@"test.app" request:edit error:&error],"metadata edit refuses symlink manifest");unlink(snapshot.fileSystemRepresentation);Check([NSFileManager.defaultManager moveItemAtPath:savedManifest toPath:snapshot error:NULL],"restore regular manifest fixture");
    error=nil;
    NSMutableDictionary *wrong=[[NSDictionary dictionaryWithContentsOfFile:snapshot]mutableCopy];wrong[@"format"]=@"AppState2";[wrong writeToFile:snapshot atomically:YES];
    Check([[service runBundle:@"test.app" request:@{@"operation":@"catalog"} error:&error][@"backups"]count]==0,"old format is not listed");
    service.paths=@{@"root":[temp stringByAppendingPathComponent:@"operations"],@"worker":template,@"vendor":template,@"bootstrap":temp,@"ldid":[temp stringByAppendingPathComponent:@"ldid"]};
    NSDictionary *result=[service runBundle:@"test.app" request:@{@"operation":@"save"} error:&error];
    Check(result!=nil && error==nil,"scoped worker success is parsed");
    NSUInteger launchesBeforeSwitch=service.runner.launches;
    error=nil;Check(![service runBundle:@"test.app" request:@{@"operation":@"switch"} error:&error] && error!=nil && service.runner.launches==launchesBeforeSwitch,"removed switch fails before old worker or archive access");
    service.runner.mode=@"copy-failure";error=nil;
    Check(![service runBundle:@"test.app" request:@{@"operation":@"save"} error:&error] && error.code==2 && [error.userInfo[@"posixCode"]intValue]==28 && [error.userInfo[@"sourceDomain"]isEqual:@"PXAppState"] && [error.userInfo[@"sourceCode"]intValue]==1,"known copy failure preserves finite file error metadata without becoming an unknown outcome");error=nil;
    Check([NSFileManager.defaultManager contentsOfDirectoryAtPath:service.paths[@"root"] error:NULL].count==0,"operation artifacts removed after success");
    for(NSString *operation in @[@"save",@"baseline",@"switch",@"delete",@"describe",@"profile",@"sessionSupplement"]) {
        __block BOOL finished=NO;NSUInteger count=service.runner.launches;
        [service executeBundle:@"test.app" request:@{@"operation":operation} completion:^(NSDictionary *value,NSError *failure){Check(value==nil && failure!=nil,"obsolete public interface is rejected");finished=YES;}];
        NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:5];
        while(!finished && deadline.timeIntervalSinceNow>0)[NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        Check(finished && service.runner.launches==count,"obsolete interface never launches legacy worker");
    }
    service.runner.mode=@"timeout";
    Check([service runBundle:@"test.app" request:@{@"operation":@"save"} error:&error]==nil && ![error.userInfo[@"stateMayBePartial"] boolValue] && [error.userInfo[@"archiveMayBePartial"] boolValue],"unknown save completion reports archive uncertainty without live restore"); error=nil;
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
    Check(![second runBundle:@"test.app" request:@{@"operation":@"save"} error:&timeoutError] && timeoutError.code==1,"only actual outstanding native work prevents a concurrent mutation");
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
