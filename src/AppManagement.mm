#import "AppManagement.h"
#import "AppManagementPolicy.h"
#import "ScreenUnlock.h"
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <TargetConditionals.h>
#include <rfb/rfb.h>
#include <arpa/inet.h>
#include <dlfcn.h>
#include <signal.h>
#include <sys/sysctl.h>
#include <unistd.h>
#include <limits.h>
#include <pthread.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <notify.h>

// Independent device-control v1. See rv/docs/app-control-protocol.md.
static const int TVAppEncoding = (int)0xC0A1A990;
static int tvAppEncodings[] = {TVAppEncoding, 0};
static dispatch_queue_t tvAppQueue;
static NSMutableDictionary *tvAppClients;
static rfbScreenInfoPtr tvAppScreen;
static pthread_mutex_t tvAppScreenMutex = PTHREAD_MUTEX_INITIALIZER;
static BOOL tvAppRegistered;
static int tvAppLockToken = -1;

@interface NSObject (TVAppSPI)
+ (id)defaultWorkspace;
- (NSArray *)allInstalledApplications;
+ (id)applicationProxyForIdentifier:(NSString *)identifier;
- (NSString *)applicationIdentifier;
- (NSString *)localizedName;
- (NSString *)bundleExecutable;
- (NSURL *)bundleURL;
- (BOOL)isInstalled;
- (BOOL)openApplicationWithBundleID:(NSString *)identifier;
+ (UIImage *)_applicationIconImageForBundleIdentifier:(NSString *)identifier format:(int)format scale:(CGFloat)scale;
@end

@interface TVAppClient : NSObject
@property BOOL enabled;
@property BOOL connected;
@property NSUInteger pending;
@property NSNumber *lastLocked;
@end
@implementation TVAppClient
@end

static BOOL tvAppValidID(NSString *identifier) {
    if (![identifier isKindOfClass:NSString.class] || identifier.length == 0 || identifier.length > 255) return NO;
    NSArray *parts = [identifier componentsSeparatedByString:@"."];
    if (parts.count < 2) return NO;
    NSCharacterSet *invalid = [[NSCharacterSet characterSetWithCharactersInString:
        @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-"] invertedSet];
    for (NSString *part in parts) if (part.length == 0 || [part rangeOfCharacterFromSet:invalid].location != NSNotFound) return NO;
    return YES;
}

static id tvAppWorkspace(void) {
    Class cls = NSClassFromString(@"LSApplicationWorkspace");
    return [cls respondsToSelector:@selector(defaultWorkspace)] ? [cls defaultWorkspace] : nil;
}

static id tvAppProxy(NSString *identifier) {
    Class cls = NSClassFromString(@"LSApplicationProxy");
    return [cls respondsToSelector:@selector(applicationProxyForIdentifier:)] ? [cls applicationProxyForIdentifier:identifier] : nil;
}

static NSDictionary *tvAppInfo(id proxy) {
    if (![proxy respondsToSelector:@selector(applicationIdentifier)] ||
        ![proxy respondsToSelector:@selector(isInstalled)] || ![proxy isInstalled] ||
        ![proxy respondsToSelector:@selector(bundleURL)] || ![proxy respondsToSelector:@selector(bundleExecutable)]) return nil;
    NSString *identifier = [proxy applicationIdentifier];
    NSURL *url = [proxy bundleURL];
    NSString *executable = [proxy bundleExecutable];
    if (!tvAppValidID(identifier) || !url.isFileURL || ![url.path.pathExtension.lowercaseString isEqualToString:@"app"] ||
        executable.length == 0 || [executable containsString:@"/"] || [executable isEqualToString:@"."] || [executable isEqualToString:@".."]) return nil;
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfURL:[url URLByAppendingPathComponent:@"Info.plist"]];
    if (!info) return nil;
    NSArray *tags = [info[@"SBAppTags"] isKindOfClass:NSArray.class] ? info[@"SBAppTags"] : @[];
    if ([tags containsObject:@"hidden"] || [tags containsObject:@"system-service"] || info[@"NSAppClip"] ||
        [url.path.lowercaseString containsString:@"placeholder"]) return nil;
    NSString *name = [proxy respondsToSelector:@selector(localizedName)] ? [proxy localizedName] : nil;
    if (name.length == 0) return nil;
    BOOL launch = [[NSFileManager defaultManager] isExecutableFileAtPath:[url.path stringByAppendingPathComponent:executable]];
    return @{@"bundle_id":identifier, @"name":name, @"can_launch":@(launch), @"can_terminate":@(launch && tvAppCanTerminate(identifier))};
}

typedef CFStringRef (*CopyForeground)(void);
static CopyForeground tvAppForegroundFunction(void) {
    static CopyForeground fn;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *handle = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_LAZY);
        if (handle) fn = (CopyForeground)dlsym(handle, "SBSCopyFrontmostApplicationDisplayIdentifier");
    });
    return fn;
}
static NSString *tvAppForeground(void) {
    CopyForeground fn = tvAppForegroundFunction();
    NSString *identifier = fn ? CFBridgingRelease(fn()) : nil;
    return tvAppValidID(identifier) ? identifier : nil;
}

