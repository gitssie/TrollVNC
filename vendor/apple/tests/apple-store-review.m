#import "TVAppleStoreReview.h"
#import <dlfcn.h>
#include <string.h>

// Device-only probe: private stdin for passwords/codes; no response bodies,
// cookies, SAP signatures, page tokens or retrieval URLs in output.
static NSDictionary *ReadInput(void) {
    char buffer[8192] = {0};
    if (!fgets(buffer, sizeof(buffer), stdin)) return nil;
    NSData *data = [NSData dataWithBytes:buffer length:strlen(buffer)];
    memset(buffer, 0, sizeof(buffer));
    id value = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    return [value isKindOfClass:NSDictionary.class] ? value : nil;
}
static void PrintError(NSString *stage, NSError *error) {
    printf("stage=%s error_code=%ld diagnostic=%s\n", stage.UTF8String,
        (long)error.code, (TVAppleDiagnosticMessage(error) ?: @"").UTF8String);
    fflush(stdout);
}
static NSDictionary *ResponseJSON(NSDictionary *reply) {
    NSData *body = reply[@"data"];
    if (![body isKindOfClass:NSData.class]) return nil;
    id value = [NSJSONSerialization JSONObjectWithData:body options:0 error:NULL];
    return [value isKindOfClass:NSDictionary.class] ? value : nil;
}
static void PrintReply(NSString *stage, NSDictionary *reply, NSError *error) {
    NSDictionary *json = ResponseJSON(reply);
    NSNumber *status = [json[@"status"]isKindOfClass:NSNumber.class] ? json[@"status"] : nil;
    printf("stage=%s http=%ld finance_status=%s bytes=%lu\n", stage.UTF8String,
        (long)[reply[@"status"]integerValue], status ? status.stringValue.UTF8String : "unavailable",
        (unsigned long)[reply[@"data"]length]);
    PrintError(stage, error);
}
static TVAppleManualCodeProvider *CodeProvider(void) {
    __block __weak TVAppleManualCodeProvider *weakProvider = nil;
    TVAppleManualCodeProvider *provider = [[TVAppleManualCodeProvider alloc]
        initWithChallengeHandler:^(NSDictionary *challenge) {
            NSMutableDictionary *event = [challenge mutableCopy];
            event[@"event"] = @"requires_verification_code";
            NSData *json = [NSJSONSerialization dataWithJSONObject:event options:0 error:NULL];
            puts([[NSString alloc]initWithData:json encoding:NSUTF8StringEncoding].UTF8String);
            fflush(stdout);
            NSDictionary *submission = ReadInput();
            if (![submission[@"code"]isKindOfClass:NSString.class] ||
                ![weakProvider submitCode:submission[@"code"] forChallengeID:submission[@"challenge_id"] error:NULL])
                [weakProvider cancelChallengeID:challenge[@"challenge_id"] error:NULL];
        }];
    weakProvider = provider;
    return provider;
}
static BOOL ConversionSucceeded(NSDictionary *reply, NSError *error) {
    NSDictionary *json = ResponseJSON(reply);
    id issues = json[@"validationResults"], result = json[@"result"];
    return !error && [reply[@"status"]integerValue] == 200 &&
        [json[@"status"]isKindOfClass:NSNumber.class] && [json[@"status"]compare:@0] == NSOrderedSame &&
        !json[@"errorMessageKey"] && !json[@"errors"] &&
        (!issues || ([issues isKindOfClass:NSArray.class] && ![issues count])) &&
        [result isKindOfClass:NSDictionary.class] && !result[@"requires"] &&
        [result[@"details"]isKindOfClass:NSString.class] && [result[@"details"]length] > 0;
}
int main(void) {
    @autoreleasepool {
        NSDictionary *config = ReadInput();
        NSString *appleID = config[@"apple_id"], *password = config[@"password"];
        if (![appleID isKindOfClass:NSString.class] || !appleID.length ||
            ![password isKindOfClass:NSString.class] || !password.length) return 2;
        NSDictionary *billing = [config[@"billing"]isKindOfClass:NSDictionary.class] ? config[@"billing"] : nil;
        BOOL completeReview = [config[@"complete_review"]boolValue];
        BOOL fieldsOnly = [config[@"conversion_fields"]boolValue];
        BOOL authFirst = !config[@"auth_first"] || [config[@"auth_first"]boolValue];
        config = nil;
        for (NSString *name in @[@"StoreServices", @"AuthKit", @"AppleMediaServices"]) {
            NSString *path = [NSString stringWithFormat:@"/System/Library/PrivateFrameworks/%@.framework/%@", name, name];
            dlopen(path.UTF8String, RTLD_NOW);
        }
        NSError *error = nil;
        NSDictionary *response = nil;
        id context = nil;
        NSString *credential = nil;
        TVAppleStoreAttempt attempt = authFirst ? TVAppleStoreAttemptNeedsTrust :
            TVAppleNativeStoreLoginForReview(appleID, password, &response, &context, &error);
        if (attempt == TVAppleStoreAttemptNeedsTrust) {
            error = nil;
            NSDictionary *auth = TVAppleNativeAuthenticateSMS(appleID, password, CodeProvider(), &error);
            PrintError(@"authkit", error);
            credential = [auth[@"AKPassword"]isKindOfClass:NSString.class] ? auth[@"AKPassword"] : nil;
            password = nil;
            if (!credential.length || error) return 1;
            attempt = TVAppleNativeStoreLoginForReviewWithPET(appleID, credential, &response, &context, &error);
        }
        password = nil;
        BOOL needsReview = TVAppleStoreReviewEntryURL(response) != nil;
        printf("store_attempt=%ld review_required=%d\n", (long)attempt, needsReview);
        PrintError(@"store", error);
        if (attempt == TVAppleStoreAttemptSucceeded && !needsReview) return 0;
        if (!needsReview || !credential.length) return 1;
        NSDictionary *bootstrapResponse = nil;
        id bootstrapContext = nil;
        error = nil;
        TVAppleStoreAttempt bootstrap = TVAppleNativeStoreReviewAuthentication(appleID, credential,
            &bootstrapResponse, &bootstrapContext, &error);
        PrintError(@"review_authentication", error);
        BOOL nativeReviewContinuation = bootstrap == TVAppleStoreAttemptFailed && bootstrapContext &&
            [error.domain isEqual:TVAppleErrorDomain] && error.code == TVAppleErrorAccountNeedsReview &&
            TVAppleStoreReviewEntryURL(bootstrapResponse) != nil;
        if (!bootstrapContext || (!nativeReviewContinuation && (bootstrap != TVAppleStoreAttemptSucceeded || error))) return 1;
        if (nativeReviewContinuation) response = bootstrapResponse;
        error = nil;
        context = bootstrapContext;
        TVAppleNativeStoreReviewSession *session = [[TVAppleNativeStoreReviewSession alloc]
            initWithAuthenticationResponse:response context:context error:&error];
        if (!session) { PrintError(@"review", error); return 1; }
        NSDictionary *reply = billing ? [session validateBilling:billing error:&error] :
            fieldsOnly ? [session loadConversionFields:&error] : [session loadEntry:&error];
        PrintReply(billing ? @"billing_validation" : @"review_fields", reply, error);
        if (!reply || error) return 1;
        if (!completeReview) return 0;
        if (!billing) return 2;
        NSDictionary *submitted = [session submitConversion:&error];
        PrintReply(@"review_submission", submitted, error);
        if (!ConversionSucceeded(submitted, error)) return 1;
        puts("review_complete=1 payment_method=None");
        fflush(stdout);
        // Separate subsequent Store login check; never re-submit conversion.
        NSDictionary *loginResponse = nil;
        id loginContext = nil;
        error = nil;
        TVAppleStoreAttempt finalLogin = TVAppleNativeStoreLoginForReviewWithPET(appleID, credential,
            &loginResponse, &loginContext, &error);
        printf("post_review_store_attempt=%ld review_required=%d\n", (long)finalLogin,
            TVAppleStoreReviewEntryURL(loginResponse) != nil);
        PrintError(@"post_review_store_login", error);
        return 0;
    }
}
