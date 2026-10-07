#import "TVAppleServices.h"
#include <string.h>
// Standalone test runner: one JSON line over stdin, never argv/environment.
// No credentials, endpoint URL or verification codes are printed.
int main(int argc, char **argv) {
    @autoreleasepool {
        char input[8192] = {0};
        if (argc > 2) return 2;
        FILE *source = argc == 2 ? fopen(argv[1], "r") : stdin;
        if (!source || !fgets(input, sizeof(input), source)) return 2;
        if (argc == 2) { fclose(source); remove(argv[1]); }
        NSData *data = [NSData dataWithBytes:input length:strlen(input)];
        memset(input, 0, sizeof(input));
        NSDictionary *config = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
        if (![config isKindOfClass:NSDictionary.class] || ![config[@"apple_id"] isKindOfClass:NSString.class] ||
            ![config[@"password"] isKindOfClass:NSString.class]) return 2;
        TVAppleServices *service = [TVAppleServices new];
        __block __weak TVAppleManualCodeProvider *weakProvider = nil;
        TVAppleManualCodeProvider *provider = [[TVAppleManualCodeProvider alloc] initWithChallengeHandler:^(NSDictionary *challenge) {
            NSMutableDictionary *event = [challenge mutableCopy]; event[@"event"] = @"requires_verification_code";
            NSData *json = [NSJSONSerialization dataWithJSONObject:event options:0 error:NULL];
            puts([[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding].UTF8String); fflush(stdout);
            char codeInput[1024] = {0};
            if (!fgets(codeInput, sizeof(codeInput), stdin)) { [weakProvider cancelChallengeID:challenge[@"challenge_id"] error:NULL]; return; }
            NSData *codeData = [NSData dataWithBytes:codeInput length:strlen(codeInput)]; memset(codeInput, 0, sizeof(codeInput));
            id submission = [NSJSONSerialization JSONObjectWithData:codeData options:0 error:NULL];
            if (![submission isKindOfClass:NSDictionary.class] || ![submission[@"code"] isKindOfClass:NSString.class] ||
                ![weakProvider submitCode:submission[@"code"] forChallengeID:submission[@"challenge_id"] error:NULL]) {
                [weakProvider cancelChallengeID:challenge[@"challenge_id"] error:NULL];
            }
        }];
        weakProvider = provider;
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        __block int status = 0;
        puts("Starting native App Store login"); fflush(stdout);
        [service signInAppStoreAppleID:config[@"apple_id"] password:config[@"password"] verificationCodeProvider:provider
            completion:^(NSDictionary *result, NSError *error) {
                NSMutableDictionary *summary = [NSMutableDictionary new];
                summary[@"outcome"] = result[@"outcome"] ?: @"failed";
                if (result[@"signed_in_domains"]) summary[@"signed_in_domains"] = result[@"signed_in_domains"];
                if (result[@"two_factor_bootstrap"]) summary[@"two_factor_bootstrap"] = result[@"two_factor_bootstrap"];
                if (result[@"stage"]) summary[@"stage"] = result[@"stage"];
                if (error) { summary[@"error_code"] = @(error.code); summary[@"error"] = error.localizedDescription; status = 1; }
                NSData *json = [NSJSONSerialization dataWithJSONObject:summary options:NSJSONWritingPrettyPrinted error:NULL];
                puts([[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding].UTF8String);
                fflush(stdout); dispatch_semaphore_signal(done);
            }];
        NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + 480;
        while (dispatch_semaphore_wait(done, DISPATCH_TIME_NOW)) {
            if (NSProcessInfo.processInfo.systemUptime >= deadline) return 3;
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        }
        return status;
    }
}
