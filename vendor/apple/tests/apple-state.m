#import "TVAppleServices.h"
// Read-only standalone smoke test. No sign-out command is exposed by this executable.
int main(int argc, char **argv) {
    @autoreleasepool {
        BOOL selfTest = argc == 2 && [@(argv[1]) isEqual:@"--self-test"];
        if (argc != 1 && !selfTest) { fprintf(stderr, "Usage: apple-state [--self-test]\n"); return 2; }
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        __block int status = 0;
        TVAppleServices *service = [TVAppleServices new];
        [service queryState:^(NSDictionary *state, NSError *error) {
            if (error) {
                fprintf(stderr, "%s (%ld): %s\n", error.domain.UTF8String, (long)error.code, error.localizedDescription.UTF8String);
                status = 1;
            } else {
                if (selfTest) {
                    // Random nonexistent identity: exercises real backend preflight and final
                    // verification without selecting any phone account for deletion.
                    NSString *absentID = [NSString stringWithFormat:@"apple-module-%@@invalid", NSUUID.UUID.UUIDString];
                    [service signOutAppleID:absentID localDataPolicy:TVAppleLocalDataRemove completion:^(NSDictionary *result, NSError *e) {
                        NSArray *before = [state[@"accounts"] valueForKey:@"identifier"];
                        NSArray *after = [result[@"state"][@"accounts"] valueForKey:@"identifier"];
                        BOOL same = [[NSSet setWithArray:before] isEqual:[NSSet setWithArray:after ?: @[]]];
                        BOOL ok = !e && [result[@"already_signed_out"] boolValue] && [result[@"outcome"] isEqual:@"succeeded"] && same;
                        puts(ok ? "PASS native query + idempotent no-op signout; account identities unchanged" : "FAIL native self-test");
                        status = ok ? 0 : 1; dispatch_semaphore_signal(done);
                    }];
                    return;
                }
                NSData *json = [NSJSONSerialization dataWithJSONObject:state options:NSJSONWritingPrettyPrinted error:NULL];
                puts([[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding].UTF8String);
            }
            dispatch_semaphore_signal(done);
        }];
        NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + 600;
        while (dispatch_semaphore_wait(done, DISPATCH_TIME_NOW)) {
            if (NSProcessInfo.processInfo.systemUptime >= deadline) return 2;
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        }
        return status;
    }
}
