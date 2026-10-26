#import "TVKaringNative.h"
#import <NetworkExtension/NetworkExtension.h>
#import <objc/message.h>
#include <sys/file.h>
#include <fcntl.h>
#include <unistd.h>
#include <mach-o/dyld.h>

@protocol TVKaringConfigurationLoading
- (void)loadConfigurationsWithCompletionQueue:(dispatch_queue_t)queue handler:(void (^)(NSArray *, NSError *))handler;
@end
@interface NEVPNConnection (TVKaringSession)
- (void)createSessionWithConfigurationIdentifier:(NSUUID *)identifier forceInfoFetch:(BOOL)force completionHandler:(void (^)(void))handler;
@end

static BOOL Wait(NSTimeInterval timeout, BOOL (^done)(void)) {
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + timeout;
    while (!done() && NSProcessInfo.processInfo.systemUptime < deadline)
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    return done();
}
static NETunnelProviderManager *Manager(void) {
    Class cls = NSClassFromString(@"NEConfigurationManager");
    SEL shared = NSSelectorFromString(@"sharedManagerForAllUsers");
    if (![cls respondsToSelector:shared]) return nil;
    id<TVKaringConfigurationLoading> loader = ((id (*)(id, SEL))objc_msgSend)(cls, shared);
    __block BOOL loaded = NO, ready = NO;
    __block NETunnelProviderManager *manager;
    [loader loadConfigurationsWithCompletionQueue:dispatch_get_main_queue() handler:^(NSArray *items, NSError *error) {
        if (!error) for (id item in items) {
            @try {
                if (![[item valueForKeyPath:@"VPN.protocol.providerBundleIdentifier"] isEqual:@"com.nebula.karing.karingService"]) continue;
                NETunnelProviderManager *candidate = [NETunnelProviderManager new];
                SEL setter = NSSelectorFromString(@"setConfiguration:");
                if (![candidate respondsToSelector:setter]) continue;
                NSUUID *identifier = [item valueForKey:@"identifier"];
                if (![identifier isKindOfClass:NSUUID.class]) continue;
                ((void (*)(id, SEL, id))objc_msgSend)(candidate, setter, item);
                [candidate setValue:@YES forKey:@"hasLoaded"];
                if (![candidate.connection respondsToSelector:@selector(createSessionWithConfigurationIdentifier:forceInfoFetch:completionHandler:)]) continue;
                manager = candidate;
                [candidate.connection createSessionWithConfigurationIdentifier:identifier forceInfoFetch:YES completionHandler:^{
                    dispatch_async(dispatch_get_main_queue(), ^{ ready = YES; });
                }];
                break;
            } @catch (__unused NSException *exception) { manager = nil; }
        }
        loaded = YES;
    }];
    if (!Wait(5, ^BOOL { return loaded; }) || !manager || !Wait(5, ^BOOL { return ready; })) return nil;
    // Session creation completion can precede initial status delivery.
    Wait(2, ^BOOL { return manager.connection.status != NEVPNStatusInvalid; });
    return manager;
}
static NSDictionary *Message(NETunnelProviderManager *manager, BOOL restart) {
    if (manager.connection.status != NEVPNStatusConnected)
        return @{@"error":@"vpn_not_connected", @"outcome":@"not_sent"};
    NSData *payload = [NSJSONSerialization dataWithJSONObject:@{@"messageId":restart ? @"restart" : @"clashiApiConnections",
        @"messageParams":restart ? @"" : @"true"} options:0 error:nil];
    __block BOOL replied = NO;
    __block NSData *response;
    NSError *error;
    BOOL sent = [(NETunnelProviderSession *)manager.connection sendProviderMessage:payload returnError:&error responseHandler:^(NSData *data) {
        dispatch_async(dispatch_get_main_queue(), ^{ response = data; replied = YES; });
    }];
    if (!sent || error) return @{@"error":@"ipc_send_failed", @"outcome":restart ? @"unknown" : @"failed"};
    if (!Wait(5, ^BOOL { return replied; })) return @{@"error":@"ipc_timeout", @"outcome":@"unknown"};
    if (restart && !response.length) return @{@"accepted":@YES};
    id json = response.length ? [NSJSONSerialization JSONObjectWithData:response options:0 error:nil] : nil;
    if (!restart && [json isKindOfClass:NSDictionary.class] && [json[@"connections"] isKindOfClass:NSArray.class]) return @{@"data":json};
    // Empty replies also occur when the caller identity is rejected by iOS.
    return @{@"error":restart ? @"reload_response_unrecognized" : @"ipc_unavailable", @"outcome":restart ? @"unknown" : @"failed"};
}
static NSString *RuntimeRoot(void) {
    uint32_t length = 0;
    _NSGetExecutablePath(NULL, &length);
    char *buffer = calloc(length, 1);
    if (!buffer) return @"";
    NSString *path = _NSGetExecutablePath(buffer, &length) == 0 ? @(buffer) : @"";
    free(buffer);
    path = path.stringByResolvingSymlinksInPath;
    NSRange usr = [path rangeOfString:@"/usr/" options:NSBackwardsSearch];
    return usr.location == NSNotFound ? @"" : [path substringToIndex:usr.location];
}
static NSString *Container(void) {
    NSFileManager *files = NSFileManager.defaultManager;
    NSURL *group = [files containerURLForSecurityApplicationGroupIdentifier:@"group.com.nebula.karing"];
    if (group && [files fileExistsAtPath:[group.path stringByAppendingPathComponent:@"service_core.json"]]) return group.path;
    NSArray *roots = @[@"/var/mobile/Containers/Shared/AppGroup"];
    for (NSString *root in roots) {
        for (NSString *entry in [files contentsOfDirectoryAtPath:root error:nil]) {
            NSString *path = [root stringByAppendingPathComponent:entry];
            NSDictionary *meta = [NSDictionary dictionaryWithContentsOfFile:[path stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"]];
            if ([meta[@"MCMMetadataIdentifier"] isEqual:@"group.com.nebula.karing"]) return path;
        }
    }
    return nil;
}
NSDictionary *TVKaringConnectionState(NSInteger status) {
    NSString *phase=@"unknown";
    switch(status){case NEVPNStatusInvalid:phase=@"invalid";break;case NEVPNStatusDisconnected:phase=@"disconnected";break;case NEVPNStatusConnecting:phase=@"connecting";break;case NEVPNStatusConnected:phase=@"connected";break;case NEVPNStatusReasserting:phase=@"reasserting";break;case NEVPNStatusDisconnecting:phase=@"disconnecting";break;}
    return @{@"vpn_connected":status==NEVPNStatusConnected ? @YES : @NO,@"status":phase,@"native_status":@(status)};
}
static NSDictionary *ConnectionState(NETunnelProviderManager *manager) {
    return TVKaringConnectionState(manager.connection.status);
}
static NSDictionary *SetConnection(NETunnelProviderManager *manager,BOOL connect) {
    NSInteger before=manager.connection.status;
    BOOL already=connect?before==NEVPNStatusConnected:before==NEVPNStatusDisconnected;
    if(already)return @{@"outcome":@"succeeded",@"already_in_state":@YES,@"data":ConnectionState(manager)};
    if(before==NEVPNStatusInvalid||before==NEVPNStatusDisconnecting)
        return @{@"error":@"vpn_state_not_ready",@"outcome":@"not_sent",@"data":ConnectionState(manager)};
    if(connect){
        NSString *container=Container();NSDictionary *config=container?TVKaringReadDocument(container,@"service_core.json"):nil;
        if(![config[@"data"]isKindOfClass:NSDictionary.class])return @{@"error":@"vpn_configuration_unavailable",@"outcome":@"not_sent"};
        if(!manager.enabled){
            __block BOOL saved=NO;__block NSError *failure=nil;manager.enabled=YES;
            [manager saveToPreferencesWithCompletionHandler:^(NSError *error){dispatch_async(dispatch_get_main_queue(),^{failure=error;saved=YES;});}];
            if(!Wait(6,^BOOL{return saved;})||failure)return @{@"error":@"vpn_enable_unconfirmed",@"outcome":@"unknown"};
        }
        if(before!=NEVPNStatusConnecting&&before!=NEVPNStatusReasserting){
            NSError *error=nil;if(![manager.connection startVPNTunnelAndReturnError:&error]||error)
                return @{@"error":@"vpn_start_rejected",@"outcome":@"unknown",@"data":ConnectionState(manager)};
        }
    }else [manager.connection stopVPNTunnel];
    BOOL verified=Wait(20,^BOOL{return manager.connection.status==(connect?NEVPNStatusConnected:NEVPNStatusDisconnected);});
    if(!verified)return @{@"error":@"vpn_state_unconfirmed",@"outcome":@"unknown",@"data":ConnectionState(manager)};
    return @{@"outcome":@"succeeded",@"data":ConnectionState(manager)};
}
NSDictionary *TVKaringNativeRequest(NSString *operation) {
    if (!NSThread.isMainThread) return @{@"error":@"invalid_execution_context"};
    if ([operation isEqual:@"config"] || [operation isEqual:@"profiles"]) {
        NSString *container = Container();
        if (!container) return @{@"error":@"karing_container_unavailable"};
        if ([operation isEqual:@"config"]) return TVKaringReadDocument(container, @"service_core.json");
        NSMutableDictionary *documents = [NSMutableDictionary dictionary];
        for (NSString *file in @[@"karing_subscribe.json", @"karing_subscribe_use.json", @"karing_setting.json"]) {
            NSDictionary *document = TVKaringReadDocument(container, file);
            if (document[@"error"]) return document;
            documents[file] = document[@"data"];
        }
        return @{@"data":documents};
    }
    if (![@[@"status", @"reload", @"connection", @"connect", @"disconnect"] containsObject:operation]) return @{@"error":@"invalid_operation"};
    NETunnelProviderManager *manager = Manager();
    if (!manager) return @{@"error":@"karing_session_unavailable", @"outcome":@"not_sent"};
    if ([operation isEqual:@"connection"]) return @{@"data":ConnectionState(manager)};
    if ([operation isEqual:@"connect"] || [operation isEqual:@"disconnect"]) return SetConnection(manager,[operation isEqual:@"connect"]);
    if ([operation isEqual:@"status"]) return Message(manager, NO);
    // Serializes reloads across independently spawned helpers; no global write gate.
    NSString *lockPath = [RuntimeRoot() stringByAppendingString:@"/tmp/trollvnc-karing-reload.lock"];
    int lock = open(lockPath.fileSystemRepresentation, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (lock < 0) return @{@"error":@"reload_lock_unavailable", @"outcome":@"not_sent"};
    if (flock(lock, LOCK_EX | LOCK_NB) != 0) { close(lock); return @{@"error":@"reload_busy", @"outcome":@"not_sent"}; }
    NSDictionary *result;
    @try {
        NSString *container = Container();
        NSDictionary *original = container ? TVKaringReadDocument(container, @"service_core.json") : nil;
        NSDictionary *before = Message(manager, NO);
        id started = before[@"data"][@"startTime"];
        if (!original[@"data"] || (![started isKindOfClass:NSString.class] && ![started isKindOfClass:NSNumber.class])) {
            result = @{@"error":@"reload_preflight_failed", @"outcome":@"not_sent"};
        } else {
            result = Message(manager, YES); // Exactly one mutation; never replay.
            if (result[@"accepted"]) {
                __block BOOL verified = NO;
                NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + 15;
                while (!verified && NSProcessInfo.processInfo.systemUptime < deadline) {
                    NSDate *tick = [NSDate dateWithTimeIntervalSinceNow:0.3];
                    [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:tick];
                    NSDictionary *after = Message(manager, NO);
                    id current = after[@"data"][@"startTime"];
                    verified = ([current isKindOfClass:NSString.class] || [current isKindOfClass:NSNumber.class]) && ![current isEqual:started];
                }
                BOOL sameConfig = [original[@"data"] isEqual:TVKaringReadDocument(container, @"service_core.json")[@"data"]];
                result = verified && sameConfig ? @{@"outcome":@"succeeded", @"reloadVerified":@YES, @"sameConfig":@YES} :
                    @{@"error":@"reload_unverified", @"outcome":@"unknown", @"reloadVerified":@NO};
            }
        }
    } @finally { flock(lock, LOCK_UN); close(lock); }
    return result;
}

NSDictionary *TVKaringNativeRequestWithParameters(NSString *operation, NSDictionary *parameters) {
    if (![operation isEqual:@"select"]) return parameters.count ? @{@"error":@"unexpected_parameters",@"outcome":@"not_sent"} : TVKaringNativeRequest(operation);
    if (!NSThread.isMainThread) return @{@"error":@"invalid_execution_context",@"outcome":@"not_sent"};
    NSString *container=Container();
    if (!container) return @{@"error":@"karing_container_unavailable",@"outcome":@"not_sent"};
    NSMutableDictionary *original=[NSMutableDictionary dictionary];
    for (NSString *filename in @[@"service_core.json",@"karing_setting.json",@"karing_subscribe_use.json",@"karing_subscribe.json"]) {
        NSDictionary *document=TVKaringReadDocument(container,filename);
        if (!document[@"data"]) return @{@"error":@"selection_documents_unavailable",@"outcome":@"not_sent"};
        original[filename]=document[@"data"];
    }
    NSDictionary *planned=TVKaringSelectionDocuments(original,parameters);
    if (planned[@"error"]) return planned;
    NETunnelProviderManager *manager=Manager();
    if (!manager || !Message(manager,NO)[@"data"]) return @{@"error":@"selection_core_unavailable",@"outcome":@"not_sent"};
    NSArray *filenames=@[@"karing_setting.json",@"karing_subscribe_use.json",@"service_core.json"];
    NSMutableArray *written=[NSMutableArray array];
    for (NSString *filename in filenames) {
        if (!TVKaringWriteDocument(container,filename,planned[@"data"][filename])) {
            BOOL restored=YES;
            for (NSString *changed in written.reverseObjectEnumerator)
                if (!TVKaringWriteDocument(container,changed,original[changed])) restored=NO;
            return @{@"error":@"selection_save_failed",@"outcome":@"unknown",@"previousConfigRestored":@(restored)};
        }
        [written addObject:filename];
    }
    // The same production reload verifies a new core startTime and unchanged
    // persisted configuration. Never replay a reload after an uncertain result.
    NSDictionary *reloaded=TVKaringNativeRequest(@"reload");
    if (![reloaded[@"outcome"] isEqual:@"succeeded"])
        return @{@"error":@"selection_reload_unconfirmed",@"outcome":@"unknown",@"configSaved":@YES};
    for (NSString *filename in filenames)
        if (![TVKaringReadDocument(container,filename)[@"data"] isEqual:planned[@"data"][filename]])
            return @{@"error":@"selection_configuration_changed",@"outcome":@"unknown",@"configSaved":@YES};
    return @{@"outcome":@"succeeded",@"reloadVerified":@YES,@"configSaved":@YES,@"selection":parameters};
}
