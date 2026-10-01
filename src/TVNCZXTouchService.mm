// SPDX-License-Identifier: GPL-2.0-only
#import "TVNCZXTouchService.h"
#import "ZXTouchTCPServer.h"
#import "ZXTouchImage.hpp"
#import "STHIDEventGenerator.h"
#import "ScreenCapturer.h"
#import "FBSOrientationObserver.h"
#import <UIKit/UIKit.h>
#import <Vision/Vision.h>
#import <sys/utsname.h>
#include <atomic>
#include <unistd.h>
#include <algorithm>
#include <cmath>

@interface NSObject (ZXTouchWorkspace)
+ (id)defaultWorkspace;
- (BOOL)openApplicationWithBundleID:(NSString *)identifier;
@end

static void ZXRequire(BOOL condition, NSString *message) {
    if (!condition) @throw [NSException exceptionWithName:@"ZXTouchInput" reason:message userInfo:nil];
}
static NSString *ZXString(const std::string &value) {
    NSString *text = [[NSString alloc] initWithBytes:value.data() length:value.size() encoding:NSUTF8StringEncoding];
    ZXRequire(text != nil, @"Payload must be UTF-8");
    return text;
}
static NSString *ZXClean(NSString *text) {
    return [[[text ?: @"" stringByReplacingOccurrencesOfString:@"\r" withString:@" "]
        stringByReplacingOccurrencesOfString:@"\n" withString:@" "] stringByReplacingOccurrencesOfString:@";;" withString:@"; "];
}
static NSData *ZXReply(NSString *fields) {
    return [[fields ? [NSString stringWithFormat:@"0;;%@\r\n", fields] : @"0\r\n" copy] dataUsingEncoding:NSUTF8StringEncoding];
}
static NSData *ZXError(NSString *message) {
    return [[NSString stringWithFormat:@"-1;;%@\r\n", ZXClean(message)] dataUsingEncoding:NSUTF8StringEncoding];
}
static double ZXNumber(const std::string &value, double low, double high) {
    double result;
    ZXRequire(zxtouch::number(value, result) && result >= low && result <= high, @"Invalid numeric argument");
    return result;
}
static int ZXInteger(const std::string &value, int low, int high) {
    int result;
    ZXRequire(zxtouch::integer(value, result) && result >= low && result <= high, @"Invalid integer argument");
    return result;
}
static void ZXSync(dispatch_queue_t queue, dispatch_block_t block) {
    __block NSException *failure = nil;
    dispatch_sync(queue, ^{
        @try { block(); } @catch (NSException *exception) { failure = exception; }
    });
    if (failure) @throw failure;
}
static void ZXMain(dispatch_block_t block) {
    if (NSThread.isMainThread) block(); else ZXSync(dispatch_get_main_queue(), block);
}
static int ZXQuad(UIInterfaceOrientation orientation) {
    switch (orientation) {
        case UIInterfaceOrientationLandscapeLeft: return 1;
        case UIInterfaceOrientationPortraitUpsideDown: return 2;
        case UIInterfaceOrientationLandscapeRight: return 3;
        default: return 0;
    }
}
static zxtouch::GrayImage ZXGray(CGImageRef image, int width, int height) {
    ZXRequire(image && width > 0 && height > 0 && width <= 16384 && height <= 16384 &&
        (uint64_t)width * height <= 32 * 1024 * 1024, @"Image dimensions are too large");
    zxtouch::GrayImage result{width, height, std::vector<uint8_t>((size_t)width * height)};
    CGColorSpaceRef space = CGColorSpaceCreateDeviceGray();
    CGContextRef context = CGBitmapContextCreate(result.pixels.data(), width, height, 8, width, space, kCGImageAlphaNone);
    CGColorSpaceRelease(space);
    ZXRequire(context != NULL, @"Unable to allocate image buffer");
    CGContextSetInterpolationQuality(context, kCGInterpolationHigh);
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), image);
    CGContextRelease(context);
    return result;
}