typedef int (*TVProcPath)(int, void *, uint32_t);
static TVProcPath tvAppProcPath(void) {
    return (TVProcPath)dlsym(RTLD_DEFAULT, "proc_pidpath");
}

// Resolve a target by exact canonical executable path, never by killall/name alone.
static NSArray<NSDictionary *> *tvAppProcesses(id proxy, NSString **error) {
    TVProcPath pathFn = tvAppProcPath();
    NSString *executable = [proxy bundleExecutable];
    char expected[PATH_MAX];
    NSString *target = [[proxy bundleURL].path stringByAppendingPathComponent:executable];
    if (!pathFn || !realpath(target.fileSystemRepresentation, expected)) {
        *error = @"Cannot resolve the App executable";
        return nil;
    }
    int mib[] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
    NSMutableData *data = nil;
    size_t length = 0;
    BOOL read = NO;
    for (int attempt = 0; attempt < 3; ++attempt) {
        if (sysctl(mib, 4, NULL, &length, NULL, 0) != 0 || length > 16 * 1024 * 1024) break;
        length += 32 * sizeof(struct kinfo_proc);
        data = [NSMutableData dataWithLength:length];
        if (sysctl(mib, 4, data.mutableBytes, &length, NULL, 0) == 0) { read = YES; break; }
        if (errno != ENOMEM) break;
    }
    if (!read) { *error = @"Cannot enumerate App processes"; return nil; }
    NSMutableArray *matches = [NSMutableArray array];
    struct kinfo_proc *processes = (struct kinfo_proc *)data.mutableBytes;
    for (size_t i = 0; i < length / sizeof(struct kinfo_proc); ++i) {
        struct kinfo_proc *p = &processes[i];
        if (p->kp_proc.p_pid <= 1 || p->kp_proc.p_pid == getpid() ||
            !tvAppCanInspectProcess(p->kp_eproc.e_ucred.cr_uid, geteuid())) continue;
        // Names only narrow candidates; identity is established using the full path below.
        if (strncmp(p->kp_proc.p_comm, executable.UTF8String, MAXCOMLEN) != 0) continue;
        char actual[PATH_MAX], canonical[PATH_MAX];
        if (pathFn(p->kp_proc.p_pid, actual, sizeof(actual)) <= 0) {
            if (kill(p->kp_proc.p_pid, 0) == -1 && errno == ESRCH) continue;
            *error = @"Cannot verify the target process identity"; return nil;
        }
        if (!realpath(actual, canonical)) { *error = @"Cannot verify the target executable path"; return nil; }
        if (strcmp(expected, canonical) == 0) [matches addObject:@{@"pid":@(p->kp_proc.p_pid),
            @"seconds":@(p->kp_proc.p_starttime.tv_sec), @"micros":@(p->kp_proc.p_starttime.tv_usec)}];
    }
    return matches;
}

