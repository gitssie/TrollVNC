#!/usr/bin/env python3
"""Execute production ZXTouch input and HID methods with recording host shims.

UIKit and physical dispatch are unavailable on the host. Extract actual methods
without rewriting their logic; compare the event masks handed to IOKit against
the existing VNC builder. This does not claim live UIKit delivery.
"""
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / "src/STHIDEventGenerator.mm").read_text()
header = (ROOT / "src/STHIDEventGenerator.h").read_text()
spi = (ROOT / "include-spi/IOKitSPI.h").read_text()
service = (ROOT / "src/TVNCZXTouchService.mm").read_text()


def body_at(prefix, text=source):
    start = text.index(prefix)
    brace = text.index("{", start)
    depth = 1
    end = brace + 1
    while depth:
        depth += (text[end] == "{") - (text[end] == "}")
        end += 1
    return text[start:end]


keys = "\n".join(re.findall(r'static NSString \*const \w+ = @"[^"\n]+";', header))
masks = ",\n".join(re.findall(r"kIOHIDDigitizerEvent\w+\s*=\s*1\s*<<\s*\d+", spi))
phase = body_at("static UITouchPhase phaseFromString(")
vnc = body_at("- (IOHIDEventRef)_createIOHIDEventType:")
vnc_mask = vnc[vnc.index("IOHIDDigitizerEventMask eventMask ="):vnc.index("uint64_t machTime")]
hand_types = re.search(r"typedef enum\s*\{[^}]+\}\s*HandEventType;", source).group(0)
methods = "\n".join(body_at(prefix) for prefix in [
    "- (IOHIDDigitizerEventMask)eventMaskFromEventInfo:",
    "- (boolean_t)isTouchFromEventInfo:",
    "- (boolean_t)isTouchFromChildEventInfo:",
    "- (IOHIDEventRef)_createIOHIDEventWithInfo:",
])

