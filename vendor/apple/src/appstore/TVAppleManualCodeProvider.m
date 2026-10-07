#import "TVAppleBackend.h"

@implementation TVAppleManualCodeProvider {
    void (^_handler)(NSDictionary *);
    TVAppleCodeCompletion _pending;
    NSString *_challengeID;
    NSTimeInterval _deadline;
}
- (instancetype)initWithChallengeHandler:(void (^)(NSDictionary *))handler {
    NSParameterAssert(handler);
    if ((self = [super init])) _handler = [handler copy];
    return self;
}
- (void)prepareForAuthentication:(void (^)(NSError *))completion {
    NSError *error = nil;
    @synchronized (self) {
        if (_pending) error = TVAppleError(TVAppleErrorConflict, @"A verification challenge is already pending.");
    }
    completion(error);
}
- (void)requestCodeForChallenge:(NSDictionary *)challenge completion:(TVAppleCodeCompletion)completion {
    NSString *identifier = NSUUID.UUID.UUIDString;
    NSError *error = nil;
    @synchronized (self) {
        if (_pending) error = TVAppleError(TVAppleErrorConflict, @"A verification challenge is already pending.");
        else {
            _challengeID = identifier; _pending = [completion copy];
            _deadline = NSProcessInfo.processInfo.systemUptime + 90;
        }
    }
    if (error) { completion(nil, error); return; }
    NSMutableDictionary *event = [challenge mutableCopy];
    event[@"challenge_id"] = identifier; event[@"expires_in"] = @90;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{ self->_handler([event copy]); });
    __weak TVAppleManualCodeProvider *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 90 * NSEC_PER_SEC), dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        TVAppleManualCodeProvider *self = weakSelf;
        if (!self) return;
        TVAppleCodeCompletion reply = nil;
        @synchronized (self) {
            if ([self->_challengeID isEqual:identifier] && self->_pending) {
                reply = self->_pending; self->_pending = nil; self->_challengeID = nil;
            }
        }
        if (reply) reply(nil, TVAppleError(TVAppleErrorVerificationCode, @"The verification challenge expired."));
    });
}
- (BOOL)submitCode:(NSString *)code forChallengeID:(NSString *)identifier error:(NSError **)error {
    if (![code isKindOfClass:NSString.class] || code.length != 6 ||
        [code rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789"] invertedSet]].location != NSNotFound) {
        if (error) *error = TVAppleError(TVAppleErrorInvalidRequest, @"A six-digit verification code is required."); return NO;
    }
    TVAppleCodeCompletion reply = nil;
    @synchronized (self) {
        if (!_pending || ![_challengeID isEqual:identifier] || NSProcessInfo.processInfo.systemUptime >= _deadline) {
            if (error) *error = TVAppleError(TVAppleErrorVerificationCode, @"The verification challenge is unavailable or expired."); return NO;
        }
        reply = _pending; _pending = nil; _challengeID = nil;
    }
    if (error) *error = nil;
    reply([code copy], nil); return YES;
}
- (void)cancelAuthentication {
    TVAppleCodeCompletion reply = nil;
    @synchronized (self) { reply = _pending; _pending = nil; _challengeID = nil; }
    if (reply) reply(nil, TVAppleError(TVAppleErrorVerificationCode, @"Authentication finished; the challenge is no longer available."));
}
- (BOOL)cancelChallengeID:(NSString *)identifier error:(NSError **)error {
    TVAppleCodeCompletion reply = nil;
    @synchronized (self) {
        if (!_pending || ![_challengeID isEqual:identifier]) {
            if (error) *error = TVAppleError(TVAppleErrorVerificationCode, @"The verification challenge is unavailable."); return NO;
        }
        reply = _pending; _pending = nil; _challengeID = nil;
    }
    if (error) *error = nil;
    reply(nil, TVAppleError(TVAppleErrorVerificationCode, @"The verification challenge was cancelled.")); return YES;
}
@end