static BOOL tvAppSameProcess(NSDictionary *identity) {
    int mib[] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, [identity[@"pid"] intValue]};
    struct kinfo_proc info = {};
    size_t size = sizeof(info);
    return sysctl(mib, 4, &info, &size, NULL, 0) == 0 && size == sizeof(info) &&
        info.kp_proc.p_starttime.tv_sec == [identity[@"seconds"] longLongValue] &&
        info.kp_proc.p_starttime.tv_usec == [identity[@"micros"] longLongValue];
}

static BOOL tvAppTerminate(id proxy, NSString **error) {
    NSArray *processes = tvAppProcesses(proxy, error);
    if (!processes) return NO;
    for (NSDictionary *identity in processes) {
        if (tvAppSameProcess(identity) && kill([identity[@"pid"] intValue], SIGTERM) != 0 && errno != ESRCH) {
            *error = [NSString stringWithFormat:@"Cannot terminate App: %s", strerror(errno)]; return NO;
        }
    }
    for (int tick = 0; tick < 30; ++tick) {
        BOOL alive = NO;
        for (NSDictionary *identity in processes) {
            if (!tvAppSameProcess(identity)) continue;
            alive = YES;
            if (tick == 10 && kill([identity[@"pid"] intValue], SIGKILL) != 0 && errno != ESRCH) {
                *error = [NSString stringWithFormat:@"Cannot force terminate App: %s", strerror(errno)]; return NO;
            }
        }
        if (!alive) break;
        usleep(50000);
    }
    NSArray *remaining = tvAppProcesses(proxy, error);
    if (!remaining) return NO;
    if (remaining.count) { *error = @"App did not exit or was relaunched"; return NO; }
    return YES;
}

// UIKit work never holds a client reference while waiting indefinitely for the main thread.
// A delayed icon task owns only its result and can finish safely after a client disconnects.
static id tvAppMainRead(id (^work)(void), NSString **error) {
    if (NSThread.isMainThread) return work();
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block id result = nil;
    dispatch_async(dispatch_get_main_queue(), ^{
        @try { result = work(); } @catch (NSException *exception) { (void)exception; }
        dispatch_semaphore_signal(done);
    });
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC)) != 0) {
        *error = @"App icon service is busy"; return nil;
    }
    return result;
}

static NSDictionary *tvAppExecute(unsigned char op, NSDictionary *request, NSString **error) {
    if (op == 7) return tvScreenUnlockState(error);
    if (op == 8) return tvScreenUnlockPrepare(error);
    if (op == 10) return tvScreenLock(error);
    if (op == 1) {
        id workspace = tvAppWorkspace();
        if (![workspace respondsToSelector:@selector(allInstalledApplications)]) { *error = @"App enumeration is unavailable"; return nil; }
        NSArray *installed = [workspace allInstalledApplications];
        if (![installed isKindOfClass:NSArray.class] || installed.count == 0) { *error = @"Installed App list is unavailable"; return nil; }
        NSMutableArray *apps = [NSMutableArray array];
        for (id proxy in installed) {
            if (![proxy respondsToSelector:@selector(applicationIdentifier)] || ![proxy respondsToSelector:@selector(isInstalled)]) {
                *error = @"Installed App list is incomplete"; return nil;
            }
            NSDictionary *info = tvAppInfo(proxy);
            if (info) [apps addObject:info];
            if (apps.count > 4096) { *error = @"Installed App list is too large"; return nil; }
        }
        [apps sortUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
            return [left[@"name"] localizedCaseInsensitiveCompare:right[@"name"]];
        }];
        return @{@"apps":apps};
    }
    if (op == 5) return @{@"bundle_id":tvAppForeground() ?: NSNull.null};
    NSString *identifier = request[@"bundle_id"];
    if (!tvAppValidID(identifier)) { *error = @"Invalid App Bundle ID"; return nil; }
    id proxy = tvAppProxy(identifier);
    NSDictionary *info = tvAppInfo(proxy);
    if (!info || ![info[@"bundle_id"] isEqual:identifier]) { *error = @"App is not installed or unavailable"; return nil; }
    if (op == 6) {
        NSData *png = tvAppMainRead(^id{
            if (![UIImage respondsToSelector:@selector(_applicationIconImageForBundleIdentifier:format:scale:)]) return nil;
            UIImage *icon = [UIImage _applicationIconImageForBundleIdentifier:identifier format:2 scale:2.0];
            if (!icon) return nil;
            UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
            format.scale = 1;
            UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(64, 64) format:format];
            return [renderer PNGDataWithActions:^(UIGraphicsImageRendererContext *context) {
                (void)context; [icon drawInRect:CGRectMake(0, 0, 64, 64)];
            }];
        }, error);
        if (*error) return nil;
        if (!png) return @{@"png":NSNull.null};
        if (png.length > 256 * 1024) { *error = @"Cannot encode App icon"; return nil; }
        return @{@"png":[png base64EncodedStringWithOptions:0]};
    }
    if ((op == 3 || op == 4) && ![info[@"can_terminate"] boolValue]) { *error = @"This App is protected from termination"; return nil; }
    if ((op == 3 || op == 4) && !tvAppTerminate(proxy, error)) return nil;
    if (op == 2 || op == 4) {
        if (![info[@"can_launch"] boolValue]) { *error = @"App cannot be launched"; return nil; }
        id workspace = tvAppWorkspace();
        BOOL accepted = [workspace respondsToSelector:@selector(openApplicationWithBundleID:)] &&
            [workspace openApplicationWithBundleID:identifier];
        if (!accepted) { *error = @"iOS refused to open App (check lock state or frozen App policy)"; return nil; }
    }
    return @{@"bundle_id":identifier};
}

