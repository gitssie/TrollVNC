#import "ScreenUnlock.h"
#import "STHIDEventGenerator.h"
#include <dlfcn.h>
#include <mach/mach.h>
#include <math.h>
#include <notify.h>
#include <unistd.h>

// Read system UI through AXRuntime in this process. No SpringBoard injection.
@interface NSObject (TVUnlockSPI)
+ (id)primaryApp;
- (NSString *)bundleId;
- (NSArray *)explorerElements;
- (unsigned long long)traits;
- (NSString *)value;
- (NSString *)label;
- (CGRect)frame;
@end

typedef mach_port_t (*TVSBPort)(void);
typedef void (*TVSBLock)(mach_port_t, BOOL *, BOOL *);
static TVSBPort tvPort;
static TVSBLock tvLock;
static Class tvAX;
static int tvBlankToken = -1;
static NSLock *tvLeaseLock;
static NSMutableDictionary *tvLeases;
static NSTimeInterval tvLastAttempt;
static NSTimeInterval tvLastPrepare;

static void tvUnlockInit(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *sbs = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_LAZY);
        if (sbs) {
            tvPort = (TVSBPort)dlsym(sbs, "SBSSpringBoardServerPort");
            tvLock = (TVSBLock)dlsym(sbs, "SBGetScreenLockStatus");
        }
        dlopen("/System/Library/PrivateFrameworks/AXRuntime.framework/AXRuntime", RTLD_LAZY);
        dlopen("/System/Library/PrivateFrameworks/AccessibilityUI.framework/AccessibilityUI", RTLD_LAZY);
        tvAX = NSClassFromString(@"AXElement");
        tvLeaseLock = [NSLock new];
        tvLeases = [NSMutableDictionary new];
        if (notify_register_check("com.apple.springboard.hasBlankedScreen", &tvBlankToken) != NOTIFY_STATUS_OK)
            tvBlankToken = -1;
    });
}

BOOL tvScreenUnlockSupported(void) {
    tvUnlockInit();
    return tvPort && tvLock && [tvAX respondsToSelector:@selector(primaryApp)] && tvBlankToken >= 0;
}

BOOL tvScreenLockSupported(void) {
    tvUnlockInit();
    return tvPort && tvLock && tvBlankToken >= 0;
}

static BOOL tvReadBlanked(BOOL *blanked) {
    tvUnlockInit();
    uint64_t state = UINT64_MAX;
    if (tvBlankToken < 0 || notify_get_state(tvBlankToken, &state) != NOTIFY_STATUS_OK || state > 1) return NO;
    *blanked = state != 0;
    return YES;
}

static BOOL tvReadLock(BOOL *locked, BOOL *passcode) {
    tvUnlockInit();
    if (!tvPort || !tvLock) return NO;
    mach_port_t port = tvPort();
    if (port == MACH_PORT_NULL) return NO;
    *locked = YES; *passcode = YES;
    tvLock(port, locked, passcode);
    return YES;
}

BOOL tvScreenReadLocked(BOOL *locked) {
    BOOL passcode;
    return tvReadLock(locked, &passcode);
}

NSDictionary *tvScreenLock(NSString **error) {
    BOOL locked, passcode, blanked;
    if (!tvReadLock(&locked, &passcode)) { *error = @"Cannot read screen lock state"; return nil; }
    // A lock command must never toggle an already locked phone awake.
    if (locked) return tvScreenUnlockState(error);
    if (!tvReadBlanked(&blanked)) { *error = @"Cannot read display state"; return nil; }
    STHIDEventGenerator *gen = [STHIDEventGenerator sharedGenerator];
    if (blanked) [gen hardwareLock];
    else [gen powerPress];
    // Send the HID action once; wait only for the resulting system state.
    for (int tick = 0; tick < 20; ++tick) {
        usleep(100000);
        if (!tvReadLock(&locked, &passcode)) { *error = @"Cannot read screen lock state"; return nil; }
        if (locked) return tvScreenUnlockState(error);
    }
    *error = @"Screen did not lock";
    return nil;
}

