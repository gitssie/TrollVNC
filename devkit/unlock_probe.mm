// Device diagnostics: use the production state reader; never send or print a passcode.
#import "../src/ScreenUnlock.mm"
#import <objc/runtime.h>
#include <notify.h>

int gOrientationFixQuad = 0;
BOOL tvncLoggingEnabled = NO;
BOOL tvncVerboseLoggingEnabled = NO;

int main(int argc, const char **argv) {
    @autoreleasepool {
        tvUnlockInit();
        printf("supported=%d automation_symbol=%d\n", tvScreenUnlockSupported(),
               dlsym(RTLD_DEFAULT, "_AXSSetAutomationEnabled") != NULL);
        NSString *error = nil;
        int token = 0; uint64_t blanked = 0;
        notify_register_check("com.apple.springboard.hasBlankedScreen", &token);
        notify_get_state(token, &blanked);
        printf("blanked=%llu\n", blanked);
        BOOL production = argc > 1 && strcmp(argv[1], "--production-unlock") == 0;
        if (production || (argc > 1 && strcmp(argv[1], "--simple-unlock") == 0)) {
            char code[64] = {0};
            if (!fgets(code, sizeof(code), stdin) || strlen(code) != 7 || code[6] != '\n') return 2;
            for (int i = 0; i < 6; i++) if (code[i] < '0' || code[i] > '9') return 2;
            NSDictionary *initial = tvScreenUnlockState(&error);
            if (!initial || ![initial[@"locked"] boolValue]) { memset(code, 0, sizeof(code)); printf("SKIP device is not locked\n"); return 6; }
            STHIDEventGenerator *gen = [STHIDEventGenerator sharedGenerator];
            if (production) tvScreenUnlockPrepare(&error);
            else if (blanked) [gen powerPress];
            for (int i = 0; i < 10; i++) {
                [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];
                notify_get_state(token, &blanked);
                if (!blanked) break;
            }
            printf("wake blanked=%llu\n", blanked); fflush(stdout);
            if (blanked) { memset(code, 0, sizeof(code)); return 3; }
            [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];
            if (!production) [gen swipeUpToPasscode];
            BOOL ready = NO;
            for (int i = 0; i < 12; i++) {
                [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.25]];
                NSDictionary *current = tvScreenUnlockState(&error);
                ready = [current[@"input_ready"] boolValue] && [current[@"input_empty"] boolValue];
                if (ready) break;
            }
            printf("passcode_ready=%d\n", ready); fflush(stdout);
            if (!ready) { memset(code, 0, sizeof(code)); return 4; }
            rfbClientPtr client = (rfbClientPtr)1;
            if (production && ![tvScreenUnlockArm(client, 6, &error)[@"armed"] boolValue]) {
                memset(code, 0, sizeof(code)); printf("FAILED input not armed\n"); return 7;
            }
            for (int i = 0; i < 6; i++) {
                if (production && tvScreenUnlockKey(client, YES, code[i]) != 1) { memset(code, 0, sizeof(code)); return 8; }
                NSString *digit = [[NSString alloc] initWithBytes:&code[i] length:1 encoding:NSASCIIStringEncoding];
                [gen keyDown:digit];
                if (production) tvScreenUnlockKey(client, NO, code[i]);
                [gen keyUp:digit];
                [NSThread sleepForTimeInterval:0.1];
            }
            memset(code, 0, sizeof(code));
            for (int i = 0; i < 12; i++) {
                [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.25]];
                NSDictionary *current = tvScreenUnlockState(&error);
                if (current && ![current[@"locked"] boolValue]) { tvScreenUnlockClose(client); printf("SUCCESS unlocked\n"); return 0; }
            }
            printf("FAILED unlock not confirmed\n"); return 5;
        }
        if (argc > 1 && strcmp(argv[1], "--prepare") == 0) {
            printf("hid_size=%s\n", [[[STHIDEventGenerator sharedGenerator] valueForKey:@"physicalScreenSize"] description].UTF8String);
            tvScreenUnlockPrepare(&error);
            for (int i = 0; i < 12; i++) {
                [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];
                NSDictionary *current = tvScreenUnlockState(&error);
                printf("probe locked=%d ready=%d empty=%d\n", [current[@"locked"] boolValue],
                    [current[@"input_ready"] boolValue], [current[@"input_empty"] boolValue]);
                fflush(stdout);
                if ([current[@"input_ready"] boolValue]) break;
            }
        }
        NSDictionary *state = tvScreenUnlockState(&error);
        NSData *json = [NSJSONSerialization dataWithJSONObject:state ?: @{@"error":error ?: @"unknown"} options:0 error:nil];
        printf("state=%s\n", [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding].UTF8String);
        if (![state[@"locked"] boolValue]) return 0;
        @try {
            id app = [tvAX primaryApp];
            printf("app_class=%s bundle=%s explorer_selector=%d\n", object_getClassName(app),
                   [app respondsToSelector:@selector(bundleId)] ? [[app bundleId] UTF8String] : "unavailable",
                   [app respondsToSelector:@selector(explorerElements)]);
            if (![app respondsToSelector:@selector(bundleId)] || ![[app bundleId] isEqualToString:@"com.apple.springboard"]) return 0;
            NSArray *elements = [app respondsToSelector:@selector(explorerElements)] ? [app explorerElements] : nil;
            printf("elements=%lu\n", (unsigned long)elements.count);
            for (id element in elements) {
                if (![element respondsToSelector:@selector(traits)]) continue;
                unsigned long long traits = [element traits];
                NSString *label = [element respondsToSelector:@selector(label)] ? [element label] : nil;
                BOOL digit = label.length && [label characterAtIndex:0] >= '0' && [label characterAtIndex:0] <= '9';
                BOOL passcode = label.length && ([label rangeOfString:@"密码"].location != NSNotFound ||
                    [label rangeOfString:@"passcode" options:NSCaseInsensitiveSearch].location != NSNotFound);
                if (!(traits & 0x1000000ULL) && !digit && !passcode) continue;
                CGRect frame = [element respondsToSelector:@selector(frame)] ? [element frame] : CGRectZero;
                id value = [element respondsToSelector:@selector(value)] ? [element value] : nil;
                printf("element traits=0x%llx frame=(%.1f,%.1f,%.1f,%.1f) kind=%s digit=%d secure=%d empty=%d value_chars=%lu\n", traits,
                    frame.origin.x, frame.origin.y, frame.size.width, frame.size.height, object_getClassName(element), digit,
                    !!(traits & 0x1000000ULL), tvEmptySecureField(element),
                    [value isKindOfClass:NSString.class] ? (unsigned long)[value length] : 0);
            }
        } @catch (NSException *exception) { printf("exception=%s\n", exception.name.UTF8String); }
    }
}
