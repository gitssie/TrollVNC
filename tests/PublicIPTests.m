#import "TVNCPublicIP.h"
#include <assert.h>
static NSDictionary *query(NSString *body, NSInteger status, NSError *error) {
    NSURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:[NSURL URLWithString:@"https://ipv4.is"]
        statusCode:status HTTPVersion:@"HTTP/1.1" headerFields:@{}];
    return TVNCPublicIPResult([body dataUsingEncoding:NSUTF8StringEncoding],response,error);
}
int main(void) { @autoreleasepool {
    NSDictionary *result = query(@"203.0.113.42\n",200,nil);
    assert([result[@"ok"] boolValue] && [result[@"ip"] isEqual:@"203.0.113.42"]);
    for (NSString *body in @[@"", @"<html>blocked</html>", @"2001:db8::1", @"256.1.1.1",
        [@"203.0.113.42" stringByAppendingString:[NSString stringWithFormat:@"%Cevil",(unichar)0]]]) {
        result=query(body,200,nil);
        assert(![result[@"ok"] boolValue] && result[@"ip"]==NSNull.null);
        assert([result[@"error"][@"error_code"] isEqual:@"invalid_response"]);
    }
    for (NSNumber *status in @[@403,@429,@503]) {
        result=query(@"203.0.113.42",status.integerValue,nil);
        assert(result[@"ip"]==NSNull.null);
        assert([result[@"error"][@"retryable"] boolValue] == (status.integerValue!=403));
    }
    NSArray *codes=@[@(NSURLErrorNetworkConnectionLost),@(NSURLErrorNotConnectedToInternet),
        @(NSURLErrorTimedOut),@(NSURLErrorServerCertificateUntrusted)];
    NSArray *names=@[@"network_unavailable",@"network_unavailable",@"timeout",@"tls_error"];
    for (NSUInteger i=0;i<codes.count;i++) {
        result=query(@"203.0.113.42",200,[NSError errorWithDomain:NSURLErrorDomain code:[codes[i] integerValue] userInfo:nil]);
        assert(![result[@"ok"] boolValue] && result[@"ip"]==NSNull.null);
        assert([result[@"error"][@"error_code"] isEqual:names[i]]);
        assert([result[@"error"][@"retryable"] boolValue] == (i!=3));
    }
    puts("Public IP result tests passed");
} return 0; }
