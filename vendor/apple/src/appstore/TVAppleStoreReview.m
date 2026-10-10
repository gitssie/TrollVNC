#import "TVAppleStoreReview.h"
#import <dlfcn.h>
@interface NSObject (TVAppleStoreReviewSelectors)
- (id)initWithURLRequest:(NSURLRequest *)request;
- (void)setITunesStoreRequest:(BOOL)value;
- (void)setShouldSendSecureToken:(BOOL)value;
- (void)setShouldProcessProtocol:(BOOL)value;
- (void)setShouldDecodeResponse:(BOOL)value;
- (id)initWithRequestProperties:(id)properties;
- (void)setAuthenticationContext:(id)context;
- (void)setSendsResponseForHTTPFailures:(BOOL)value;
- (void)startWithConnectionResponseBlock:(void (^)(id, NSError *))completion;
- (NSInteger)statusCode;
- (NSData *)bodyData;
- (NSURL *)URL;
- (void)setPassword:(nullable NSString *)value;
- (void)setInitialPassword:(nullable NSString *)value;
- (id)initWithBundleIdentifier:(NSString *)identifier;
+ (NSString *)userAgentForProcessInfo:(id)processInfo;
- (void)setClientIdentifier:(NSString *)identifier;
- (void)setURL:(nullable NSURL *)url;
- (void)setURLBagKey:(NSString *)key;
- (void)setRequestParameters:(NSDictionary *)parameters;
+ (id)mainQueue;
- (void)addOperation:(id)operation;
- (id)initWithURLRequestProperties:(id)properties;
- (id)mescalSession;
- (NSError *)error;
- (NSData *)signData:(NSData *)data error:(NSError **)error;
- (NSData *)primeForAccountCreationWithData:(NSData *)data error:(NSError **)error;
- (BOOL)verifyPrimeSignature:(NSData *)data error:(NSError **)error;
- (NSDictionary *)allHeaderFields;
- (NSString *)accountName;
- (id)valueForKey:(NSString *)key error:(NSError **)error;
- (NSString *)machineGUID;
- (NSString *)deviceSerialNumber;

@end
static BOOL Has(id object, NSArray *names) {
    for (NSString *name in names) if (![object respondsToSelector:NSSelectorFromString(name)]) return NO;
    return object != nil;
}
static NSURL *Entry(id value, NSUInteger depth) {
    if (depth > 8) return nil;
    if ([value isKindOfClass:NSString.class]) {
        NSURLComponents *parts = [NSURLComponents componentsWithString:value];
        NSString *scheme = parts.scheme.lowercaseString;
        if (![@[@"https", @"itms-appss", @"itmss"] containsObject:scheme] ||
            ![parts.host.lowercaseString hasSuffix:@".itunes.apple.com"] || parts.user || parts.password ||
            (parts.port && parts.port.integerValue != 443) ||
            ![parts.path isEqual:@"/WebObjects/MZFinance.woa/wa/com.apple.jingle.app.finance.DirectAction/convertWizard"]) return nil;
        parts.scheme = @"https";
        return parts.URL; // Preserve the actual server query, never reconstruct it.
    }
    if ([value isKindOfClass:NSDictionary.class]) {
        for (id item in [value allValues]) { NSURL *url = Entry(item, depth + 1); if (url) return url; }
    } else if ([value isKindOfClass:NSArray.class]) {
        for (id item in value) { NSURL *url = Entry(item, depth + 1); if (url) return url; }
    }
    return nil;
}
NSURL *TVAppleStoreReviewEntryURL(NSDictionary *response) { return Entry(response, 0); }
@interface TVAppleNativeStoreReviewSession ()
@property NSURL *entry;
@property id context;
@property id sap;
@property NSString *guid;
@property NSString *serial;
@property NSMutableDictionary *conversionData;
@property BOOL submitted;
@property BOOL validated;
@property NSString *primingSignature;
@property NSString *pageUUID;

