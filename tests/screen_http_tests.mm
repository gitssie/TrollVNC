#import <Foundation/Foundation.h>
#include <unistd.h>
// Exercise the production operation runner with deterministic screen/HID primitives.
static NSLock *tvLeaseLock;
static NSMutableDictionary *tvLeases;
static BOOL tvHTTPActive;
static NSTimeInterval tvLastAttempt;
static double clockNow;
static BOOL connected, locked, nonempty, neverReady, cancelAfterDigit, rejectEntering, cancelDuringAuthorization, keyboardHeld;
static NSUInteger preparations, digits, locks;
static NSMutableArray *phases;
@interface TVTestClock : NSObject
+ (instancetype)processInfo;
- (NSTimeInterval)systemUptime;
@end
@implementation TVTestClock
+ (instancetype)processInfo { static TVTestClock *c; if (!c) c = [self new]; return c; }
- (NSTimeInterval)systemUptime { return clockNow; }
@end
static void testSleep(unsigned int micros) { clockNow += micros / 1000000.; }
#define NSProcessInfo TVTestClock
#define usleep testSleep
static void tvUnlockInit(void) {}
static NSDictionary *tvScreenUnlockState(NSString **error) {
    (void)error;
    return @{@"locked":@(locked), @"passcode_required":@YES,
        @"input_ready":@(!neverReady && preparations >= 2), @"input_empty":@(!nonempty)};
}
static NSDictionary *tvScreenUnlockPrepareImpl(NSString **error, BOOL (^active)(void)) {
    if (!active()) { *error = @"cancelled"; return nil; }
    preparations++; return tvScreenUnlockState(error);
}
static BOOL tvReadLock(BOOL *isLocked, BOOL *required) { *isLocked = locked; *required = YES; return YES; }
static NSDictionary *tvScreenLockImpl(NSString **error, BOOL (^active)(void)) {
    if (!active()) { *error = @"cancelled"; return nil; }
    if (!locked) { locks++; locked = YES; }
    return tvScreenUnlockState(error);
}
@interface STHIDEventGenerator : NSObject
+ (instancetype)sharedGenerator;
- (void)performKeyboardSequence:(dispatch_block_t)block;
- (void)keyPress:(NSString *)character;
@end
@implementation STHIDEventGenerator
+ (instancetype)sharedGenerator { static STHIDEventGenerator *g; if (!g) g = [self new]; return g; }
- (void)performKeyboardSequence:(dispatch_block_t)block { keyboardHeld = YES; block(); keyboardHeld = NO; }
- (void)keyPress:(NSString *)character {
    NSCAssert(character.length == 1, @"one digit per input");
    digits++;
    if (cancelAfterDigit) connected = NO;
    if (digits == 6) locked = NO;
}
@end
#include "../src/ScreenHTTPControl.inc"
static void reset(void) {
    tvLeaseLock = [NSLock new]; tvLeases = [NSMutableDictionary new]; tvHTTPActive = NO;
    tvLastAttempt = 0; clockNow = 100; connected = YES; locked = YES;
    nonempty = neverReady = cancelAfterDigit = rejectEntering = cancelDuringAuthorization = keyboardHeld = NO;
    preparations = digits = locks = 0; phases = [NSMutableArray new];
}
static void run(BOOL locking) {
    tvScreenHTTPControl(locking, @"001234", ^BOOL { return connected; }, ^BOOL { NSCAssert(!keyboardHeld, @"authorization cannot wait under keyboard mutex"); if (cancelDuringAuthorization) connected = NO; return YES; }, ^BOOL(NSDictionary *event) {
        NSCAssert(!event[@"passcode"], @"events must not contain credentials");
        [phases addObject:event[@"phase"]];
        return !(rejectEntering && [event[@"phase"] isEqual:@"entering"]);
    });
    NSCAssert(!tvHTTPActive, @"operation reservation released");
}
int main(void) {
    @autoreleasepool {
        reset(); run(NO); NSCAssert(digits == 6 && !locked && [phases.lastObject isEqual:@"unlocked"], @"unlock one six-digit attempt");
        NSCAssert(preparations >= 3, @"two stable ready samples");
        reset(); locked = NO; run(NO); NSCAssert(digits == 0 && [phases.lastObject isEqual:@"unlocked"], @"already unlocked");
        reset(); nonempty = YES; run(NO); NSCAssert(digits == 0 && [phases.lastObject isEqual:@"failed"], @"nonempty input rejected");
        reset(); rejectEntering = YES; run(NO); NSCAssert(digits == 0, @"cancel before input");
        reset(); cancelAfterDigit = YES; run(NO); NSCAssert(digits == 1 && ![phases containsObject:@"unlocked"], @"cancel stops later digits");
        reset(); cancelDuringAuthorization = YES; run(NO); NSCAssert(digits == 0 && preparations == 0, @"cancel during authorization prevents action");
        reset(); neverReady = YES; run(NO); NSCAssert(digits == 0 && [phases.lastObject isEqual:@"failed"], @"prepare timeout");
        reset(); tvLastAttempt = clockNow; run(NO); NSCAssert(digits == 0 && [phases.lastObject isEqual:@"failed"], @"cooldown");
        reset(); tvLeases[@1] = @{@"until":@(clockNow + 8)}; run(NO); NSCAssert(digits == 0 && [phases.lastObject isEqual:@"failed"], @"legacy reservation");
        reset(); run(YES); NSCAssert(locks == 0 && [phases.lastObject isEqual:@"locked"], @"idempotent lock");
        reset(); locked = NO; run(YES); NSCAssert(locks == 1 && locked && [phases.lastObject isEqual:@"locked"], @"lock once");
        puts("screen HTTP native runner: 11 scenarios PASS");
    }
}
