#import <Foundation/Foundation.h>
#import "TVNCAppleService.h"
#import "TVAppleServices.h"
#import "TVAppleBackend.h"
#import "ZXTouchTCPServer.h"
#define CHECK(x) do { if (!(x)) { fprintf(stderr,"FAIL %d\n",__LINE__); exit(1); } } while(0)
@interface FakeApple : TVAppleServices
@property TVAppleCompletion pending;
@property TVAppleManualCodeProvider *provider;
@property NSString *name;
@end
@implementation FakeApple
- (void)queryState:(TVAppleCompletion)c { self.pending=c; }
- (void)queryAccountState:(TVAppleCompletion)c { c(@{@"accounts":@[]},nil); }
- (void)signInAppStoreAppleID:(NSString *)a password:(NSString *)p verificationCodeProvider:(id<TVAppleVerificationCodeProvider>)v completion:(TVAppleCompletion)c {
    (void)a;(void)p;self.pending=c;self.provider=(id)v;
}
- (void)enableICloudAppleID:(NSString *)a password:(NSString *)p devicePasscode:(NSString *)d verificationCodeProvider:(id<TVAppleVerificationCodeProvider>)v completion:(TVAppleCompletion)c {
    (void)a;(void)p;(void)d;self.pending=c;self.provider=(id)v;
}
- (void)beginAddingContactEmail:(NSString *)e appleID:(NSString *)a completion:(TVAppleCompletion)c { (void)e;(void)a;self.pending=c; }
- (void)verifyContactEmailChallenge:(NSString *)ch code:(NSString *)code appleID:(NSString *)a completion:(TVAppleCompletion)c { (void)ch;(void)code;(void)a;self.pending=c; }
- (void)setAppleIDFirstName:(NSString *)f lastName:(NSString *)l appleID:(NSString *)a completion:(TVAppleCompletion)c {
    (void)l;(void)a;self.name=f;self.pending=c;
}
@end
static NSDictionary *Call(TVNCAppleService *s,NSDictionary *d) {
    NSData *j=[NSJSONSerialization dataWithJSONObject:d options:0 error:nil];
    NSData *reply=[s handlePayload:[j base64EncodedStringWithOptions:0]];
    NSString *line=[[NSString alloc]initWithData:reply encoding:NSUTF8StringEncoding];
    CHECK([line hasPrefix:@"0;;"]&&[line hasSuffix:@"\r\n"]);
    NSData *data=[[NSData alloc]initWithBase64EncodedString:[line substringWithRange:NSMakeRange(3,line.length-5)] options:0];
    return [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
}
static NSDictionary *Invoke(TVNCAppleService *s,NSString *m,NSDictionary *p) {return Call(s,@{@"action":@"invoke",@"method":m,@"params":p});}
static void Pump(void) {[[NSRunLoop currentRunLoop]runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.1]];}
@interface SocketApple : TVAppleServices
@end
@implementation SocketApple
- (void)queryState:(TVAppleCompletion)c {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{c(@{@"accounts":@[],@"message":@"雪;;line\r\nnext"},nil);});
}
- (void)signInAppStoreAppleID:(NSString *)a password:(NSString *)p verificationCodeProvider:(id<TVAppleVerificationCodeProvider>)v completion:(TVAppleCompletion)c {
    (void)a;(void)p;
    [v requestCodeForChallenge:@{@"type":@"trusted_device"} completion:^(NSString *code,NSError *e){
        c(code ? @{@"outcome":@"succeeded"} : nil,e);
    }];
}
@end
int main(int argc,const char **argv){@autoreleasepool{
    if(argc==2){
        TVNCAppleService *adapter=[[TVNCAppleService alloc]initWithServices:[SocketApple new]];
        ZXTouchTCPServer *server=[[ZXTouchTCPServer alloc]initWithHandler:^NSData *(const zxtouch::Command &cmd,NSUInteger client){
            (void)client;
            if(cmd.task==31)return [adapter handlePayload:[[NSString alloc]initWithBytes:cmd.payload.data() length:cmd.payload.size() encoding:NSUTF8StringEncoding]];
            return [@"-1;;unsupported\r\n" dataUsingEncoding:NSUTF8StringEncoding];
        } disconnected:^(NSUInteger client){(void)client;}];
        CHECK([server startOnHost:@"127.0.0.1" port:atoi(argv[1]) error:nil]);puts("READY");fflush(stdout);
        [[NSRunLoop currentRunLoop]run];return 0;
    }

    FakeApple *fake=[FakeApple new];TVNCAppleService *service=[[TVNCAppleService alloc]initWithServices:fake];
    CHECK(Invoke(service,@"bad",@{})[@"error"]);
    CHECK(Invoke(service,@"signOutAppleID",@{@"apple_id":@"example@example.com",@"local_data_policy":@"merge"})[@"error"]);
    CHECK(Invoke(service,@"setName",@{@"apple_id":@"example@example.com",@"first_name":@1,@"last_name":@"Last"})[@"error"]);
    NSString *op=Invoke(service,@"queryState",@{})[@"operation_id"];CHECK(op);
    CHECK([Invoke(service,@"queryState",@{})[@"error"][@"code"]isEqual:@"busy"]);
    fake.pending(@{@"accounts":@[]},nil);
    NSDictionary *done=Call(service,@{@"action":@"result",@"operation_id":op});CHECK([done[@"status"]isEqual:@"completed"]&&done[@"result"]);
    // Delayed duplicate callbacks cannot alter the completed result.
    fake.pending(nil,[NSError errorWithDomain:@"fake" code:2 userInfo:nil]);
    CHECK(!Call(service,@{@"action":@"result",@"operation_id":op})[@"error"]);
    CHECK(Call(service,@{@"action":@"result",@"operation_id":@"wrong"})[@"error"]);
    NSDictionary *cloudParams=@{@"apple_id":@"example@example.com",@"password":@"secret",@"device_passcode":@"123456"};
    NSString *cloudOp=Invoke(service,@"enableICloud",cloudParams)[@"operation_id"];CHECK(cloudOp);
    TVAppleManualCodeProvider *oldProvider=fake.provider;
    TVAppleCompletion oldCompletion=fake.pending;
    __block NSUInteger cancelled=0;
    [oldProvider requestCodeForChallenge:@{@"type":@"trusted_device"} completion:^(NSString *v,NSError *e){CHECK(!v&&e);cancelled++;}];Pump();
    CHECK([Call(service,@{@"action":@"result",@"operation_id":cloudOp})[@"status"]isEqual:@"requires_verification_code"]);
    NSMutableDictionary *cloudInfo=[TVAppleError(TVAppleErrorNativeFailure,@"Native iCloud/CDP sign-in failed.").userInfo mutableCopy];
    [cloudInfo addEntriesFromDictionary:@{@"TVAppleFailureStage":@"icloud_cdp",@"TVAppleNativeCompletionReceived":@YES,@"TVAppleNativeDomain":@"com.apple.appleaccount",@"TVAppleNativeCode":@403,@"private_token":@"SECRET"}];
    oldCompletion(nil,[NSError errorWithDomain:TVAppleErrorDomain code:TVAppleErrorNativeFailure userInfo:cloudInfo]);
    NSDictionary *cloudDone=Call(service,@{@"action":@"result",@"operation_id":cloudOp});
    CHECK([cloudDone[@"status"]isEqual:@"completed"]&&[cloudDone[@"result"][@"outcome"]isEqual:@"failed"]);
    CHECK(!cloudDone[@"challenge"]&&cancelled==1&&[cloudDone[@"error"][@"native_code"]integerValue]==403);
    CHECK(!cloudDone[@"error"][@"private_token"]);
    NSString *nextCloud=Invoke(service,@"enableICloud",cloudParams)[@"operation_id"];CHECK(nextCloud);
    TVAppleCompletion nextCompletion=fake.pending;
    oldCompletion(@{@"outcome":@"succeeded"},nil);
    __block NSUInteger lateReplies=0;
    [oldProvider requestCodeForChallenge:@{@"type":@"trusted_device"} completion:^(NSString *v,NSError *e){CHECK(!v&&e);lateReplies++;}];
    CHECK(lateReplies==1);
    [oldProvider prepareForAuthentication:^(NSError *e){CHECK(e);lateReplies++;}];CHECK(lateReplies==2);Pump();
    CHECK([Call(service,@{@"action":@"result",@"operation_id":cloudOp})isEqual:cloudDone]);
    CHECK([Call(service,@{@"action":@"result",@"operation_id":nextCloud})[@"status"]isEqual:@"running"]);
    nextCompletion(@{@"outcome":@"succeeded"},nil);
    op=Invoke(service,@"setName",@{@"apple_id":@"example@example.com",@"first_name":@"a;;b\r\n雪",@"last_name":@"Last"})[@"operation_id"];CHECK([fake.name isEqual:@"a;;b\r\n雪"]);
    fake.pending(nil,[NSError errorWithDomain:TVAppleErrorDomain code:TVAppleErrorOutcomeUnknown userInfo:@{@"password":@"SECRET"}]);
    done=Call(service,@{@"action":@"result",@"operation_id":op});CHECK([done[@"error"]count]==2&&[done[@"error"][@"code"]integerValue]==TVAppleErrorOutcomeUnknown);
    op=Invoke(service,@"queryState",@{})[@"operation_id"];
    fake.pending(nil,TVAppleError(TVAppleErrorOutcomeUnknown,@"Native email response did not complete."));
    done=Call(service,@{@"action":@"result",@"operation_id":op});
    CHECK([done[@"error"][@"message"]isEqual:@"Native email response did not complete."]);
    op=Invoke(service,@"signInAppStore",@{@"apple_id":@"example@example.com",@"password":@"secret"})[@"operation_id"];
    __block NSString *code=nil;
    [fake.provider requestCodeForChallenge:@{@"type":@"trusted_device"} completion:^(NSString *v,NSError *e){(void)e;code=v;}];Pump();
    NSDictionary *state=Call(service,@{@"action":@"result",@"operation_id":op});CHECK([state[@"status"]isEqual:@"requires_verification_code"]);
    NSString *challenge=state[@"challenge"][@"challenge_id"];
    TVAppleCompletion loginCompletion=fake.pending;
    NSString *read=Invoke(service,@"queryAccountState",@{})[@"operation_id"];CHECK(read);
    CHECK([Call(service,@{@"action":@"result",@"operation_id":read})[@"status"]isEqual:@"completed"]);
    NSString *independent=Invoke(service,@"setName",@{@"apple_id":@"example@example.com",@"first_name":@"First",@"last_name":@"Last"})[@"operation_id"];CHECK(independent);
    fake.pending(@{@"outcome":@"succeeded"},nil);
    CHECK([Call(service,@{@"action":@"result",@"operation_id":op})[@"status"]isEqual:@"requires_verification_code"]);
    fake.pending=loginCompletion;
    CHECK(Call(service,@{@"action":@"submit_code",@"operation_id":op,@"challenge_id":@"wrong",@"code":@"012345"})[@"error"]);
    CHECK(Call(service,@{@"action":@"submit_code",@"operation_id":op,@"challenge_id":challenge,@"code":@"123"})[@"error"]);
    CHECK([Call(service,@{@"action":@"submit_code",@"operation_id":op,@"challenge_id":challenge,@"code":@"012345"})[@"accepted"]boolValue]);CHECK([code isEqual:@"012345"]);
    CHECK(Call(service,@{@"action":@"submit_code",@"operation_id":op,@"challenge_id":challenge,@"code":@"012345"})[@"error"]);
    fake.pending(@{@"outcome":@"succeeded",@"authenticated":@YES,@"review_completed":@YES,@"payment_method":@"None",
        @"billing_address":@{@"addressOfficialCity":@"Boston"}},nil);
    // Operation IDs work across callers; no per-connection native cancellation.
    CHECK([Call(service,@{@"action":@"result",@"operation_id":op})[@"status"]isEqual:@"completed"]);
    NSDictionary *reviewResult=Call(service,@{@"action":@"result",@"operation_id":op})[@"result"];
    CHECK([reviewResult[@"review_completed"]boolValue] && [reviewResult[@"payment_method"]isEqual:@"None"] &&
        [reviewResult[@"billing_address"][@"addressOfficialCity"]isEqual:@"Boston"]);
    op=Invoke(service,@"beginAddingContactEmail",@{@"apple_id":@"example@example.com",@"email":@"target@example.com"})[@"operation_id"];
    fake.pending(@{@"outcome":@"requires_email_verification",@"challenge_id":@"email-challenge",@"expires_in":@300},nil);
    CHECK(Invoke(service,@"signInAppStore",@{@"apple_id":@"example@example.com",@"password":@"secret"})[@"operation_id"]);
    fake.pending(@{@"outcome":@"succeeded"},nil);
    CHECK(Invoke(service,@"verifyContactEmail",@{@"apple_id":@"other@example.com",@"challenge_id":@"email-challenge",@"code":@"012345"})[@"error"]);
    op=Invoke(service,@"beginAddingContactEmail",@{@"apple_id":@"example@example.com",@"email":@"target@example.com"})[@"operation_id"];CHECK(op);
    fake.pending(@{@"outcome":@"requires_email_verification",@"challenge_id":@"email-challenge-new",@"expires_in":@300},nil);
    CHECK(Invoke(service,@"verifyContactEmail",@{@"apple_id":@"example@example.com",@"challenge_id":@"email-challenge",@"code":@"012345"})[@"error"]);
    op=Invoke(service,@"verifyContactEmail",@{@"apple_id":@"example@example.com",@"challenge_id":@"email-challenge-new",@"code":@"012345"})[@"operation_id"];CHECK(op);
    fake.pending(@{@"outcome":@"succeeded"},nil);
    op=Invoke(service,@"queryState",@{})[@"operation_id"];CHECK(op);[service stop];
    CHECK(Invoke(service,@"queryState",@{})[@"error"]);fake.pending(@{@"accounts":@[]},nil);
    CHECK([Call(service,@{@"action":@"result",@"operation_id":op})[@"status"]isEqual:@"completed"]);
    NSData *bad=[service handlePayload:@"!!"];CHECK(bad.length);
    FakeApple *fullFake=[FakeApple new];TVNCAppleService *full=[[TVNCAppleService alloc]initWithServices:fullFake];
    for(int i=0;i<62;i++){CHECK(Invoke(full,@"queryState",@{})[@"operation_id"]);fullFake.pending(@{@"accounts":@[]},nil);}
    CHECK(Invoke(full,@"beginAddingContactEmail",@{@"apple_id":@" example@example.com ",@"email":@"target@example.com"})[@"operation_id"]);
    fullFake.pending(@{@"outcome":@"requires_email_verification",@"challenge_id":@"reserved",@"expires_in":@300},nil);
    CHECK([Invoke(full,@"queryState",@{})[@"error"][@"code"]isEqual:@"result_capacity"]);
    CHECK(Invoke(full,@"verifyContactEmail",@{@"apple_id":@"example@example.com",@"challenge_id":@"reserved",@"code":@"123"})[@"error"]);
    CHECK(Invoke(full,@"verifyContactEmail",@{@"apple_id":@"EXAMPLE@example.com",@"challenge_id":@"reserved",@"code":@"012345"})[@"operation_id"]);
    fullFake.pending(@{@"outcome":@"succeeded"},nil);
    CHECK([Invoke(full,@"queryState",@{})[@"error"][@"code"]isEqual:@"result_capacity"]);
    // Expired results are pruned lazily, without evicting unexpired records.
    NSMutableDictionary *finished=[full valueForKey:@"finished"];
    for(NSString *key in finished.allKeys)finished[key]=@(NSProcessInfo.processInfo.systemUptime-601);
    CHECK(Invoke(full,@"queryState",@{})[@"operation_id"]);fullFake.pending(@{@"accounts":@[]},nil);
    FakeApple *nearFake=[FakeApple new];TVNCAppleService *near=[[TVNCAppleService alloc]initWithServices:nearFake];
    for(int i=0;i<63;i++){CHECK(Invoke(near,@"queryState",@{})[@"operation_id"]);nearFake.pending(@{@"accounts":@[]},nil);}
    CHECK([Invoke(near,@"beginAddingContactEmail",@{@"apple_id":@"example@example.com",@"email":@"target@example.com"})[@"error"][@"code"]isEqual:@"result_capacity"]);

    puts("Apple socket adapter tests PASS");
}return 0;}
