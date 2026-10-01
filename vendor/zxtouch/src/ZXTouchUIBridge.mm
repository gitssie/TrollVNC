// SPDX-License-Identifier: GPL-2.0-only
#import "ZXTouchUIBridge.h"

@interface ZXUITicket : NSObject
@property dispatch_semaphore_t semaphore;
@property NSDictionary *reply;
@property NSDictionary *request;
@end
@implementation ZXUITicket
@end

@implementation ZXTouchUIBridge {
    id<ZXNotificationCenter> _center;
    NSMutableDictionary<NSString *, ZXUITicket *> *_pending;
    BOOL _stopped;
}
- (instancetype)initWithCenter:(id<ZXNotificationCenter>)center {
    if ((self = [super init])) {
        _center = center;
        _pending = [NSMutableDictionary dictionary];
        [_center addObserver:self selector:@selector(receive:) name:ZXUIResponseName object:nil];
    }
    return self;
}
- (void)receive:(NSNotification *)notification {
    NSDictionary *info = notification.userInfo;
    NSString *identifier = [info[@"id"] isKindOfClass:NSString.class] ? info[@"id"] : nil;
    if (!identifier) return;
    @synchronized(_pending) {
        ZXUITicket *ticket = _pending[identifier];
        if (!ticket || ticket.reply || ![info[@"target"] isEqual:ticket.request[@"target"]]) return;
        if (![info[@"ok"] isKindOfClass:NSNumber.class]) return;
        if ([info[@"ok"] boolValue] && ![info[@"value"] isKindOfClass:NSString.class]) return;
        if (![info[@"ok"] boolValue] && ![info[@"error"] isKindOfClass:NSString.class]) return;
        ticket.reply = info;
        dispatch_semaphore_signal(ticket.semaphore);
    }
}
- (NSDictionary *)requestTask:(int)task fields:(NSArray<NSString *> *)fields target:(NSString *)target
                     timeout:(NSTimeInterval)timeout cancelled:(BOOL (^)(void))cancelled {
    if (!_center) return @{@"ok":@NO, @"error":@"ZXTouch UI adapter is not available on this platform"};
    ZXUITicket *ticket = [ZXUITicket new];
    ticket.semaphore = dispatch_semaphore_create(0);
    NSString *identifier = NSUUID.UUID.UUIDString;
    ticket.request = @{@"id":identifier, @"target":target, @"task":@(task), @"fields":fields,
        @"expires": @([NSDate.date timeIntervalSince1970] + timeout)};
    @synchronized(_pending) {
        if (_stopped) return @{@"ok":@NO, @"error":@"ZXTouch service is stopping"};
        _pending[identifier] = ticket;
        // Order the initial post before stop posts cancellation/cleanup.
        [_center postNotificationName:ZXUIRequestName object:nil userInfo:ticket.request deliverImmediately:NO];
    }
    CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + timeout;
    NSString *failure = @"ZXTouch UI adapter did not reply before the timeout";
    for (;;) {
        if (cancelled()) { failure = @"ZXTouch command was cancelled"; break; }
        if (dispatch_semaphore_wait(ticket.semaphore, dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC)) == 0) break;
        if (CFAbsoluteTimeGetCurrent() >= deadline) break;
    }
    NSDictionary *reply;
    @synchronized(_pending) { reply = ticket.reply; [_pending removeObjectForKey:identifier]; }
    if (reply) return reply;
    NSMutableDictionary *cancel = [ticket.request mutableCopy];
    cancel[@"cancel"] = @YES;
    [_center postNotificationName:ZXUIRequestName object:nil userInfo:cancel deliverImmediately:NO];
    return @{@"ok":@NO, @"error":failure};
}
- (void)sendTouches:(NSArray<NSDictionary *> *)touches {
    if (_center) [_center postNotificationName:ZXUITouchName object:nil userInfo:@{@"touches":touches} deliverImmediately:NO];
}
- (void)stop {
    NSArray<ZXUITicket *> *tickets;
    @synchronized(_pending) {
        _stopped = YES;
        tickets = _pending.allValues;
        for (ZXUITicket *ticket in tickets) {
            if (!ticket.reply) ticket.reply = @{@"ok":@NO, @"error":@"ZXTouch service is stopping"};
            dispatch_semaphore_signal(ticket.semaphore);
        }
    }
    for (ZXUITicket *ticket in tickets) {
        NSMutableDictionary *cancel = [ticket.request mutableCopy];
        cancel[@"cancel"] = @YES;
        [_center postNotificationName:ZXUIRequestName object:nil userInfo:cancel deliverImmediately:NO];
    }
    [_center postNotificationName:ZXUIRequestName object:nil userInfo:@{
        @"id":NSUUID.UUID.UUIDString, @"target":@"com.apple.springboard", @"task":@0,
        @"fields":@[], @"expires":@(NSDate.date.timeIntervalSince1970 + 5)} deliverImmediately:NO];
    [_center removeObserver:self];
}
- (void)dealloc { [_center removeObserver:self]; }
@end
