#import "TVKaringNative.h"
#import <NetworkExtension/NetworkExtension.h>
#import <objc/message.h>
#include <sys/file.h>
#include <fcntl.h>
#include <unistd.h>
#include <mach-o/dyld.h>
#if defined(TVAS_ROOTHIDE)
#include <dlfcn.h>
#endif

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
#if defined(TVAS_ROOTHIDE)
static NSString *MappedPath(NSString *path, BOOL system) {
    // Resolve the library at runtime: Karing's identity cannot rely on dyld
    // environment overrides or RootHide's virtual .jbroot loader symlink.
    static void *library;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *location = [RuntimeRoot() stringByAppendingString:@"/usr/lib/libroothide.dylib"];
        library = dlopen(location.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
    });
    const char *(*jailbreak)(const char *) = library ? dlsym(library, "jbroot") : NULL;
    const char *(*root)(const char *) = library ? dlsym(library, "rootfs") : NULL;
    if (!jailbreak || !root) return nil;
    const char *converted = system ? root(path.fileSystemRepresentation) : path.fileSystemRepresentation;
    if (!converted) return nil;
    NSString *relative = @(converted);
    const char *mapped = jailbreak(relative.fileSystemRepresentation);
    return mapped ? @(mapped) : nil;
}
#endif
static NSString *Container(void) {
    NSFileManager *files = NSFileManager.defaultManager;
    NSURL *group = [files containerURLForSecurityApplicationGroupIdentifier:@"group.com.nebula.karing"];
    if (group && [files fileExistsAtPath:[group.path stringByAppendingPathComponent:@"service_core.json"]]) return group.path;
    NSMutableArray *roots = [@[@"/var/mobile/Containers/Shared/AppGroup", @"/rootfs/var/mobile/Containers/Shared/AppGroup"] mutableCopy];
#if defined(TVAS_ROOTHIDE)
    NSString *mapped = MappedPath(@"/var/mobile/Containers/Shared/AppGroup", YES);
    if (mapped) [roots insertObject:mapped atIndex:0];
#else
    NSString *runtime = RuntimeRoot();
    if (runtime.length) [roots insertObject:[runtime stringByAppendingString:@"/rootfs/var/mobile/Containers/Shared/AppGroup"] atIndex:0];
#endif
    for (NSString *root in roots) {
        for (NSString *entry in [files contentsOfDirectoryAtPath:root error:nil]) {
            NSString *path = [root stringByAppendingPathComponent:entry];
            NSDictionary *meta = [NSDictionary dictionaryWithContentsOfFile:[path stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"]];
            if ([meta[@"MCMMetadataIdentifier"] isEqual:@"group.com.nebula.karing"]) return path;
        }
    }
    return nil;
}
NSDictionary *TVKaringNativeRequest(NSString *operation) {
    if (!NSThread.isMainThread) return @{@"error":@"invalid_execution_context"};
#if defined(TVKARING_DIAGNOSTICS) && defined(TVAS_ROOTHIDE)
    if ([operation isEqual:@"diagnostics"]) {
        NSString *mapped = MappedPath(@"/var/mobile/Containers/Shared/AppGroup", YES);
        return @{@"runtimeRoot":RuntimeRoot(), @"mappedGroup":mapped ?: @"unavailable",
            @"entries":@([NSFileManager.defaultManager contentsOfDirectoryAtPath:mapped ?: @"/nonexistent" error:nil].count),
            @"libraryReadable":@(access([RuntimeRoot() stringByAppendingString:@"/usr/lib/libroothide.dylib"].fileSystemRepresentation, R_OK) == 0)};
    }
#endif
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
    if (![@[@"status", @"reload"] containsObject:operation]) return @{@"error":@"invalid_operation"};
    NETunnelProviderManager *manager = Manager();
    if (!manager) return @{@"error":@"karing_session_unavailable", @"outcome":@"not_sent"};
    if ([operation isEqual:@"status"]) return Message(manager, NO);
    // Serializes reloads across independently spawned helpers; no global write gate.
    NSString *lockPath = [RuntimeRoot() stringByAppendingString:@"/tmp/trollvnc-karing-reload.lock"];
#if defined(TVAS_ROOTHIDE)
    lockPath = MappedPath(@"/tmp/trollvnc-karing-reload.lock", NO);
    if (!lockPath) return @{@"error":@"path_conversion_unavailable", @"outcome":@"not_sent"};
#endif
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
