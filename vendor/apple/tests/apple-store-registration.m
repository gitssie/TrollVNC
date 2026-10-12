// Independent native registration bootstrap. No account creation or sign-in.
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <unistd.h>

static id Call(id object, NSString *name) {
    SEL selector=NSSelectorFromString(name);
    return [object respondsToSelector:selector] ? ((id(*)(id,SEL))objc_msgSend)(object,selector) : nil;
}
static BOOL Has(id object, NSArray *names) {
    for(NSString *name in names) if(![object respondsToSelector:NSSelectorFromString(name)]) return NO;
    return object!=nil;
}
static void Emit(NSDictionary *value) {
    NSData *data=[NSJSONSerialization dataWithJSONObject:value options:0 error:NULL];
    fwrite(data.bytes,1,data.length,stdout);fputc('\n',stdout);fflush(stdout);
}
static BOOL Wait(BOOL (^done)(void), NSTimeInterval seconds) {
    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:seconds];
    while(!done() && deadline.timeIntervalSinceNow>0)
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    return done();
}
static NSDictionary *Request(NSURL *url, NSString *bagKey, NSDictionary *parameters, NSString *ua, NSString *signature, BOOL nativeDefaults) {
    NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:35];
    [request setValue:ua forHTTPHeaderField:@"User-Agent"];
    if(signature)[request setValue:signature forHTTPHeaderField:@"X-Apple-ActionSignature"];
    id properties=[NSClassFromString(@"SSMutableURLRequestProperties") alloc];
    if(!Has(properties,@[@"initWithURLRequest:",@"setClientIdentifier:",@"setITunesStoreRequest:",@"setShouldSendSecureToken:",@"setShouldProcessProtocol:",@"setShouldDecodeResponse:"])) return nil;
    properties=((id(*)(id,SEL,id))objc_msgSend)(properties,NSSelectorFromString(@"initWithURLRequest:"),request);
    ((void(*)(id,SEL,id))objc_msgSend)(properties,NSSelectorFromString(@"setClientIdentifier:"),@"com.apple.AppStore");
    if(!nativeDefaults)for(NSString *name in @[@"setITunesStoreRequest:",@"setShouldSendSecureToken:",@"setShouldProcessProtocol:",@"setShouldDecodeResponse:"])
        ((void(*)(id,SEL,BOOL))objc_msgSend)(properties,NSSelectorFromString(name),[name isEqual:@"setITunesStoreRequest:"]);
    if(bagKey) {
        if(!Has(properties,@[@"setURL:",@"setURLBagKey:",@"setRequestParameters:"]))return nil;
        ((void(*)(id,SEL,id))objc_msgSend)(properties,NSSelectorFromString(@"setURL:"),nil);
        ((void(*)(id,SEL,id))objc_msgSend)(properties,NSSelectorFromString(@"setURLBagKey:"),bagKey);
        ((void(*)(id,SEL,id))objc_msgSend)(properties,NSSelectorFromString(@"setRequestParameters:"),parameters);
    }
    id operation=[NSClassFromString(@"SSURLConnectionRequest") alloc];
    if(!Has(operation,@[@"initWithRequestProperties:",@"setSendsResponseForHTTPFailures:",@"startWithConnectionResponseBlock:"]))return nil;
    operation=((id(*)(id,SEL,id))objc_msgSend)(operation,NSSelectorFromString(@"initWithRequestProperties:"),properties);
    ((void(*)(id,SEL,BOOL))objc_msgSend)(operation,NSSelectorFromString(@"setSendsResponseForHTTPFailures:"),YES);
    NSObject *lock=[NSObject new];__block BOOL done=NO,closed=NO;__block NSDictionary *result=nil;
    void (^completion)(id,NSError *)=^(id response,NSError *error){
        @synchronized(lock){if(closed)return;
            if(!error && Has(response,@[@"bodyData",@"URL",@"allHeaderFields",@"statusCode"])) {
                NSData *body=Call(response,@"bodyData");NSURL *actual=Call(response,@"URL");NSDictionary *headers=Call(response,@"allHeaderFields");
                if([body isKindOfClass:NSData.class] && body.length<=3000000 && [actual isKindOfClass:NSURL.class] && [headers isKindOfClass:NSDictionary.class])
                    result=@{@"status":@(((NSInteger(*)(id,SEL))objc_msgSend)(response,NSSelectorFromString(@"statusCode"))),@"body":body,@"url":actual,@"headers":headers};
            } else if(error)Emit(@{@"stage":@"native_transport_error",@"domain":error.domain,@"code":@(error.code)});
            done=YES;
        }
    };
    ((void(*)(id,SEL,id))objc_msgSend)(operation,NSSelectorFromString(@"startWithConnectionResponseBlock:"),completion);
    Wait(^BOOL{ @synchronized(lock){return done;} },45);
    @synchronized(lock){closed=YES;return result;}
}
static NSString *Header(NSDictionary *headers, NSString *name) {
    for(NSString *key in headers)if([key caseInsensitiveCompare:name]==NSOrderedSame && [headers[key]isKindOfClass:NSString.class])return headers[key];
    return nil;
}
static void Summary(NSString *stage, NSDictionary *response) {
    NSData *body=response[@"body"];NSURL *url=response[@"url"];
    id parsed=[NSJSONSerialization JSONObjectWithData:body options:0 error:NULL];
    if(!parsed)parsed=[NSPropertyListSerialization propertyListWithData:body options:NSPropertyListImmutable format:NULL error:NULL];
    NSMutableDictionary *value=[@{@"stage":stage,@"http_status":response[@"status"],@"host":url.host ?: @"",@"path":url.path ?: @"",@"body_bytes":@(body.length),@"content_type":Header(response[@"headers"],@"Content-Type") ?: @"",@"server_signature_present":@(Header(response[@"headers"],@"X-Apple-ActionSignature").length>0)} mutableCopy];
    if([parsed isKindOfClass:NSDictionary.class]) {
        value[@"response_keys"]=[[parsed allKeys]sortedArrayUsingSelector:@selector(compare:)];
        for(NSString *key in @[@"status",@"failureType",@"errorCode",@"hsa2Eligible",@"smsCodeEligible"])
            if([parsed[key]isKindOfClass:NSNumber.class] || [parsed[key]isKindOfClass:NSString.class])value[key]=parsed[key];
        NSDictionary *options=parsed[@"createAccountOptions"];
        if([options isKindOfClass:NSDictionary.class])for(NSString *key in @[@"hsa2Eligible",@"smsCodeEligible",@"hsa2IneligibleReason"])
            if([options[key]isKindOfClass:NSNumber.class] || [options[key]isKindOfClass:NSString.class])value[key]=options[key];
    }
    Emit(value);
    // Private stdout IPC; outer script saves the raw body locally, never prints it.
    Emit(@{@"stage":@"private_registration_response",@"phase":stage,@"url":url.absoluteString,@"headers":response[@"headers"],@"body_base64":[body base64EncodedStringWithOptions:0]});
}
int main(void) { @autoreleasepool {
    alarm(300);
    for(NSString *name in @[@"StoreServices",@"AppleMediaServices",@"StoreUI",@"StoreKitUI",@"iTunesStoreUI"])
        dlopen([NSString stringWithFormat:@"/System/Library/PrivateFrameworks/%@.framework/%@",name,name].UTF8String,RTLD_NOW);
    id client=[NSClassFromString(@"AMSProcessInfo") alloc];SEL init=NSSelectorFromString(@"initWithBundleIdentifier:");
    if(![client respondsToSelector:init])return 2;
    client=((id(*)(id,SEL,id))objc_msgSend)(client,init,@"com.apple.AppStore");
    Class agent=NSClassFromString(@"AMSUserAgent");SEL agentSelector=NSSelectorFromString(@"userAgentForProcessInfo:");
    if(![agent respondsToSelector:agentSelector])return 2;
    NSString *ua=((id(*)(id,SEL,id))objc_msgSend)(agent,agentSelector,client);
    id bag=Call(NSClassFromString(@"AMSPurchaseTask"),@"createBagForSubProfile");
    SEL bagURL=NSSelectorFromString(@"URLForKey:");if(![bag respondsToSelector:bagURL])return 2;
    id value=((id(*)(id,SEL,id))objc_msgSend)(bag,bagURL,@"signup");
    SEL resolve=NSSelectorFromString(@"valueWithError:");NSError *error=nil;
    if(![value respondsToSelector:resolve])return 2;
    NSURL *entry=((id(*)(id,SEL,NSError **))objc_msgSend)(value,resolve,&error);
    if(![entry isKindOfClass:NSURL.class] || !ua.length)return 3;
    NSString *guid=Call([NSClassFromString(@"SUScriptInterface") new],@"machineGUID");
    if(![guid isKindOfClass:NSString.class] || !guid.length)return 3;
    NSURLComponents *entryParts=[NSURLComponents componentsWithURL:entry resolvingAgainstBaseURL:NO];
    NSMutableArray *query=[entryParts.queryItems mutableCopy] ?: [NSMutableArray new];
    [query addObject:[NSURLQueryItem queryItemWithName:@"guid" value:guid]];
    entryParts.queryItems=query;entry=entryParts.URL;
    Emit(@{@"stage":@"native_registration_start",@"user_agent":ua,@"bag_profile":Call(NSClassFromString(@"AMSPurchaseTask"),@"bagSubProfile") ?: @"",@"entry_host":entry.host,@"entry_path":entry.path,@"account_creation_attempted":@NO});
    NSDictionary *unsignedEntry=Request(entry,nil,nil,ua,nil,NO);
    if(!unsignedEntry)return 7;
    Summary(@"native_entry_without_prime",unsignedEntry);
    id setup=[NSClassFromString(@"SUSetupMescalSessionOperation") alloc];
    if(!Has(setup,@[@"initWithURLRequestProperties:",@"setCompletionBlock:",@"mescalSession",@"error"]))return 4;
    setup=((id(*)(id,SEL,id))objc_msgSend)(setup,NSSelectorFromString(@"initWithURLRequestProperties:"),nil);
    __block BOOL done=NO;__block id sap=nil;__weak id weakSetup=setup;
    void (^completion)(void)=^{id strong=weakSetup;if(!Call(strong,@"error"))sap=Call(strong,@"mescalSession");done=YES;};
    ((void(*)(id,SEL,id))objc_msgSend)(setup,NSSelectorFromString(@"setCompletionBlock:"),completion);
    id queue=Call(NSClassFromString(@"ISOperationQueue"),@"mainQueue");
    if(![queue respondsToSelector:NSSelectorFromString(@"addOperation:")])return 4;
    ((void(*)(id,SEL,id))objc_msgSend)(queue,NSSelectorFromString(@"addOperation:"),setup);
    if(!Wait(^BOOL{return done;},60) || !Has(sap,@[@"primeForAccountCreationWithData:error:",@"verifyPrimeSignature:error:"]))return 5;
    NSData *prime=((id(*)(id,SEL,id,NSError **))objc_msgSend)(sap,NSSelectorFromString(@"primeForAccountCreationWithData:error:"),NSData.data,&error);
    if(!prime.length)return 6;
    Emit(@{@"stage":@"native_sap_ready",@"prime_bytes":@(prime.length)});
    NSDictionary *reply=Request(entry,nil,nil,ua,[prime base64EncodedStringWithOptions:0],NO);
    if(!reply)return 7;Summary(@"signup_prime",reply);
    NSString *signature=Header(reply[@"headers"],@"X-Apple-ActionSignature");
    NSData *proof=[[NSData alloc]initWithBase64EncodedString:signature ?: @"" options:0];
    BOOL verified=proof.length && ((BOOL(*)(id,SEL,id,NSError **))objc_msgSend)(sap,NSSelectorFromString(@"verifyPrimeSignature:error:"),proof,&error);
    Emit(@{@"stage":@"native_registration_proof",@"verified":@(verified)});
    NSDictionary *defaultEntry=Request(entry,@"signup",@{@"guid":guid},ua,[prime base64EncodedStringWithOptions:0],YES);
    if(!defaultEntry)return 9;Summary(@"signup_native_defaults",defaultEntry);
    id ssDevice=Call(NSClassFromString(@"SSDevice"),@"currentDevice");
    SEL legacyAgent=NSSelectorFromString(@"userAgentWithBundleIdentifier:version:");
    if([ssDevice respondsToSelector:legacyAgent]) {
        NSDictionary *info=[NSBundle bundleWithPath:@"/Applications/AppStore.app"].infoDictionary;
        NSString *version=info[@"CFBundleShortVersionString"];
        if(version.length) {
            NSString *ssUA=((id(*)(id,SEL,id,id))objc_msgSend)(ssDevice,legacyAgent,@"com.apple.AppStore",version);
            if([ssUA isKindOfClass:NSString.class] && ssUA.length && ![ssUA isEqual:ua]) {
                Emit(@{@"stage":@"native_store_services_agent",@"user_agent":ssUA});
                NSDictionary *ssEntry=Request(entry,@"signup",@{@"guid":guid},ssUA,[prime base64EncodedStringWithOptions:0],YES);
                if(!ssEntry)return 9;Summary(@"signup_store_services_agent",ssEntry);
            }
        }
    }
    NSDictionary *fields=Request(entry,@"createAccountFieldsSrv",@{@"iso3CountryCode":@"USA",@"guid":guid},ua,nil,NO);
    if(!fields)return 9;Summary(@"country_fields",fields);
    NSDictionary *options=Request(entry,@"createAccountOptionsSrv",@{@"iso3CountryCode":@"USA",@"guid":guid},ua,nil,NO);
    if(!options)return 9;Summary(@"creation_options",options);
    Emit(@{@"stage":@"native_registration_bootstrap_finished",@"entry_proof_verified":@(verified),@"account_creation_attempted":@NO,@"verification_code_sent":@NO});
    return verified ? 0 : 8;
} }
