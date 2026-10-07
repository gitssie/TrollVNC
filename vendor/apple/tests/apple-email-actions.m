#import "TVAppleServices.h"
#include <string.h>
// One process owns the native email challenge. Each stdin line is a separate
// command: begin(email), verify(challenge_id,code), forward(email), or query.
// No credentials/code/URL in argv or environment, and no automatic code fetch.
static void Emit(NSDictionary *value){
    NSData *json=[NSJSONSerialization dataWithJSONObject:value options:0 error:NULL];
    if(json)puts([[NSString alloc]initWithData:json encoding:NSUTF8StringEncoding].UTF8String);
    fflush(stdout);
}
int main(void){@autoreleasepool{
    TVAppleServices *service=[TVAppleServices new];char input[4096]={0};
    while(fgets(input,sizeof(input),stdin)){
        @autoreleasepool{
            id config=[NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:input length:strlen(input)]options:0 error:NULL];memset(input,0,sizeof(input));
            if(![config isKindOfClass:NSDictionary.class]||![config[@"apple_id"]isKindOfClass:NSString.class]||![config[@"action"]isKindOfClass:NSString.class]){Emit(@{@"error_code":@(TVAppleErrorInvalidRequest)});continue;}
            __block BOOL finished=NO;TVAppleCompletion reply=^(NSDictionary *result,NSError *error){
                Emit(error?@{@"error_code":@(error.code),@"error":error.localizedDescription}:result);
                @synchronized(service){finished=YES;}
            };
            NSString *action=config[@"action"];
            if([action isEqual:@"begin"]&&[config[@"email"]isKindOfClass:NSString.class])
                [service beginAddingContactEmail:config[@"email"]appleID:config[@"apple_id"]completion:reply];
            else if([action isEqual:@"verify"]&&[config[@"challenge_id"]isKindOfClass:NSString.class]&&[config[@"code"]isKindOfClass:NSString.class])
                [service verifyContactEmailChallenge:config[@"challenge_id"]code:config[@"code"]appleID:config[@"apple_id"]completion:reply];
            else if([action isEqual:@"forward"]&&[config[@"email"]isKindOfClass:NSString.class])
                [service setSignInWithAppleForwardingEmail:config[@"email"]appleID:config[@"apple_id"]completion:reply];
            else if([action isEqual:@"query"])[service queryAppleIDEmailSettings:config[@"apple_id"]completion:reply];
            else{Emit(@{@"error_code":@(TVAppleErrorInvalidRequest)});continue;}
            config=nil;NSTimeInterval deadline=NSProcessInfo.processInfo.systemUptime+200;
            for(;;){@synchronized(service){if(finished)break;}if(NSProcessInfo.processInfo.systemUptime>=deadline)return 3;
                [[NSRunLoop currentRunLoop]runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.02]];}
        }
    }return 0;
}}
