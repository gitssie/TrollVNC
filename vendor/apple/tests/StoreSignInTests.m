#import "TVAppleStoreSignIn.h"
#include <assert.h>
@interface TVAppleNativeStoreSignIn (TestSeams)
- (NSDictionary *)authenticate:(NSString *)a password:(NSString *)p provider:(id<TVAppleVerificationCodeProvider>)v error:(NSError **)e;
- (TVAppleStoreAttempt)store:(NSString *)a credential:(NSString *)p response:(NSDictionary **)r context:(id *)c error:(NSError **)e;
- (TVAppleStoreAttempt)prepare:(NSString *)a credential:(NSString *)p response:(NSDictionary **)r context:(id *)c error:(NSError **)e;
- (TVAppleNativeStoreReviewSession *)reviewSession:(NSDictionary *)r context:(id)c error:(NSError **)e;
- (NSDictionary *)billing:(NSError **)e;
@end
static NSDictionary *Reply(id status, id details) {
    return @{@"status":@200, @"data":[NSJSONSerialization dataWithJSONObject:@{@"status":status,@"result":@{@"details":details}} options:0 error:NULL]};
}
@interface MockReview : TVAppleNativeStoreReviewSession
@property NSUInteger validations;
@property NSUInteger submissions;
@property BOOL reject;
@property BOOL timeout;
@end
@implementation MockReview
- (NSDictionary *)validateBilling:(NSDictionary *)billing error:(NSError **)error {
    assert(billing[@"phoneOfficeAreaCode"]); self.validations++;
    if (self.reject) { *error=TVAppleError(TVAppleErrorInvalidRequest,@"Fixture validation rejected."); return nil; }
    return @{};
}
- (NSDictionary *)submitConversion:(NSError **)error {
    self.submissions++;
    if (self.timeout) { *error=TVAppleError(TVAppleErrorOutcomeUnknown,@"Fixture timeout."); return nil; }
    return Reply(@0,@"native-protocol-details");
}
@end
@interface LoginFixture : TVAppleNativeStoreSignIn
@property BOOL review;
@property BOOL badSource;
@property BOOL badFinalLogin;
@property BOOL unknownFinalLogin;
@property BOOL prepareReview;
@property NSUInteger stores;
@property NSUInteger sources;
@property MockReview *session;
@end
@implementation LoginFixture
- (NSDictionary *)authenticate:(NSString *)a password:(NSString *)p provider:(id<TVAppleVerificationCodeProvider>)v error:(NSError **)e {
    (void)a;(void)p;(void)v;(void)e; return @{@"AKPassword":@"private-native-credential"};
}
- (TVAppleStoreAttempt)store:(NSString *)a credential:(NSString *)p response:(NSDictionary **)r context:(id *)c error:(NSError **)e {
    (void)a; assert([p isEqual:@"private-native-credential"]); self.stores++;
    if (self.review && self.stores==1) {
        *r=@{@"url":@"https://buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/com.apple.jingle.app.finance.DirectAction/convertWizard?opaque=retained"};
        *c=[NSObject new]; *e=TVAppleError(TVAppleErrorAccountNeedsReview,@"Fixture Review."); return TVAppleStoreAttemptFailed;
    }
    if (self.badFinalLogin) { *e=TVAppleError(TVAppleErrorAuthenticationFailed,@"Fixture login rejected."); return TVAppleStoreAttemptFailed; }
    if (self.unknownFinalLogin) { *e=TVAppleError(TVAppleErrorOutcomeUnknown,@"Fixture login timeout."); return TVAppleStoreAttemptUnknown; }
    return TVAppleStoreAttemptSucceeded;
}
- (TVAppleStoreAttempt)prepare:(NSString *)a credential:(NSString *)p response:(NSDictionary **)r context:(id *)c error:(NSError **)e {
    (void)a;(void)p; *c=[NSObject new];
    if (self.prepareReview) {
        *r=@{@"url":@"https://buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/com.apple.jingle.app.finance.DirectAction/convertWizard?fresh=continuation"};
        *e=TVAppleError(TVAppleErrorAccountNeedsReview,@"Fixture native type3 continuation."); return TVAppleStoreAttemptFailed;
    }
    return TVAppleStoreAttemptSucceeded;
}
- (TVAppleNativeStoreReviewSession *)reviewSession:(NSDictionary *)r context:(id)c error:(NSError **)e {
    (void)r;(void)c;(void)e; return self.session;
}
- (NSDictionary *)billing:(NSError **)e {
    self.sources++;
    if (self.badSource) { *e=TVAppleError(TVAppleErrorInvalidRequest,@"Fixture bad source."); return nil; }
    return @{@"phoneOfficeAreaCode":@"617"};
}
@end
static LoginFixture *Fixture(void) {
    LoginFixture *f=[LoginFixture new]; f.review=YES; f.session=[MockReview new]; return f;
}
int main(void) { @autoreleasepool {
    NSDictionary *source=@{@"status":@"ok",@"address":@{@"Address":@" 1 Test Avenue ",@"City":@"Boston",@"State":@"MA",@"Zip_Code":@"02108",@"Telephone":@"+1 (617) 555-0100",@"Credit_Card_Number":@"discarded"}};
    NSError *error=nil;
    NSDictionary *billing=TVAppleUSStoreBillingAddress(source,&error);
    assert(!error && billing.count==6 && [billing[@"phoneOfficeAreaCode"]isEqual:@"617"] && [billing[@"phoneOfficeNumber"]isEqual:@"5550100"]);
    assert([billing[@"addressOfficialLineFirst"]isEqual:@"1 Test Avenue"] && !billing[@"Credit_Card_Number"]);
    assert(!TVAppleUSStoreBillingAddress(@[],&error));
    assert(!TVAppleUSStoreBillingAddress(@{@"status":@"ok",@"address":@{}},&error));
    assert(TVAppleStoreConversionSucceeded(Reply(@0,@"details")));
    assert(!TVAppleStoreConversionSucceeded(Reply(@0.5,@"details")));
    assert(!TVAppleStoreConversionSucceeded(Reply(@0,NSNull.null)));
    LoginFixture *f=Fixture(); error=nil;
    NSDictionary *result=[f signIn:@"test@example.invalid" password:@"fixture" provider:nil error:&error];
    assert(!error && [result[@"authenticated"]boolValue] && [result[@"review_completed"]boolValue]);
    assert([result[@"payment_method"]isEqual:@"None"] && f.stores==2 && f.sources==1 && f.session.submissions==1);
    f=Fixture(); f.prepareReview=YES; error=nil;
    result=[f signIn:@"test@example.invalid" password:@"fixture" provider:nil error:&error];
    assert(!error && [result[@"authenticated"]boolValue] && [result[@"review_completed"]boolValue] && f.session.submissions==1);
    f=Fixture(); f.review=NO; error=nil;
    result=[f signIn:@"test@example.invalid" password:@"fixture" provider:nil error:&error];
    assert(!error && [result[@"authenticated"]boolValue] && ![result[@"review_completed"]boolValue] && f.sources==0 && f.session.submissions==0);
    f=Fixture(); f.badSource=YES; error=nil;
    assert(![f signIn:@"test@example.invalid" password:@"fixture" provider:nil error:&error] && error && f.session.submissions==0);
    f=Fixture(); f.session.reject=YES; error=nil;
    assert(![f signIn:@"test@example.invalid" password:@"fixture" provider:nil error:&error] && error && f.session.submissions==0);
    f=Fixture(); f.session.timeout=YES; error=nil;
    assert(![f signIn:@"test@example.invalid" password:@"fixture" provider:nil error:&error] && error.code==TVAppleErrorOutcomeUnknown && f.session.submissions==1 && f.stores==1);
    f=Fixture(); f.badFinalLogin=YES; error=nil;
    result=[f signIn:@"test@example.invalid" password:@"fixture" provider:nil error:&error];
    assert(error && [result[@"review_completed"]boolValue] && ![result[@"authenticated"]boolValue] && f.session.submissions==1);
    f=Fixture(); f.unknownFinalLogin=YES; error=nil;
    result=[f signIn:@"test@example.invalid" password:@"fixture" provider:nil error:&error];
    assert(error.code==TVAppleErrorOutcomeUnknown && [result[@"review_completed"]boolValue] && [result[@"outcome"]isEqual:@"unknown"] && !result[@"authenticated"] && f.session.submissions==1);
    puts("PASS Store login Review branch: iOS address mapping, ordinary login, validation failure, single commit, post-conversion login failure");
} return 0; }
