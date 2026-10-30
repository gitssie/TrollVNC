#import "TVNCAppStateService.h"
#import "TVAppStateServices.h"
#import "TVASRuntime.h"
#import "TVASErrors.h"
static NSDictionary *Fail(NSString *code) {NSMutableDictionary *record=[TVASErrorRecord(TVASMakeError(code,[@{@"busy":@"An AppState operation is already running.",@"invalid_request":@"Invalid AppState request.",@"operation_unavailable":@"The operation result is unavailable or expired.",@"service_stopping":@"The AppState service is stopping."}objectForKey:code]?:@"The AppState request could not be completed."))mutableCopy];record[@"code"]=code;return @{@"error":record};}
static NSData *Wire(NSDictionary *value) {
    NSData *data=[NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
    if(!data || data.length>700000)data=[NSJSONSerialization dataWithJSONObject:Fail(@"response_too_large") options:0 error:nil];
    return [[NSString stringWithFormat:@"0;;%@\r\n",[data base64EncodedStringWithOptions:0]]dataUsingEncoding:NSUTF8StringEncoding];
}
@implementation TVNCAppStateService {
    TVAppStateServices *_services;
    NSMutableDictionary<NSString *,NSMutableDictionary *> *_operations;
    NSMutableDictionary<NSString *,NSNumber *> *_finished;
    NSString *_active;
    NSMutableDictionary<NSString *,NSDictionary *> *_observers;
    BOOL _stopped;
}
- (instancetype)init {return [self initWithServices:[TVAppStateServices new]];}
- (NSData *)downloadStatePart:(NSDictionary *)params error:(NSError **)error {
    return TVASReadShadowPart(@"",params,error);
}
- (NSDictionary *)uploadStatePart:(NSDictionary *)params error:(NSError **)error {
    return TVASWriteShadowPart(@"",params,error);
}
- (instancetype)initWithServices:(TVAppStateServices *)services {
    if((self=[super init])){_services=services;_operations=[NSMutableDictionary new];_finished=[NSMutableDictionary new];_observers=[NSMutableDictionary new];}return self;
}
- (void)publish:(NSString *)operation {
    NSDictionary *record=[_operations[operation] copy];
    for(NSString *token in [_observers.allKeys copy]) {
        NSDictionary *subscription=_observers[token];
        if(![subscription[@"operation"] isEqual:operation])continue;
        void (^observer)(NSDictionary *)=subscription[@"observer"];
        observer(record);
        if([record[@"status"] isEqual:@"completed"])[_observers removeObjectForKey:token];
    }
}
- (NSString *)observeRequest:(NSDictionary *)request observer:(void (^)(NSDictionary *))observer {
    @synchronized(self) {
        if(_observers.count>=64){observer(Fail(@"stream_capacity"));return nil;}
        NSDictionary *record=[self request:request];
        observer(record);
        NSString *operation=record[@"operation_id"];
        if(!operation || [record[@"status"] isEqual:@"completed"])return nil;
        NSString *token=NSUUID.UUID.UUIDString;
        _observers[token]=@{@"operation":operation,@"observer":[observer copy]};
        return token;
    }
}
- (void)removeObserver:(NSString *)identifier { @synchronized(self){[_observers removeObjectForKey:identifier];} }
- (NSDictionary *)accessTokenForBundle:(NSString *)bundle error:(NSError **)error {
    return [_services accessTokenForBundle:bundle error:error];
}
- (NSDictionary *)request:(NSDictionary *)request {
    @synchronized(self) {
        for(NSString *key in _finished.allKeys)if(NSProcessInfo.processInfo.systemUptime-_finished[key].doubleValue>600){[_finished removeObjectForKey:key];[_operations removeObjectForKey:key];}
        if([request[@"action"] isEqual:@"result"] && request.count==2 && [request[@"operation_id"]isKindOfClass:NSString.class])return _operations[request[@"operation_id"]]?[_operations[request[@"operation_id"]]copy]:Fail(@"operation_unavailable");
        if(![request[@"action"]isEqual:@"invoke"] || request.count!=3)return Fail(@"invalid_request");
        NSError *error=nil;NSDictionary *native=TVASRequest(request[@"method"],request[@"params"],&error);
        if(!native)return @{@"error":TVASErrorRecord(error)};
        NSString *method=request[@"method"],*bundle=request[@"params"][@"bundle_id"];
        if(_stopped)return Fail(@"service_stopping");
        if(_active)return Fail(@"busy");
        if(_operations.count>=64)return Fail(@"result_capacity");
        NSString *identifier=NSUUID.UUID.UUIDString;_active=identifier;
        _operations[identifier]=[@{@"operation_id":identifier,@"method":method,@"status":@"running"}mutableCopy];
        @try {
            [_services executeBundle:bundle request:native progress:^(NSDictionary *event){
                @synchronized(self){if(![self->_active isEqual:identifier])return;
                    NSMutableDictionary *safe=[NSMutableDictionary new];
                    for(NSString *key in @[@"phase",@"stage",@"completed",@"total",@"files",@"entries",@"bytes",@"savedCurrent"])if([event[key]isKindOfClass:NSString.class] || [event[key]isKindOfClass:NSNumber.class])safe[key]=event[key];
                    self->_operations[identifier][@"progress"]=safe;
                    [self publish:identifier];
                }
            } completion:^(NSDictionary *result,NSError *failure){
                @synchronized(self){if(![self->_active isEqual:identifier])return;
                    NSMutableDictionary *op=self->_operations[identifier];op[@"status"]=@"completed";
                    if(result)op[@"result"]=result;
                    if(failure){
                        NSDictionary *safe=TVASErrorRecord(failure);
                        op[@"error"]=safe;
                    }
                    if(!result && !failure){NSMutableDictionary *missing=[TVASErrorRecord([NSError errorWithDomain:@"TVAppStateServices" code:4 userInfo:@{@"errorCode":@"operation_failed",@"outcomeUnknown":@YES,NSLocalizedDescriptionKey:@"The operation returned no result; completion could not be confirmed."}])mutableCopy];missing[@"code"]=@"missing_result";op[@"error"]=missing;}
                    self->_finished[identifier]=@(NSProcessInfo.processInfo.systemUptime);self->_active=nil;
                    [self publish:identifier];
                }
            }];
        } @catch(__unused NSException *exception){
            _active=nil;
            _operations[identifier][@"status"]=@"completed";NSMutableDictionary *uncertain=[TVASErrorRecord([NSError errorWithDomain:@"TVAppStateServices" code:4 userInfo:@{@"errorCode":@"operation_failed",@"outcomeUnknown":@YES,NSLocalizedDescriptionKey:@"The operation completion could not be confirmed."}])mutableCopy];uncertain[@"code"]=@"outcome_unknown";_operations[identifier][@"error"]=uncertain;_finished[identifier]=@(NSProcessInfo.processInfo.systemUptime);
            [self publish:identifier];
        }
        return [_operations[identifier]copy];
    }
}
- (NSData *)handlePayload:(NSString *)payload {
    if(payload.length>900000)return Wire(Fail(@"invalid_request"));
    NSData *data=[[NSData alloc]initWithBase64EncodedString:payload options:0];
    id request=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;
    if(![request isKindOfClass:NSDictionary.class])return Wire(Fail(@"invalid_request"));
    return Wire([self request:request]);
}
- (void)stop {@synchronized(self){_stopped=YES;}} // Native mutation completes independently.
@end