// AX reports either an empty value or a localized count for a secure field.
// Unknown formats are deliberately not accepted as an empty password field.
static BOOL tvEmptySecureField(id element) {
    if (![element respondsToSelector:@selector(value)]) return NO;
    id raw = [element value];
    if (![raw isKindOfClass:NSString.class]) return NO;
    NSString *value = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (value.length == 0) return YES;
    if (value.length > 128) return NO;
    NSRegularExpression *pattern = [NSRegularExpression regularExpressionWithPattern:@"[0-9]+" options:0 error:nil];
    NSArray *numbers = [pattern matchesInString:value options:0 range:NSMakeRange(0, value.length)];
    if (numbers.count == 0) return NO;
    NSTextCheckingResult *first = numbers.firstObject;
    // A bare digit could be actual input, never interpret it as a count.
    return first.range.length < value.length && [[value substringWithRange:first.range] isEqualToString:@"0"];
}

NSDictionary *tvScreenUnlockState(NSString **error) {
    BOOL locked, passcode;
    if (!tvReadLock(&locked, &passcode)) { *error = @"Cannot read screen lock state"; return nil; }
    BOOL ready = NO, empty = NO;
    NSString *reason = locked ? @"等待密码输入界面" : @"已解锁";
    if (locked && passcode && [tvAX respondsToSelector:@selector(primaryApp)]) {
        @try {
            // Automation exposes AX elements without enabling VoiceOver.
            void (*enable)(BOOL) = (void (*)(BOOL))dlsym(RTLD_DEFAULT, "_AXSSetAutomationEnabled");
            if (enable) enable(YES);
            id app = [tvAX primaryApp];
            if (![app respondsToSelector:@selector(bundleId)] || ![[app bundleId] isEqualToString:@"com.apple.springboard"]) {
                reason = @"等待锁屏界面";
            } else {
                NSArray *elements = [app respondsToSelector:@selector(explorerElements)] ? [app explorerElements] : nil;
                if (![elements isKindOfClass:NSArray.class] || elements.count > 512) elements = @[];
                BOOL secure = NO, enabled = NO;
                NSMutableSet *keys = [NSMutableSet new];
                for (id element in elements) {
                    if (![element respondsToSelector:@selector(traits)] || ![element respondsToSelector:@selector(frame)]) continue;
                    unsigned long long traits = [element traits];
                    CGRect frame = [element frame];
                    if (CGRectIsEmpty(frame) || !isfinite(frame.origin.x) || !isfinite(frame.origin.y)) continue;
                    if (traits & 0x1000000ULL) {
                        secure = YES;
                        enabled = !(traits & (0x100ULL | 0x2000000ULL | 0x8000000000000ULL));
                        empty = tvEmptySecureField(element);
                    }
                    if ((traits & (0x1ULL | 0x20ULL)) && !(traits & (0x100ULL | 0x2000000ULL)) &&
                        [element respondsToSelector:@selector(label)]) {
                        NSString *label = [element label];
                        if (label.length && label.length < 32) {
                            unichar digit = [label characterAtIndex:0];
                            if (digit >= '0' && digit <= '9') [keys addObject:@(digit)];
                        }
                    }
                }
                ready = secure && enabled && keys.count == 10;
                reason = ready ? (empty ? @"可以输入密码" : @"密码框已有输入，请先清空") : @"等待可用的密码键盘";
            }
        } @catch (NSException *exception) { (void)exception; reason = @"密码界面检测暂不可用"; }
    }
    return @{@"locked":@(locked), @"passcode_required":@(passcode), @"input_ready":@(ready),
        @"input_empty":@(empty), @"reason":reason};
}

