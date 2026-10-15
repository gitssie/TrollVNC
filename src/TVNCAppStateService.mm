#import "TVNCAppStateService.h"
#import "TVAppStateServices.h"
static NSDictionary *Fail(NSString *code) {return @{@"error":@{@"code":code}};}
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
    BOOL _uncertain;
}
- (instancetype)init {return [self initWithServices:[TVAppStateServices new]];}
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
- (NSDictionary *)request:(NSDictionary *)request {
    @synchronized(self) {
        for(NSString *key in _finished.allKeys)if(NSProcessInfo.processInfo.systemUptime-_finished[key].doubleValue>600){[_finished removeObjectForKey:key];[_operations removeObjectForKey:key];}
        if([request[@"action"] isEqual:@"result"] && request.count==2 && [request[@"operation_id"]isKindOfClass:NSString.class])return _operations[request[@"operation_id"]]?[_operations[request[@"operation_id"]]copy]:Fail(@"operation_unavailable");
        if(![request[@"action"]isEqual:@"invoke"] || request.count!=3)return Fail(@"invalid_request");
        NSError *error=nil;NSDictionary *native=TVASRequest(request[@"method"],request[@"params"],&error);
        if(!native)return Fail(@"invalid_request");
        NSString *method=request[@"method"],*bundle=request[@"params"][@"bundle_id"];
        BOOL readOnly=[@[@"list",@"describe",@"status",@"profile"]containsObject:method];
        if(_stopped)return Fail(@"service_stopping");
        if(_uncertain && !readOnly)return Fail(@"outcome_unknown");
        if(_active)return Fail(@"busy");
        if(_operations.count>=64)return Fail(@"result_capacity");
        NSString *identifier=NSUUID.UUID.UUIDString;_active=identifier;
        _operations[identifier]=[@{@"operation_id":identifier,@"method":method,@"status":@"running"}mutableCopy];
        @try {
            [_services executeBundle:bundle request:native progress:^(NSDictionary *event){
                @synchronized(self){if(![self->_active isEqual:identifier])return;
                    NSMutableDictionary *safe=[NSMutableDictionary new];
                    for(NSString *key in @[@"phase",@"stage",@"completed",@"total",@"files",@"bytes",@"savedCurrent"])if([event[key]isKindOfClass:NSString.class] || [event[key]isKindOfClass:NSNumber.class])safe[key]=event[key];
                    self->_operations[identifier][@"progress"]=safe;
                    [self publish:identifier];
                }
            } completion:^(NSDictionary *result,NSError *failure){
                @synchronized(self){if(![self->_active isEqual:identifier])return;
                    NSMutableDictionary *op=self->_operations[identifier];op[@"status"]=@"completed";
                    if(result)op[@"result"]=result;
                    if(failure){
                        NSMutableDictionary *safe=[@{@"domain":failure.domain,@"code":@(failure.code),@"state_may_be_partial":@([failure.userInfo[@"stateMayBePartial"]boolValue]),@"archive_may_be_partial":@([failure.userInfo[@"archiveMayBePartial"]boolValue])}mutableCopy];
                        NSDictionary *reasons=@{
                            @"Retry restoration before backing up this incomplete environment.":@"restore_pending",
                            @"Retry restoration before backing up this incomplete environment":@"restore_pending",
                            @"Name this account before its first backup":@"name_required",
                            @"Store is busy":@"store_busy",
                            @"The selected backup is unavailable":@"archive_unavailable",
                            @"Invalid snapshot manifest":@"invalid_archive",
                            @"Invalid baseline manifest":@"invalid_archive",
                            @"Container payload differs":@"invalid_archive",
                            @"Keychain archive checksum differs":@"invalid_archive",
                            @"Cannot restore keychain":@"keychain_failed",
                            @"Cannot restore identity":@"identity_failed"};
                        NSString *reason=reasons[failure.localizedDescription];if(reason)safe[@"reason"]=reason;
                        if([@"TVAppStateServices" isEqual:failure.domain] && failure.code>=3)self->_uncertain=YES;
                        NSString *pending=failure.userInfo[@"pendingCaptureReference"];
                        NSString *prefix=[bundle stringByAppendingString:@"/snapshots/.capture-"];
                        if([pending isKindOfClass:NSString.class] && [pending hasPrefix:prefix] && [[NSUUID alloc]initWithUUIDString:[pending substringFromIndex:prefix.length]])safe[@"pending_capture_id"]=[@"capture:" stringByAppendingString:[pending substringFromIndex:prefix.length]];
                        op[@"error"]=safe;
                    }
                    if(!result && !failure){op[@"error"]=@{@"code":@"missing_result"};if(!readOnly)self->_uncertain=YES;}
                    self->_finished[identifier]=@(NSProcessInfo.processInfo.systemUptime);self->_active=nil;
                    [self publish:identifier];
                }
            }];
        } @catch(__unused NSException *exception){
            _uncertain=YES;_stopped=YES;_active=nil;
            _operations[identifier][@"status"]=@"completed";_operations[identifier][@"error"]=@{@"code":@"outcome_unknown"};_finished[identifier]=@(NSProcessInfo.processInfo.systemUptime);
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
