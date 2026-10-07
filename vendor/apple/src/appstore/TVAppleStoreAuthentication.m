// Adapted from appknox/appstorectl cli/login.m and cli/authkit.m, commit
// 4b60f16b2066056cc9a9c53da9a61c1aa53fec2f. Copyright (c) 2026 Appknox.
// MIT notice retained in docs/appstorectl-LICENSE. Service adaptation replaces
// terminal input/logging with injected providers and bounded asynchronous tickets.
#import "TVAppleStoreLogin.h"
#import "TVAppleAuthenticationSelectors.h"
#import <dlfcn.h>
#import <objc/runtime.h>

@interface TVAppleAuthTicket : NSObject
@property dispatch_semaphore_t signal;
@property NSDictionary *value;
@property BOOL resolved;
- (void)resolve:(NSDictionary *)value;
- (BOOL)wait:(NSTimeInterval)timeout;
@end
@implementation TVAppleAuthTicket
- (instancetype)init { if ((self = [super init])) _signal = dispatch_semaphore_create(0); return self; }
- (void)resolve:(NSDictionary *)value {
    @synchronized (self) { if (_resolved) return; _resolved = YES; _value = value; }
    dispatch_semaphore_signal(_signal);
}
- (BOOL)wait:(NSTimeInterval)timeout {
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + timeout;
    while (YES) {
        @synchronized (self) { if (_resolved) return YES; }
        dispatch_semaphore_wait(_signal, dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC));
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate date]];
        if (NSProcessInfo.processInfo.systemUptime >= deadline) return NO;
    }
    return YES;
}
@end
static BOOL Require(id object, NSArray<NSString *> *selectors, NSError **error) {
    for (NSString *name in selectors) if (![object respondsToSelector:NSSelectorFromString(name)]) {
        *error = TVAppleError(TVAppleErrorUnsupported, @"A required authentication selector is unavailable."); return NO;
    }
    return YES;
}
TVAppleStoreAttempt TVAppleNativeStoreLogin(NSString *appleID, NSString *password, NSError **error) {
    Class requestClass = NSClassFromString(@"SSAuthenticateRequest");
    Class baseClass = NSClassFromString(@"SSAuthenticationContext");
    if (!Require(requestClass, @[@"_isAuthkitEntitled"], error) || ![requestClass _isAuthkitEntitled]) {
        if (!*error) *error = TVAppleError(TVAppleErrorPermissionDenied, @"Effective AuthKit entitlement is missing.");
        return TVAppleStoreAttemptFailed;
    }
    // Upstream buildContext: use Apple's sign-in factory and force authentication.
    id context = nil;
    if ([baseClass respondsToSelector:@selector(contextForSignIn)]) context = [[baseClass contextForSignIn] mutableCopy];
    if (!context) context = [NSClassFromString(@"SSMutableAuthenticationContext") new];
    if (!Require(context, @[@"setAccountName:", @"setPassword:", @"setInitialPassword:", @"setPromptStyle:",
        @"setCanSetActiveAccount:", @"setCanCreateNewAccount:", @"setAllowsSilentAuthentication:", @"setAllowsRetry:",
        @"setShouldSuppressDialogs:", @"setShouldCreateNewSession:"], error)) return TVAppleStoreAttemptFailed;
    [context setAccountName:appleID]; [context setPassword:password]; [context setInitialPassword:password];
    [context setPromptStyle:1]; [context setCanSetActiveAccount:YES]; [context setCanCreateNewAccount:YES];
    [context setAllowsSilentAuthentication:YES]; [context setAllowsRetry:NO];
    [context setShouldSuppressDialogs:NO]; [context setShouldCreateNewSession:YES];
    id request = [requestClass alloc];
    if (!Require(request, @[@"initWithAuthenticationContext:", @"startWithAuthenticateResponseBlock:"], error)) return TVAppleStoreAttemptFailed;
    request = [request initWithAuthenticationContext:context];
    if (!request) { *error = TVAppleError(TVAppleErrorUnsupported, @"Authentication request could not be created."); return TVAppleStoreAttemptFailed; }
    TVAppleAuthTicket *ticket = [TVAppleAuthTicket new];
    [request startWithAuthenticateResponseBlock:^(id response, NSError *failure) {
        if (![response respondsToSelector:@selector(authenticateResponseType)] || ![response respondsToSelector:@selector(error)]) {
            [ticket resolve:@{ @"type":@(-1) }]; return;
        }
        NSError *nativeError = [response error] ?: failure;
        [ticket resolve:@{ @"type":@([response authenticateResponseType]), @"domain":nativeError.domain ?: @"",
                           @"code":@(nativeError.code), @"has_error":@(nativeError != nil) }];
    }];
    if (![ticket wait:120]) {
        *error = TVAppleError(TVAppleErrorOutcomeUnknown, @"App Store authentication timed out; do not replay automatically."); return TVAppleStoreAttemptUnknown;
    }
    [context setPassword:nil]; [context setInitialPassword:nil];
    NSDictionary *reply = ticket.value;
    NSInteger type = [reply[@"type"] integerValue];
    if (type < 0 || type > 4 || (type == 4 && [reply[@"has_error"] boolValue])) {
        *error = TVAppleError(TVAppleErrorOutcomeUnknown, @"The Store returned an uninterpretable authentication result."); return TVAppleStoreAttemptUnknown;
    }
    if (type == 4 && ![reply[@"has_error"] boolValue]) return TVAppleStoreAttemptSucceeded;
    if (type == 1 && [reply[@"domain"] isEqual:@"SSServerErrorDomain"] && [reply[@"code"] integerValue] == -5000) {
        *error = TVAppleError(TVAppleErrorVerificationCode, @"App Store rejected authentication; a two-factor trust bootstrap may be required.");
        return TVAppleStoreAttemptNeedsTrust;
    }
    *error = TVAppleError(type == 3 ? TVAppleErrorAccountNeedsReview : TVAppleErrorAuthenticationFailed,
        type == 3 ? @"The account requires review by Apple." : @"App Store authentication failed.");
    return TVAppleStoreAttemptFailed;
}

