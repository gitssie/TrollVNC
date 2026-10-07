#import "TVAppleSearchParty.h"
#include <assert.h>
@interface Driver : NSObject <TVAppleSearchPartyDriver>
@property NSArray *states;
@property NSUInteger probes,restarts;
@property BOOL restartOK;
@end
@implementation Driver
- (TVAppleServiceHealth)probeWithTimeout:(NSTimeInterval)timeout {
    assert(timeout==5||timeout==10);return [self.states[self.probes++]unsignedIntegerValue];
}
- (BOOL)restartWithTimeout:(NSTimeInterval)timeout error:(NSError **)error {
    assert(timeout==5);self.restarts++;if(!self.restartOK&&error)*error=TVAppleError(TVAppleErrorBackendRead,@"test failure");return self.restartOK;
}
@end
static void Check(NSArray *states,BOOL restartOK,BOOL success,NSUInteger probes,NSUInteger restarts,BOOL recovered){
    Driver *driver=[Driver new];driver.states=states;driver.restartOK=restartOK;
    TVAppleSearchPartyGuard *guard=[[TVAppleSearchPartyGuard alloc]initWithDriver:driver];NSError *error=nil;
    assert([guard prepare:&error]==success);assert((error==nil)==success);
    assert(driver.probes==probes&&driver.restarts==restarts&&guard.recovered==recovered);
}
@interface Manager : NSObject
@property dispatch_queue_t queue;
@property NSUInteger responses,invalidations;
@property BOOL late;
@property dispatch_semaphore_t blockedProxy;
@property(copy) void(^completion)(long long);
@end
@implementation Manager
- (instancetype)init{if((self=[super init])){_queue=dispatch_queue_create("test.searchparty",DISPATCH_QUEUE_SERIAL);dispatch_queue_set_specific(_queue,(__bridge const void *)self,(__bridge void *)self,NULL);}return self;}
- (void)start{}
- (void)invalidate{self.invalidations++;}
- (id)proxy{assert(dispatch_get_specific((__bridge const void *)self));if(self.blockedProxy)dispatch_semaphore_wait(self.blockedProxy,DISPATCH_TIME_FOREVER);return self;}
- (void)beaconingStateWithCompletion:(void(^)(long long))completion{
    if(self.late){self.completion=completion;return;}
    for(NSUInteger i=0;i<self.responses;i++)completion(3);
}
@end
int main(void){@autoreleasepool{
    Check(@[@(TVAppleServiceHealthy)],YES,YES,1,0,NO);
    Check(@[@(TVAppleServiceUnavailable)],YES,NO,1,0,NO);
    Check(@[@(TVAppleServiceUnresponsive)],NO,NO,1,1,NO);
    Check(@[@(TVAppleServiceUnresponsive),@(TVAppleServiceHealthy)],YES,YES,2,1,YES);
    Check(@[@(TVAppleServiceUnresponsive),@(TVAppleServiceUnresponsive)],YES,NO,2,1,NO);
    Check(@[@(TVAppleServiceUnresponsive),@(TVAppleServiceUnavailable)],YES,NO,2,1,NO);
    assert(TVAppleSearchPartyProbeManager([NSObject new],0.05)==TVAppleServiceUnavailable);
    Manager *manager=[Manager new];manager.responses=2;
    assert(TVAppleSearchPartyProbeManager(manager,0.2)==TVAppleServiceHealthy);dispatch_sync(manager.queue,^{});assert(manager.invalidations==1);
    manager=[Manager new];manager.late=YES;
    assert(TVAppleSearchPartyProbeManager(manager,0.05)==TVAppleServiceUnresponsive);dispatch_sync(manager.queue,^{});assert(manager.invalidations==1);
    manager.completion(3);manager.completion(3); // Late/duplicate callbacks stay closed.
    manager.completion=nil;
    manager=[Manager new];manager.blockedProxy=dispatch_semaphore_create(0);
    NSTimeInterval started=NSProcessInfo.processInfo.systemUptime;
    assert(TVAppleSearchPartyProbeManager(manager,0.05)==TVAppleServiceUnresponsive);
    assert(NSProcessInfo.processInfo.systemUptime-started<0.5);
    dispatch_semaphore_signal(manager.blockedProxy);dispatch_sync(manager.queue,^{});
    assert(manager.invalidations==1);
    puts("PASS searchparty: recovery boundaries, queue affinity, duplicate/late callbacks");
}return 0;}
