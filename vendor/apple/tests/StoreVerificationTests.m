#import "TVAppleStoreSignIn.h"
#include <assert.h>
static NSUInteger calls;
static NSDictionary *Automatic(NSString *a, NSString *p, id<TVAppleVerificationCodeProvider> v, NSError **e) {
    (void)a; (void)p; (void)v; (void)e; calls++; return @{@"automatic":@YES};
}
#define TVAppleNativeAuthenticateAutomatic Automatic
#import "../src/appstore/TVAppleStoreSignIn.m"
#undef TVAppleNativeAuthenticateAutomatic
int main(void) { @autoreleasepool {
    TVAppleNativeStoreSignIn *login=[TVAppleNativeStoreSignIn new];
    NSError *error=nil;
    TVAppleManualCodeProvider *provider=[[TVAppleManualCodeProvider alloc] initWithChallengeHandler:^(NSDictionary *c){(void)c; assert(NO);}];
    for (id value in @[provider, NSNull.null]) {
        NSDictionary *result=[login authenticate:@"test@example.com" password:@"fixture" provider:value==NSNull.null ? nil : value error:&error];
        assert([result[@"automatic"] boolValue] && !error);
    }
    assert(calls==2);
    puts("PASS production Store login always uses automatic verification selection");
} return 0; }
