#import "TVAppleStoreSignIn.h"
@interface NSObject (TVStoreCredentialCleanup)
- (void)setPassword:(id)value;
- (void)setInitialPassword:(id)value;
@end
NSDictionary *TVAppleUSStoreBillingAddress(id response, NSError **error) {
    NSDictionary *root = [response isKindOfClass:NSDictionary.class] ? response : nil;
    NSDictionary *source = [root[@"address"] isKindOfClass:NSDictionary.class] ? root[@"address"] : nil;
    NSDictionary *mapping = @{@"Address":@"addressOfficialLineFirst", @"City":@"addressOfficialCity",
        @"State":@"addressOfficialStateProvince", @"Zip_Code":@"addressOfficialPostalCode"};
    NSMutableDictionary *billing = [NSMutableDictionary new];
    if (![root[@"status"] isEqual:@"ok"] || !source) goto invalid;
    for (NSString *key in mapping) {
        id raw = source[key];
        if (![raw isKindOfClass:NSString.class]) goto invalid;
        NSString *value = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!value.length) goto invalid;
        billing[mapping[key]] = value;
    }
    if (![source[@"Telephone"] isKindOfClass:NSString.class]) goto invalid;
    {
        NSMutableString *digits = [NSMutableString new];
        NSString *phone = source[@"Telephone"];
        for (NSUInteger i = 0; i < phone.length; i++) {
            unichar c = [phone characterAtIndex:i];
            if (c >= '0' && c <= '9') [digits appendFormat:@"%C", c];
        }
        if (digits.length == 11 && [digits hasPrefix:@"1"]) [digits deleteCharactersInRange:NSMakeRange(0, 1)];
        if (digits.length != 10) goto invalid;
        billing[@"phoneOfficeAreaCode"] = [digits substringToIndex:3];
        billing[@"phoneOfficeNumber"] = [digits substringFromIndex:3];
    }
    return billing;
