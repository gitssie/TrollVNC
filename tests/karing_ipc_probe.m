// Native device probe. Default is read-only discovery; IPC messages are fixed.
// Exit 3 means restart transport accepted, but actual reload remains unverified.
#import <Foundation/Foundation.h>
#import <NetworkExtension/NetworkExtension.h>
#import <objc/runtime.h>
#import <objc/message.h>

@protocol ProbeConfigurationLoading
- (void)loadConfigurationsWithCompletionQueue:(dispatch_queue_t)queue
                                      handler:(void (^)(NSArray *, NSError *))handler;
@end
@interface NEVPNConnection (ProbeReload)
- (void)createSessionWithConfigurationIdentifier:(NSUUID *)identifier
                                 forceInfoFetch:(BOOL)force
                              completionHandler:(void (^)(void))handler;
@end

static BOOL Wait(BOOL (^done)(void)) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:10];
    while (!done() && [deadline timeIntervalSinceNow] > 0) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                               beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    }
    return done();
}
static NSDictionary *ErrorSummary(NSError *error) {
    return error ? @{ @"domain":error.domain, @"code":@(error.code) } : @{};
}
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc == 2 && strcmp(argv[1], "--inspect") == 0) {
            NSMutableDictionary *classes = [NSMutableDictionary dictionary];
            for (NSString *name in @[@"NEConfigurationManager", @"NEVPNManager", @"NETunnelProviderManager", @"NEVPNConnection", @"NETunnelProviderSession"]) {
                Class cls = NSClassFromString(name);
                NSMutableArray *methods = [NSMutableArray array];
                for (NSUInteger kind = 0; kind < 2; kind++) {
                    unsigned count = 0;
                    Method *list = class_copyMethodList(kind ? object_getClass(cls) : cls, &count);
                    for (unsigned i = 0; i < count; i++) {
                        NSString *selector = NSStringFromSelector(method_getName(list[i]));
                        if ([selector rangeOfString:@"configuration" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                            [selector rangeOfString:@"session" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                            [selector rangeOfString:@"manager" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                            [selector rangeOfString:@"load" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                            [selector rangeOfString:@"init" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                            [selector rangeOfString:@"shared" options:NSCaseInsensitiveSearch].location != NSNotFound) {
                            [methods addObject:@{@"method":selector,@"type":@(method_getTypeEncoding(list[i])),@"class":@(kind != 0)}];
                        }
                    }
                    free(list);
                }
                classes[name] = methods;
            }
            NSData *out = [NSJSONSerialization dataWithJSONObject:classes options:NSJSONWritingSortedKeys error:nil];
            fwrite(out.bytes, 1, out.length, stdout); putchar('\n');
            return 0;
        }
        BOOL readMode = argc == 2 && strcmp(argv[1], "--ipc-read") == 0;
        BOOL restartMode = argc == 2 && strcmp(argv[1], "--restart-current") == 0;
        BOOL messageMode = readMode || restartMode;
        BOOL privateMode = messageMode || (argc == 2 && strcmp(argv[1], "--private") == 0);
        if (argc > 1 && !messageMode && !privateMode) return 2;
        __block BOOL complete = NO;
        __block NSArray<NETunnelProviderManager *> *managers;
        __block NSError *loadError;
        __block NSArray *configurations;
        if (privateMode) {
            Class cls = NSClassFromString(@"NEConfigurationManager");
            SEL shared = NSSelectorFromString(@"sharedManagerForAllUsers");
            if (!cls || ![cls respondsToSelector:shared]) return 2;
            id<ProbeConfigurationLoading> manager = ((id (*)(id, SEL))objc_msgSend)(cls, shared);
            [manager loadConfigurationsWithCompletionQueue:dispatch_get_main_queue()
                handler:^(NSArray *result, NSError *error) {
                    configurations = result; loadError = error;
                    NSMutableArray *wrapped = [NSMutableArray array];
                    for (id configuration in result) {
                        @try {
                            id protocol = [configuration valueForKeyPath:@"VPN.protocol"];
                            NSString *provider = [protocol valueForKey:@"providerBundleIdentifier"];
                            if (![provider isKindOfClass:NSString.class] || ![provider isEqualToString:@"com.nebula.karing.karingService"]) continue;
                            NETunnelProviderManager *wrapper = [NETunnelProviderManager new];
                            SEL setter = NSSelectorFromString(@"setConfiguration:");
                            if ([wrapper respondsToSelector:setter]) {
                                ((void (*)(id, SEL, id))objc_msgSend)(wrapper, setter, configuration);
                                [wrapper setValue:@YES forKey:@"hasLoaded"];
                                [wrapper.connection createSessionWithConfigurationIdentifier:
                                    [configuration valueForKey:@"identifier"] forceInfoFetch:YES
                                    completionHandler:^{ }];
                                [wrapped addObject:wrapper];
                            }
                        } @catch (__unused NSException *exception) {}
                    }
                    managers = wrapped; complete = YES;
                }];
        } else {
            [NETunnelProviderManager loadAllFromPreferencesWithCompletionHandler:
             ^(NSArray<NETunnelProviderManager *> *result, NSError *error) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    managers = result; loadError = error; complete = YES;
                });
            }];
        }
        NSMutableDictionary *summary = [NSMutableDictionary dictionary];
        summary[@"completed"] = @(Wait(^BOOL { return complete; }));
        summary[@"error"] = ErrorSummary(loadError);
        summary[@"managerCount"] = @(managers.count);
        if (privateMode && managers.count) {
            NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:2];
            while ([deadline timeIntervalSinceNow] > 0) {
                [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
            }
        }
        if (privateMode) summary[@"configurationCount"] = @(configurations.count);
        if (privateMode) {
            NSMutableArray *karingConfigurations = [NSMutableArray array];
            for (id configuration in configurations) {
                @try {
                    id protocol = [configuration valueForKeyPath:@"VPN.protocol"];
                    NSString *provider = [protocol valueForKey:@"providerBundleIdentifier"];
                    if ([provider isKindOfClass:NSString.class] && [provider isEqualToString:@"com.nebula.karing.karingService"]) {
                        [karingConfigurations addObject:@{@"provider":provider, @"identifier":[[configuration valueForKey:@"identifier"] UUIDString] ?: @""}];
                    }
                } @catch (__unused NSException *exception) {}
            }
            summary[@"karingConfigurations"] = karingConfigurations;
        }
        NSMutableArray *found = [NSMutableArray array];
        NETunnelProviderManager *selected;
        for (NETunnelProviderManager *manager in managers) {
            NETunnelProviderProtocol *protocol = (id)manager.protocolConfiguration;
            NSString *identifier = protocol.providerBundleIdentifier ?: @"";
            if (![identifier isEqualToString:@"com.nebula.karing.karingService"]) continue;
            [found addObject:@{ @"provider":identifier, @"status":@(manager.connection.status), @"enabled":@(manager.enabled) }];
            if (manager.connection.status == NEVPNStatusConnected) selected = manager;
        }
        summary[@"karing"] = found;
        if (messageMode && selected) {
            // Exact string-valued protocol verified in the installed LibVpnCore
            // ExtensionProvider: restart / clashiApiConnections (spelling intentional).
            NSDictionary *message = @{ @"messageId":restartMode ? @"restart" : @"clashiApiConnections",
                                       @"messageParams":restartMode ? @"" : @"true" };
            NSData *data = [NSJSONSerialization dataWithJSONObject:message options:0 error:nil];
            __block BOOL replied = NO;
            __block NSUInteger responseLength = 0;
            __block NSArray *responseKeys;
            __block id startTime;
            NSError *sendError;
            BOOL sent = [(NETunnelProviderSession *)selected.connection sendProviderMessage:data
                returnError:&sendError responseHandler:^(NSData *response) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        responseLength = response.length;
                        id json = response.length ? [NSJSONSerialization JSONObjectWithData:response options:0 error:nil] : nil;
                        if ([json isKindOfClass:NSDictionary.class]) {
                            responseKeys = [[json allKeys] sortedArrayUsingSelector:@selector(compare:)];
                            id value = json[@"startTime"];
                            if ([value isKindOfClass:NSNumber.class] || [value isKindOfClass:NSString.class]) startTime = value;
                        }
                        replied = YES;
                    });
                }];
            summary[@"sent"] = @(sent);
            summary[@"sendError"] = ErrorSummary(sendError);
            summary[@"replied"] = @(sent && Wait(^BOOL { return replied; }));
            // Do not log arbitrary provider responses or sensitive message payloads.
            summary[@"responseBytes"] = @(responseLength);
            if (responseKeys) summary[@"responseKeys"] = responseKeys;
            if (startTime) summary[@"providerStartTime"] = startTime;
            summary[@"operation"] = restartMode ? @"restart-current" : @"read";
            summary[@"statusAfter"] = @(selected.connection.status);
            if (restartMode) summary[@"reloadVerified"] = @NO;
            if (!sent || sendError || !replied || (readMode && ![responseKeys containsObject:@"connections"])) {
                NSData *output = [NSJSONSerialization dataWithJSONObject:summary options:NSJSONWritingSortedKeys error:nil];
                fwrite(output.bytes, 1, output.length, stdout); putchar('\n');
                return 1;
            }
        }
        NSData *output = [NSJSONSerialization dataWithJSONObject:summary options:NSJSONWritingSortedKeys error:nil];
        fwrite(output.bytes, 1, output.length, stdout); putchar('\n');
        if (restartMode && complete && !loadError && selected) return 3;
        return complete && !loadError && selected ? 0 : 1;
    }
}
