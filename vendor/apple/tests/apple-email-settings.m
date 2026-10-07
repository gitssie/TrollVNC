#import "TVAppleServices.h"
#include <string.h>
int main(void){@autoreleasepool{
    char input[2048]={0};if(!fgets(input,sizeof(input),stdin))return 2;
    id config=[NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:input length:strlen(input)]options:0 error:NULL];memset(input,0,sizeof(input));
    if(![config isKindOfClass:NSDictionary.class]||![config[@"apple_id"]isKindOfClass:NSString.class])return 2;
    TVAppleServices *service=[TVAppleServices new];__block BOOL finished=NO;__block int status=1;
    [service queryAppleIDEmailSettings:config[@"apple_id"] completion:^(NSDictionary *result,NSError *error){
        NSDictionary *summary=error?@{@"error_code":@(error.code),@"error":error.localizedDescription}:result;
        NSData *json=[NSJSONSerialization dataWithJSONObject:summary options:0 error:NULL];puts([[NSString alloc]initWithData:json encoding:NSUTF8StringEncoding].UTF8String);
        status=error?1:0;@synchronized(service){finished=YES;}
    }];
    NSTimeInterval deadline=NSProcessInfo.processInfo.systemUptime+60;
    for(;;){@synchronized(service){if(finished)break;}if(NSProcessInfo.processInfo.systemUptime>=deadline)return 3;[[NSRunLoop currentRunLoop]runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];}
    return status;
}}