static BOOL tvAppWrite(rfbClientPtr cl, TVAppClient *state, unsigned char op, unsigned char status, uint32_t id, NSDictionary *payload) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    if (!json || json.length > 1024 * 1024) {
        status = 1;
        json = [NSJSONSerialization dataWithJSONObject:@{@"error":@"App response is too large or invalid"} options:0 error:nil];
    }
    unsigned char header[12] = {140, 1, op, status};
    uint32_t netID = htonl(id), length = htonl((uint32_t)json.length);
    memcpy(header + 4, &netID, 4); memcpy(header + 8, &length, 4);
    BOOL attempted = NO, ok = NO;
    // LibVNCServer can invoke close callbacks while holding sendMutex.
    // Never acquire it while holding the registry or per-client state lock.
    pthread_mutex_lock(&cl->sendMutex);
    @synchronized(state) {
        if (state.connected && (op == 0 || state.enabled) && cl->sock != RFB_INVALID_SOCKET) {
            attempted = YES;
            ok = rfbWriteExact(cl, (const char *)header, sizeof(header)) >= 0 &&
                rfbWriteExact(cl, (const char *)json.bytes, (int)json.length) >= 0;
        }
    }
    pthread_mutex_unlock(&cl->sendMutex);
    if (attempted && !ok) rfbCloseClient(cl);
    return ok;
}

// Hold screen lifetime separately from the client registry. The iterator owns
// live client references, and close callbacks never need the screen mutex.
static void tvAppPushLocked(void) {
    @autoreleasepool {
        pthread_mutex_lock(&tvAppScreenMutex);
        @try {
            if (!tvAppRegistered || !tvAppScreen) return;
            rfbClientIteratorPtr iterator = rfbGetClientIterator(tvAppScreen);
            BOOL read = NO, locked = NO;
            @try {
                rfbClientPtr cl;
                while ((cl = rfbClientIteratorNext(iterator))) {
                    TVAppClient *state;
                    @synchronized(tvAppClients) {
                        state = tvAppClients[[NSValue valueWithPointer:cl]];
                    }
                    if (!state) continue;
                    @synchronized(state) {
                        if (!state.connected || !state.enabled) continue;
                    }
                    if (!read) {
                        if (!tvScreenReadLocked(&locked)) break;
                        read = YES;
                    }
                    BOOL changed;
                    @synchronized(state) {
                        changed = !state.lastLocked || state.lastLocked.boolValue != locked;
                    }
                    if (changed && tvAppWrite(cl, state, 11, 0, 0, @{@"locked":@(locked)})) {
                        @synchronized(state) {
                            if (state.connected && state.enabled) state.lastLocked = @(locked);
                        }
                    }
                }
            } @finally {
                rfbReleaseClientIterator(iterator);
            }
        } @finally {
            pthread_mutex_unlock(&tvAppScreenMutex);
        }
    }
}

