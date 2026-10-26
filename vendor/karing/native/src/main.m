#import "TVKaringNative.h"
#include <stdio.h>
#include <unistd.h>
#include <errno.h>
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSDictionary *result;
        @try {
            if (argc != 2) result = @{@"error":@"invalid_operation"};
            else if (strcmp(argv[1], "select") == 0) {
                NSMutableData *input = [NSMutableData data];
                unsigned char buffer[1024]; ssize_t count;
                do {
                    count = read(STDIN_FILENO, buffer, sizeof(buffer));
                    if (count > 0) [input appendBytes:buffer length:(NSUInteger)count];
                } while ((count > 0 || (count < 0 && errno == EINTR)) && input.length <= 4096);
                id parameters = count == 0 && input.length <= 4096 ? [NSJSONSerialization JSONObjectWithData:input options:0 error:nil] : nil;
                result = [parameters isKindOfClass:NSDictionary.class] ? TVKaringNativeRequestWithParameters(@(argv[1]), parameters) : @{@"error":@"invalid_parameters", @"outcome":@"not_sent"};
            } else result = TVKaringNativeRequest(@(argv[1]));
        }
        @catch (__unused NSException *exception) { result = @{@"error":@"native_failure", @"outcome":@"unknown"}; }
        NSData *data = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
        if (!data) return 1;
        fwrite(data.bytes, 1, data.length, stdout); putchar('\n');
        // JSON operation failures are returned to the facade, never hidden by exit status.
        return ferror(stdout) ? 1 : 0;
    }
}
