// SPDX-License-Identifier: GPL-2.0-only
// Independent protocol adapter. No networking or recording runs in applications.
#import <UIKit/UIKit.h>
#import "ZXTouchUIBridge.h"
#include <cmath>
#import "IOKitSPI.h"

@interface NSObject (ZXPrivate)
+ (id)defaultCenter;
+ (id)activeInstance;
- (void)insertText:(NSString *)text;
- (void)moveCursorByAmount:(long long)amount;
- (void)deleteBackward;
- (void)showKeyboard;
- (void)hideKeyboard;
@end

static double ZXValue(NSString *text, double low, double high) {
    NSScanner *scanner = [NSScanner scannerWithString:text];
    double value;
    if (![scanner scanDouble:&value] || !scanner.isAtEnd || !std::isfinite(value) || value < low || value > high)
        @throw [NSException exceptionWithName:@"ZXInput" reason:@"Invalid numeric argument" userInfo:nil];
    return value;
}
static void ZXCheck(BOOL ok, NSString *message) {
    if (!ok) @throw [NSException exceptionWithName:@"ZXInput" reason:message userInfo:nil];
}

@interface ZXAppAdapter : NSObject
- (void)hid:(IOHIDEventRef)event;
@end
static void ZXHID(void *target, void *refcon, IOHIDEventQueueRef queue, IOHIDEventRef event) {
    [(__bridge ZXAppAdapter *)target hid:event];
}
@implementation ZXAppAdapter {
    id<ZXNotificationCenter> _center;
    NSMutableDictionary<NSString *, UIWindow *> *_windows;
    NSMutableSet<NSString *> *_pending;
    NSMutableDictionary *_timers;
    NSMapTable<NSString *, UIWindow *> *_priorWindows;
    UIWindow *_toast;
    dispatch_source_t _toastTimer;
    BOOL _dark;
    IOHIDEventSystemClientRef _hid;
    UIWindow *_indicator;
    NSMutableDictionary<NSNumber *, UILabel *> *_dots;
    UIColor *_dotColor;
    BOOL _coordinates;
}
- (instancetype)init {
    if ((self = [super init])) {
        _center = [NSClassFromString(@"NSDistributedNotificationCenter") defaultCenter];
        _windows = [NSMutableDictionary dictionary];
        _pending = [NSMutableSet set];
        _timers = [NSMutableDictionary dictionary];
        _priorWindows = [NSMapTable strongToWeakObjectsMapTable];
        _dots = [NSMutableDictionary dictionary];
        _dotColor = [UIColor.systemBlueColor colorWithAlphaComponent:.6];
        [_center addObserver:self selector:@selector(receive:) name:ZXUIRequestName object:nil];
    }
    return self;
}
- (void)reply:(NSDictionary *)request value:(NSString *)value error:(NSString *)error {
    NSString *identifier = request[@"id"];
    if (![_pending containsObject:identifier]) return;
    [_pending removeObject:identifier];
    [_center postNotificationName:ZXUIResponseName object:nil userInfo:@{
        @"id": identifier, @"target": request[@"target"], @"ok": @(error == nil),
        @"value": value ?: @"", @"error": error ?: @""} deliverImmediately:NO];
}
- (UIWindow *)window {
    UIWindowScene *scene = nil;
    for (UIScene *candidate in UIApplication.sharedApplication.connectedScenes) {
        if ([candidate isKindOfClass:UIWindowScene.class] && candidate.activationState == UISceneActivationStateForegroundActive) {
            scene = (UIWindowScene *)candidate; break;
        }
    }
    ZXCheck(scene != nil, @"No active window scene for ZXTouch UI");
    UIWindow *window = [[UIWindow alloc] initWithWindowScene:scene];
    window.frame = scene.coordinateSpace.bounds;
    window.windowLevel = UIWindowLevelAlert + 3;
    window.backgroundColor = UIColor.clearColor;
    window.overrideUserInterfaceStyle = _dark ? UIUserInterfaceStyleDark : UIUserInterfaceStyleUnspecified;
    window.rootViewController = [UIViewController new];
    window.rootViewController.view.backgroundColor = UIColor.clearColor;
    return window;
}
- (void)dismiss:(NSString *)identifier {
    dispatch_source_t timer = _timers[identifier];
    if (timer) dispatch_source_cancel(timer);
    [_timers removeObjectForKey:identifier];
    UIWindow *window = _windows[identifier];
    BOOL wasKey = window.isKeyWindow;
    UIWindow *previous = [_priorWindows objectForKey:identifier];
    // A lower dialog can expire while a newer one is key. Preserve the
    // restoration chain rather than leaving that newer dialog pointing at
    // the now-hidden window.
    for (NSString *other in _windows.allKeys) {
        if (![other isEqual:identifier] && [_priorWindows objectForKey:other] == window) {
            if (previous) [_priorWindows setObject:previous forKey:other];
            else [_priorWindows removeObjectForKey:other];
        }
    }
    [window.rootViewController dismissViewControllerAnimated:NO completion:nil];
    window.hidden = YES;
    [_windows removeObjectForKey:identifier];
    if (wasKey && previous && !previous.hidden) [previous makeKeyWindow];
    [_priorWindows removeObjectForKey:identifier];
}
- (void)execute:(NSDictionary *)request {
    NSArray<NSString *> *f = request[@"fields"];
    int task = [request[@"task"] intValue];
    NSString *identifier = request[@"id"];
    if (task == 0) {
        for (NSString *key in _windows.allKeys) [self dismiss:key];
        [_pending removeAllObjects];
        [self clearToast];
        [self stopIndicator];
    } else if (task == 24) {
        ZXCheck(f.count >= 1, @"Missing keyboard task");
        int action = (int)ZXValue(f[0], 1, 5);
        ZXCheck(f.count == (action == 5 ? 1 : 2), @"Invalid keyboard arguments");
        Class type = NSClassFromString(@"UIKeyboardImpl");
        id keyboard = [type respondsToSelector:@selector(activeInstance)] ? [type activeInstance] : nil;
        ZXCheck(keyboard != nil, @"No active keyboard input in foreground application");
        if (action == 2) {
            int visibility = (int)ZXValue(f[1], 1, 2);
            SEL selector = visibility == 1 ? @selector(hideKeyboard) : @selector(showKeyboard);
            ZXCheck([keyboard respondsToSelector:selector], @"Keyboard visibility is unavailable");
            if (visibility == 1) [keyboard hideKeyboard]; else [keyboard showKeyboard];
        } else if (action == 3) {
            long long offset = (long long)ZXValue(f[1], -256, 256);
            ZXCheck([keyboard respondsToSelector:@selector(moveCursorByAmount:)], @"Cursor movement is unavailable");
            [keyboard moveCursorByAmount:offset];
        } else if (action == 4) {
            int count = (int)ZXValue(f[1], 0, 256);
            ZXCheck([keyboard respondsToSelector:@selector(deleteBackward)], @"Deletion is unavailable");
            for (int i=0; i<count; ++i) [keyboard deleteBackward];
        } else {
            NSString *text = action == 5 ? (UIPasteboard.generalPasteboard.string ?: @"") : f[1];
            ZXCheck(text.length <= 1024 * 1024, @"Text is too long");
            ZXCheck([keyboard respondsToSelector:@selector(insertText:)], @"Text insertion is unavailable");
            [keyboard insertText:text];
        }
        [self reply:request value:nil error:nil];
    } else if (task == 12 || task == 29) {
        ZXCheck(f.count == (task == 12 ? 3 : 4), @"Invalid alert arguments");
        ZXCheck(_windows.count < 8, @"Too many open ZXTouch dialogs");
        double duration = task == 12 ? ZXValue(f[2], 0, 3600) : 0;
        UIWindow *window = [self window];
        _windows[identifier] = window;
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:f[0] message:f[1] preferredStyle:UIAlertControllerStyleAlert];
        if (task == 29) {
            __weak UIAlertController *weakAlert = alert;
            [alert addTextFieldWithConfigurationHandler:^(UITextField *field) { field.placeholder = f[2]; field.text = f[3]; }];
            [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) {
                [self reply:request value:nil error:@"Input cancelled"]; [self dismiss:identifier];
            }]];
            [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                [self reply:request value:weakAlert.textFields.firstObject.text ?: @"" error:nil]; [self dismiss:identifier];
            }]];
        } else {
            [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { [self dismiss:identifier]; }]];
        }
        for (UIWindow *previous in window.windowScene.windows)
            if (previous.isKeyWindow) { [_priorWindows setObject:previous forKey:identifier]; break; }
        [window makeKeyAndVisible];
        [window.rootViewController presentViewController:alert animated:NO completion:^{
            if (task == 12) [self reply:request value:nil error:nil];
        }];
        NSTimeInterval lifetime = task == 29 ? MAX(0, [request[@"expires"] doubleValue] - NSDate.date.timeIntervalSince1970) : (duration > 0 ? duration : 3600);
        dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        _timers[identifier] = timer;
        dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(lifetime * NSEC_PER_SEC)), DISPATCH_TIME_FOREVER, 10 * NSEC_PER_MSEC);
        dispatch_source_set_event_handler(timer, ^{
            [self reply:request value:nil error:@"Input timed out"]; [self dismiss:identifier];
        });
        dispatch_resume(timer);
    } else if (task == 22) {
        ZXCheck(f.count == 5, @"Invalid toast arguments");
        int type = (int)ZXValue(f[0], 0, 4);
        double duration = ZXValue(f[2], 0, 3600);
        int position = (int)ZXValue(f[3], 0, 3);
        double font = ZXValue(f[4], 0, 100);
        [self clearToast];
        if (type != 0) {
            UIWindow *window = [self window];
            window.userInteractionEnabled = NO;
            UILabel *label = [UILabel new];
            label.text = f[1]; label.numberOfLines = 0; label.textAlignment = NSTextAlignmentCenter;
            label.font = [UIFont systemFontOfSize:font > 0 ? font : 17]; label.textColor = UIColor.whiteColor;
            label.backgroundColor = type == 1 ? UIColor.systemRedColor : type == 2 ? UIColor.systemOrangeColor : type == 4 ? UIColor.systemGreenColor : UIColor.darkGrayColor;
            CGFloat width = MIN(420, window.bounds.size.width - 40);
            CGSize size = [label sizeThatFits:CGSizeMake(width - 24, window.bounds.size.height / 2)];
            CGFloat height = MIN(window.bounds.size.height / 2, size.height + 24);
            CGFloat x = (window.bounds.size.width - width) / 2;
            CGFloat y = position == 1 ? window.bounds.size.height - height - 60 : 60;
            if (position >= 2) { y = (window.bounds.size.height - height) / 2; x = position == 2 ? 20 : window.bounds.size.width - width - 20; }
            label.frame = CGRectMake(x, y, width, height); label.layer.cornerRadius = 10; label.clipsToBounds = YES;
            [window.rootViewController.view addSubview:label]; window.hidden = NO; _toast = window;
            _toastTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
            dispatch_source_set_timer(_toastTimer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(MAX(duration, .1) * NSEC_PER_SEC)), DISPATCH_TIME_FOREVER, 10 * NSEC_PER_MSEC);
            dispatch_source_set_event_handler(_toastTimer, ^{ [self clearToast]; });
            dispatch_resume(_toastTimer);
        }
        [self reply:request value:nil error:nil];
    } else if (task == 26) {
        ZXCheck(f.count == 1, @"Invalid touch indicator arguments");
        int action = (int)ZXValue(f[0], 0, 2);
        if (action == 0) {
            [self stopIndicator];
        } else if (action == 1 && !_indicator) {
            _indicator = [self window]; _indicator.userInteractionEnabled = NO;
            _hid = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
            if (!_hid) { _indicator = nil; ZXCheck(NO, @"Cannot monitor touch events"); }
            IOHIDEventSystemClientRegisterEventCallback(_hid, ZXHID, (__bridge void *)self, NULL);
            IOHIDEventSystemClientScheduleWithRunLoop(_hid, CFRunLoopGetMain(), kCFRunLoopCommonModes);
            _indicator.hidden = NO;
        }
        if (action != 0) [self reloadIndicator];
        [self reply:request value:nil error:nil];
    } else if (task == 90) {
        ZXCheck(f.count == 1, @"Invalid cache command");
        ZXValue(f[0], 1, 3);
        NSDictionary *config = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/ZXTouch/config/tweak/config.plist"];
        _dark = [config[@"dark_mode"] boolValue];
        for (UIWindow *window in _windows.allValues) window.overrideUserInterfaceStyle = _dark ? UIUserInterfaceStyleDark : UIUserInterfaceStyleUnspecified;
        [self reply:request value:nil error:nil];
    } else {
        [self reply:request value:nil error:@"Unsupported app adapter task"];
    }
}
- (void)clearToast {
    if (_toastTimer) { dispatch_source_cancel(_toastTimer); _toastTimer = nil; }
    _toast.hidden = YES; _toast = nil;
}
- (void)stopIndicator {
    if (_hid) {
        IOHIDEventSystemClientUnregisterEventCallback(_hid);
        IOHIDEventSystemClientUnscheduleWithRunLoop(_hid, CFRunLoopGetMain(), kCFRunLoopCommonModes);
        CFRelease(_hid); _hid = NULL;
    }
    _indicator.hidden = YES; _indicator = nil; [_dots removeAllObjects];
}
- (void)reloadIndicator {
    NSDictionary *config = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/ZXTouch/config/tweak/config.plist"];
    NSDictionary *indicator = [config[@"touch_indicator"] isKindOfClass:NSDictionary.class] ? config[@"touch_indicator"] : nil;
    NSDictionary *color = [indicator[@"color"] isKindOfClass:NSDictionary.class] ? indicator[@"color"] : nil;
    _coordinates = [indicator[@"show_coordinates"] boolValue];
    if (color) {
        double r = [color[@"r"] doubleValue], g = [color[@"g"] doubleValue], b = [color[@"b"] doubleValue], a = color[@"alpha"] ? [color[@"alpha"] doubleValue] : .6;
        if (std::isfinite(r) && std::isfinite(g) && std::isfinite(b) && std::isfinite(a))
            _dotColor = [UIColor colorWithRed:MAX(0,MIN(255,r))/255 green:MAX(0,MIN(255,g))/255 blue:MAX(0,MIN(255,b))/255 alpha:MAX(0,MIN(1,a))];
    }
    for (UILabel *dot in _dots.allValues) dot.backgroundColor = _dotColor;
}
- (void)hid:(IOHIDEventRef)event {
    if (!_indicator || IOHIDEventGetType(event) != kIOHIDEventTypeDigitizer) return;
    CFArrayRef children = IOHIDEventGetChildren(event);
    if (!children) return;
    CGSize size = _indicator.bounds.size;
    UIInterfaceOrientation orientation = _indicator.windowScene.interfaceOrientation;
    for (CFIndex i=0; i<CFArrayGetCount(children); ++i) {
        IOHIDEventRef finger = (IOHIDEventRef)CFArrayGetValueAtIndex(children, i);
        if (IOHIDEventGetType(finger) != kIOHIDEventTypeDigitizer) continue;
        NSNumber *key = @(IOHIDEventGetIntegerValue(finger, kIOHIDEventFieldDigitizerIndex));
        if (!IOHIDEventGetIntegerValue(finger, kIOHIDEventFieldDigitizerTouch)) {
            [_dots[key] removeFromSuperview]; [_dots removeObjectForKey:key]; continue;
        }
        double x = IOHIDEventGetFloatValue(finger, kIOHIDEventFieldDigitizerX);
        double y = IOHIDEventGetFloatValue(finger, kIOHIDEventFieldDigitizerY);
        if (!std::isfinite(x) || !std::isfinite(y) || x < 0 || y < 0 || x > 1 || y > 1) continue;
        double nx = x, ny = y;
        if (orientation == UIInterfaceOrientationLandscapeLeft) { nx=1-y; ny=x; }
        else if (orientation == UIInterfaceOrientationLandscapeRight) { nx=y; ny=1-x; }
        else if (orientation == UIInterfaceOrientationPortraitUpsideDown) { nx=1-x; ny=1-y; }
        UILabel *dot = _dots[key];
        if (!dot) {
            if (_dots.count >= 20) continue;
            dot = [UILabel new]; dot.backgroundColor = _dotColor;
            dot.layer.cornerRadius=14; dot.clipsToBounds=YES; dot.textColor=UIColor.whiteColor;
            dot.font=[UIFont systemFontOfSize:10]; dot.textAlignment=NSTextAlignmentCenter; dot.text=key.stringValue;
            [_indicator.rootViewController.view addSubview:dot]; _dots[key]=dot;
        }
        dot.text = _coordinates ? [NSString stringWithFormat:@"%.0f,%.0f", nx*size.width*UIScreen.mainScreen.nativeScale, ny*size.height*UIScreen.mainScreen.nativeScale] : key.stringValue;
        CGFloat diameter = _coordinates ? 72 : 28;
        dot.frame=CGRectMake(nx*size.width-diameter/2, ny*size.height-14, diameter, 28);
    }
}
- (void)receive:(NSNotification *)notification {
    NSDictionary *request = notification.userInfo;
    NSString *target = request[@"target"], *identifier = request[@"id"];
    if (![target isEqual:NSBundle.mainBundle.bundleIdentifier] || ![identifier isKindOfClass:NSString.class] || identifier.length > 64) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([request[@"cancel"] boolValue]) { [self->_pending removeObject:identifier]; [self dismiss:identifier]; return; }
        if (![request[@"fields"] isKindOfClass:NSArray.class] || ![request[@"task"] isKindOfClass:NSNumber.class] ||
            ![request[@"expires"] isKindOfClass:NSNumber.class] || [request[@"expires"] doubleValue] <= NSDate.date.timeIntervalSince1970) return;
        for (id field in request[@"fields"]) if (![field isKindOfClass:NSString.class]) return;
        if ([self->_pending containsObject:identifier]) return;
        [self->_pending addObject:identifier];
        @try { [self execute:request]; }
        @catch (NSException *exception) { [self reply:request value:nil error:exception.reason]; [self dismiss:identifier]; }
    });
}
@end

__attribute__((constructor)) static void ZXInstallAdapter(void) {
    dispatch_async(dispatch_get_main_queue(), ^{ static ZXAppAdapter *adapter; if (!adapter) adapter = [ZXAppAdapter new]; });
}