static rfbBool tvAppNew(rfbClientPtr cl, void **data) {
    TVAppClient *state = [TVAppClient new]; state.connected = YES;
    @synchronized(tvAppClients) {
        tvAppClients[[NSValue valueWithPointer:cl]] = state;
    }
    *data = (__bridge_retained void *)state;
    return TRUE;
}
static void tvAppClose(rfbClientPtr cl, void *data) {
    TVAppClient *state;
    @synchronized(tvAppClients) {
        NSValue *key = [NSValue valueWithPointer:cl];
        state = tvAppClients[key];
        // close callbacks may repeat or race; consume the retained data once.
        if (!state || (__bridge void *)state != data) return;
        [tvAppClients removeObjectForKey:key];
        @synchronized(state) { state.connected = NO; state.enabled = NO; }
    }
    TVAppClient *owned = (__bridge_transfer TVAppClient *)data;
    (void)owned;
    tvScreenUnlockClose(cl);
}
static rfbBool tvAppEnable(rfbClientPtr cl, void **data, int encoding) {
    TVAppClient *state;
    @synchronized(tvAppClients) {
        state = tvAppClients[[NSValue valueWithPointer:cl]];
        if (!state || (__bridge void *)state != *data) return FALSE;
    }
    if (encoding == 0) { @synchronized(state) { state.enabled = NO; state.lastLocked = nil; } return TRUE; }
    if (encoding != TVAppEncoding) return FALSE;
    BOOL launch = [tvAppWorkspace() respondsToSelector:@selector(openApplicationWithBundleID:)];
    BOOL terminate = tvAppProcPath() != NULL;
    BOOL ok = tvAppWrite(cl, state, 0, 0, 0, @{@"list":@([tvAppWorkspace() respondsToSelector:@selector(allInstalledApplications)]), @"launch":@(launch), @"terminate":@(terminate),
        @"restart":@(launch && terminate), @"foreground":@(tvAppForegroundFunction() != NULL),
        @"icons":@([UIImage respondsToSelector:@selector(_applicationIconImageForBundleIdentifier:format:scale:)]),
        @"unlock":@(tvScreenUnlockSupported()), @"lock":@(tvScreenLockSupported()), @"control":@(!cl->viewOnly)});
    if (ok) {
        @synchronized(state) {
            if (state.connected) { state.enabled = YES; state.lastLocked = nil; }
        }
        dispatch_async(tvAppQueue, ^{ tvAppPushLocked(); });
    }
    return ok;
}
static rfbBool tvAppMessage(rfbClientPtr cl, void *data, const rfbClientToServerMsg *message) {
    if (message->type != 139) return FALSE;
    @autoreleasepool {
        TVAppClient *state;
        @synchronized(tvAppClients) {
            state = tvAppClients[[NSValue valueWithPointer:cl]];
            if (!state || (__bridge void *)state != data) return TRUE;
        }
        unsigned char header[11];
        if (rfbReadExact(cl, (char *)header, sizeof(header)) <= 0) return TRUE;
        uint32_t id, length;
        memcpy(&id, header + 3, 4); memcpy(&length, header + 7, 4);
        id = ntohl(id); length = ntohl(length);
        unsigned char op = header[1];
        if (header[0] != 1 || op < 1 || op > 10 || header[2] != 0 || id == 0 || length > 4096) {
            rfbCloseClient(cl); return TRUE;
        }
        NSMutableData *payload = [NSMutableData dataWithLength:length];
        if (length && rfbReadExact(cl, (char *)payload.mutableBytes, (int)length) <= 0) return TRUE;
        NSDictionary *request = [NSJSONSerialization JSONObjectWithData:payload options:0 error:nil];
        if (![request isKindOfClass:NSDictionary.class]) {
            tvAppWrite(cl, state, op, 1, id, @{@"error":@"Invalid App request"}); return TRUE;
        }
        BOOL unavailable;
        @synchronized(state) {
            unavailable = !state.enabled || !state.connected || state.pending >= 8 || (cl->viewOnly && ((op >= 2 && op <= 4) || op >= 8));
            if (!unavailable) state.pending++;
        }
        if (unavailable) {
            tvAppWrite(cl, state, op, 1, id, @{@"error":@"App control is unavailable, read-only, or busy"}); return TRUE;
        }
        rfbIncrClientRef(cl);
        NSTimeInterval queuedAt = NSProcessInfo.processInfo.systemUptime;
        dispatch_async(tvAppQueue, ^{
            @autoreleasepool {
                @synchronized(state) {
                    if (!state.connected || !state.enabled || cl->sock == RFB_INVALID_SOCKET) {
                        state.pending--; rfbDecrClientRef(cl); return;
                    }
                }
                NSString *error = nil;
                NSDictionary *result = nil;
                @try {
                    if (NSProcessInfo.processInfo.systemUptime - queuedAt > 8.0) error = @"App request expired before execution";
                    else if (cl->viewOnly && ((op >= 2 && op <= 4) || op >= 8)) error = @"Device control is read-only";
                    else if (op == 9) {
                        NSNumber *digits = request[@"digits"];
                        if (![digits isKindOfClass:NSNumber.class] || [digits doubleValue] != [digits unsignedIntegerValue]) error = @"Invalid unlock input request";
                        else result = tvScreenUnlockArm(cl, [digits unsignedIntegerValue], &error);
                    }
                    else result = tvAppExecute(op, request, &error);
                } @catch (NSException *exception) {
                    error = [NSString stringWithFormat:@"App operation failed: %@", exception.name];
                }
                tvAppWrite(cl, state, op, result ? 0 : 1, id, result ?: @{@"error":error ?: @"App operation failed"});
                @synchronized(state) { state.pending--; }
                rfbDecrClientRef(cl);
            }
        });
    }
    return TRUE;
}

