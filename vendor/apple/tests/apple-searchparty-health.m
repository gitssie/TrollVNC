#import "TVAppleSearchParty.h"
int main(void){@autoreleasepool{
    NSError *error=nil;BOOL recovered=NO;BOOL ready=TVApplePrepareSearchParty(&recovered,&error);
    NSDictionary *result=@{@"ready":@(ready),@"recovered":@(recovered),@"error_code":@(error.code)};
    NSData *json=[NSJSONSerialization dataWithJSONObject:result options:0 error:NULL];
    puts([[NSString alloc]initWithData:json encoding:NSUTF8StringEncoding].UTF8String);return ready?0:1;
}}