@implementation TVNCZXTouchService {
    ZXTouchTCPServer *_server;
    FBSOrientationObserver *_observer;
    UIInterfaceOrientation _orientation; // main thread only
    NSMutableDictionary<NSNumber *, NSMutableDictionary<NSNumber *, NSDictionary *> *> *_clients;
    dispatch_semaphore_t _imageSlot;
    dispatch_queue_t _keyboardQueue;
    std::atomic<bool> _stopping;
}
- (instancetype)init {
    if ((self = [super init])) {
        _clients = [NSMutableDictionary dictionary];
        _imageSlot = dispatch_semaphore_create(1);
        _keyboardQueue = dispatch_queue_create("com.82flex.trollvnc.zxtouch.keyboard", DISPATCH_QUEUE_SERIAL);
        _orientation = UIInterfaceOrientationPortrait;
        _stopping = false;
    }
    return self;
}
- (BOOL)startOnHost:(NSString *)host port:(int)port error:(NSError **)error {
    if (_server) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EALREADY userInfo:nil];
        return NO;
    }
    _stopping = false;
    _observer = [FBSOrientationObserver new];
    _orientation = _observer.activeInterfaceOrientation;
    __weak TVNCZXTouchService *weakSelf = self;
    [_observer setHandler:^(FBSOrientationUpdate *update) {
        TVNCZXTouchService *strongSelf = weakSelf;
        if (strongSelf && update) ZXMain(^{ strongSelf->_orientation = update.orientation; });
    }];
    _server = [[ZXTouchTCPServer alloc] initWithHandler:^NSData *(const zxtouch::Command &command, NSUInteger client) {
        return [weakSelf execute:command client:client];
    } disconnected:^(NSUInteger client) { [weakSelf releaseClient:client]; }];
    if ([_server startOnHost:host port:port error:error]) return YES;
    [self stop];
    return NO;
}
- (void)stop {
    _stopping = true;
    [_server stop];
    [_observer invalidate];
    _observer = nil;
    for (NSNumber *client in _clients.allKeys) [self releaseClient:client.unsignedIntegerValue];
    // Wait for a current short press/chord to finish. Workers check stopping
    // inside this same lock before emitting, and never hop to main while held.
    [[STHIDEventGenerator sharedGenerator] performKeyboardSequence:^{}];
    [[STHIDEventGenerator sharedGenerator] flushPendingEvents];
}
- (void)releaseClient:(NSUInteger)client {
    ZXMain(^{
        NSDictionary *state = self->_clients[@(client)];
        if (!state.count) { [self->_clients removeObjectForKey:@(client)]; return; }
        NSMutableArray *events = [NSMutableArray array];
        for (NSDictionary *touch in state.allValues) {
            NSMutableDictionary *event = [touch mutableCopy];
            event[HIDEventPhaseKey] = HIDEventPhaseCanceled;
            [events addObject:event];
        }
        [self->_clients removeObjectForKey:@(client)];
        for (NSDictionary *other in self->_clients.allValues) [events addObjectsFromArray:other.allValues];
        [[STHIDEventGenerator sharedGenerator] dispatchNormalizedTouches:events];
    });
}
- (void)touch:(const zxtouch::Command &)command client:(NSUInteger)client {
    ZXMain(^{
        if (self->_stopping) return;
        CGSize native = [UIScreen.mainScreen nativeBounds].size;
        // nativeBounds may reflect orientation on some runtimes; use portrait axes.
        double width = MIN(native.width, native.height), height = MAX(native.width, native.height);
        int q = ZXQuad(self->_orientation);
        double orientedWidth = q % 2 ? height : width, orientedHeight = q % 2 ? width : height;
        NSMutableDictionary *next = [self->_clients[@(client)] mutableCopy] ?: [NSMutableDictionary dictionary];
        bool used[20] = {};
        for (NSDictionary *state in self->_clients.allValues)
            for (NSDictionary *event in state.allValues) used[[event[HIDEventTouchIDKey] intValue] - 32] = true;
        NSMutableArray *changed = [NSMutableArray array];
        for (auto &touch : command.touches) {
            ZXRequire(touch.x < orientedWidth && touch.y < orientedHeight, @"Touch is outside the screen");
            NSDictionary *previous = next[@(touch.finger)];
            ZXRequire(touch.type == 1 ? previous == nil : previous != nil, @"Invalid touch phase sequence");
            int slot = previous ? [previous[HIDEventTouchIDKey] intValue] - 32 : 0;
            if (!previous) {
                while (slot < 20 && used[slot]) ++slot;
                ZXRequire(slot < 20, @"Too many active fingers");
                used[slot] = true;
            }
            double x = touch.x, y = touch.y, nx = x, ny = y;
            if (q == 1) { nx = y; ny = height - 1 - x; }
            else if (q == 2) { nx = width - 1 - x; ny = height - 1 - y; }
            else if (q == 3) { nx = width - 1 - y; ny = x; }
            NSDictionary *event = @{
                HIDEventTouchIDKey: @(slot + 32), HIDEventFingerKey: @(slot + 32),
                HIDEventPhaseKey: touch.type == 0 ? HIDEventPhaseEnded : touch.type == 1 ? HIDEventPhaseBegan : HIDEventPhaseMoved,
                HIDEventXKey: @(std::clamp(nx / width, 0.0, 1.0)), HIDEventYKey: @(std::clamp(ny / height, 0.0, 1.0)),
                HIDEventMajorRadiusKey: @0.04, HIDEventMinorRadiusKey: @0.04
            };
            [changed addObject:event];
            if (touch.type == 0) [next removeObjectForKey:@(touch.finger)];
            else {
                NSMutableDictionary *stationary = [event mutableCopy];
                stationary[HIDEventPhaseKey] = HIDEventPhaseStationary;
                next[@(touch.finger)] = stationary;
            }
        }
        self->_clients[@(client)] = next;
        NSMutableSet *changedIDs = [NSMutableSet set];
        for (NSDictionary *event in changed) [changedIDs addObject:event[HIDEventTouchIDKey]];
        for (NSDictionary *state in self->_clients.allValues)
            for (NSDictionary *event in state.allValues)
                if (![changedIDs containsObject:event[HIDEventTouchIDKey]]) [changed addObject:event];
        [[STHIDEventGenerator sharedGenerator] dispatchNormalizedTouches:changed];
    });
}
- (UIImage *)snapshot {
    __block UIImage *result = nil;
    ZXMain(^{
        if (self->_stopping) return;
        CGImageRef image = [ScreenCapturer copyNativeScreenImage];
        if (!image) return;
        int q = ZXQuad(self->_orientation);
        UIImageOrientation orientations[] = {UIImageOrientationUp, UIImageOrientationRight, UIImageOrientationDown, UIImageOrientationLeft};
        UIImage *source = [UIImage imageWithCGImage:image scale:1 orientation:orientations[q]];
        CGSize size = CGSizeMake(CGImageGetWidth(image), CGImageGetHeight(image));
        if (q % 2) size = CGSizeMake(size.height, size.width);
        UIGraphicsBeginImageContextWithOptions(size, YES, 1);
        [source drawInRect:CGRectMake(0, 0, size.width, size.height)];
        result = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        CGImageRelease(image);
    });
    ZXRequire(result.CGImage != NULL, @"Unable to capture screen");
    return result;
}
- (void)emitKeyboard:(dispatch_block_t)block {
    [[STHIDEventGenerator sharedGenerator] performKeyboardSequence:^{
        if (!self->_stopping) block();
    }];
}
- (NSData *)keyboard:(const zxtouch::Command &)command {
    auto &f = command.fields;
    int task = ZXInteger(f[0], 1, 7);
    if (task == 1 || task == 2 || task == 3 || task == 4 || task == 7) ZXRequire(f.size() == 2, @"Keyboard command requires one argument");
    else ZXRequire(f.size() == 1, @"Unexpected keyboard arguments");
    NSString *text = f.size() == 2 ? ZXString(f[1]) : @"";
    if (task == 2) return ZXError(@"Keyboard visibility requires an app-side adapter");
    int count = task == 3 || task == 4 ? ZXInteger(f[1], task == 3 ? -256 : 0, 256) : 0;
    ZXRequire(task != 1 || text.length <= 256, @"Text is too long; send at most 256 characters per command");
    __block NSString *result = @"";
    // Hardware keyPress sleeps for 50ms; serialize it off the main runloop.
    // Only pasteboard access crosses to main, so capture/accept/stop can progress.
    ZXSync(_keyboardQueue, ^{
        if (self->_stopping) return;
        STHIDEventGenerator *generator = STHIDEventGenerator.sharedGenerator;
        if (task == 6) ZXMain(^{ result = UIPasteboard.generalPasteboard.string ?: @""; });
        else if (task == 7) ZXMain(^{ UIPasteboard.generalPasteboard.string = text; });
        else if (task == 5 || (task == 1 && ![text canBeConvertedToEncoding:NSASCIIStringEncoding])) {
            if (task == 1) ZXMain(^{ UIPasteboard.generalPasteboard.string = text; });
            [self emitKeyboard:^{
                [generator keyDown:@"LEFTCOMMAND"]; [generator keyPress:@"v"]; [generator keyUp:@"LEFTCOMMAND"];
            }];
        } else if (task == 1) {
            for (NSUInteger i = 0; i < text.length && !self->_stopping; ++i)
                [self emitKeyboard:^{ [generator keyPress:[text substringWithRange:NSMakeRange(i, 1)]]; }];
        } else {
            NSString *key = task == 4 ? @"BACKSPACE" : count < 0 ? @"LEFTARROW" : @"RIGHTARROW";
            for (int i = 0; i < std::abs(count) && !self->_stopping; ++i)
                [self emitKeyboard:^{ [generator keyPress:key]; }];
        }
    });
    return ZXReply(ZXClean(result));
}
- (NSData *)deviceInfo:(const zxtouch::Command &)command {
    ZXRequire(command.fields.size() == 1, @"Invalid device-info arguments");
    int task = ZXInteger(command.fields[0], 1, 31);
    __block NSString *result = nil;
    ZXMain(^{
        int q = ZXQuad(self->_orientation);
        CGSize size = UIScreen.mainScreen.nativeBounds.size;
        double width = MIN(size.width, size.height), height = MAX(size.width, size.height);
        UIDevice *device = UIDevice.currentDevice;
        if (task == 1) result = [NSString stringWithFormat:@"%.0f;;%.0f", q % 2 ? height : width, q % 2 ? width : height];
        else if (task == 2) result = [NSString stringWithFormat:@"%ld", (long)self->_orientation];
        else if (task == 3) result = [NSString stringWithFormat:@"%g", UIScreen.mainScreen.scale];
        else if (task == 30) {
            struct utsname info; uname(&info);
            result = [NSString stringWithFormat:@"%@;;%@;;%@;;%s;;%@", ZXClean(device.name), ZXClean(device.systemName),
                ZXClean(device.systemVersion), info.machine, device.identifierForVendor.UUIDString ?: @""];
        } else if (task == 31) {
            device.batteryMonitoringEnabled = YES;
            result = [NSString stringWithFormat:@"%ld;;%g", (long)device.batteryState, device.batteryLevel * 100];
        }
    });
    ZXRequire(result != nil, @"Unsupported device-info task");
    return ZXReply(result);
}
- (NSData *)color:(const zxtouch::Command &)command image:(UIImage *)image {
    auto &f = command.fields;
    int width = (int)CGImageGetWidth(image.CGImage), height = (int)CGImageGetHeight(image.CGImage);
    int x, y, endX, endY, step = 1;
    int bounds[6] = {0,255,0,255,0,255};
    BOOL search = command.task == 28;
    if (!search) {
        ZXRequire(f.size() == 2, @"Color picker requires x and y");
        x = (int)ZXNumber(f[0], 0, width - 1); y = (int)ZXNumber(f[1], 0, height - 1);
        endX = x + 1; endY = y + 1;
    } else {
        ZXRequire(f.size() == 12 && ZXInteger(f[0], 1, 1) == 1, @"Invalid color search arguments");
        x = ZXInteger(f[1], 0, width - 1); y = ZXInteger(f[2], 0, height - 1);
        int w = ZXInteger(f[3], 0, 16384), h = ZXInteger(f[4], 0, 16384);
        endX = w ? MIN(width, x + w) : width; endY = h ? MIN(height, y + h) : height;
        for (int i = 0; i < 6; ++i) bounds[i] = ZXInteger(f[5 + i], 0, 255);
        ZXRequire(bounds[0] <= bounds[1] && bounds[2] <= bounds[3] && bounds[4] <= bounds[5], @"Invalid color range");
        step = ZXInteger(f[11], 0, 16384) + 1;
    }
    CGImageRef crop = CGImageCreateWithImageInRect(image.CGImage, CGRectMake(x, y, endX - x, endY - y));
    ZXRequire(crop != NULL, @"Unable to crop screenshot");
    size_t w = CGImageGetWidth(crop), h = CGImageGetHeight(crop);
    std::vector<uint8_t> pixels(w * h * 4);
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(pixels.data(), w, h, 8, w * 4, space,
        (CGBitmapInfo)kCGBitmapByteOrder32Big | (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(space);
    if (context) { CGContextDrawImage(context, CGRectMake(0,0,w,h), crop); CGContextRelease(context); }
    CGImageRelease(crop);
    ZXRequire(context != NULL, @"Unable to read image colors");
    for (int cy = 0; cy < (int)h; cy += step) for (int cx = 0; cx < (int)w; cx += step) {
        auto p = &pixels[((size_t)cy * w + cx) * 4];
        if (p[0] < bounds[0] || p[0] > bounds[1] || p[1] < bounds[2] || p[1] > bounds[3] || p[2] < bounds[4] || p[2] > bounds[5]) continue;
        return ZXReply(search ? [NSString stringWithFormat:@"%d;;%d;;%d;;%d;;%d", x+cx,y+cy,p[0],p[1],p[2]] :
            [NSString stringWithFormat:@"%d;;%d;;%d", p[0],p[1],p[2]]);
    }
    return ZXReply(@"-1;;-1;;-1;;-1;;-1");
}
- (NSData *)match:(const zxtouch::Command &)command image:(UIImage *)image {
    auto &f = command.fields;
    ZXRequire(f.size() == 1 || f.size() == 4, @"Invalid image-match arguments");
    NSString *path = ZXString(f[0]);
    ZXRequire(path.isAbsolutePath, @"Template path must be absolute");
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
    ZXRequire(attributes && [attributes[NSFileSize] unsignedLongLongValue] <= 16 * 1024 * 1024, @"Template file is missing or too large");
    UIImage *pattern = [UIImage imageWithContentsOfFile:path];
    ZXRequire(pattern.CGImage != NULL, @"Unable to load template image");
    int tries = f.size() == 4 ? ZXInteger(f[1], 1, 8) : 2;
    double threshold = f.size() == 4 ? ZXNumber(f[2], 0, 1) : .8;
    double ratio = f.size() == 4 ? ZXNumber(f[3], .1, 1) : .8;
    int sw = (int)CGImageGetWidth(image.CGImage), sh = (int)CGImageGetHeight(image.CGImage);
    int pw = (int)CGImageGetWidth(pattern.CGImage), ph = (int)CGImageGetHeight(pattern.CGImage);
    ZXRequire(pw <= 4096 && ph <= 4096, @"Template dimensions are too large");
    auto native = ZXGray(image.CGImage, sw, sh);
    double scale = std::min(1.0, 320.0 / std::max(sw, sh));
    int cw = std::max(1, int(std::round(sw * scale))), ch = std::max(1, int(std::round(sh * scale)));
    auto coarse = ZXGray(image.CGImage, cw, ch);
    for (int attempt = 0; attempt < tries && !self->_stopping; ++attempt) {
        int w = std::max(1, int(std::round(pw * std::pow(ratio, attempt))));
        int h = std::max(1, int(std::round(ph * std::pow(ratio, attempt))));
        if (w > sw || h > sh) continue;
        auto fullPattern = ZXGray(pattern.CGImage, w, h);
        auto smallPattern = ZXGray(pattern.CGImage, std::max(1, int(std::round(w * scale))), std::max(1, int(std::round(h * scale))));
        auto candidates = zxtouch::matchCandidates(coarse, smallPattern);
        zxtouch::Match best;
        int radius = int(std::ceil(1 / scale));
        int sample = std::max(1, int(std::ceil(std::sqrt(double(w) * h / 4096))));
        for (auto candidate : candidates) {
            int px = int(std::round(candidate.x / scale)), py = int(std::round(candidate.y / scale));
            for (int y = std::max(0, py-radius); y <= std::min(sh-h, py+radius); ++y)
                for (int x = std::max(0, px-radius); x <= std::min(sw-w, px+radius); ++x) {
                    double score = zxtouch::correlation(native, fullPattern, x, y, sample);
                    if (score > best.score) best = {x,y,score};
                }
        }
        if (best.x >= 0 && best.score >= threshold) return ZXReply([NSString stringWithFormat:@"%d;;%d;;%d;;%d", best.x,best.y,w,h]);
    }
    return ZXError(@"Template image not found on screen");
}
- (NSData *)ocr:(const zxtouch::Command &)command image:(UIImage *)image {
    auto &f = command.fields;
    int task = ZXInteger(f[0], 1, 2);
    ZXRequire((task == 2 && f.size() == 2) || (task == 1 && f.size() == 8), @"Invalid OCR arguments");
    int level = ZXInteger(f[task == 2 ? 1 : 4], 0, 1);
    VNRecognizeTextRequest *request = [VNRecognizeTextRequest new];
    request.recognitionLevel = level == 1 ? VNRequestTextRecognitionLevelFast : VNRequestTextRecognitionLevelAccurate;
    request.revision = VNRecognizeTextRequestRevision2;
    NSError *error = nil;
    if (task == 2) {
        NSArray *languages;
        if (@available(iOS 15.0, *)) languages = [request supportedRecognitionLanguagesAndReturnError:&error];
        else languages = [VNRecognizeTextRequest supportedRecognitionLanguagesForTextRecognitionLevel:request.recognitionLevel revision:request.revision error:&error];
        return error ? ZXError(error.localizedDescription) : ZXReply([languages componentsJoinedByString:@";;"]);
    }
    auto rect = zxtouch::split(f[1], ",,");
    ZXRequire(rect.size() == 4, @"Invalid OCR region");
    double sw = CGImageGetWidth(image.CGImage), sh = CGImageGetHeight(image.CGImage);
    double x = ZXNumber(rect[0],0,sw-1), y = ZXNumber(rect[1],0,sh-1);
    double w = ZXNumber(rect[2],0,16384), h = ZXNumber(rect[3],0,16384);
    w = w ? std::min(w,sw-x) : sw-x; h = h ? std::min(h,sh-y) : sh-y;
    if (!f[2].empty()) request.customWords = [ZXString(f[2]) componentsSeparatedByString:@",,"];
    request.minimumTextHeight = f[3].empty() ? 1.0/32 : ZXNumber(f[3],0,1);
    if (!f[5].empty()) request.recognitionLanguages = [ZXString(f[5]) componentsSeparatedByString:@",,"];
    request.usesLanguageCorrection = ZXInteger(f[6],0,1);
    ZXRequire(f[7].empty(), @"OCR debug-image output is not included");
    CGImageRef crop = CGImageCreateWithImageInRect(image.CGImage, CGRectMake(x,y,w,h));
    ZXRequire(crop != NULL, @"Unable to crop OCR region");
    VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:crop options:@{}];
    BOOL ok = [handler performRequests:@[request] error:&error];
    CGImageRelease(crop);
    if (!ok) return ZXError(error.localizedDescription ?: @"OCR failed");
    NSMutableArray *result = [NSMutableArray array];
    for (VNRecognizedTextObservation *observation in request.results) {
        VNRecognizedText *text = [observation topCandidates:1].firstObject;
        if (!text) continue;
        CGRect box = observation.boundingBox;
        NSString *clean = [ZXClean(text.string) stringByReplacingOccurrencesOfString:@",," withString:@", "];
        [result addObject:[NSString stringWithFormat:@"%@,,%d,,%d,,%d,,%d", clean,
            (int)(x+box.origin.x*w), (int)(y+(1-CGRectGetMaxY(box))*h), (int)(box.size.width*w), (int)(box.size.height*h)]];
    }
    return ZXReply([result componentsJoinedByString:@";;"]);
}
- (NSData *)execute:(const zxtouch::Command &)command client:(NSUInteger)client {
    if (_stopping) return command.task == 10 ? nil : ZXError(@"ZXTouch service is stopping");
    @try {
        // Validate UTF-8 for all text commands before passing to native APIs.
        if (command.task != 10) ZXString(command.payload);
        switch (command.task) {
            case 10: [self touch:command client:client]; return nil;
            case 11: {
                NSString *identifier = ZXString(command.payload);
                ZXRequire(identifier.length > 0 && identifier.length <= 255 && command.fields.size() == 1, @"Invalid bundle identifier");
                __block BOOL opened = NO;
                ZXMain(^{
                    if (self->_stopping) return;
                    id workspace = [NSClassFromString(@"LSApplicationWorkspace") defaultWorkspace];
                    if ([workspace respondsToSelector:@selector(openApplicationWithBundleID:)]) opened = [workspace openApplicationWithBundleID:identifier];
                });
                return opened ? ZXReply(nil) : ZXError(@"Unable to open application");
            }
            case 18: {
                ZXRequire(command.fields.size() == 1, @"Invalid sleep arguments");
                int remaining = ZXInteger(command.payload, 0, 60000000);
                while (remaining > 0 && !_stopping) { int chunk = std::min(remaining, 10000); usleep(chunk); remaining -= chunk; }
                return ZXReply(@"Sleep ends");
            }
            case 24: return [self keyboard:command];
            case 25: return [self deviceInfo:command];
            case 14: case 15: case 19: case 20:
                return ZXError(@"Recording and phone-side script playback are not included");
            case 21: case 23: case 27: case 28: case 30: {
                dispatch_semaphore_wait(_imageSlot, DISPATCH_TIME_FOREVER);
                @try {
                    @autoreleasepool {
                        if (_stopping) return ZXError(@"ZXTouch service is stopping");
                        UIImage *image = (command.task == 27 && command.fields[0] == "2") ? nil : [self snapshot];
                        if (command.task == 21) return [self match:command image:image];
                        if (command.task == 23 || command.task == 28) return [self color:command image:image];
                        if (command.task == 27) return [self ocr:command image:image];
                        ZXRequire(command.payload.empty(), @"Screenshot does not accept arguments");
                        NSData *jpeg = UIImageJPEGRepresentation(image, .85);
                        ZXRequire(jpeg.length > 0, @"Unable to encode screenshot");
                        NSMutableData *response = [ZXReply([NSString stringWithFormat:@"image/jpeg;;%lu", (unsigned long)jpeg.length]) mutableCopy];
                        [response appendData:jpeg];
                        return response;
                    }
                } @finally { dispatch_semaphore_signal(_imageSlot); }
            }
            default: return ZXError(@"Unsupported ZXTouch task");
        }
    } @catch (NSException *exception) {
        // Touch has no reply in the original protocol. Release its fingers on
        // invalid state rather than poisoning a following response.
        if (command.task == 10) { [self releaseClient:client]; return nil; }
        return ZXError(exception.reason ?: @"ZXTouch command failed");
    }
}
@end
