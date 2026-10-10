#import "TVAppleStoreSignIn.h"
@interface TVAppleNativeStoreSignIn (BillingProbe)
- (NSDictionary *)billing:(NSError **)error;
@end
// Read-only on-device address-source check. Never fetches or prints credentials.
int main(void) { @autoreleasepool {
    NSError *error=nil;
    NSDictionary *billing=[[TVAppleNativeStoreSignIn new] billing:&error];
    if (!billing || error) { printf("billing_available=0 error_code=%ld\n",(long)error.code); return 1; }
    NSData *json=[NSJSONSerialization dataWithJSONObject:billing options:0 error:NULL];
    puts([[NSString alloc]initWithData:json encoding:NSUTF8StringEncoding].UTF8String);
} return 0; }
