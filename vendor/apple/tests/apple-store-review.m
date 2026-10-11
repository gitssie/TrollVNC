#import "TVAppleStoreReview.h"
#import "TVAppleStoreSignIn.h"
#import <dlfcn.h>
#include <string.h>

@interface TVAppleNativeStoreSignIn (ReviewProbeBilling)
- (NSDictionary *)billing:(NSError **)error;
@end

static BOOL TracePrivateData = NO;
static void PrintPrivateTrace(NSDictionary *event) {
    if(!TracePrivateData || ![NSJSONSerialization isValidJSONObject:event])return;
    NSData *data=[NSJSONSerialization dataWithJSONObject:event options:NSJSONWritingSortedKeys error:NULL];
    puts([[NSString alloc]initWithData:data encoding:NSUTF8StringEncoding].UTF8String);fflush(stdout);
}
@interface NSObject (ReviewTraceCookieSelectors)
+ (id)defaultStore;
+ (id)sharedStorage;
- (id)activeAccount;
- (NSDictionary *)cookieHeadersForURL:(NSURL *)url account:(id)account;
@end
// Probe-only subclass: trace the module's actual native responses, not daemon hooks.
@interface TVAppleNativeStoreReviewSession (ReviewProbeTracing)
- (NSDictionary *)requestBagKey:(NSString *)key parameters:(NSDictionary *)parameters post:(BOOL)post error:(NSError **)error;
- (NSString *)signatureForAccount:(BOOL)final error:(NSError **)error;
@end
static void PrintRoute(NSString *stage, NSURL *url) {
    NSURLComponents *parts = url ? [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO] : nil;
    NSMutableArray *names = [NSMutableArray new];
    NSRegularExpression *allowed = [NSRegularExpression regularExpressionWithPattern:@"^[A-Za-z0-9_-]{1,64}$" options:0 error:NULL];
    for (NSURLQueryItem *item in parts.queryItems) if ([allowed numberOfMatchesInString:item.name options:0 range:NSMakeRange(0,item.name.length)]) [names addObject:item.name];
    NSDictionary *event = @{@"event":@"native_review_route",@"stage":stage,@"host":parts.host ?: @"",@"path":parts.path ?: @"",@"query_names":[names sortedArrayUsingSelector:@selector(compare:)]};
    NSData *data=[NSJSONSerialization dataWithJSONObject:event options:NSJSONWritingSortedKeys error:NULL];
    puts([[NSString alloc]initWithData:data encoding:NSUTF8StringEncoding].UTF8String);fflush(stdout);
}
@interface ReviewRouteTraceSession : TVAppleNativeStoreReviewSession
@end
@implementation ReviewRouteTraceSession
- (NSDictionary *)requestBagKey:(NSString *)key parameters:(NSDictionary *)parameters post:(BOOL)post error:(NSError **)error {
    if (TracePrivateData && post) {
        PrintPrivateTrace(@{@"event":@"private_native_review_submission_parameters",
            @"bag_key":key ?: @"",@"parameters":parameters ?: @{},
            @"trace_scope":@"module_parameters_before_native_transport"});
    }
    NSDictionary *reply=[super requestBagKey:key parameters:parameters post:post error:error];
    PrintRoute(key ?: @"actual_review_entry",reply[@"url"]);
    NSDictionary *headers=reply[@"headers"];BOOL proof=NO;NSString *type=@"";
    for(NSString *name in headers) {
        if([name caseInsensitiveCompare:@"X-Apple-ActionSignature"]==NSOrderedSame)proof=[headers[name]isKindOfClass:NSString.class] && [headers[name]length]>0;
        if([name caseInsensitiveCompare:@"Content-Type"]==NSOrderedSame && [headers[name]isKindOfClass:NSString.class])type=headers[name];
    }
    NSDictionary *event=@{@"event":@"native_review_response",@"bag_key":key ?: @"",@"method":post?@"POST":@"GET",@"http_status":reply[@"status"] ?: @0,@"body_bytes":@([reply[@"data"]length]),@"proof_present":@(proof),@"content_type":type,@"response_header_names":[headers.allKeys sortedArrayUsingSelector:@selector(compare:)] ?: @[],@"trace_scope":@"module_native_response"};
    NSData *data=[NSJSONSerialization dataWithJSONObject:event options:NSJSONWritingSortedKeys error:NULL];puts([[NSString alloc]initWithData:data encoding:NSUTF8StringEncoding].UTF8String);fflush(stdout);
    if(TracePrivateData && reply) {
        id store=NSClassFromString(@"SSAccountStore");id storage=NSClassFromString(@"SSVCookieStorage");
        NSDictionary *cookieHeaders=@{};
        if([store respondsToSelector:@selector(defaultStore)] && [storage respondsToSelector:@selector(sharedStorage)]) {
            id accountStore=[store defaultStore];id cookies=[storage sharedStorage];
            if([accountStore respondsToSelector:@selector(activeAccount)] && [cookies respondsToSelector:@selector(cookieHeadersForURL:account:)])
                cookieHeaders=[cookies cookieHeadersForURL:reply[@"url"] account:[accountStore activeAccount]] ?: @{};
        }
        PrintPrivateTrace(@{@"event":@"private_native_review_trace",@"bag_key":key ?: @"",@"url":[reply[@"url"]absoluteString] ?: @"",@"headers":headers ?: @{},@"body_base64":[reply[@"data"]base64EncodedStringWithOptions:0] ?: @"",@"active_account_cookie_snapshot":cookieHeaders,@"cookie_scope":@"current_active_account_snapshot_not_wire_capture"});
    }
    return reply;
}
@end

