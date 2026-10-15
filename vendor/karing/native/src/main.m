#import "TVKaringNative.h"
#include <stdio.h>
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSDictionary *result;
        @try { result = argc == 2 ? TVKaringNativeRequest(@(argv[1])) : @{@"error":@"invalid_operation"}; }
        @catch (__unused NSException *exception) { result = @{@"error":@"native_failure", @"outcome":@"unknown"}; }
        NSData *data = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
        if (!data) return 1;
        fwrite(data.bytes, 1, data.length, stdout); putchar('\n');
        // JSON operation failures are returned to the facade, never hidden by exit status.
        return ferror(stdout) ? 1 : 0;
    }
}
