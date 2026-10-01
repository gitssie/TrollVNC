// SPDX-License-Identifier: GPL-2.0-only
#import <Foundation/Foundation.h>
#import "ZXTouchProcessRunner.h"
#import "ZXTouchUIBridge.h"
#include <unistd.h>

static void Check(BOOL ok, NSString *message) {
    if (!ok) { fprintf(stderr, "%s\n", message.UTF8String); exit(1); }
}
@interface TestCenter : NSObject <ZXNotificationCenter>
@property NSNotificationCenter *local;
@property (copy) void (^request)(NSDictionary *);
@property NSInteger cancellations;
@end
@implementation TestCenter
- (instancetype)init { if ((self = [super init])) _local = [NSNotificationCenter new]; return self; }
- (void)addObserver:(id)o selector:(SEL)s name:(NSString *)n object:(id)obj { [_local addObserver:o selector:s name:n object:obj]; }
- (void)removeObserver:(id)o { [_local removeObserver:o]; }
- (void)postNotificationName:(NSString *)name object:(id)object userInfo:(NSDictionary *)info deliverImmediately:(BOOL)now {
    if ([name isEqual:ZXUIRequestName]) {
        if ([info[@"cancel"] boolValue]) ++_cancellations;
        else if (_request) _request(info);
    } else [_local postNotificationName:name object:object userInfo:info];
}
@end