static rfbProtocolExtension tvAppExtension = {
    .newClient = tvAppNew, .pseudoEncodings = tvAppEncodings, .enablePseudoEncoding = tvAppEnable,
    .handleMessage = tvAppMessage, .close = tvAppClose,
};
void tvRegisterAppManagement(rfbScreenInfoPtr screen) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        tvAppQueue = dispatch_queue_create("com.82flex.trollvnc.apps", DISPATCH_QUEUE_SERIAL);
        tvAppClients = [NSMutableDictionary new];
    });
    pthread_mutex_lock(&tvAppScreenMutex);
    tvAppScreen = screen;
    tvAppRegistered = YES;
    pthread_mutex_unlock(&tvAppScreenMutex);
    if (tvAppLockToken < 0) {
        // The system notification is only a trigger; query actual lock status.
        // Also used by Appium WebDriverAgent's XCUIDevice+FBHelpers.
        if (notify_register_dispatch("com.apple.springboard.lockstate", &tvAppLockToken, tvAppQueue,
            ^(int token) { (void)token; tvAppPushLocked(); }) != NOTIFY_STATUS_OK) tvAppLockToken = -1;
    }
    rfbRegisterProtocolExtension(&tvAppExtension);
}
void tvUnregisterAppManagement(void) {
    if (tvAppLockToken >= 0) { notify_cancel(tvAppLockToken); tvAppLockToken = -1; }
    pthread_mutex_lock(&tvAppScreenMutex);
    tvAppRegistered = NO; tvAppScreen = NULL;
    pthread_mutex_unlock(&tvAppScreenMutex);
    rfbUnregisterProtocolExtension(&tvAppExtension);
}