// Device-only probe: private stdin for passwords/codes. Raw diagnostic material
// is emitted only when trace_private_data is explicitly enabled.
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
        BOOL externalPETMode = config[@"pet"] != nil;
        NSString *externalPET = [config[@"pet"]isKindOfClass:NSString.class] ? config[@"pet"] : nil;
        if (![appleID isKindOfClass:NSString.class] || !appleID.length ||
            (externalPETMode ? (!externalPET.length || password != nil) :
                (![password isKindOfClass:NSString.class] || !password.length))) return 2;
        NSDictionary *billing = [config[@"billing"]isKindOfClass:NSDictionary.class] ? config[@"billing"] : nil;
        BOOL completeReview = [config[@"complete_review"]boolValue];
        BOOL traceOnly = [config[@"trace_only"]boolValue];
        BOOL traceRoutes = traceOnly || [config[@"trace_routes"]boolValue];
        TracePrivateData = traceRoutes && [config[@"trace_private_data"]boolValue];
        if (traceOnly && (completeReview || billing || [config[@"auto_address"]boolValue])) return 2;
        BOOL autoAddress = [config[@"auto_address"]boolValue];
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
        NSString *credential = externalPET;
        TVAppleStoreAttempt attempt = externalPET.length ?
            TVAppleNativeStoreLoginForReviewWithPET(appleID, externalPET, &response, &context, &error) :
            authFirst ? TVAppleStoreAttemptNeedsTrust :
            TVAppleNativeStoreLoginForReview(appleID, password, &response, &context, &error);
        externalPET = nil;
        // External PET mode never falls back to native password authentication.
        if (credential.length && attempt == TVAppleStoreAttemptNeedsTrust) {
            PrintError(@"external_pet_store", error); return 1;
        }
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
        if (traceRoutes) PrintRoute(@"store_authentication_entry",TVAppleStoreReviewEntryURL(response));
        PrintPrivateTrace(@{@"event":@"private_native_authentication_trace",@"stage":@"store",@"response":response ?: @{}});
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
        PrintPrivateTrace(@{@"event":@"private_native_authentication_trace",@"stage":@"review_preauthentication",@"response":bootstrapResponse ?: @{}});
        if (traceRoutes) PrintRoute(@"review_preauthentication_entry",TVAppleStoreReviewEntryURL(response));
        error = nil;
        context = bootstrapContext;
        TVAppleNativeStoreReviewSession *session = [[(traceRoutes ? ReviewRouteTraceSession.class : TVAppleNativeStoreReviewSession.class) alloc]
            initWithAuthenticationResponse:response context:context error:&error];
        if (!session) { PrintError(@"review", error); return 1; }
        if (traceOnly) {
            NSDictionary *fields=[session loadConversionFields:&error];PrintReply(@"trace_conversion_fields",fields,error);
            if(!fields || error)return 1;
            NSString *signature=[session signatureForAccount:NO error:&error];
            PrintError(@"trace_sap_handshake",error);
            printf("native_review_proof_verified=%d billing_validation_submitted=0 conversion_submitted=0\n",signature.length>0);fflush(stdout);
            return signature.length && !error ? 0 : 1;
        }
        if (autoAddress && !billing) {
            billing = [[TVAppleNativeStoreSignIn new] billing:&error];
            PrintError(@"auto_address", error);
            if (!billing || error) return 1;
        }
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