NSDictionary *tvScreenUnlockPrepare(NSString **error) {
    NSDictionary *state = tvScreenUnlockState(error);
    if (!state || ![state[@"locked"] boolValue]) return state;
    if (!tvScreenUnlockSupported()) { *error = @"Screen unlock is unavailable on this iOS version"; return nil; }
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    // Idempotent polling must not continuously restart the presentation animation.
    if (now - tvLastPrepare >= 3.0 && ![state[@"input_ready"] boolValue]) {
        tvLastPrepare = now;
        BOOL blanked;
        if (!tvReadBlanked(&blanked)) { *error = @"Cannot read display state"; return nil; }
        if (blanked) [[STHIDEventGenerator sharedGenerator] powerPress];
        // Wake before swiping. A power press when already lit would switch it off.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 800 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            NSString *error = nil;
            NSDictionary *current = tvScreenUnlockState(&error);
            BOOL blanked;
            if ([current[@"locked"] boolValue] && [current[@"passcode_required"] boolValue] &&
                ![current[@"input_ready"] boolValue] && tvReadBlanked(&blanked) && !blanked) {
                dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
                    [[STHIDEventGenerator sharedGenerator] swipeUpToPasscode];
                });
            }
        });
    }
    return state;
}

NSDictionary *tvScreenUnlockArm(rfbClientPtr client, NSUInteger digits, NSString **error) {
    tvUnlockInit();
    NSValue *key = [NSValue valueWithPointer:client];
    if (digits == 0) { tvScreenUnlockClose(client); return @{@"armed":@NO}; }
    if (digits != 6) { *error = @"Only 6 digit passcodes are supported"; return nil; }
    [tvLeaseLock lock];
    NSDictionary *state = tvScreenUnlockState(error);
    if (!state) { [tvLeaseLock unlock]; return nil; }
    if (![state[@"locked"] boolValue]) { [tvLeaseLock unlock]; return @{@"armed":@NO, @"locked":@NO}; }
    if (![state[@"input_ready"] boolValue] || ![state[@"input_empty"] boolValue]) {
        [tvLeaseLock unlock]; *error = state[@"reason"]; return nil;
    }
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    if (now - tvLastAttempt < 8.0) {
        [tvLeaseLock unlock]; *error = @"请稍后再尝试解锁"; return nil;
    }
    tvLastAttempt = now;
    tvLeases[key] = [@{@"until":@(now + 8.0), @"remaining":@(digits), @"pressed":[NSMutableSet new]} mutableCopy];
    [tvLeaseLock unlock];
    return @{@"armed":@YES, @"locked":@YES};
}

int tvScreenUnlockKey(rfbClientPtr client, BOOL down, uint32_t key) {
    tvUnlockInit();
    [tvLeaseLock lock];
    NSMutableDictionary *lease = tvLeases[[NSValue valueWithPointer:client]];
    if (!lease) { [tvLeaseLock unlock]; return 0; }
    NSMutableSet *pressed = lease[@"pressed"];
    int result = -1;
    if (!down && [pressed containsObject:@(key)]) { [pressed removeObject:@(key)]; result = 1; }
    else if (down && key >= '0' && key <= '9' && ![pressed containsObject:@(key)] &&
        [lease[@"until"] doubleValue] > NSProcessInfo.processInfo.systemUptime && [lease[@"remaining"] unsignedIntegerValue] > 0) {
        BOOL locked, passcode;
        if (tvReadLock(&locked, &passcode) && locked && passcode) {
            [pressed addObject:@(key)];
            lease[@"remaining"] = @([lease[@"remaining"] unsignedIntegerValue] - 1);
            result = 1;
        } else { lease[@"remaining"] = @0; }
    }
    [tvLeaseLock unlock];
    return result;
}

void tvScreenUnlockClose(rfbClientPtr client) {
    tvUnlockInit();
    [tvLeaseLock lock];
    [tvLeases removeObjectForKey:[NSValue valueWithPointer:client]];
    [tvLeaseLock unlock];
}
