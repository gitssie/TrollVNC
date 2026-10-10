#import "../src/TVASAppLifecycle.h"
#include <signal.h>
@interface TVASAppLifecycle (SignalTest)
- (BOOL)signalProcess:(NSDictionary *)identity signal:(int)sig error:(NSError **)error;
@end
@interface SignalSpy : TVASAppLifecycle
@property NSDictionary *identity;
@property NSString *path;
@property NSUInteger deliveries;
@end
@implementation SignalSpy
- (NSDictionary *)identityForPID:(pid_t)pid error:(NSError **)error {(void)pid;(void)error;return self.identity;}
- (NSString *)executableForPID:(pid_t)pid {(void)pid;return self.path;}
- (BOOL)sendSignal:(int)sig pid:(pid_t)pid {(void)sig;(void)pid;self.deliveries++;return YES;}
@end
@interface FakeLifecycle : TVASAppLifecycle
@property BOOL absent;
@property BOOL failRead;
@property BOOL launchOK;
@property BOOL survive;
@property NSUInteger launches;
@property NSMutableArray *live;
@property NSMutableArray *signals;
@end
@implementation FakeLifecycle
- (NSDictionary *)target:(NSString *)bundle error:(NSError **)error {(void)bundle;(void)error;return @{@"installed":@(!self.absent)};}
- (NSArray *)processes:(NSDictionary *)target error:(NSError **)error {(void)target;(void)error;return self.failRead?nil:self.live.copy;}
- (BOOL)launch:(NSString *)bundle {(void)bundle;self.launches++;if(self.launchOK)[self.live addObject:@{@"pid":@42,@"main":@YES}];return self.launchOK;}
- (BOOL)signalProcess:(NSDictionary *)identity signal:(int)sig error:(NSError **)error {(void)error;[self.signals addObject:@(sig)];if(sig==SIGKILL && !self.survive)[self.live removeObject:identity];return YES;}
- (void)pause {}
@end
#define CHECK(x) do{if(!(x)){fprintf(stderr,"FAIL %d\n",__LINE__);exit(1);}}while(0)
int main(){@autoreleasepool{
    SignalSpy *spy=[SignalSpy new];spy.identity=@{@"uid":@501,@"seconds":@7,@"micros":@8};spy.path=@"/other/executable";
    NSDictionary *identity=@{@"pid":@42,@"seconds":@7,@"micros":@8,@"path":@"/target/App"};
    CHECK([spy signalProcess:identity signal:SIGTERM error:NULL] && !spy.deliveries);
    CHECK([spy signalProcess:identity signal:SIGKILL error:NULL] && !spy.deliveries);
    spy.path=@"/target/App";CHECK([spy signalProcess:identity signal:SIGTERM error:NULL] && spy.deliveries==1);
    spy.identity=@{@"uid":@501,@"seconds":@9,@"micros":@8};CHECK([spy signalProcess:identity signal:SIGKILL error:NULL] && spy.deliveries==1);
    FakeLifecycle *f=[FakeLifecycle new];f.live=[NSMutableArray new];f.signals=[NSMutableArray new];NSError *e=nil;
    f.absent=YES;NSDictionary *r=[f execute:@"status" bundle:@"test.app" error:&e];CHECK(![r[@"installed"]boolValue] && !e);
    CHECK(![f execute:@"launch" bundle:@"test.app" error:&e] && e && !f.launches);
    f.absent=NO;f.launchOK=YES;r=[f execute:@"launch" bundle:@"test.app" error:&e];CHECK([r[@"main_running"]boolValue] && f.launches==1 && !e);
    [f.live addObject:@{@"pid":@43,@"main":@NO}];r=[f execute:@"status" bundle:@"test.app" error:&e];CHECK([r[@"extension_process_count"]intValue]==1 && [r[@"pids"]count]==2);
    CHECK(![f execute:@"stop" bundle:@"com.apple.springboard" error:&e] && !f.signals.count);
    r=[f execute:@"stop" bundle:@"test.app" error:&e];CHECK(![r[@"running"]boolValue] && f.signals.count==4 && !e);
    [f.live addObject:@{@"pid":@44,@"main":@NO}];f.survive=YES;CHECK(![f execute:@"stop" bundle:@"test.app" error:&e] && [e.userInfo[@"stateMayBePartial"]boolValue]);
    f.failRead=YES;NSUInteger before=f.launches;CHECK(![f execute:@"launch" bundle:@"test.app" error:&e] && f.launches==before);
    f.failRead=NO;[f.live removeAllObjects];f.launchOK=NO;CHECK(![f execute:@"launch" bundle:@"test.app" error:&e] && [e.userInfo[@"stateMayBePartial"]boolValue]);
    puts("App lifecycle installation/status/launch/stop/extensions/protection/timeout tests PASS (native calls substituted)");
}return 0;}