int main(int argc, const char *argv[]) { @autoreleasepool {
    NSDictionary *runtimePaths = [ZXTouchProcessRunner runtimePaths];
    Check([runtimePaths[@"executable"] isAbsolutePath] && [[runtimePaths[@"executable"] lastPathComponent] isEqual:@"runtime-tests"], @"Runtime path followed spoofed argv[0]");
    NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    NSString *bin = [root stringByAppendingPathComponent:@"usr/bin"];
    NSFileManager *fm = NSFileManager.defaultManager;
    Check([fm createDirectoryAtPath:bin withIntermediateDirectories:YES attributes:nil error:nil], @"Create test runtime");
    Check([fm createSymbolicLinkAtPath:[bin stringByAppendingPathComponent:@"python3"] withDestinationPath:@"/usr/bin/python3" error:nil], @"Python runtime symlink");
    ZXTouchProcessRunner *runner = [[ZXTouchProcessRunner alloc] initWithRuntimeRoot:root modulePath:argc > 1 ? @(argv[1]) : @"" logPath:[root stringByAppendingPathComponent:@"output.log"]];
    NSError *error = nil;
    Check([runner runShell:@"printf '%s' \"literal ' spaces\"" cancelled:^BOOL { return NO; } error:&error], error.description);
    Check([[NSString stringWithContentsOfFile:[root stringByAppendingPathComponent:@"output.log"] encoding:NSUTF8StringEncoding error:nil] isEqual:@"literal ' spaces"], @"Shell quoting changed");
    Check(![runner runShell:@"exit 7" cancelled:^BOOL { return NO; } error:&error], @"Nonzero exit succeeded");
    NSString *orphanMarker = [root stringByAppendingPathComponent:@"orphan-survived"];
    // A shell that exits immediately must not strand a child after untracking.
    NSString *background = [NSString stringWithFormat:@"(sleep .3; touch '%@') &", orphanMarker];
    Check([runner runShell:background cancelled:^BOOL { return NO; } error:&error], error.description);
    usleep(500000);
    Check(![fm fileExistsAtPath:orphanMarker], @"Background descendant survived command completion");
    CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
    Check(![runner runShell:@"sleep 30 & wait" cancelled:^BOOL { return CFAbsoluteTimeGetCurrent() - start > .1; } error:&error], @"Cancellation succeeded");
    Check(CFAbsoluteTimeGetCurrent() - start < 2, @"Process cancellation was not prompt");
    NSString *script = [root stringByAppendingPathComponent:@"space ' script.py"];
    [@"import time\ntime.sleep(30)\n" writeToFile:script atomically:YES encoding:NSUTF8StringEncoding error:nil];
    Check([runner startScript:script error:&error], error.description);
    Check(runner.isScriptRunning, @"Script is not tracked");
    Check(![runner startScript:script error:&error], @"Concurrent script allowed");
    Check([runner stopScript:&error], error.description);
    for (int i=0; i<200 && runner.isScriptRunning; ++i) usleep(10000);
    Check(!runner.isScriptRunning, @"Script process was not reaped");
    NSString *bundle = [root stringByAppendingPathComponent:@"test.bdl"];
    [fm createDirectoryAtPath:bundle withIntermediateDirectories:YES attributes:nil error:nil];
    [@{@"Entry":@"../space ' script.py"} writeToFile:[bundle stringByAppendingPathComponent:@"info.plist"] atomically:YES];
    Check(![runner startScript:bundle error:&error], @"Bundle traversal allowed");
    runner.environment = @{@"ZXTOUCH_PORT":@"6123"};
    NSString *successScript = [root stringByAppendingPathComponent:@"success.py"];
    [@"import os,zxtouch.client\nassert os.path.realpath(os.getcwd()) == os.path.realpath(os.path.dirname(__file__))\nassert os.environ['ZXTOUCH_PORT'] == '6123'\nopen('script.done', 'w').write('done')\n" writeToFile:successScript atomically:YES encoding:NSUTF8StringEncoding error:nil];
    Check([runner startScript:successScript error:&error], error.description);
    for (int i=0; i<500 && runner.isScriptRunning; ++i) usleep(10000);
    if (![fm fileExistsAtPath:[root stringByAppendingPathComponent:@"script.done"]]) NSLog(@"%@", [NSString stringWithContentsOfFile:[root stringByAppendingPathComponent:@"output.log"] encoding:NSUTF8StringEncoding error:nil]);
    Check(!runner.isScriptRunning && [fm fileExistsAtPath:[root stringByAppendingPathComponent:@"script.done"]], @"Script cwd/client module/port environment failed");
    [runner stop];
    Check(![runner startScript:script error:&error], @"Stopped runner accepted a process");

    TestCenter *center = [TestCenter new];
    ZXTouchUIBridge *bridge = [[ZXTouchUIBridge alloc] initWithCenter:center];
    NSNotificationCenter *localCenter = center.local;
    center.request = ^(NSDictionary *request) {
        [localCenter postNotificationName:ZXUIResponseName object:nil userInfo:@{@"id":request[@"id"], @"target":@"wrong.app", @"ok":@YES, @"value":@"wrong"}];
        [localCenter postNotificationName:ZXUIResponseName object:nil userInfo:@{@"id":request[@"id"], @"target":request[@"target"], @"ok":@YES, @"value":@"entered text"}];
    };
    NSDictionary *reply = [bridge requestTask:29 fields:@[] target:@"test.app" timeout:.2 cancelled:^BOOL { return NO; }];
    Check([reply[@"value"] isEqual:@"entered text"], @"Bridge accepted wrong target or lost reply");
    center.request = nil;
    reply = [bridge requestTask:29 fields:@[] target:@"test.app" timeout:.1 cancelled:^BOOL { return NO; }];
    Check(![reply[@"ok"] boolValue] && center.cancellations == 1, @"Timeout did not dismiss request");
    reply = [bridge requestTask:29 fields:@[] target:@"test.app" timeout:30 cancelled:^BOOL { return YES; }];
    Check(![reply[@"ok"] boolValue] && center.cancellations == 2, @"Disconnect did not cancel request");
    [bridge stop];
    reply = [bridge requestTask:29 fields:@[] target:@"test.app" timeout:1 cancelled:^BOOL { return NO; }];
    Check(![reply[@"ok"] boolValue], @"Stopped bridge accepted request");
    // Break the fake-center block ownership cycle and remove temporary files.
    center.request = nil;
    [fm removeItemAtPath:root error:nil];
    puts("ZXTouch runtime tests passed");
} }