program = r'''
#import <Foundation/Foundation.h>
#include <stdint.h>
#include <stdio.h>
#include <algorithm>
#include <vector>
typedef NS_ENUM(NSInteger, UITouchPhase) {
    UITouchPhaseBegan, UITouchPhaseMoved, UITouchPhaseStationary,
    UITouchPhaseEnded, UITouchPhaseCancelled
};
using IOHIDDigitizerEventMask = uint32_t;
using IOHIDEventRef = CFMutableDictionaryRef;
enum { kIOHIDEventOptionNone, kIOHIDEventFieldIsBuiltIn,
    kIOHIDEventFieldDigitizerIsDisplayIntegrated,
    kIOHIDEventFieldDigitizerMinorRadius, kIOHIDEventFieldDigitizerMajorRadius };
static uint64_t mach_absolute_time() { return 1; }
static int transducerTypeFromString(NSString *) { return 0; }
static IOHIDEventRef recordEvent(uint32_t mask) {
    return (__bridge_retained CFMutableDictionaryRef)[@{ @"mask":@(mask), @"children":[NSMutableArray new] } mutableCopy];
}
static IOHIDEventRef IOHIDEventCreateDigitizerEvent(CFAllocatorRef, uint64_t,
    int, uint32_t, uint32_t, uint32_t mask, uint32_t, double, double, double,
    double, double, boolean_t, boolean_t, int) { return recordEvent(mask); }
static IOHIDEventRef IOHIDEventCreateDigitizerFingerEvent(CFAllocatorRef,
    uint64_t, uint32_t, uint32_t, uint32_t mask, double, double, double,
    double, double, boolean_t, boolean_t, int) { return recordEvent(mask); }
static void IOHIDEventSetIntegerValue(IOHIDEventRef, int, int) {}
static void IOHIDEventSetFloatValue(IOHIDEventRef, int, double) {}
static void IOHIDEventAppendEvent(IOHIDEventRef root, IOHIDEventRef child, int) {
    [((__bridge NSDictionary *)root)[@"children"] addObject:(__bridge NSDictionary *)child];
}
'''
program += "enum {\n" + masks + "\n};\n" + keys + "\n" + phase + "\n" + hand_types
program += "\nstatic uint32_t vncMask(HandEventType eventType) {\n" + vnc_mask + "return eventMask;\n}\n"
program += "\n@interface MaskHarness : NSObject\n- (IOHIDEventRef)_createIOHIDEventWithInfo:(NSDictionary *)info;\n@end\n@implementation MaskHarness\n"
program += methods + "\n@end\n"
program += r'''
static NSArray *delivered;
static BOOL revoked;
static void ZXMain(dispatch_block_t block) { block(); }
static NSDictionary *TVNCHTTPJSON(NSDictionary *body, int) { return body; }
static void tvAppHTTPDisconnect(NSString *) { revoked = YES; }
typedef NS_ENUM(NSInteger, UIInterfaceOrientation) {
    UIInterfaceOrientationUnknown, UIInterfaceOrientationPortrait,
    UIInterfaceOrientationPortraitUpsideDown, UIInterfaceOrientationLandscapeLeft,
    UIInterfaceOrientationLandscapeRight
};
namespace zxtouch {
    struct Touch { int type, finger; double x, y; };
    struct Command { int task = 10; std::vector<Touch> touches; };
}
@interface ScreenCapturer : NSObject
+ (CGSize)nativeScreenSize;
@end
@implementation ScreenCapturer
+ (CGSize)nativeScreenSize { return CGSizeMake(1170, 2532); }
@end
@interface TestServer : NSObject
- (BOOL)isClientConnected:(NSUInteger)client;
@end
@implementation TestServer
- (BOOL)isClientConnected:(NSUInteger)client { return client != 99; }
@end
@interface STHIDEventGenerator : NSObject
+ (instancetype)sharedGenerator;
- (void)dispatchNormalizedTouches:(NSArray *)events;
@end
@implementation STHIDEventGenerator
+ (instancetype)sharedGenerator { static id value; if (!value) value = [self new]; return value; }
- (void)dispatchNormalizedTouches:(NSArray *)events { delivered = [events copy]; }
@end
'''
program += body_at("static void ZXRequire(", service) + "\n"
program += body_at("static NSData *ZXError(", service) + "\n"
program += body_at("static int ZXQuad(", service) + "\n"
program += re.search(r"static constexpr int ZXTouchContactBase\s*=\s*\d+;", service).group(0) + "\n"
program += r'''
@interface ServiceHarness : NSObject {
    BOOL _stopping;
    UIInterfaceOrientation _orientation;
    TestServer *_server;
    NSMutableDictionary *_clients;
}
- (void)touch:(const zxtouch::Command &)command client:(NSUInteger)client;
- (void)releaseClient:(NSUInteger)client;
- (NSData *)execute:(const zxtouch::Command &)command client:(NSUInteger)client;
- (NSDictionary *)disconnect:(NSString *)path token:(NSString *)token client:(NSUInteger)client;
- (void)setStopping:(BOOL)value;
- (NSUInteger)contactCount:(NSUInteger)client;
- (void)setOrientation:(UIInterfaceOrientation)value;
@end
@implementation ServiceHarness
- (instancetype)init {
    if ((self = [super init])) {
        _clients = [NSMutableDictionary new]; _server = [TestServer new];
        _orientation = UIInterfaceOrientationPortrait;
    }
    return self;
}
- (void)setStopping:(BOOL)value { _stopping = value; }
- (NSUInteger)contactCount:(NSUInteger)client { return [_clients[@(client)] count]; }
- (void)setOrientation:(UIInterfaceOrientation)value { _orientation = value; }
'''
program += body_at("- (void)touch:(const zxtouch::Command &)", service) + "\n"
program += body_at("- (void)releaseClient:", service) + "\n"
execute = body_at("- (NSData *)execute:", service)
program += execute[:execute.index("@try")] + "return nil;\n}\n"
program += "- (NSDictionary *)disconnect:(NSString *)path token:(NSString *)token client:(NSUInteger)client {\n"
program += body_at('if ([path isEqual:@"/api/control/disconnect"])', service) + "\nreturn nil;\n}\n@end\n"
program += r'''
int main() { @autoreleasepool {
    MaskHarness *generator = [MaskHarness new];
    NSArray *phases = @[HIDEventPhaseBegan, HIDEventPhaseMoved, HIDEventPhaseEnded];
    HandEventType reference[] = {HandEventTouched, HandEventMoved, HandEventLifted};
    int failures = 0;
    for (NSUInteger i = 0; i < phases.count; ++i) {
        NSDictionary *touch = @{HIDEventTouchIDKey:@10, HIDEventFingerKey:@2,
            HIDEventPhaseKey:phases[i], HIDEventXKey:@0.5, HIDEventYKey:@0.4,
            HIDEventMajorRadiusKey:@0.04, HIDEventMinorRadiusKey:@0.04};
        IOHIDEventRef event = [generator _createIOHIDEventWithInfo:@{
            HIDEventInputType:HIDEventInputTypeHand, HIDEventTouchesKey:@[touch]}];
        NSDictionary *record = (__bridge NSDictionary *)event;
        uint32_t parent = [record[@"mask"] unsignedIntValue];
        uint32_t child = [record[@"children"][0][@"mask"] unsignedIntValue];
        uint32_t expected = vncMask(reference[i]);
        printf("%s: VNC=0x%02x ZXTouch parent=0x%02x child=0x%02x\n",
            [phases[i] UTF8String], expected, parent, child);
        if (parent != expected || child != expected) ++failures;
        CFRelease(event);
    }
    ServiceHarness *service = [ServiceHarness new];
    zxtouch::Command command;
    command.touches = {{1, 0, 585, 700}};
    [service touch:command client:1];
    if ([service contactCount:1] != 1 || ![delivered[0][HIDEventPhaseKey] isEqual:HIDEventPhaseBegan]) ++failures;
    if (fabs([delivered[0][HIDEventXKey] doubleValue] - .5) > 1e-9) ++failures;
    NSNumber *firstID = delivered[0][HIDEventTouchIDKey];
    if (firstID.intValue < 10 || firstID.intValue >= 30
        || [delivered[0][HIDEventFingerKey] intValue] != 2) ++failures;
    [service touch:command client:2];
    NSNumber *secondID = delivered[0][HIDEventTouchIDKey];
    if ([firstID isEqual:secondID] || delivered.count != 2) ++failures;
    command.touches = {{2, 0, 600, 710}};
    [service touch:command client:1];
    if (![delivered[0][HIDEventTouchIDKey] isEqual:firstID]
        || ![delivered[0][HIDEventPhaseKey] isEqual:HIDEventPhaseMoved]
        || ![delivered[1][HIDEventPhaseKey] isEqual:HIDEventPhaseStationary]) ++failures;
    BOOL rejected = NO;
    @try { [service touch:command client:3]; } @catch (NSException *) { rejected = YES; }
    if (!rejected || [service contactCount:3]) ++failures;
    command.touches = {{1, 1, 100, 100}, {1, 2, 2000, 100}};
    rejected = NO;
    @try { [service touch:command client:3]; } @catch (NSException *) { rejected = YES; }
    if (!rejected || [service contactCount:3]) ++failures;
    command.touches = {{0, 0, 600, 710}};
    [service touch:command client:1];
    if ([service contactCount:1] || [service contactCount:2] != 1) ++failures;
    [service disconnect:@"/api/control/disconnect" token:@"fixture" client:2];
    if (!revoked || [service contactCount:2]
        || ![delivered[0][HIDEventPhaseKey] isEqual:HIDEventPhaseCanceled]) {
        fprintf(stderr, "Control disconnect retained an owned finger\n"); ++failures;
    }
    [service setStopping:YES];
    NSData *stopped = [service execute:command client:3];
    NSDictionary *response = stopped ? [NSJSONSerialization JSONObjectWithData:stopped options:0 error:nil] : nil;
    if (!response[@"error"]) {
        fprintf(stderr, "Stopped touch returned the nil success sentinel\n"); ++failures;
    }
    [service setStopping:NO];
    [service setOrientation:UIInterfaceOrientationLandscapeLeft];
    command.touches = {{1, 0, 100, 200}};
    [service touch:command client:4];
    if (fabs([delivered[0][HIDEventXKey] doubleValue] - 200. / 1170.) > 1e-9
        || fabs([delivered[0][HIDEventYKey] doubleValue] - (2532. - 1. - 100.) / 2532.) > 1e-9) ++failures;
    [service releaseClient:4];
    if ([service contactCount:4] || ![delivered[0][HIDEventPhaseKey] isEqual:HIDEventPhaseCanceled]) ++failures;
    ServiceHarness *capacity = [ServiceHarness new];
    NSMutableSet *identifiers = [NSMutableSet new];
    NSNumber *releasedID;
    command.touches = {{1, 0, 100, 100}};
    for (NSUInteger client = 1; client <= 20; ++client) {
        [capacity touch:command client:client];
        NSNumber *identifier = delivered[0][HIDEventTouchIDKey];
        if (identifier.intValue < 10 || identifier.intValue >= 30) ++failures;
        [identifiers addObject:identifier];
        if (client == 7) releasedID = identifier;
    }
    if (identifiers.count != 20) ++failures;
    rejected = NO;
    @try { [capacity touch:command client:21]; } @catch (NSException *) { rejected = YES; }
    if (!rejected || [capacity contactCount:21]) ++failures;
    [capacity releaseClient:7];
    [capacity touch:command client:21];
    if (![delivered[0][HIDEventTouchIDKey] isEqual:releasedID]) ++failures;
    NSArray *previousDelivery = delivered;
    rejected = NO;
    @try { [capacity touch:command client:99]; } @catch (NSException *) { rejected = YES; }
    if (!rejected || delivered != previousDelivery) ++failures;
    if (failures) fprintf(stderr, "%d input invariants failed\n", failures);
    else puts("ZXTouch masks, coordinates, phases, client isolation and cleanup passed");
    return failures ? 1 : 0;
} }
'''

with tempfile.TemporaryDirectory(prefix="tvnc-hid-mask-") as directory:
    fixture = Path(directory) / "mask.mm"
    binary = Path(directory) / "mask-tests"
    fixture.write_text(program)
    subprocess.run(["xcrun", "clang++", "-std=c++17", "-fobjc-arc", "-framework", "Foundation",
                    str(fixture), "-o", str(binary)], check=True)
    raise SystemExit(subprocess.run([str(binary)]).returncode)