@end
@implementation TVAppleNativeStoreReviewSession
- (void)dealloc {
    if ([self.context respondsToSelector:@selector(setPassword:)]) [self.context setPassword:nil];
    if ([self.context respondsToSelector:@selector(setInitialPassword:)]) [self.context setInitialPassword:nil];
}
- (instancetype)initWithAuthenticationResponse:(NSDictionary *)response context:(id)context error:(NSError **)error {
    NSURL *entry = TVAppleStoreReviewEntryURL(response);
    if (!entry || !context) {
        if (error) *error = TVAppleError(TVAppleErrorAccountNeedsReview, @"Native Store Review continuation is missing."); return nil;
    }
    if ((self = [super init])) { _entry = entry; _context = context; }
    return self;
}
- (NSDictionary *)loadEntry:(NSError **)error {
    return [self requestBagKey:nil parameters:nil post:NO error:error];
}
- (NSDictionary *)loadConversionFields:(NSError **)error {
    return [self requestBagKey:@"convertAccountFieldsSrv" parameters:@{@"context":@"convert", @"iso3CountryCode":@"USA"} post:NO error:error];
}
- (NSDictionary *)requestBagKey:(NSString *)bagKey parameters:(NSDictionary *)parameters post:(BOOL)post error:(NSError **)error {
    if (error) *error = nil;
    if (!dlopen("/System/Library/PrivateFrameworks/StoreServices.framework/StoreServices", RTLD_NOW)) {
        if (error) *error = TVAppleError(TVAppleErrorUnsupported, @"Native Store transport is unavailable."); return nil;
    }
    NSURL *requestURL = self.entry;
    if (post) {
        id bag = [NSClassFromString(@"SSURLBag") new];
        if (!Has(bag, @[@"valueForKey:error:"])) { if (error) *error = TVAppleError(TVAppleErrorUnsupported, @"Native Store bag is unavailable."); return nil; }
        id value = [bag valueForKey:bagKey error:NULL];
        NSURL *endpoint = [value isKindOfClass:NSURL.class] ? value : [value isKindOfClass:NSString.class] ? [NSURL URLWithString:value] : nil;
        NSURLComponents *parts = endpoint ? [NSURLComponents componentsWithURL:endpoint resolvingAgainstBaseURL:NO] : nil;
        if (!parts.URL) { if (error) *error = TVAppleError(TVAppleErrorBackendRead, @"Native Store submission route is missing."); return nil; }
        NSMutableArray *items = [parts.queryItems mutableCopy] ?: [NSMutableArray new];
        [items addObject:[NSURLQueryItem queryItemWithName:@"context" value:@"convert"]]; parts.queryItems = items;
        requestURL = parts.URL;
    }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:requestURL
        cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:45];
    // Compile the actual device client information through Apple's framework.
    // Do not construct a hardware model, OS version or user-agent string here.
    dlopen("/System/Library/PrivateFrameworks/AppleMediaServices.framework/AppleMediaServices", RTLD_NOW);
    id client = [NSClassFromString(@"AMSProcessInfo") alloc];
    Class agentClass = NSClassFromString(@"AMSUserAgent");
    if (!Has(client, @[@"initWithBundleIdentifier:"]) || !Has(agentClass, @[@"userAgentForProcessInfo:"])) {
        if (error) *error = TVAppleError(TVAppleErrorUnsupported, @"Native Store client information is unavailable."); return nil;
    }
    client = [client initWithBundleIdentifier:@"com.apple.AppStore"];
    NSString *agent = [agentClass userAgentForProcessInfo:client];
    if (![agent isKindOfClass:NSString.class] || !agent.length) {
        if (error) *error = TVAppleError(TVAppleErrorUnsupported, @"Native Store user agent is unavailable."); return nil;
    }
    [request setValue:agent forHTTPHeaderField:@"User-Agent"];
    if (self.primingSignature) [request setValue:self.primingSignature forHTTPHeaderField:@"X-Apple-ActionSignature"];
    if (post) {
        NSMutableArray *items = [NSMutableArray new];
        for (NSString *key in [[parameters allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
            id value = parameters[key];
            if ([value isKindOfClass:NSString.class] || [value isKindOfClass:NSNumber.class])
                [items addObject:[NSURLQueryItem queryItemWithName:key value:[value description]]];
        }
        NSURLComponents *form = [NSURLComponents new]; form.queryItems = items;
        NSString *encoded = [form.percentEncodedQuery stringByReplacingOccurrencesOfString:@"+" withString:@"%2B"];
        request.HTTPMethod = @"POST"; request.HTTPBody = [encoded dataUsingEncoding:NSUTF8StringEncoding];
        [request setValue:@"application/x-www-form-urlencoded; charset=utf-8" forHTTPHeaderField:@"Content-Type"];
    }
    id properties = [NSClassFromString(@"SSMutableURLRequestProperties") alloc];
    if (!Has(properties, @[@"initWithURLRequest:", @"setITunesStoreRequest:", @"setShouldSendSecureToken:",
        @"setShouldProcessProtocol:", @"setShouldDecodeResponse:", @"setClientIdentifier:"])) {
        if (error) *error = TVAppleError(TVAppleErrorUnsupported, @"Native Store request properties are unavailable."); return nil;
    }
    properties = [properties initWithURLRequest:request];
    [properties setClientIdentifier:@"com.apple.AppStore"];
    if (bagKey && !post) {
        if (!Has(properties, @[@"setURL:", @"setURLBagKey:", @"setRequestParameters:"])) {
            if (error) *error = TVAppleError(TVAppleErrorUnsupported, @"Native conversion fields request is unavailable."); return nil;
        }
        [properties setURL:nil];
        [properties setURLBagKey:bagKey];
        if (!post) [properties setRequestParameters:parameters];
    }
    [properties setITunesStoreRequest:YES]; [properties setShouldSendSecureToken:YES];
    [properties setShouldProcessProtocol:NO]; [properties setShouldDecodeResponse:NO];
    id operation = [NSClassFromString(@"SSURLConnectionRequest") alloc];
    if (!Has(operation, @[@"initWithRequestProperties:", @"setAuthenticationContext:",
        @"setSendsResponseForHTTPFailures:", @"startWithConnectionResponseBlock:"])) {
        if (error) *error = TVAppleError(TVAppleErrorUnsupported, @"Native Store connection is unavailable."); return nil;
    }
    operation = [operation initWithRequestProperties:properties];
    [operation setAuthenticationContext:self.context]; [operation setSendsResponseForHTTPFailures:YES];
    NSObject *lock = [NSObject new];
    __block BOOL finished = NO, closed = NO;
    __block NSDictionary *reply = nil;
    __block NSError *failure = nil;
    [operation startWithConnectionResponseBlock:^(id response, NSError *nativeError) {
        @synchronized(lock) {
            if (closed || finished) return;
            if (nativeError) failure = TVAppleError(TVAppleErrorBackendRead, @"Native Store Review request failed.");
            else if (!Has(response, @[@"statusCode", @"bodyData", @"URL", @"allHeaderFields"]) ||
                     ![[response bodyData] isKindOfClass:NSData.class] || ![[response URL] isKindOfClass:NSURL.class] ||
                     ![[response allHeaderFields]isKindOfClass:NSDictionary.class])
                failure = TVAppleError(TVAppleErrorBackendRead, @"Native Store Review response is incomplete.");
            else reply = @{ @"status":@([response statusCode]), @"data":[response bodyData], @"url":[response URL], @"headers":[response allHeaderFields] ?: @{} };
            finished = YES;
        }
    }];
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + 60;
    while (YES) {
        @synchronized(lock) {
            if (finished) { closed = YES; break; }
            if (NSProcessInfo.processInfo.systemUptime >= deadline) {
                closed = YES; failure = TVAppleError(TVAppleErrorOutcomeUnknown, @"Native Store Review timed out."); break;
            }
        }
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    }
    if (failure) { if (error) *error = failure; return nil; }
    return reply;
}
- (NSString *)signatureForAccount:(BOOL)final error:(NSError **)error {
    if (!self.sap) {
        for (NSString *name in @[@"StoreKitUI", @"StoreUI"]) {
            NSString *path = [NSString stringWithFormat:@"/System/Library/PrivateFrameworks/%@.framework/%@", name, name];
            dlopen(path.UTF8String, RTLD_LAZY);
        }
        id device = [NSClassFromString(@"SUScriptInterface") new];
        if (!Has(device, @[@"machineGUID", @"deviceSerialNumber"])) {
            if (error) *error = TVAppleError(TVAppleErrorUnsupported, @"Native Store device information is unavailable."); return nil;
        }
        self.guid = [device machineGUID]; self.serial = [device deviceSerialNumber];
        if (![self.guid isKindOfClass:NSString.class] || !self.guid.length ||
            ![self.serial isKindOfClass:NSString.class] || !self.serial.length) {
            if (error) *error = TVAppleError(TVAppleErrorUnsupported, @"Native Store device information is unavailable."); return nil;
        }
        id setup = [NSClassFromString(@"SUSetupMescalSessionOperation") alloc];
        Class queueClass = NSClassFromString(@"ISOperationQueue");
        if (!Has(setup, @[@"initWithURLRequestProperties:", @"setCompletionBlock:", @"mescalSession", @"error"]) || !Has(queueClass, @[@"mainQueue"])) {
            if (error) *error = TVAppleError(TVAppleErrorUnsupported, @"Native Review SAP setup is unavailable."); return nil;
        }
        setup = [setup initWithURLRequestProperties:nil];
        NSObject *setupLock = [NSObject new]; __block BOOL setupDone = NO, setupClosed = NO;
        __block id sap = nil;
        __weak id weakSetup = setup;
        [setup setCompletionBlock:^{
            id operation = weakSetup;
            @synchronized(setupLock) { if (setupClosed || setupDone) return;
                if (![operation error]) sap = [operation mescalSession]; setupDone = YES;
            }
        }];
        [[queueClass mainQueue] addOperation:setup];
        NSTimeInterval setupDeadline = NSProcessInfo.processInfo.systemUptime + 60;
        while (YES) { @synchronized(setupLock) {
            if (setupDone || NSProcessInfo.processInfo.systemUptime >= setupDeadline) { setupClosed = YES; break; }
        } [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]]; }
        if (!Has(sap, @[@"primeForAccountCreationWithData:error:", @"verifyPrimeSignature:error:", @"signData:error:"])) {
            if (error) *error = TVAppleError(setupDone ? TVAppleErrorBackendRead : TVAppleErrorOutcomeUnknown, @"Native Review SAP setup failed."); return nil;
        }
        NSData *prime = [sap primeForAccountCreationWithData:[NSData data] error:NULL];
        if (!prime.length) { if (error) *error = TVAppleError(TVAppleErrorBackendRead, @"Native Review priming signature is unavailable."); return nil; }
        self.primingSignature = [prime base64EncodedStringWithOptions:0];
        NSDictionary *entryReply = [self loadEntry:error]; self.primingSignature = nil;
        if (!entryReply) return nil;
        NSDictionary *headers = entryReply[@"headers"]; NSString *serverSignature = nil;
        for (NSString *key in headers) if ([key isKindOfClass:NSString.class] && [key caseInsensitiveCompare:@"X-Apple-ActionSignature"] == NSOrderedSame && [headers[key]isKindOfClass:NSString.class]) serverSignature = headers[key];
        NSData *proof = serverSignature ? [[NSData alloc]initWithBase64EncodedString:serverSignature options:0] : nil;
        if (!proof.length || ![sap verifyPrimeSignature:proof error:NULL]) {
            if (error) *error = TVAppleError(TVAppleErrorBackendRead, [NSString stringWithFormat:@"Native Review priming response is incomplete (HTTP %ld, proof %d).", (long)[entryReply[@"status"]integerValue], proof.length>0]); return nil;
        }
        NSData *entryBody = entryReply[@"data"];
        NSString *entryText = [[NSString alloc]initWithData:entryBody encoding:NSUTF8StringEncoding];
        NSRegularExpression *pattern = [NSRegularExpression regularExpressionWithPattern:@"pageUUID=([^&\\s\\x22\\x27<>]+)" options:0 error:NULL];
        NSTextCheckingResult *match = entryText ? [pattern firstMatchInString:entryText options:0 range:NSMakeRange(0,entryText.length)] : nil;
        if (match.numberOfRanges == 2) self.conversionData[@"pageUUID"] = [[entryText substringWithRange:[match rangeAtIndex:1]]stringByRemovingPercentEncoding];
        self.sap = sap;
        NSURLComponents *landing = [NSURLComponents componentsWithURL:entryReply[@"url"] resolvingAgainstBaseURL:NO];
        for (NSURLQueryItem *item in landing.queryItems) if ([item.name isEqual:@"pageUUID"] && item.value.length) self.conversionData[@"pageUUID"] = item.value;
    }
    // Apple's finance JS concatenates its absent initial pageUUID as 'undefined'.
    // Validation supplies the real pageUUID before final submission.
    id value = self.conversionData[@"pageUUID"];
    if (value && ![value isKindOfClass:NSString.class]) { if (error) *error = TVAppleError(TVAppleErrorBackendRead, @"Native Review page token is malformed."); return nil; }
    NSString *page = value ?: @"undefined";
    NSString *input = [page stringByAppendingString:self.guid];
    if (final) input = [input stringByAppendingString:self.conversionData[@"acAccountName"]];
    NSObject *lock = [NSObject new]; __block BOOL done = NO, closed = NO;
    __block NSData *signature = nil; __block NSInteger nativeCode = 0;
    id sap = self.sap;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSError *failure = nil;
        NSData *data = [sap signData:[input dataUsingEncoding:NSUTF8StringEncoding] error:&failure];
        @synchronized(lock) { if (closed || done) return;
            if (!failure && [data isKindOfClass:NSData.class]) signature = data; nativeCode = failure.code; done = YES;
        }
    });
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + 60;
    while (YES) { @synchronized(lock) {
        if (done || NSProcessInfo.processInfo.systemUptime >= deadline) { closed = YES; break; }
    } [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]]; }
    if (!signature.length) { if (error) *error = TVAppleError(done ? TVAppleErrorBackendRead : TVAppleErrorOutcomeUnknown, [NSString stringWithFormat:@"Native Store SAP signing failed (code %ld).", (long)nativeCode]); return nil; }
    self.conversionData[@"guid"] = self.guid; self.conversionData[@"machineGUID"] = self.guid;
    return [signature base64EncodedStringWithOptions:0];
}
- (NSDictionary *)validateBilling:(NSDictionary *)billing error:(NSError **)error {
    if (error) *error = nil;
    if (self.submitted) { if (error) *error = TVAppleError(TVAppleErrorConflict, @"Native Review was already submitted."); return nil; }
    self.validated = NO;
    NSDictionary *reply = [self loadConversionFields:error];
    NSDictionary *root = reply ? [NSJSONSerialization JSONObjectWithData:reply[@"data"] options:0 error:NULL] : nil;
    NSDictionary *container = [root isKindOfClass:NSDictionary.class] && [root[@"data"]isKindOfClass:NSDictionary.class] ? root[@"data"] : nil;
    NSDictionary *attributes = [container[@"attributes"]isKindOfClass:NSDictionary.class] ? container[@"attributes"] : nil;
    if (![attributes isKindOfClass:NSDictionary.class]) { if (error && !*error) *error = TVAppleError(TVAppleErrorBackendRead, @"Native Store fields are missing."); return nil; }
    NSDictionary *account = [attributes[@"accountData"]isKindOfClass:NSDictionary.class] ? attributes[@"accountData"] : nil;
    self.conversionData = [NSMutableDictionary new];
    if (self.pageUUID) self.conversionData[@"pageUUID"] = self.pageUUID;
    for (NSString *group in @[@"addressInfo", @"accountInfo"]) {
        NSDictionary *values = account[group];
        if ([values isKindOfClass:NSDictionary.class]) for (NSString *key in values) {
            id value = values[key];
            if (([value isKindOfClass:NSString.class] && [value length]) || [value isKindOfClass:NSNumber.class]) self.conversionData[key] = value;
        }
    }
    NSURLComponents *entry = [NSURLComponents componentsWithURL:self.entry resolvingAgainstBaseURL:NO];
    for (NSURLQueryItem *item in entry.queryItems) if ([item.name isEqual:@"pageUUID"] && item.value.length) self.conversionData[@"pageUUID"] = item.value;
    if ([attributes[@"pageUUID"] isKindOfClass:NSString.class]) self.conversionData[@"pageUUID"] = attributes[@"pageUUID"];
    for (NSString *key in @[@"addressOfficialLineFirst", @"addressOfficialCity", @"addressOfficialStateProvince", @"addressOfficialPostalCode", @"phoneOfficeAreaCode", @"phoneOfficeNumber"]) {
        if (![billing[key] isKindOfClass:NSString.class] || ![billing[key] length]) { if (error) *error = TVAppleError(TVAppleErrorInvalidRequest, @"Billing address is incomplete."); return nil; }
        self.conversionData[key] = billing[key];
    }
    NSString *target = [self.context respondsToSelector:@selector(accountName)] ? [self.context accountName] : nil;
    if (![target isKindOfClass:NSString.class] || ![self.conversionData[@"acAccountName"]isKindOfClass:NSString.class] ||
        [target caseInsensitiveCompare:self.conversionData[@"acAccountName"]] != NSOrderedSame) { if (error) *error = TVAppleError(TVAppleErrorBackendRead, @"Native conversion account is missing."); return nil; }
    for (NSString *key in @[@"billingFirstName", @"billingLastName", @"firstName", @"lastName"]) {
        if (self.conversionData[key] && ![self.conversionData[key]isKindOfClass:NSString.class]) { if (error) *error = TVAppleError(TVAppleErrorBackendRead, @"Native Review account name fields are malformed."); return nil; }
    }
    for (NSString *suffix in @[@"FirstName", @"LastName"]) {
        NSString *key = [@"billing" stringByAppendingString:suffix];
        NSString *fallback = [suffix stringByReplacingCharactersInRange:NSMakeRange(0,1) withString:[[suffix substringToIndex:1]lowercaseString]];
        if (![self.conversionData[key]length] && [self.conversionData[fallback]isKindOfClass:NSString.class]) self.conversionData[key] = self.conversionData[fallback];
    }
    self.conversionData[@"addressOfficialCountryCode"] = @"USA";
    self.conversionData[@"iso3CountryCode"] = @"USA";
    self.conversionData[@"context"] = @"convert";
    self.conversionData[@"paymentMethodType"] = @"None";
    self.conversionData[@"agreedToTerms"] = @1;
    NSString *signature = [self signatureForAccount:NO error:error]; if (!signature) return nil;
    self.conversionData[@"xAppleActionSignature"] = signature;
    NSMutableDictionary *validationData = [NSMutableDictionary new];
    for (NSString *key in @[@"billingFirstName", @"billingLastName", @"addressOfficialCountryCode", @"addressOfficialLineFirst", @"addressOfficialCity", @"addressOfficialStateProvince", @"addressOfficialPostalCode", @"phoneOfficeAreaCode", @"phoneOfficeNumber", @"paymentMethodType", @"agreedToTerms", @"pageUUID", @"machineGUID", @"guid", @"iso3CountryCode", @"context", @"xAppleActionSignature"]) if (self.conversionData[key]) validationData[key] = self.conversionData[key];
    NSDictionary *result = [self requestBagKey:@"validateAccountFieldsSrv" parameters:validationData post:YES error:error];
    NSDictionary *validated = result ? [NSJSONSerialization JSONObjectWithData:result[@"data"] options:0 error:NULL] : nil;
    if (![validated isKindOfClass:NSDictionary.class]) validated = nil;
    if ([validated[@"pageUUID"] isKindOfClass:NSString.class]) self.conversionData[@"pageUUID"] = validated[@"pageUUID"];
    if ([self.conversionData[@"pageUUID"]isKindOfClass:NSString.class]) self.pageUUID = self.conversionData[@"pageUUID"];
    id issues = validated[@"validationResults"];
    BOOL noIssues = !issues || ([issues isKindOfClass:NSArray.class] && ![issues count]);
    self.validated = [result[@"status"]integerValue] == 200 && [validated[@"status"]isKindOfClass:NSNumber.class] &&
        [validated[@"status"]compare:@0] == NSOrderedSame && noIssues && !validated[@"errorMessageKey"] &&
        [self.conversionData[@"pageUUID"]isKindOfClass:NSString.class] && [self.conversionData[@"pageUUID"]length] > 0;
    return result;
}

- (NSDictionary *)submitConversion:(NSError **)error {
    if (error) *error = nil;
    if (!self.validated || self.submitted) { if (error) *error = TVAppleError(TVAppleErrorConflict, @"Native Review must be validated before a single submission."); return nil; }
    NSString *signature = [self signatureForAccount:YES error:error]; if (!signature) return nil;
    self.conversionData[@"xAppleActionSignature"] = signature;
    self.conversionData[@"serialNumber"] = self.serial;
    self.submitted = YES; self.validated = NO;
    return [self requestBagKey:@"createAccountSrv" parameters:self.conversionData post:YES error:error];
}

@end
