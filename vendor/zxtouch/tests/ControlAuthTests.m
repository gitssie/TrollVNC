#import "ZXTouchControlAuth.h"
#import "ZXTouchVNCPassword.h"
#import <Foundation/Foundation.h>
static NSUInteger assertions;
static void Check(BOOL value) { assertions++; if (!value) { fprintf(stderr, "FAIL assertion %lu\n", (unsigned long)assertions); exit(1); } }
int main(void) { @autoreleasepool {
    Check(ZXTouchVNCPasswordAccepted("saved-password", NULL, 0));
    Check(ZXTouchVNCPasswordAccepted("", NULL, 0));
    const char *passwords[] = {"fullpass", "readonly", NULL};
    Check(ZXTouchVNCPasswordAccepted("fullpass", passwords, 1));
    Check(ZXTouchVNCPasswordAccepted("fullpass-extra", passwords, 1));
    Check(!ZXTouchVNCPasswordAccepted("readonly", passwords, 1));
    Check(!ZXTouchVNCPasswordAccepted("wrong", passwords, 1));
    Check(!ZXTouchVNCPasswordAccepted("", passwords, 1));
    Check(!ZXTouchVNCPasswordAccepted("fullpass", passwords, 0));
    __block NSTimeInterval now = 1000;
    ZXTouchControlAuth *auth = [[ZXTouchControlAuth alloc] initWithPasswordCheck:^BOOL(NSString *password) {
        return [password isEqual:@"test-only-password"];
    } clock:^NSTimeInterval { return now; }];
    Check([auth connectWithPassword:@"wrong"] == nil);
    Check([auth connectWithPassword:@""] == nil);
    Check(![auth authorize:@"abc"]);
    NSString *first = [auth connectWithPassword:@"test-only-password"];
    NSString *second = [auth connectWithPassword:@"test-only-password"];
    Check(first && second && ![first isEqual:second]);
    Check([first componentsSeparatedByString:@"."].count == 3);
    Check([auth authorize:first] && [auth authorize:second]);
    NSArray *parts = [first componentsSeparatedByString:@"."];
    NSString *signature = [parts[2] stringByReplacingCharactersInRange:NSMakeRange(0, 1) withString:[parts[2] hasPrefix:@"a"] ? @"b" : @"a"];
    Check(![auth authorize:[NSString stringWithFormat:@"%@.%@.%@", parts[0], parts[1], signature]]);
    Check(![auth authorize:[first stringByAppendingString:@"."]]);
    // Replacing the signed header or payload must never bypass verification.
    Check(![auth authorize:[NSString stringWithFormat:@"eyJhbGciOiJub25lIn0.%@.%@", parts[1], parts[2]]]);
    Check(![auth authorize:[NSString stringWithFormat:@"%@.e30.%@", parts[0], parts[2]]]);
    [auth disconnect:first];
    Check(![auth authorize:first] && [auth authorize:second]);
    ZXTouchControlAuth *other = [[ZXTouchControlAuth alloc] initWithPasswordCheck:^BOOL(NSString *p) { (void)p; return YES; }];
    Check(![other authorize:second]);
    now = 4599; Check([auth authorize:second]);
    now = 4600; Check(![auth authorize:second]);
    NSString *third = [auth connectWithPassword:@"test-only-password"];
    Check([auth authorize:third]); [auth invalidate]; Check(![auth authorize:third]);
    for (NSUInteger i=0; i<256; i++) Check([auth connectWithPassword:@"test-only-password"] != nil);
    Check([auth connectWithPassword:@"test-only-password"] == nil);
    now += 3600; Check([auth connectWithPassword:@"test-only-password"] != nil);
    fprintf(stdout, "PASS %lu JWT assertions\n", (unsigned long)assertions);
} return 0; }
