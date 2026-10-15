#import "TVNCAppStateStream.h"
#import "TVNCAppStateService.h"

@interface TVNCAppStateStream : NSObject
- (instancetype)initWithService:(TVNCAppStateService *)service producer:(void *)producer active:(BOOL (^)(void))active;
- (void)start:(NSDictionary *)request;
@end
@implementation TVNCAppStateStream {
    TVNCAppStateService *_service;
    void *_producer;
    BOOL (^_active)(void);
    dispatch_source_t _timer;
    NSString *_subscription;
    NSDictionary *_pending;
    BOOL _terminal;
    BOOL _closed;
    double _started;
    double _lastSent;
    double _lastAuthorization;
}
- (instancetype)initWithService:(TVNCAppStateService *)service producer:(void *)producer active:(BOOL (^)(void))active {
    if((self=[super init])){_service=service;_producer=producer;_active=[active copy];_started=NSProcessInfo.processInfo.systemUptime;_lastSent=_started;}
    return self;
}
// Caller holds self's lock. No service calls under this lock: callbacks take service -> self.
- (void)closeLocked {
    if(_closed)return;
    _closed=YES;
    if(_timer){dispatch_source_cancel(_timer);_timer=nil;}
    if(_producer){tvnc_http_stream_release(_producer);_producer=NULL;}
    _pending=nil;
}
- (BOOL)sendLocked:(NSDictionary *)event {
    NSMutableData *data=nil;
    @try {data=[[NSJSONSerialization dataWithJSONObject:event options:0 error:nil]mutableCopy];}
    @catch(__unused NSException *exception){[self closeLocked];return NO;}
    if(!data || data.length>1024*1024){[self closeLocked];return NO;}
    [data appendBytes:"\n" length:1];
    if(!tvnc_http_stream_send(_producer,(const unsigned char *)data.bytes,data.length)) {
        if(!tvnc_http_stream_open(_producer))[self closeLocked];
        return NO;
    }
    _lastSent=NSProcessInfo.processInfo.systemUptime;
    return YES;
}
- (void)receive:(NSDictionary *)record {
    @synchronized(self) {
        if(_closed || _terminal)return;
        _pending=record;
        _terminal=[record[@"status"]isEqual:@"completed"] || !record[@"operation_id"];
        // Progress is coalesced to the latest state; initial ID and terminal are flushed promptly.
        if(_terminal || !_subscription) {
            if([self sendLocked:@{@"event":@"state",@"record":_pending}]) {
                _pending=nil;
                if(_terminal)[self closeLocked];
            }
        }
    }
}
- (void)tick {
    BOOL authorize=NO;
    @synchronized(self) {
        double now=NSProcessInfo.processInfo.systemUptime;
        if(!_closed && now-_lastAuthorization>=5.){_lastAuthorization=now;authorize=YES;}
    }
    BOOL active=YES;
    @try {active=!authorize || _active();}
    @catch(__unused NSException *exception){active=NO;}
    NSString *remove=nil;
    @synchronized(self) {
        double now=NSProcessInfo.processInfo.systemUptime;
        if(!_closed && (!active || !tvnc_http_stream_open(_producer) || now-_started>=600.))[self closeLocked];
        if(!_closed && _pending) {
            if([self sendLocked:@{@"event":@"state",@"record":_pending}]) {
                _pending=nil;
                if(_terminal)[self closeLocked];
            }
        } else if(!_closed && now-_lastSent>=5.) {
            [self sendLocked:@{@"event":@"heartbeat"}];
        }
        if(_closed){remove=_subscription;_subscription=nil;}
    }
    if(remove)[_service removeObserver:remove];
}
- (void)start:(NSDictionary *)request {
    // The timer owns this object until close; native observer ownership is removed on every terminal/disconnect.
    _timer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,dispatch_get_global_queue(QOS_CLASS_UTILITY,0));
    dispatch_source_set_timer(_timer,dispatch_time(DISPATCH_TIME_NOW,200*NSEC_PER_MSEC),200*NSEC_PER_MSEC,20*NSEC_PER_MSEC);
    dispatch_source_set_event_handler(_timer,^{ @autoreleasepool{[self tick];} });
    dispatch_resume(_timer);
    NSString *subscription=[_service observeRequest:request observer:^(NSDictionary *record){[self receive:record];}];
    BOOL remove;
    @synchronized(self){remove=_closed;if(!remove)_subscription=subscription;}
    if(remove && subscription)[_service removeObserver:subscription];
}
@end
TVNCHTTPResponse TVNCAppStateStreamResponse(TVNCAppStateService *service, NSDictionary *request, BOOL (^active)(void)) {
    void *producer=NULL;
    void *stream=tvnc_http_stream_new(&producer);
    TVNCAppStateStream *owner=[[TVNCAppStateStream alloc]initWithService:service producer:producer active:active];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
        @autoreleasepool {
            // Authorization is rechecked before accepting a mutation and while streaming.
            if(active())[owner start:request];
            else { [owner start:@{@"action":@"result",@"operation_id":@"cancelled-before-invoke"}]; }
        }
    });
    return {NULL,0,200,"application/x-ndjson",stream};
}
