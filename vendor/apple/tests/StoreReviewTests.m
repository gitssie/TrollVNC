#import "TVAppleStoreReview.h"
#include <assert.h>
@interface NSObject (ReviewTestContext)
- (NSString *)accountName;
@end
@interface ReviewContext : NSObject
@end
@implementation ReviewContext
- (NSString *)accountName { return @"test@example.invalid"; }
@end
@interface TVAppleNativeStoreReviewSession (TestSeams)
- (NSString *)signatureForAccount:(BOOL)final error:(NSError **)error;
- (NSDictionary *)requestBagKey:(NSString *)key parameters:(NSDictionary *)parameters post:(BOOL)post error:(NSError **)error;
@end
@interface ReviewFixture : TVAppleNativeStoreReviewSession
@property NSDictionary *fields;
@property NSDictionary *validation;
@property NSUInteger submissions;
@property BOOL submitTimeout;
@end
@implementation ReviewFixture
- (NSDictionary *)loadConversionFields:(NSError **)error {
    (void)error;
    return @{@"status":@200, @"data":[NSJSONSerialization dataWithJSONObject:self.fields options:0 error:NULL]};
}
- (NSString *)signatureForAccount:(BOOL)final error:(NSError **)error {
    (void)final; (void)error;
    [self setValue:@"native-device-serial" forKey:@"serial"];
    return @"native+signature==";
}
- (NSDictionary *)requestBagKey:(NSString *)key parameters:(NSDictionary *)parameters post:(BOOL)post error:(NSError **)error {
    assert(post);
    assert([parameters[@"paymentMethodType"]isEqual:@"None"]);
    assert([parameters[@"context"]isEqual:@"convert"]);
    assert([parameters[@"addressOfficialCountryCode"]isEqual:@"USA"]);
    assert([parameters[@"agreedToTerms"]isEqual:@1]);
    assert([parameters[@"billingFirstName"]isEqual:@"Existing"]);
    assert([parameters[@"billingLastName"]isEqual:@"Name"]);
    if ([key isEqual:@"createAccountSrv"]) {
        self.submissions++;
        if (self.submitTimeout) { *error=TVAppleError(TVAppleErrorOutcomeUnknown,@"Test timeout."); return nil; }
        return @{@"status":@200, @"data":[NSJSONSerialization dataWithJSONObject:@{@"status":@0,@"result":@{}} options:0 error:NULL]};
    }
    assert([key isEqual:@"validateAccountFieldsSrv"]);
    assert(!parameters[@"acAccountPassword"] && !parameters[@"isUnusable"]);
    return @{@"status":@200,@"data":[NSJSONSerialization dataWithJSONObject:self.validation options:0 error:NULL]};
}
@end

static ReviewFixture *Fixture(NSString *link) {
    ReviewFixture *session=[[ReviewFixture alloc]initWithAuthenticationResponse:@{@"url":link} context:[ReviewContext new] error:NULL];
    session.fields=@{@"data":@{@"attributes":@{@"pageUUID":@"server-page",@"accountData":@{
        @"accountInfo":@{@"acAccountName":@"test@example.invalid",@"firstName":@"Existing",@"lastName":@"Name",@"isUnusable":@YES},
        @"addressInfo":@{}}}}};
    session.validation=@{@"status":@0,@"pageUUID":@"validated-page",@"validationResults":@[]};
    return session;
}
int main(void) {
    @autoreleasepool {
        NSString *path = @"/WebObjects/MZFinance.woa/wa/com.apple.jingle.app.finance.DirectAction/convertWizard";
        NSString *link = [@"itms-appss://buy.itunes.apple.com" stringByAppendingString:path];
        link = [link stringByAppendingString:@"?test=a%2Bb&test=second&empty="];
        NSURL *url = TVAppleStoreReviewEntryURL(@{@"dialog":@{@"buttons":@[@{@"action":link}]}});
        assert(url && [url.scheme isEqual:@"https"]);
        assert([url.query isEqual:@"test=a%2Bb&test=second&empty="]);
        assert(!TVAppleStoreReviewEntryURL(@{@"url":@"https://example.com/convertWizard"}));
        assert(!TVAppleStoreReviewEntryURL(@{@"url":@"https://buy.itunes.apple.com/not-the-review"}));
        assert(!TVAppleStoreReviewEntryURL(@{@"url":@"http://buy.itunes.apple.com/convertWizard"}));
        NSError *error = nil;
        assert(![[TVAppleNativeStoreReviewSession alloc] initWithAuthenticationResponse:@{} context:[NSObject new] error:&error]);
        assert(error.code == TVAppleErrorAccountNeedsReview);
        NSDictionary *billing=@{@"addressOfficialLineFirst":@"1 Test + Avenue",@"addressOfficialCity":@"Boston",
            @"addressOfficialStateProvince":@"MA",@"addressOfficialPostalCode":@"02108",
            @"phoneOfficeAreaCode":@"617",@"phoneOfficeNumber":@"5550100"};
        ReviewFixture *session=Fixture(link);
        error=nil;
        assert(![session submitConversion:&error] && error.code==TVAppleErrorConflict);
        assert([session validateBilling:billing error:&error] && !error);
        assert([session submitConversion:&error] && !error && session.submissions==1);
        assert(![session submitConversion:&error] && error.code==TVAppleErrorConflict && session.submissions==1);
        assert(![session validateBilling:billing error:&error] && error.code==TVAppleErrorConflict);
        for (NSDictionary *rejected in @[@{@"status":@(-1)}, @{@"status":@0.5}, @{@"status":@0,@"validationResults":@[@{@"field":@"postal"}]},
                @{@"status":@0,@"validationResults":@{}},@{@"status":@0,@"errorMessageKey":@"authentication.required"}]) {
            session=Fixture(link); session.validation=rejected;
            assert([session validateBilling:billing error:&error]);
            assert(![session submitConversion:&error] && session.submissions==0);
        }
        session=Fixture(link); session.submitTimeout=YES;
        assert([session validateBilling:billing error:&error]);
        assert(![session submitConversion:&error] && error.code==TVAppleErrorOutcomeUnknown && session.submissions==1);
        assert(![session submitConversion:&error] && error.code==TVAppleErrorConflict && session.submissions==1);
        session=Fixture(link);
        session.fields=@{@"data":@{@"attributes":@{@"accountData":@{@"accountInfo":@{
            @"acAccountName":@"test@example.invalid",@"billingFirstName":@123}}}}};
        assert(![session validateBilling:billing error:&error] && error.code==TVAppleErrorBackendRead);
        session=Fixture(link); session.fields=@{@"data":@[]};
        assert(![session validateBilling:billing error:&error] && error.code==TVAppleErrorBackendRead);
        puts("PASS Store Review: native deep link query retained, missing continuation reported");
        puts("PASS Store Review: None, existing names, validation rejection, malformed model, single submission and timeout");
    }
    return 0;
}
