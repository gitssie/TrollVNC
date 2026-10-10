#import "TVNCAppleService.h"
#import "TVAppleServices.h"

static NSDictionary *Failure(NSString *code) { return @{ @"error": @{ @"code": code } }; }
static NSData *Wire(NSDictionary *value) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
    if (!json || json.length > 700000) json = [NSJSONSerialization dataWithJSONObject:Failure(@"response_too_large") options:0 error:nil];
    return [[NSString stringWithFormat:@"0;;%@\r\n", [json base64EncodedStringWithOptions:0]] dataUsingEncoding:NSUTF8StringEncoding];
}
static BOOL Fields(NSDictionary *d, NSArray<NSString *> *keys) {
    if (![d isKindOfClass:NSDictionary.class] || d.count != keys.count) return NO;
    for (NSString *key in keys) {
        id v = d[key];
        if (![v isKindOfClass:NSString.class] || ![v length] || [v length] > 4096) return NO;
    }
    return YES;
}
static NSString *AppleID(NSString *value) {
    return [[value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] lowercaseString];
}
static BOOL ValidCode(NSString *value) {
    return value.length == 6 && [value rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789"] invertedSet]].location == NSNotFound;
}
static NSDictionary *Methods(void) {
    return @{@"queryState": @[], @"queryAccountState": @[],
        @"signInAppStore": @[@"apple_id", @"password"],
        @"signOutAppStore": @[@"apple_id"],
        @"enableICloud": @[@"apple_id", @"password", @"device_passcode"],
        @"signOutAppleID": @[@"apple_id", @"local_data_policy"],
        @"signOutICloud": @[@"apple_id", @"local_data_policy"],
        @"disableFindMy": @[@"apple_id", @"password"],
        @"queryName": @[@"apple_id"], @"queryEmail": @[@"apple_id"],
        @"setName": @[@"apple_id", @"first_name", @"last_name"],
        @"beginAddingContactEmail": @[@"apple_id", @"email"],
        @"verifyContactEmail": @[@"apple_id", @"challenge_id", @"code"],
        @"setForwardingEmail": @[@"apple_id", @"email"],
        @"querySignInWithAppleApps": @[@"apple_id"],
        @"stopUsingAppleID": @[@"apple_id", @"bundle_id"],
        @"queryICloudDevices": @[@"apple_id"], @"removeOtherICloudDevices": @[@"apple_id"]};
}
@implementation TVNCAppleService {
    TVAppleServices *_services;
    NSMutableDictionary<NSString *, NSMutableDictionary *> *_operations;
    NSMutableDictionary<NSString *, NSNumber *> *_finished;
    NSMutableSet<NSString *> *_active;
    NSMutableDictionary<NSString *, TVAppleManualCodeProvider *> *_providers;
    NSMutableDictionary<NSString *, NSString *> *_domains;
    BOOL _stopped;
    NSString *_emailChallenge;
    NSString *_emailAppleID;
    NSTimeInterval _emailDeadline;
}
- (instancetype)init { return [self initWithServices:[TVAppleServices new]]; }
- (instancetype)initWithServices:(TVAppleServices *)services {
    if ((self = [super init])) { _services = services; _operations = [NSMutableDictionary new]; _finished = [NSMutableDictionary new]; _active = [NSMutableSet new]; _providers = [NSMutableDictionary new]; _domains = [NSMutableDictionary new]; }
    return self;
}
- (void)prune {
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    if (_emailChallenge && now >= _emailDeadline) { _emailChallenge = nil; _emailAppleID = nil; }
    for (NSString *key in _finished.allKeys) if (now - _finished[key].doubleValue > 600) {
        [_finished removeObjectForKey:key]; [_operations removeObjectForKey:key];
    }
}
- (NSDictionary *)request:(NSDictionary *)request {
    @synchronized (self) {
        [self prune];
        NSString *action = request[@"action"];
        if ([action isEqual:@"invoke"]) {
            if (request.count != 3 || ![request[@"method"] isKindOfClass:NSString.class]) return Failure(@"invalid_request");
            NSString *method = request[@"method"];
            NSDictionary *params = request[@"params"];
            NSArray *required = Methods()[method];
            if (!required || !Fields(params, required)) return Failure(@"invalid_request");
            if (params[@"local_data_policy"] && ![@[@"remove", @"keep"] containsObject:params[@"local_data_policy"]]) return Failure(@"invalid_request");
            if ([method isEqual:@"verifyContactEmail"] && !ValidCode(params[@"code"])) return Failure(@"invalid_request");
            if (_stopped) return Failure(@"service_stopping");
            NSString *domain = method;
            if ([@[@"queryName", @"setName"] containsObject:method]) domain = @"name";
            if ([@[@"beginAddingContactEmail", @"verifyContactEmail", @"setForwardingEmail"] containsObject:method]) domain = @"email";
            if ([@[@"querySignInWithAppleApps", @"stopUsingAppleID"] containsObject:method]) domain = @"authorizations";
            if ([@[@"queryICloudDevices", @"removeOtherICloudDevices"] containsObject:method]) domain = @"devices";
            if ([@[@"signInAppStore", @"signOutAppStore"] containsObject:method]) domain = @"media";
            if (_domains[domain]) return Failure(@"busy");

            if ([method isEqual:@"verifyContactEmail"] &&
                (![_emailChallenge isEqual:params[@"challenge_id"]] || ![_emailAppleID isEqual:AppleID(params[@"apple_id"])]))
                return Failure(@"email_challenge_mismatch");
            // Do not evict a recently completed result before its documented expiry.
            NSUInteger capacity = 64;
            // Reserve the final slot for the separate email verification call.
            if ([method isEqual:@"beginAddingContactEmail"] || (_emailChallenge && ![method isEqual:@"verifyContactEmail"])) capacity = 63;
            if (_operations.count >= capacity) return Failure(@"result_capacity");
            if ([method isEqual:@"beginAddingContactEmail"]) { _emailChallenge=nil; _emailAppleID=nil; }
            NSString *identifier = NSUUID.UUID.UUIDString;
            [_active addObject:identifier];
            _domains[domain] = identifier;
            _operations[identifier] = [@{@"operation_id": identifier, @"method": method, @"status": @"running"} mutableCopy];
            TVAppleManualCodeProvider *provider = nil;
            if ([method isEqual:@"signInAppStore"] || [method isEqual:@"enableICloud"]) {
                __weak TVNCAppleService *weakSelf = self;
                provider = [[TVAppleManualCodeProvider alloc] initWithChallengeHandler:^(NSDictionary *challenge) {
                    TVNCAppleService *owner = weakSelf;
                    if (!owner) return;
                    @synchronized (owner) {
                        if (![owner->_active containsObject:identifier] || owner->_stopped) return;
                        owner->_operations[identifier][@"status"] = @"requires_verification_code";
                        owner->_operations[identifier][@"challenge"] = challenge;
                    }
                }];
            }
            if (provider) _providers[identifier] = provider;
            // Retain the adapter until the native completion; disconnect does not
            // cancel a submitted mutation; its result remains independently queryable.
            NSString *emailOwner = [method isEqual:@"beginAddingContactEmail"] ? AppleID(params[@"apple_id"]) : nil;
            TVAppleCompletion completion = ^(NSDictionary *result, NSError *error) {
                @synchronized (self) {
                    if (![self->_active containsObject:identifier]) return;
                    NSMutableDictionary *op = self->_operations[identifier];
                    op[@"status"] = @"completed";
                    [op removeObjectForKey:@"challenge"];
                    if (result) op[@"result"] = result;
                    if ([method isEqual:@"beginAddingContactEmail"] && [result[@"outcome"] isEqual:@"requires_email_verification"]) {
                        self->_emailChallenge = result[@"challenge_id"];
                        self->_emailAppleID = emailOwner;
                        self->_emailDeadline = NSProcessInfo.processInfo.systemUptime + 300;
                    }
                    if (([method isEqual:@"verifyContactEmail"] || [method isEqual:@"beginAddingContactEmail"]) && !error && [result[@"outcome"] isEqual:@"succeeded"]) {
                        self->_emailChallenge = nil; self->_emailAppleID = nil;
                    }
                    if (error) {
                        NSMutableDictionary *details = [@{@"domain": error.domain, @"code": @(error.code)} mutableCopy];
                        NSString *message = TVAppleDiagnosticMessage(error);
                        if (message.length) details[@"message"] = message;
                        op[@"error"] = details;
                    }
                    if (!result && !error) op[@"error"] = @{@"code": @"missing_result"};
                    self->_finished[identifier] = @(NSProcessInfo.processInfo.systemUptime);
                    [self->_active removeObject:identifier]; [self->_providers removeObjectForKey:identifier];
                    [self->_domains removeObjectForKey:domain];
                }
            };
            @try { [self invoke:method params:params provider:provider completion:completion]; }
            @catch (__unused NSException *exception) {
                // Never export exception reasons containing input. Fail closed:
                // an exception does not prove a native write was never submitted.
                completion(nil, [NSError errorWithDomain:TVAppleErrorDomain code:TVAppleErrorOutcomeUnknown userInfo:nil]);
            }
            return [_operations[identifier] copy];
        }
        if (![action isKindOfClass:NSString.class] || ![request[@"operation_id"] isKindOfClass:NSString.class]) return Failure(@"invalid_request");
        NSString *identifier = request[@"operation_id"];
        NSMutableDictionary *op = _operations[identifier];
        if ([action isEqual:@"result"]) return request.count == 2 ? (op ? [op copy] : Failure(@"operation_unavailable")) : Failure(@"invalid_request");
        if (![@[@"submit_code", @"cancel_challenge"] containsObject:action]) return Failure(@"invalid_request");
        NSArray *keys = [action isEqual:@"submit_code"] ? @[@"action", @"operation_id", @"challenge_id", @"code"] : @[@"action", @"operation_id", @"challenge_id"];
        if (!Fields(request, keys)) return Failure(@"invalid_request");
        TVAppleManualCodeProvider *provider = _providers[identifier];
        if (_stopped || ![_active containsObject:identifier] || !provider || ![op[@"status"] isEqual:@"requires_verification_code"] || ![op[@"challenge"][@"challenge_id"] isEqual:request[@"challenge_id"]]) return Failure(@"challenge_unavailable");
        NSError *error = nil;
        BOOL accepted = [action isEqual:@"submit_code"] ? [provider submitCode:request[@"code"] forChallengeID:request[@"challenge_id"] error:&error] : [provider cancelChallengeID:request[@"challenge_id"] error:&error];
        if (!accepted) return Failure(@"code_rejected");
        if ([_active containsObject:identifier]) { op[@"status"] = @"running"; [op removeObjectForKey:@"challenge"]; }
        return @{@"operation_id": identifier, @"accepted": @YES};
    }
}
- (void)invoke:(NSString *)m params:(NSDictionary *)p provider:(TVAppleManualCodeProvider *)provider completion:(TVAppleCompletion)c {
    NSString *a = p[@"apple_id"];
    TVAppleLocalDataPolicy policy = [p[@"local_data_policy"] isEqual:@"keep"] ? TVAppleLocalDataKeep : TVAppleLocalDataRemove;
    if ([m isEqual:@"queryAccountState"]) [_services queryAccountState:c];
    else if ([m isEqual:@"queryState"]) [_services queryState:c];
    else if ([m isEqual:@"signInAppStore"]) [_services signInAppStoreAppleID:a password:p[@"password"] verificationCodeProvider:provider completion:c];
    else if ([m isEqual:@"enableICloud"]) [_services enableICloudAppleID:a password:p[@"password"] devicePasscode:p[@"device_passcode"] verificationCodeProvider:provider completion:c];
    else if ([m isEqual:@"signOutAppStore"]) [_services signOutAppStoreAppleID:a completion:c];
    else if ([m isEqual:@"signOutAppleID"]) [_services signOutAppleID:a localDataPolicy:policy completion:c];
    else if ([m isEqual:@"signOutICloud"]) [_services signOutICloudAppleID:a localDataPolicy:policy completion:c];
    else if ([m isEqual:@"disableFindMy"]) [_services disableFindMyAppleID:a password:p[@"password"] completion:c];
    else if ([m isEqual:@"queryName"]) [_services queryAppleIDNameSettings:a completion:c];
    else if ([m isEqual:@"queryEmail"]) [_services queryAppleIDEmailSettings:a completion:c];
    else if ([m isEqual:@"setName"]) [_services setAppleIDFirstName:p[@"first_name"] lastName:p[@"last_name"] appleID:a completion:c];
    else if ([m isEqual:@"beginAddingContactEmail"]) [_services beginAddingContactEmail:p[@"email"] appleID:a completion:c];
    else if ([m isEqual:@"verifyContactEmail"]) [_services verifyContactEmailChallenge:p[@"challenge_id"] code:p[@"code"] appleID:a completion:c];
    else if ([m isEqual:@"setForwardingEmail"]) [_services setSignInWithAppleForwardingEmail:p[@"email"] appleID:a completion:c];
    else if ([m isEqual:@"querySignInWithAppleApps"]) [_services querySignInWithAppleApps:a completion:c];
    else if ([m isEqual:@"stopUsingAppleID"]) [_services stopUsingAppleIDForBundleID:p[@"bundle_id"] appleID:a completion:c];
    else if ([m isEqual:@"queryICloudDevices"]) [_services queryICloudDevices:a completion:c];
    else if ([m isEqual:@"removeOtherICloudDevices"]) [_services removeOtherICloudDevices:a completion:c];
}
- (NSData *)handlePayload:(NSString *)payload {
    if (payload.length > 900000) return Wire(Failure(@"invalid_request"));
    NSData *data = [[NSData alloc] initWithBase64EncodedString:payload options:0];
    id request = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![request isKindOfClass:NSDictionary.class]) return Wire(Failure(@"invalid_request"));
    return Wire([self request:request]);
}
- (void)stop {
    @synchronized (self) { _stopped = YES; for (TVAppleManualCodeProvider *provider in _providers.allValues) [provider cancelAuthentication]; }
}
@end
