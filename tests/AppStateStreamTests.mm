#import <Foundation/Foundation.h>
#import "TVNCAppStateStream.h"
#import "TVNCAppStateService.h"
#import "TVAppStateServices.h"
#include <atomic>
#include <mutex>
#include <vector>
#include <string>
#include <thread>
#define CHECK(x) do{if(!(x)){fprintf(stderr,"FAIL %d\n",__LINE__);exit(1);}}while(0)
struct Bridge { std::mutex lock; std::vector<std::string> frames; std::atomic<bool> open{true}, blocked{false}; std::atomic<int> released{0}; };
extern "C" void *tvnc_http_stream_new(void **producer) { auto *bridge=new Bridge;*producer=bridge;return bridge; }
extern "C" bool tvnc_http_stream_send(void *p,const unsigned char *data,size_t len) {
    auto *b=(Bridge *)p;CHECK(b->released==0);
    if(!b->open || b->blocked)return false;
    std::lock_guard<std::mutex> guard(b->lock);b->frames.emplace_back((const char *)data,len);return true;
}
extern "C" bool tvnc_http_stream_open(void *p) { auto *b=(Bridge *)p;CHECK(b->released==0);return b->open; }
extern "C" void tvnc_http_stream_release(void *p) { auto *b=(Bridge *)p;CHECK(b->released.fetch_add(1)==0); }
// The service seam is substituted; no native workers, containers or credentials are used.
@implementation TVAppStateServices
- (void)executeBundle:(NSString *)b request:(NSDictionary *)r completion:(void (^)(NSDictionary *,NSError *))c {(void)b;(void)r;(void)c;}
- (void)executeBundle:(NSString *)b request:(NSDictionary *)r progress:(void (^)(NSDictionary *))p completion:(void (^)(NSDictionary *,NSError *))c {(void)b;(void)r;(void)p;(void)c;}
@end
@interface StreamFake : TVAppStateServices
@property(copy) void (^progress)(NSDictionary *);
@property(copy) void (^completion)(NSDictionary *,NSError *);
@property NSUInteger invokes;
@end
@implementation StreamFake
- (void)executeBundle:(NSString *)b request:(NSDictionary *)r progress:(void (^)(NSDictionary *))p completion:(void (^)(NSDictionary *,NSError *))c {
    (void)b;(void)r;@synchronized(self){self.invokes++;self.progress=p;self.completion=c;}
}
@end
static void Wait(BOOL (^ready)(void)) {
    for(int i=0;i<300;i++){if(ready())return;std::this_thread::sleep_for(std::chrono::milliseconds(10));}CHECK(NO);
}
static NSArray *Frames(Bridge *b) {
    std::lock_guard<std::mutex> guard(b->lock);NSMutableArray *frames=[NSMutableArray new];
    for(auto &raw:b->frames){NSData *data=[NSData dataWithBytes:raw.data() length:raw.size()];[frames addObject:[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]];}
    return frames;
}
static NSDictionary *Invoke(void) { return @{@"action":@"invoke",@"method":@"createBaseline",@"params":@{@"bundle_id":@"test.app"}}; }
int main(){@autoreleasepool{
    StreamFake *fake=[StreamFake new];TVNCAppStateService *service=[[TVNCAppStateService alloc]initWithServices:fake];
    auto response=TVNCAppStateStreamResponse(service,Invoke(),^BOOL{return YES;});Bridge *bridge=(Bridge *)response.stream;
    Wait(^BOOL{return Frames(bridge).count>0;});
    NSString *operation=Frames(bridge)[0][@"record"][@"operation_id"];CHECK(operation && fake.invokes==1);
    for(int i=0;i<200;i++)fake.progress(@{@"phase":@"backup",@"stage":@"copy",@"files":@(i),@"bytes":@(i*100),@"secret":@"NO"});
    Wait(^BOOL{return Frames(bridge).count>=2;});
    CHECK(Frames(bridge).count<10 && !Frames(bridge).lastObject[@"record"][@"progress"][@"secret"]);
    fake.completion(@{@"bundle_id":@"test.app",@"backups":@[]},nil);
    Wait(^BOOL{return bridge->released==1;});
    CHECK([Frames(bridge).lastObject[@"record"][@"status"]isEqual:@"completed"]);
    NSUInteger count=Frames(bridge).count;fake.progress(@{@"phase":@"restore",@"stage":@"copy"});fake.completion(nil,[NSError errorWithDomain:@"late" code:1 userInfo:nil]);
    CHECK(Frames(bridge).count==count && fake.invokes==1);
    delete bridge;

    fake=[StreamFake new];service=[[TVNCAppStateService alloc]initWithServices:fake];
    response=TVNCAppStateStreamResponse(service,Invoke(),^BOOL{return YES;});Bridge *disconnected=(Bridge *)response.stream;
    Wait(^BOOL{return Frames(disconnected).count>0;});operation=Frames(disconnected)[0][@"record"][@"operation_id"];
    disconnected->open=false;Wait(^BOOL{return disconnected->released==1;});
    response=TVNCAppStateStreamResponse(service,@{@"action":@"result",@"operation_id":operation},^BOOL{return YES;});Bridge *resumed=(Bridge *)response.stream;
    Wait(^BOOL{return Frames(resumed).count>0;});CHECK(fake.invokes==1);
    resumed->blocked=true;fake.completion(@{@"bundle_id":@"test.app",@"backups":@[]},nil);
    std::this_thread::sleep_for(std::chrono::milliseconds(250));CHECK(resumed->released==0);
    resumed->blocked=false;Wait(^BOOL{return resumed->released==1;});
    CHECK([Frames(resumed).lastObject[@"record"][@"status"]isEqual:@"completed"] && fake.invokes==1);
    delete disconnected;delete resumed;

    fake=[StreamFake new];service=[[TVNCAppStateService alloc]initWithServices:fake];
    response=TVNCAppStateStreamResponse(service,Invoke(),^BOOL{return NO;});Bridge *rejected=(Bridge *)response.stream;
    Wait(^BOOL{return rejected->released==1;});CHECK(fake.invokes==0);delete rejected;
    puts("PASS app-state stream progress/coalescing/terminal/late callback/disconnect/resume/backpressure/no replay");
}return 0;}
