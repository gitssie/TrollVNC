#import "TVKaringNative.h"
#include <stdio.h>
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2 || argc > 3) return 2;
        TVKaringHelperClient *client = [[TVKaringHelperClient alloc] initWithExecutable:@(argv[1])];
        BOOL reload = argc == 3 && strcmp(argv[2], "--allow-reload") == 0;
        NSMutableArray *operations = [@[@"status", @"config", @"profiles"] mutableCopy];
        if (reload) [operations addObject:@"reload"];
        BOOL passed = YES;
        for (NSString *operation in operations) {
            NSDictionary *result = [client request:operation];
            NSDictionary *data = result[@"data"];
            BOOL valid = !result[@"error"];
            NSMutableDictionary *summary = [@{@"operation":operation} mutableCopy];
            if ([operation isEqual:@"status"]) valid &= [data[@"connections"] isKindOfClass:NSArray.class] && data[@"startTime"] != nil;
            if ([operation isEqual:@"config"]) {
                valid &= [data[@"outbounds"] isKindOfClass:NSArray.class] && [data[@"route"] isKindOfClass:NSDictionary.class];
                summary[@"outboundCount"] = @([data[@"outbounds"] count]);
            }
            if ([operation isEqual:@"profiles"]) valid &= data[@"karing_subscribe.json"] != nil && data[@"karing_setting.json"] != nil;
            if ([operation isEqual:@"reload"]) valid &= [result[@"reloadVerified"] boolValue] && [result[@"outcome"] isEqual:@"succeeded"];
            summary[@"passed"] = @(valid); passed &= valid;
            if (result[@"error"]) summary[@"error"] = result[@"error"];
            // Never print full config, subscription URLs, nodes or connections.
            NSData *output = [NSJSONSerialization dataWithJSONObject:summary options:0 error:nil];
            fwrite(output.bytes, 1, output.length, stdout); putchar('\n'); fflush(stdout);
            if (!valid) break;
        }
        return passed ? 0 : 1;
    }
}
