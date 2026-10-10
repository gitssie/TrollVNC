#import <Foundation/Foundation.h>
#import "TVNCAppStateService.h"
#import "TVAppStateServices.h"
#import "ZXTouchTCPServer.h"
#define CHECK(x) do{if(!(x)){fprintf(stderr,"FAIL %d\n",__LINE__);exit(1);}}while(0)
@interface Fake : TVAppStateServices
@property void (^pending)(NSDictionary *,NSError *);
@property NSDictionary *request;
@end
@implementation Fake
- (void)executeBundle:(NSString *)b request:(NSDictionary *)r progress:(void (^)(NSDictionary *))p completion:(void (^)(NSDictionary *,NSError *))c {
    (void)b;self.pending=c;self.request=r;if(p)p(@{@"phase":@"backup",@"stage":@"verify",@"credential":@"SECRET"});
}
@end
@interface SocketFake : TVAppStateServices
@end
@implementation SocketFake
- (void)executeBundle:(NSString *)b request:(NSDictionary *)r progress:(void (^)(NSDictionary *))p completion:(void (^)(NSDictionary *,NSError *))c {
    if(p)p(@{@"phase":@"backup",@"stage":@"verify"});
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,200*NSEC_PER_MSEC),dispatch_get_main_queue(),^{
        if([r[@"operation"]isEqual:@"switch"]){CHECK([r[@"reference"]isEqual:@"test.app/snapshots/20261006-01"]);}
        if([@[@"launch",@"stop",@"status"]containsObject:r[@"operation"]]) {
            BOOL running=![r[@"operation"]isEqual:@"stop"];
            c(@{@"bundle_id":b,@"installed":@YES,@"running":@(running),@"main_running":@(running),@"extension_process_count":@0,@"pids":running?@[@42]:@[]},nil);return;
        }
        c(@{@"bundle_id":b,@"backups":@[@{@"backup_id":@"snapshot:20261006-01",@"display_name":@"雪;;Name\r\nNext"}],@"current_backup_id":@"snapshot:20261006-01",@"restore_pending":@NO},nil);
    });
}
@end
static NSDictionary *Call(TVNCAppStateService *s,NSDictionary *d){
    NSString *payload=[[NSJSONSerialization dataWithJSONObject:d options:0 error:nil]base64EncodedStringWithOptions:0];
    NSString *reply=[[NSString alloc]initWithData:[s handlePayload:payload] encoding:NSUTF8StringEncoding];
    CHECK([reply hasPrefix:@"0;;"]&&[reply hasSuffix:@"\r\n"]);
    NSData *data=[[NSData alloc]initWithBase64EncodedString:[reply substringWithRange:NSMakeRange(3,reply.length-5)] options:0];
    return [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
}
static NSDictionary *Invoke(TVNCAppStateService *s,NSString *m,NSDictionary *p){return Call(s,@{@"action":@"invoke",@"method":m,@"params":p});}
int main(int argc,const char **argv){@autoreleasepool{
    if(argc==2){
        TVNCAppStateService *adapter=[[TVNCAppStateService alloc]initWithServices:[SocketFake new]];
        ZXTouchTCPServer *server=[[ZXTouchTCPServer alloc]initWithHandler:^NSData *(const zxtouch::Command &cmd,NSUInteger client){
            (void)client;if(cmd.task!=32)return [@"-1;;unsupported\r\n" dataUsingEncoding:NSUTF8StringEncoding];
            return [adapter handlePayload:[[NSString alloc]initWithBytes:cmd.payload.data() length:cmd.payload.size() encoding:NSUTF8StringEncoding]];
        } disconnected:^(NSUInteger client){(void)client;}];
        CHECK([server startOnHost:@"127.0.0.1" port:atoi(argv[1]) error:nil]);puts("READY");fflush(stdout);[[NSRunLoop currentRunLoop]run];return 0;
    }
    Fake *fake=[Fake new];TVNCAppStateService *s=[[TVNCAppStateService alloc]initWithServices:fake];
    CHECK(Invoke(s,@"switch",@{@"bundle_id":@"test.app"})[@"error"]);
    NSString *op=Invoke(s,@"switch",@{@"bundle_id":@"test.app",@"backup_id":@"snapshot:20261006-01"})[@"operation_id"];CHECK(op);
    CHECK([fake.request[@"reference"]isEqual:@"test.app/snapshots/20261006-01"]);
    CHECK([Invoke(s,@"list",@{@"bundle_id":@"test.app"})[@"error"][@"code"]isEqual:@"busy"]);
    NSDictionary *state=Call(s,@{@"action":@"result",@"operation_id":op});CHECK([state[@"progress"]count]==2);
    fake.pending(nil,[NSError errorWithDomain:@"TVAppStateServices" code:2 userInfo:@{@"stateMayBePartial":@YES,@"password":@"SECRET"}]);
    state=Call(s,@{@"action":@"result",@"operation_id":op});CHECK([state[@"error"][@"state_may_be_partial"]boolValue] && !state[@"error"][@"password"]);
    // Known finished partial restore can be retried; durable session prevents saving it.
    op=Invoke(s,@"switch",@{@"bundle_id":@"test.app",@"backup_id":@"snapshot:20261006-01"})[@"operation_id"];CHECK(op);
    fake.pending(nil,[NSError errorWithDomain:@"TVAppStateServices" code:4 userInfo:@{@"stateMayBePartial":@YES}]);
    CHECK([Invoke(s,@"save",@{@"bundle_id":@"test.app"})[@"error"][@"code"]isEqual:@"outcome_unknown"]);
    CHECK([Invoke(s,@"launch",@{@"bundle_id":@"test.app"})[@"error"][@"code"]isEqual:@"outcome_unknown"]);
    CHECK([Invoke(s,@"stop",@{@"bundle_id":@"test.app"})[@"error"][@"code"]isEqual:@"outcome_unknown"]);
    op=Invoke(s,@"status",@{@"bundle_id":@"test.app"})[@"operation_id"];CHECK(op && [fake.request[@"operation"]isEqual:@"status"]);fake.pending(@{@"bundle_id":@"test.app",@"running":@NO},nil);
    op=Invoke(s,@"list",@{@"bundle_id":@"test.app"})[@"operation_id"];CHECK(op);fake.pending(@{@"backups":@[]},nil);
    // Duplicate completion cannot overwrite a finished result.
    fake.pending(nil,[NSError errorWithDomain:@"fake" code:1 userInfo:nil]);CHECK(!Call(s,@{@"action":@"result",@"operation_id":op})[@"error"]);
    op=Invoke(s,@"describe",@{@"bundle_id":@"test.app"})[@"operation_id"];[s stop];fake.pending(@{@"bundle_id":@"test.app"},nil);
    CHECK([Call(s,@{@"action":@"result",@"operation_id":op})[@"status"]isEqual:@"completed"]);CHECK(Invoke(s,@"list",@{@"bundle_id":@"test.app"})[@"error"]);
    puts("App-state socket adapter tests PASS");
}return 0;}