invalid:
    if (error) *error = TVAppleError(TVAppleErrorInvalidRequest, @"US billing address source returned incomplete fields.");
    return nil;
}
BOOL TVAppleStoreConversionSucceeded(NSDictionary *reply) {
    NSData *data = reply[@"data"];
    id json = [data isKindOfClass:NSData.class] ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
    if (![json isKindOfClass:NSDictionary.class]) return NO;
    id status = json[@"status"], issues = json[@"validationResults"], result = json[@"result"];
    return [reply[@"status"] integerValue] == 200 && [status isKindOfClass:NSNumber.class] &&
        [status compare:@0] == NSOrderedSame && !json[@"errorMessageKey"] && !json[@"errors"] &&
        (!issues || ([issues isKindOfClass:NSArray.class] && ![issues count])) &&
        [result isKindOfClass:NSDictionary.class] && !result[@"requires"] &&
        [result[@"details"] isKindOfClass:NSString.class] && [result[@"details"] length] > 0;
}
@implementation TVAppleNativeStoreSignIn
- (NSDictionary *)authenticate:(NSString *)appleID password:(NSString *)password
    provider:(id<TVAppleVerificationCodeProvider>)provider error:(NSError **)error {
    return TVAppleNativeAuthenticateSMS(appleID, password, provider, error);
}
- (TVAppleStoreAttempt)store:(NSString *)appleID credential:(NSString *)credential
    response:(NSDictionary **)response context:(id *)context error:(NSError **)error {
    return TVAppleNativeStoreLoginForReviewWithPET(appleID, credential, response, context, error);
}
- (TVAppleStoreAttempt)prepare:(NSString *)appleID credential:(NSString *)credential
    response:(NSDictionary **)response context:(id *)context error:(NSError **)error {
    return TVAppleNativeStoreReviewAuthentication(appleID, credential, response, context, error);
}
- (TVAppleNativeStoreReviewSession *)reviewSession:(NSDictionary *)response context:(id)context error:(NSError **)error {
    return [[TVAppleNativeStoreReviewSession alloc] initWithAuthenticationResponse:response context:context error:error];
}
- (NSDictionary *)billing:(NSError **)error {
    NSURLSessionConfiguration *config = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 35;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://www.meiguodizhi.com/api/v1/dz"]];
    request.HTTPMethod = @"POST";
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{@"city":@"", @"path":@"/", @"method":@"refresh"} options:0 error:NULL];
    NSCondition *condition = [NSCondition new];
    __block BOOL done = NO, closed = NO;
    __block NSData *body = nil;
    __block NSInteger status = 0;
    NSURLSessionDataTask *task = [session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *failure) {
        [condition lock];
        if (!closed) { body = failure ? nil : data; status = [response isKindOfClass:NSHTTPURLResponse.class] ? [(NSHTTPURLResponse *)response statusCode] : 0; done = YES; [condition broadcast]; }
        [condition unlock];
    }];
    [task resume];
    [condition lock];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:40];
    while (!done && [condition waitUntilDate:deadline]) {}
    closed = YES;
    NSData *received = body;
    NSInteger httpStatus = status;
    [condition unlock];
    [session invalidateAndCancel];
    if (httpStatus != 200 || !received) {
        *error = TVAppleError(TVAppleErrorAuthenticationFailed, @"US billing address source request failed."); return nil;
    }
    return TVAppleUSStoreBillingAddress([NSJSONSerialization JSONObjectWithData:received options:0 error:NULL], error);
}
- (NSDictionary *)signIn:(NSString *)appleID password:(NSString *)password
    provider:(id<TVAppleVerificationCodeProvider>)provider error:(NSError **)error {
    NSDictionary *auth = [self authenticate:appleID password:password provider:provider error:error];
    NSString *credential = [auth[@"AKPassword"] isKindOfClass:NSString.class] ? auth[@"AKPassword"] : nil;
    if (*error) return nil;
    if (!credential.length) { *error = TVAppleError(TVAppleErrorAuthenticationFailed, @"Native authentication returned no Store credential."); return nil; }
    NSDictionary *response = nil;
    id context = nil;
    TVAppleStoreAttempt attempt = [self store:appleID credential:credential response:&response context:&context error:error];
    BOOL review = TVAppleStoreReviewEntryURL(response) != nil;
    if (!review) {
        if ([context respondsToSelector:@selector(setPassword:)]) [context setPassword:nil];
        if ([context respondsToSelector:@selector(setInitialPassword:)]) [context setInitialPassword:nil];
        if (attempt != TVAppleStoreAttemptSucceeded || *error) return nil;
        return @{@"outcome":@"succeeded", @"authenticated":@YES, @"review_completed":@NO, @"signed_in_domains":@[@"media"]};
    }
    id entryContext = context;
    @try {
    *error = nil;
    context = nil;
    NSDictionary *preparedResponse = nil;
    TVAppleStoreAttempt prepared = [self prepare:appleID credential:credential response:&preparedResponse context:&context error:error];
    BOOL nativeReviewContinuation = prepared == TVAppleStoreAttemptFailed && context &&
        [(*error).domain isEqual:TVAppleErrorDomain] && (*error).code == TVAppleErrorAccountNeedsReview &&
        TVAppleStoreReviewEntryURL(preparedResponse) != nil;
    if (!context || (!nativeReviewContinuation && (prepared != TVAppleStoreAttemptSucceeded || *error))) {
        NSInteger code = *error ? (*error).code : TVAppleErrorAuthenticationFailed;
        *error = TVAppleError(code,[NSString stringWithFormat:@"Review pre-conversion authentication failed (context=%d): %@",context != nil, TVAppleDiagnosticMessage(*error) ?: @"No native continuation."]);
        return nil;
    }
    // Type3 is a valid continuation, never a completed login or conversion.
    if (nativeReviewContinuation) response = preparedResponse;
    *error = nil;
    TVAppleNativeStoreReviewSession *reviewSession = [self reviewSession:response context:context error:error];
    if (!reviewSession || *error) return nil;
    NSDictionary *billing = [self billing:error];
    if (!billing || *error || ![reviewSession validateBilling:billing error:error] || *error) return nil;
    NSDictionary *submitted = [reviewSession submitConversion:error];
    if (*error) return nil;
    if (!TVAppleStoreConversionSucceeded(submitted)) {
        *error = TVAppleError(TVAppleErrorOutcomeUnknown, @"Store Review submission did not return a complete conversion result; do not replay automatically."); return nil;
    }
    // Conversion is committed. A separate login failure must not replay Review
    // or erase its successful result.
    response = nil; context = nil;
    attempt = [self store:appleID credential:credential response:&response context:&context error:error];
    BOOL signedIn = attempt == TVAppleStoreAttemptSucceeded && !*error && !TVAppleStoreReviewEntryURL(response);
    NSMutableDictionary *result = [@{@"outcome":signedIn ? @"succeeded" : @"failed", @"authenticated":@(signedIn),
        @"review_completed":@YES, @"payment_method":@"None", @"billing_address":billing,
        @"signed_in_domains":signedIn ? @[@"media"] : @[]} mutableCopy];
    if (!signedIn) {
        result[@"stage"] = @"post_review_store_login";
        if (!*error) *error = TVAppleError(TVAppleErrorAuthenticationFailed, @"Review completed but subsequent Store login failed.");
        if (attempt == TVAppleStoreAttemptUnknown || (*error).code == TVAppleErrorOutcomeUnknown) {
            result[@"outcome"] = @"unknown";
            [result removeObjectForKey:@"authenticated"];
            [result removeObjectForKey:@"signed_in_domains"];
        }
    }
    return result;
    } @finally {
        for (id owned in @[entryContext ?: NSNull.null, context ?: NSNull.null]) {
            if ([owned respondsToSelector:@selector(setPassword:)]) [owned setPassword:nil];
            if ([owned respondsToSelector:@selector(setInitialPassword:)]) [owned setInitialPassword:nil];
        }
    }
}
@end