@interface TVAppleChallengeState : NSObject
@property id<TVAppleVerificationCodeProvider> provider;
@property NSError *failure;
@property NSUInteger requests;
@property NSUInteger promptRequests;
@property NSString *suppliedCode;
@property TVAppleAuthTicket *codeTicket;
@property BOOL closed;
@end
@implementation TVAppleChallengeState
@end
static const char ChallengeKey;
static NSDictionary<NSString *, NSValue *> *OriginalPrompts;
static NSMutableDictionary<NSString *, TVAppleChallengeState *> *ContextRegistry;
static TVAppleChallengeState *ChallengeState(id context) {
    TVAppleChallengeState *state = objc_getAssociatedObject(context, &ChallengeKey);
    if (state) return state;
    @synchronized (ContextRegistry) {
        NSString *identifier = [context respondsToSelector:@selector(_identifier)] ? [[context _identifier] description] : nil;
        NSString *reason = [context respondsToSelector:@selector(reason)] ? [context reason] : nil;
        if (identifier.length) state = ContextRegistry[identifier];
        if (!state && reason.length) state = ContextRegistry[reason];
    }
    if (state) objc_setAssociatedObject(context, &ChallengeKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return state;
}
static id FetchCode(TVAppleChallengeState *state) {
    TVAppleAuthTicket *ticket;
    BOOL start = NO;
    @synchronized (state) {
        if (state.closed || state.failure) return nil;
        if (!state.provider) { state.failure = TVAppleError(TVAppleErrorVerificationCode, @"A verification code provider is required."); return nil; }
        if (state.suppliedCode) return state.suppliedCode;
        if (!state.codeTicket) {
            state.requests++;
            state.codeTicket = [TVAppleAuthTicket new];
            start = YES;
        }
        ticket = state.codeTicket;
    }
    if (start) @synchronized (state) {
        if (state.closed) { [ticket resolve:@{ @"failed":@YES }]; return nil; }
        [state.provider requestCodeForChallenge:@{ @"kind":@"apple_two_factor", @"verification_method":@"trusted_device", @"attempt":@1 }
        completion:^(NSString *code, NSError *failure) {
            BOOL valid = [code isKindOfClass:NSString.class] && code.length == 6 &&
                [code rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789"] invertedSet]].location == NSNotFound;
            @synchronized (state) {
                if (state.closed) { [ticket resolve:@{ @"failed":@YES }]; return; }
                if (valid && !failure) state.suppliedCode = [code copy];
                else state.failure = failure ?: TVAppleError(TVAppleErrorVerificationCode, @"A fresh six-digit verification code was not provided.");
                [ticket resolve:valid && !failure ? @{ @"code":code } : @{ @"failed":@YES }];
            }
        }];
    }
    if (![ticket wait:120]) {
        @synchronized (state) { state.failure = TVAppleError(TVAppleErrorVerificationCode, @"The verification challenge timed out."); }
        return nil;
    }
    @synchronized (state) { return state.closed ? nil : state.suppliedCode; }
}

static id CodePrompt(id context, SEL selector, BOOL secure, id trustedNumber) {
    TVAppleChallengeState *state = ChallengeState(context);
    if (!state) {
        id (*original)(id, SEL, BOOL, id) = (void *)OriginalPrompts[NSStringFromSelector(selector)].pointerValue;
        return original(context, selector, secure, trustedNumber);
    }
    @synchronized (state) {
        if (++state.promptRequests > 1) {
            state.failure = TVAppleError(TVAppleErrorVerificationCode, @"Apple requested another code; no automatic code retries.");
            return nil;
        }
    }
    return FetchCode(state);
}

// On iOS 15 this callback, not the getter, calls AKReadLine. Native machine
// code confirms completion arguments are (NSNumber *code, NSError *error).
static void SecondFactorUI(id context, SEL selector, void (^completion)(NSNumber *, NSError *)) {
    TVAppleChallengeState *state = ChallengeState(context);
    if (!state) {
        void (*original)(id, SEL, id) = (void *)OriginalPrompts[NSStringFromSelector(selector)].pointerValue;
        original(context, selector, completion); return;
    }
    @synchronized (state) {
        if (state.closed || state.failure || ++state.promptRequests > 1) {
            NSError *failure = state.failure ?: TVAppleError(TVAppleErrorVerificationCode, @"The verification challenge is unavailable or was requested again.");
            state.failure = failure; completion(nil, failure); return;
        }
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        NSString *code = FetchCode(state);
        NSError *failure = nil;
        @synchronized (state) {
            if (state.closed || state.failure || !code) failure = state.failure ?: TVAppleError(TVAppleErrorVerificationCode, @"The verification challenge is unavailable.");
            else [context setSecondFactorCode:@(code.longLongValue)];
        }
        completion(failure ? nil : @(code.longLongValue), failure);
    });
}

static id NoTerminalPrompt(id context, SEL selector) {
    TVAppleChallengeState *state = ChallengeState(context);
    if (!state) {
        id (*original)(id, SEL) = (void *)OriginalPrompts[NSStringFromSelector(selector)].pointerValue;
        return original(context, selector);
    }
    @synchronized (state) {
        state.failure = TVAppleError(TVAppleErrorAccountNeedsReview,
            [NSString stringWithFormat:@"An additional authentication interaction is required (%@).", NSStringFromSelector(selector)]);
    }
    return nil;
}
static id NoTerminalPromptWithObject(id context, SEL selector, id argument) {
    if (!ChallengeState(context)) {
        id (*original)(id, SEL, id) = (void *)OriginalPrompts[NSStringFromSelector(selector)].pointerValue;
        return original(context, selector, argument);
    }
    return NoTerminalPrompt(context, selector);
}
static NSString *ErrorMetadata(NSError *error) {
    NSMutableArray *codes = [NSMutableArray new];
    NSMutableOrderedSet *flags = [NSMutableOrderedSet new];
    for (NSUInteger i = 0; error && i < 4; i++) {
        [codes addObject:@(error.code).stringValue];
        NSString *description = error.localizedDescription.lowercaseString;
        for (NSString *word in @[@"context", @"class", @"decode", @"xpc", @"unsupported", @"restricted", @"locked", @"disabled", @"server", @"service", @"security", @"password", @"trusted", @"phone", @"verify", @"invalid"]) {
            if ([description containsString:word]) [flags addObject:word];
        }
        id underlying = error.userInfo[NSUnderlyingErrorKey];
        error = [underlying isKindOfClass:NSError.class] ? underlying : nil;
    }
    return [NSString stringWithFormat:@"codes %@; flags %@", [codes componentsJoinedByString:@","], [flags.array componentsJoinedByString:@","]];
}
static BOOL Shape(Method method, const char *result, NSArray<NSString *> *arguments);
static BOOL NativeReplyShape(id block) {
    struct BlockLayout { void *isa; int flags; int reserved; void *invoke; void *descriptor; };
    struct BlockLayout *layout = (__bridge void *)block;
    if (!layout || !(layout->flags & (1 << 30))) return NO;
    uintptr_t descriptor = (uintptr_t)layout->descriptor + 2 * sizeof(uintptr_t);
    if (layout->flags & (1 << 25)) descriptor += 2 * sizeof(uintptr_t);
    const char *types = *(const char **)descriptor;
    if (!types) return NO;
    NSMethodSignature *signature = [NSMethodSignature signatureWithObjCTypes:types];
    if (strcmp(signature.methodReturnType, "v") || signature.numberOfArguments != 4) return NO;
    NSArray *names = @[@"NSHTTPURLResponse", @"NSDictionary", @"NSError"];
    for (NSUInteger i = 1; i < 4; i++) {
        const char *type = [signature getArgumentTypeAtIndex:i];
        if (type[0] != '@') return NO;
        if (type[1] == '"' && ![@(type) containsString:names[i - 1]]) return NO;
    }
    return YES;
}
static void TrustedDeviceUI(id context, SEL selector, NSDictionary *dictionary, long long status,
                            id configuration, void (^completion)(NSHTTPURLResponse *, NSDictionary *, NSError *)) {
    TVAppleChallengeState *state = ChallengeState(context);
    if (!state) {
        void (*original)(id, SEL, id, long long, id, id) = (void *)OriginalPrompts[NSStringFromSelector(selector)].pointerValue;
        original(context, selector, dictionary, status, configuration, completion); return;
    }
    // The completion is Apple's ServerUI reply: actual HTTP response, body, error.
    // Never synthesize a success response or feed a device code to an SMS endpoint.
    if (!NativeReplyShape(completion)) {
        @synchronized (state) { state.failure = TVAppleError(TVAppleErrorUnsupported, @"Unsupported ServerUI completion ABI."); }
        return;
    }
    NSError *failure = nil;
    @synchronized (state) {
        if (state.closed || state.failure || ++state.promptRequests > 1)
            failure = state.failure ?: TVAppleError(TVAppleErrorVerificationCode, @"The verification challenge is unavailable or was requested again.");
    }
    if (![dictionary isKindOfClass:NSDictionary.class] || status != 200 ||
        ![dictionary[@"securityCode"] isKindOfClass:NSDictionary.class] ||
        ![dictionary[@"hsa2Account"] isKindOfClass:NSNumber.class] || ![dictionary[@"hsa2Account"] boolValue])
        failure = TVAppleError(TVAppleErrorAccountNeedsReview, @"Unsupported two-factor account response.");
    if (failure) { @synchronized (state) { state.failure = failure; } completion(nil, nil, failure); return; }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        NSString *code = FetchCode(state);
        NSError *error = nil;
        @synchronized (state) {
            if (state.closed || state.failure || !code) error = state.failure ?: TVAppleError(TVAppleErrorVerificationCode, @"The verification challenge is unavailable.");
        }
        id utility = [context respondsToSelector:@selector(utility)] ? [context utility] : nil;
        id signer = [configuration respondsToSelector:@selector(resourceLoadDelegate)] ? [configuration resourceLoadDelegate] : nil;
        if (!error && (!Shape(class_getInstanceMethod([utility class], @selector(mutableJSONRequestForPath:)), "@", @[@"@"]) ||
            !Shape(class_getInstanceMethod([signer class], @selector(signRequest:)), "v", @[@"@"]) ||
            !Shape(class_getInstanceMethod([context class], @selector(_verifySecondFactorCodeWithRequest:completion:)), "v", @[@"@", @"@?"])))
            error = TVAppleError(TVAppleErrorUnsupported, @"Native trusted-device request interfaces are unavailable.");
        NSMutableURLRequest *request = nil;
        if (!error) {
            request = [utility mutableJSONRequestForPath:@"/auth/verify/trusteddevice/securitycode"];
            if (![request isKindOfClass:NSMutableURLRequest.class] || ![request.URL.scheme isEqual:@"https"] ||
                ![request.URL.host isEqual:@"gsa.apple.com"] || ![request.URL.path isEqual:@"/auth/verify/trusteddevice/securitycode"])
                error = TVAppleError(TVAppleErrorUnsupported, @"Unexpected native authentication endpoint.");
        }
        if (!error) {
            request.HTTPMethod = @"POST";
            request.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{ @"securityCode":@{ @"code":code } } options:0 error:&error];
        }
        @synchronized (state) {
            if (state.closed || state.failure) error = state.failure ?: TVAppleError(TVAppleErrorVerificationCode, @"Authentication already finished.");
            if (error) { state.failure = error; completion(nil, nil, error); return; }
            [signer signRequest:request];
            // This native verifier forwards the actual response even when the
            // successful body is empty; the generic JSON utility can drop it.
            [context _verifySecondFactorCodeWithRequest:request completion:completion];
        }
    });
}
static BOOL Shape(Method method, const char *result, NSArray<NSString *> *arguments) {
    if (!method || method_getNumberOfArguments(method) != arguments.count + 2) return NO;
    char *type = method_copyReturnType(method); BOOL ok = strcmp(type, result) == 0; free(type);
    for (NSUInteger i = 0; ok && i < arguments.count; i++) {
        type = method_copyArgumentType(method, (unsigned int)i + 2);
        ok = strcmp(type, arguments[i].UTF8String) == 0; free(type);
    }
    return ok;
}
static Class ServiceContextClass(void) {
    static Class supportedClass;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class base = NSClassFromString(@"AKAppleIDAuthenticationCommandLineContext");
        SEL prompt = NSSelectorFromString(@"_promptForVerificationCodeWithSecureEntry:forTrustedNumber:");
        Method method = class_getInstanceMethod(base, prompt);
        if (!Shape(method, "@", @[@"B", @"@"])) return;
        Method initializer = class_getInstanceMethod(base, @selector(initWithVerificationType:));
        if (!Shape(initializer, "@", @[@"q"])) return;
        SEL deviceUI = NSSelectorFromString(@"_handleServerUISMSVerificationWithResponseDictionary:statusCode:configuration:completion:");
        Method deviceMethod = class_getInstanceMethod(base, deviceUI);
        if (!Shape(deviceMethod, "v", @[@"@", @"q", @"@", @"@?"])) return;
        Method secondFactorUI = class_getInstanceMethod(base, NSSelectorFromString(@"presentSecondFactorUIWithCompletion:"));
        if (!Shape(secondFactorUI, "v", @[@"@?"])) return;
        NSArray *noArguments = @[@"_promptForUsername", @"_promptForPassword", @"_promptForPhoneNumber", @"_promptForFirstName", @"_promptForLastName", @"_promptForBirthday"];
        NSArray *oneArgument = @[@"_promptUserForSelectionWithTrustedNumbers:", @"_promptUserForTermsWithResponseDictionary:"];
        // Validate every ABI before installing any process-local adapter.
        for (NSString *name in noArguments) {
            SEL sel = NSSelectorFromString(name); Method m = class_getInstanceMethod(base, sel);
            if (!Shape(m, "@", @[])) return;
        }
        for (NSString *name in oneArgument) {
            SEL sel = NSSelectorFromString(name); Method m = class_getInstanceMethod(base, sel);
            if (!Shape(m, "@", @[@"@"])) return;
        }
        NSMutableDictionary *originals = [NSMutableDictionary new];
        for (NSString *name in [[noArguments arrayByAddingObjectsFromArray:oneArgument] arrayByAddingObjectsFromArray:@[NSStringFromSelector(prompt), NSStringFromSelector(deviceUI), @"presentSecondFactorUIWithCompletion:"]]) {
            Method m = class_getInstanceMethod(base, NSSelectorFromString(name));
            originals[name] = [NSValue valueWithPointer:method_getImplementation(m)];
        }
        OriginalPrompts = [originals copy];
        ContextRegistry = [NSMutableDictionary new];
        // AuthKit accepts the exact native command-line context. Attach state to
        // our instances; unrelated instances delegate to their original methods.
        method_setImplementation(method, (IMP)CodePrompt);
        method_setImplementation(deviceMethod, (IMP)TrustedDeviceUI);
        method_setImplementation(secondFactorUI, (IMP)SecondFactorUI);
        for (NSString *name in noArguments) method_setImplementation(class_getInstanceMethod(base, NSSelectorFromString(name)), (IMP)NoTerminalPrompt);
        for (NSString *name in oneArgument) method_setImplementation(class_getInstanceMethod(base, NSSelectorFromString(name)), (IMP)NoTerminalPromptWithObject);
        supportedClass = base;
    });
    return supportedClass;
}
NSDictionary *TVAppleNativeAuthenticate(NSString *appleID, NSString *password, id<TVAppleVerificationCodeProvider> provider, BOOL requireChallenge, NSError **error) {
    if (!dlopen("/System/Library/PrivateFrameworks/AuthKit.framework/AuthKit", RTLD_NOW)) {
        *error = TVAppleError(TVAppleErrorUnsupported, @"AuthKit framework is unavailable."); return nil;
    }
    Class contextClass = ServiceContextClass();
    id context = [[contextClass alloc] initWithVerificationType:1], controller = [NSClassFromString(@"AKAppleIDAuthenticationController") new];
    if (!Require(context, @[@"setUsername:", @"_setPassword:", @"setReason:", @"setSecurityCode:", @"setSecondFactorCode:", @"_identifier"], error) ||
        !Require(controller, @[@"authenticateWithContext:completion:"], error)) return nil;
    if (provider) {
    TVAppleAuthTicket *prepared = [TVAppleAuthTicket new];
    [provider prepareForAuthentication:^(NSError *failure) { [prepared resolve:@{ @"ok":@(failure == nil) }]; }];
    if (![prepared wait:30] || ![prepared.value[@"ok"] boolValue]) {
        *error = TVAppleError(TVAppleErrorVerificationCode, @"Verification code provider is not ready."); return nil;
    }
    }
    TVAppleChallengeState *state = [TVAppleChallengeState new]; state.provider = provider;
    objc_setAssociatedObject(context, &ChallengeKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSString *reason = [@"Apple module account sign-in " stringByAppendingString:NSUUID.UUID.UUIDString];
    [context setUsername:appleID]; [context _setPassword:password]; [context setReason:reason];
    NSString *identifier = [[context _identifier] description];
    if (!identifier.length) { *error = TVAppleError(TVAppleErrorUnsupported, @"Authentication context has no request identifier."); return nil; }
    @synchronized (ContextRegistry) { ContextRegistry[identifier] = state; ContextRegistry[reason] = state; }
    TVAppleAuthTicket *ticket = [TVAppleAuthTicket new];
    [controller authenticateWithContext:context completion:^(NSDictionary *results, NSError *failure) {
        @synchronized (ContextRegistry) { [ContextRegistry removeObjectForKey:identifier]; [ContextRegistry removeObjectForKey:reason]; }
        [ticket resolve:@{ @"ok":@([results isKindOfClass:NSDictionary.class] && failure == nil),
                           @"native_results":[results isKindOfClass:NSDictionary.class] ? results : @{},
                           @"challenged":@([results isKindOfClass:NSDictionary.class] && [results[@"AKDidShowServerUI"] boolValue]),
                           @"has_error":@(failure != nil), @"error_code":@(failure.code),
                           @"metadata":ErrorMetadata(failure),
                           @"bad_password":@([failure.domain isEqual:@"AKAuthenticationError"] && failure.code == -7006) }];
    }];
    BOOL completed = [ticket wait:180];
    @synchronized (state) { state.closed = YES; state.suppliedCode = nil; [state.codeTicket resolve:@{ @"failed":@YES }]; state.codeTicket = nil; }
    if ([provider respondsToSelector:@selector(cancelAuthentication)]) [provider cancelAuthentication];
    if (completed) @synchronized (ContextRegistry) { [ContextRegistry removeObjectForKey:identifier]; [ContextRegistry removeObjectForKey:reason]; }
    @synchronized (state) { state.provider = nil; }
    [context _setPassword:nil]; [context setSecurityCode:nil]; [context setSecondFactorCode:nil];
    if (!completed) {
        *error = TVAppleError(TVAppleErrorOutcomeUnknown, @"AuthKit authentication timed out; inspect system state before another write."); return nil;
    }
    @synchronized (state) {
        if (state.failure) { *error = state.failure; return nil; }
        if (![ticket.value[@"ok"] boolValue]) {
            if ([ticket.value[@"native_results"] count] && [ticket.value[@"has_error"] boolValue]) {
                *error = TVAppleError(TVAppleErrorOutcomeUnknown, @"AuthKit returned contradictory results and an error."); return nil;
            }
            if (![ticket.value[@"has_error"] boolValue]) {
                *error = TVAppleError(TVAppleErrorOutcomeUnknown, @"AuthKit returned neither a result nor an error."); return nil;
            }
            *error = TVAppleError(TVAppleErrorAuthenticationFailed, [ticket.value[@"bad_password"] boolValue] ? @"Apple rejected the password." :
                [NSString stringWithFormat:@"AuthKit authentication failed (%@; code challenges %lu).",
                    ticket.value[@"metadata"], (unsigned long)state.requests]); return nil;
        }
        if (requireChallenge && !state.requests && ![ticket.value[@"challenged"] boolValue]) {
            *error = TVAppleError(TVAppleErrorVerificationCode, @"AuthKit returned cached identity without establishing two-factor trust."); return nil;
        }
    }
    return ticket.value[@"native_results"];
}

BOOL TVAppleNativeEstablishTrust(NSString *appleID, NSString *password, id<TVAppleVerificationCodeProvider> provider, NSError **error) {
    return TVAppleNativeAuthenticate(appleID, password, provider, YES, error) != nil;
}
