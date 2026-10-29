#!/usr/bin/env python3
"""Run the real keyboard dispatcher/native methods against recording host shims.

Simulate an installed but unresponsive App adapter. Hardware keyboard actions
must still dispatch through the native generator, without trying a second input
backend after dispatch. This fixture does not prove iOS text-field delivery.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / "src/TVNCZXTouchService.mm").read_text()


def method(prefix):
    start = source.index(prefix)
    brace = source.index("{", start)
    depth, end = 1, brace + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


dispatch = source[source.index("            case 24:"):source.index("            case 25:")]
program = r'''
#import <Foundation/Foundation.h>
#include "ZXTouchProtocol.hpp"
static NSMutableArray *keys;
static int uiRequests;
static BOOL connected;
static int disconnectAfterPress, presses;
static void Check(BOOL condition, NSString *message) {
    if (!condition) { fprintf(stderr, "%s\n", message.UTF8String); exit(1); }
}
static void ZXMain(dispatch_block_t block) { block(); }
@interface TestServer : NSObject
- (BOOL)isClientConnected:(NSUInteger)client;
@end
@implementation TestServer
- (BOOL)isClientConnected:(NSUInteger)client { return connected && client != 99; }
@end
@interface UIPasteboard : NSObject
@property NSString *string;
+ (instancetype)generalPasteboard;
@end
@implementation UIPasteboard
+ (instancetype)generalPasteboard { static id shared; if (!shared) shared = [self new]; return shared; }
@end
@interface STHIDEventGenerator : NSObject
+ (instancetype)sharedGenerator;
- (void)performKeyboardSequence:(dispatch_block_t)block;
- (void)keyDown:(NSString *)key;
- (void)keyUp:(NSString *)key;
- (void)keyPress:(NSString *)key;
@end
@implementation STHIDEventGenerator
+ (instancetype)sharedGenerator { static id shared; if (!shared) shared = [self new]; return shared; }
- (void)performKeyboardSequence:(dispatch_block_t)block { block(); }
- (void)keyDown:(NSString *)key { [keys addObject:[@"down:" stringByAppendingString:key]]; }
- (void)keyUp:(NSString *)key { [keys addObject:[@"up:" stringByAppendingString:key]]; }
- (void)keyPress:(NSString *)key {
    [keys addObject:[@"press:" stringByAppendingString:key]];
    if (++presses == disconnectAfterPress) connected = NO;
}
@end
'''
for prefix in ["static void ZXRequire(", "static NSString *ZXString(",
               "static NSString *ZXClean(", "static NSData *ZXReply(",
               "static NSData *ZXError(", "static int ZXInteger(", "static void ZXSync("]:
    program += method(prefix) + "\n"
program += r'''
@interface Harness : NSObject {
    BOOL _hasAppAdapter; // Simulates the old installed-file predicate.
    BOOL _stopping;
    dispatch_queue_t _keyboardQueue;
    TestServer *_server;
}
- (NSData *)execute:(const zxtouch::Command &)command client:(NSUInteger)client;
- (NSData *)keyboard:(const zxtouch::Command &)command client:(NSUInteger)client;
- (NSData *)ui:(const zxtouch::Command &)command client:(NSUInteger)client target:(NSString *)target;
- (NSString *)foreground;
- (void)disconnectNextQueuedWork;
@end
@implementation Harness
- (instancetype)init {
    if ((self = [super init])) {
        _hasAppAdapter = YES;
        _keyboardQueue = dispatch_queue_create("keyboard-test", DISPATCH_QUEUE_SERIAL);
        _server = [TestServer new];
    }
    return self;
}
- (NSString *)foreground { return @"fixture.app"; }
- (void)disconnectNextQueuedWork { dispatch_async(_keyboardQueue, ^{ connected = NO; }); }
- (NSData *)ui:(const zxtouch::Command &)command client:(NSUInteger)client target:(NSString *)target {
    (void)command; (void)client; (void)target;
    ++uiRequests;
    return ZXError(@"ZXTouch UI adapter did not reply before the timeout");
}
- (NSData *)execute:(const zxtouch::Command &)command client:(NSUInteger)client {
    @try {
        switch (command.task) {
'''
program += dispatch
program += r'''
            default: return ZXError(@"Unexpected task");
        }
    } @catch (NSException *exception) { return ZXError(exception.reason); }
}
'''
program += method("- (BOOL)emitKeyboard:") + "\n" + method("- (NSData *)keyboard:")
program += r'''
@end
static NSDictionary *send(Harness *service, std::initializer_list<const char *> fields,
                          BOOL live = YES, int after = 0, BOOL queued = NO) {
    keys = [NSMutableArray new]; uiRequests = 0;
    connected = live; disconnectAfterPress = after; presses = 0;
    if (queued) [service disconnectNextQueuedWork];
    zxtouch::Command command; command.task = 24;
    for (const char *field : fields) command.fields.emplace_back(field);
    NSData *data = [service execute:command client:1];
    return [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
}
int main() { @autoreleasepool {
    Harness *service = [Harness new];
    NSDictionary *reply = send(service, {"1", "aA7@"});
    Check(!reply[@"error"] && uiRequests == 0, @"Text typing incorrectly requires the unavailable App adapter");
    Check([keys isEqual:@[@"press:a", @"press:A", @"press:7", @"press:@"]], @"ASCII text did not use native keyPress in order");
    reply = send(service, {"3", "-2"});
    Check(!reply[@"error"] && uiRequests == 0 && [keys isEqual:@[@"press:LEFTARROW", @"press:LEFTARROW"]], @"Cursor movement depends on App injection");
    reply = send(service, {"4", "2"});
    Check(!reply[@"error"] && uiRequests == 0 && [keys isEqual:@[@"press:BACKSPACE", @"press:BACKSPACE"]], @"Delete depends on App injection");
    reply = send(service, {"7", "clipboard fixture"});
    Check(!reply[@"error"] && uiRequests == 0 && keys.count == 0 && [UIPasteboard.generalPasteboard.string isEqual:@"clipboard fixture"], @"Clipboard set dispatches keys or requires App injection");
    reply = send(service, {"5"});
    Check(!reply[@"error"] && uiRequests == 0 && [keys isEqual:@[@"down:LEFTCOMMAND", @"press:v", @"up:LEFTCOMMAND"]], @"Paste did not release Command or requires App injection");
    reply = send(service, {"1", "中文"});
    Check(!reply[@"error"] && uiRequests == 0 && [UIPasteboard.generalPasteboard.string isEqual:@"中文"] && [keys isEqual:@[@"down:LEFTCOMMAND", @"press:v", @"up:LEFTCOMMAND"]], @"Unicode text lost the native clipboard/paste path");
    reply = send(service, {"6"});
    Check([reply[@"value"] isEqual:@"中文"] && keys.count == 0, @"Clipboard read inserted text");
    reply = send(service, {"8", "aA7@"});
    Check(!reply[@"error"] && uiRequests == 0 && [UIPasteboard.generalPasteboard.string isEqual:@"aA7@"] && [keys isEqual:@[@"down:LEFTCOMMAND", @"press:v", @"up:LEFTCOMMAND"]], @"Literal ASCII text was translated into layout-dependent physical keys");
    reply = send(service, {"8", "中文"});
    Check(!reply[@"error"] && uiRequests == 0 && [UIPasteboard.generalPasteboard.string isEqual:@"中文"], @"Literal Unicode lost its original content");
    reply = send(service, {"2", "1"});
    Check(reply[@"error"] && uiRequests == 1 && keys.count == 0, @"Visibility must retain the explicit App-adapter requirement");
    for (const char *bad : {"0", "9", "2.5", "-1", "1x"}) {
        reply = send(service, {bad, "x"});
        Check(reply[@"error"] && keys.count == 0 && uiRequests == 0, @"Invalid keyboard task dispatched input");
    }
    reply = send(service, {"4", "257"});
    Check(reply[@"error"] && keys.count == 0 && uiRequests == 0, @"Unbounded deletion dispatched input");
    reply = send(service, {"1"});
    Check(reply[@"error"] && keys.count == 0 && uiRequests == 0, @"Missing text dispatched input");
    reply = send(service, {"1", "abcd"}, NO);
    Check(reply[@"error"] && keys.count == 0, @"Disconnected client started typing");
    reply = send(service, {"4", "4"}, YES, 1);
    Check(reply[@"error"] && [keys isEqual:@[@"press:BACKSPACE"]], @"Deletion continued after disconnect");
    reply = send(service, {"1", "abcd"}, YES, 1);
    Check(reply[@"error"] && [keys isEqual:@[@"press:a"]], @"Typing continued after disconnect");
    reply = send(service, {"1", "abcd"}, YES, 0, YES);
    Check(reply[@"error"] && keys.count == 0, @"Queued text started after disconnect");
    reply = send(service, {"5"}, YES, 1);
    Check(reply[@"error"] && [keys isEqual:@[@"down:LEFTCOMMAND", @"press:v", @"up:LEFTCOMMAND"]], @"Paste left Command held after disconnect");
    reply = send(service, {"8", "aA7@"}, NO);
    Check(reply[@"error"] && keys.count == 0 && [UIPasteboard.generalPasteboard.string isEqual:@"中文"], @"Disconnected literal input modified pasteboard");
    puts("ZXTouch native keyboard routing, typing, paste and validation passed");
} }
'''

with tempfile.TemporaryDirectory(prefix="tvnc-keyboard-") as temp:
    fixture = Path(temp) / "keyboard.mm"
    binary = Path(temp) / "keyboard-tests"
    fixture.write_text(program)
    subprocess.run(["xcrun", "clang++", "-std=c++20", "-fobjc-arc", "-framework", "Foundation",
                    "-I", str(ROOT / "vendor/zxtouch/include"), str(fixture),
                    str(ROOT / "vendor/zxtouch/src/ZXTouchProtocol.cpp"), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
