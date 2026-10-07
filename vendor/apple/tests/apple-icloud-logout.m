#import "TVAppleServices.h"
#include <string.h>
// Real account mutation. JSON input requires explicit apple_id and local_data_policy.
int main(void) {
    @autoreleasepool {
        char input[2048] = {0};
        if (!fgets(input, sizeof(input), stdin)) return 2;
        id config = [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:input length:strlen(input)] options:0 error:NULL];
        memset(input, 0, sizeof(input));
        if (![config isKindOfClass:NSDictionary.class] || ![config[@"apple_id"] isKindOfClass:NSString.class]) return 2;
        TVAppleLocalDataPolicy policy;
        if ([config[@"local_data_policy"] isEqual:@"remove"]) policy = TVAppleLocalDataRemove;
        else if ([config[@"local_data_policy"] isEqual:@"keep"]) policy = TVAppleLocalDataKeep;
        else return 2;
        TVAppleServices *service = [TVAppleServices new];
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        __block int status = 1;
        [service signOutICloudAppleID:config[@"apple_id"] localDataPolicy:policy completion:^(NSDictionary *result, NSError *error) {
            NSMutableDictionary *summary = [NSMutableDictionary new];
            summary[@"outcome"] = result[@"outcome"] ?: @"failed";
            if (result[@"service_recoveries"]) summary[@"service_recoveries"]=result[@"service_recoveries"];
            if (result[@"warnings"]) summary[@"warnings"] = result[@"warnings"];
            if (result[@"completed_domains"]) summary[@"completed_domains"] = result[@"completed_domains"];
            if (result[@"already_signed_out"]) summary[@"already_signed_out"] = result[@"already_signed_out"];
            if (result[@"target_signed_out"]) summary[@"target_signed_out"] = result[@"target_signed_out"];
            if (error) { summary[@"error_code"] = @(error.code); summary[@"error"] = error.localizedDescription; }
            NSDictionary *state = result[@"state"];
            if (state) {
                NSMutableArray *selected = [NSMutableArray new];
                for (NSDictionary *record in state[@"accounts"]) {
                    if ([record[@"selected"] boolValue]) [selected addObject:@{@"domain":record[@"domain"], @"primary":record[@"primary"], @"authenticated":record[@"authenticated"], @"enabled_dataclasses":record[@"enabled_dataclasses"]}];
                }
                summary[@"selected_accounts"] = selected;
                summary[@"find_my_enabled"] = state[@"find_my_enabled"];
            }
            NSData *json = [NSJSONSerialization dataWithJSONObject:summary options:0 error:NULL];
            puts([[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding].UTF8String); fflush(stdout);
            status = !error && [result[@"outcome"] isEqual:@"succeeded"] ? 0 : 1;
            dispatch_semaphore_signal(done);
        }];
        NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + 90;
        while (dispatch_semaphore_wait(done, DISPATCH_TIME_NOW)) {
            if (NSProcessInfo.processInfo.systemUptime >= deadline) return 3;
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        }
        return status;
    }
}
