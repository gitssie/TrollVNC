// Independent implementation: capture BulletinBoard events without network work in SpringBoard's callback.
#import <Foundation/Foundation.h>
#import "../src/NotificationPaths.h"
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <arpa/inet.h>
#include <stdatomic.h>
#include <objc/runtime.h>

@interface NSObject (TVNCBulletinFields)
- (NSString *)sectionID;
- (NSString *)bulletinID;
- (NSDate *)date;
- (id)content;
- (NSString *)title;
- (NSString *)subtitle;
- (NSString *)message;
@end
static dispatch_queue_t tvCaptureQueue;
static NSMutableArray *tvItems;
static NSString *tvEpoch;
static uint64_t tvRevision;
static atomic_uint tvQueued;
static dispatch_source_t tvListener;

static NSString *tvText(id value, NSUInteger bytes) {
    if (![value isKindOfClass:NSString.class]) return @"";
    NSString *bounded = value;
    if (bounded.length > bytes) {
        NSRange last = [bounded rangeOfComposedCharacterSequenceAtIndex:bytes];
        bounded = [bounded substringToIndex:last.location];
    }
    NSMutableString *text = [bounded mutableCopy];
    // Bound UTF-8 bytes, preserve composed characters.
    while ([text lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > bytes && text.length)
        [text deleteCharactersInRange:[text rangeOfComposedCharacterSequenceAtIndex:text.length - 1]];
    return text;
}
static void tvCapture(id bulletin) {
    if (!tvCaptureQueue) return;
    if (atomic_fetch_add(&tvQueued, 1) >= 128) {
        atomic_fetch_sub(&tvQueued, 1); return;
    }
    NSDictionary *item = nil;
    @try {
        id content = [bulletin respondsToSelector:@selector(content)] ? [bulletin content] : nil;
        NSString *source = tvText([bulletin sectionID], 255);
        NSString *identifier = tvText([bulletin bulletinID], 200);
        NSString *title = tvText([content title], 1024);
        NSString *subtitle = tvText([content subtitle], 1024);
        NSString *message = tvText([content message], 4096);
        NSDate *date = [bulletin date];
        if (identifier.length && (title.length || subtitle.length || message.length)) {
            item = @{@"id":[NSString stringWithFormat:@"%@:%@", source, identifier],
                @"source":source, @"title":title, @"subtitle":subtitle, @"message":message,
                @"timestamp":@((long long)([date isKindOfClass:NSDate.class] ? date.timeIntervalSince1970 : NSDate.date.timeIntervalSince1970))};
        }
    } @catch (NSException *exception) { (void)exception; }
    if (!item) { atomic_fetch_sub(&tvQueued, 1); return; }
    dispatch_async(tvCaptureQueue, ^{
        @autoreleasepool {
            NSUInteger old = [tvItems indexOfObjectPassingTest:^BOOL(NSDictionary *existing, NSUInteger index, BOOL *stop) {
                (void)index; (void)stop; return [existing[@"id"] isEqual:item[@"id"]];
            }];
            if (old != NSNotFound && [tvItems[old] isEqual:item]) { atomic_fetch_sub(&tvQueued, 1); return; }
            if (old != NSNotFound) [tvItems removeObjectAtIndex:old];
            [tvItems insertObject:item atIndex:0];
            if (tvItems.count > 100) [tvItems removeLastObject];
            tvRevision++;
            atomic_fetch_sub(&tvQueued, 1);
        }
    });
}

// Only root/mobile can connect. No TCP port, no distributed broadcast of notification text.
static void tvServe(int socket) {
    uid_t uid; gid_t gid;
    if (getpeereid(socket, &uid, &gid) != 0 || (uid != 0 && uid != getuid())) { close(socket); return; }
    struct timeval timeout = {0, 200000};
    setsockopt(socket, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
    int one = 1; setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
    NSDictionary *snapshot = @{@"revision":[NSString stringWithFormat:@"%@:%llu", tvEpoch, (unsigned long long)tvRevision], @"notifications":[tvItems copy]};
    NSData *body = [NSJSONSerialization dataWithJSONObject:snapshot options:0 error:nil];
    // JSON escaping can exceed raw UTF-8 field limits. Keep the newest entries within the wire budget.
    while (body.length > 768 * 1024 && tvItems.count) {
        [tvItems removeLastObject]; tvRevision++;
        snapshot = @{@"revision":[NSString stringWithFormat:@"%@:%llu", tvEpoch, (unsigned long long)tvRevision], @"notifications":[tvItems copy]};
        body = [NSJSONSerialization dataWithJSONObject:snapshot options:0 error:nil];
    }
    if (body && body.length <= 768 * 1024) {
        uint32_t size = htonl((uint32_t)body.length);
        NSMutableData *packet = [NSMutableData dataWithBytes:&size length:4]; [packet appendData:body];
        const char *bytes = (const char *)packet.bytes; NSUInteger offset = 0;
        while (offset < packet.length) { ssize_t count = write(socket, bytes + offset, packet.length - offset); if (count <= 0) break; offset += count; }
    }
    close(socket);
}
static void tvStart(void) {
    NSString *directory = tvNotificationDirectory();
    if (mkdir(directory.fileSystemRepresentation, 0700) != 0 && errno != EEXIST) return;
    struct stat directoryInfo;
    if (lstat(directory.fileSystemRepresentation, &directoryInfo) != 0 || !S_ISDIR(directoryInfo.st_mode)
        || directoryInfo.st_uid != getuid() || chmod(directory.fileSystemRepresentation, 0700) != 0) return;
    NSString *path = tvNotificationSocketPath();
    struct sockaddr_un address = {}; address.sun_family = AF_UNIX;
    if (strlen(path.fileSystemRepresentation) >= sizeof(address.sun_path)) return;
    strlcpy(address.sun_path, path.fileSystemRepresentation, sizeof(address.sun_path));
    struct stat previous;
    if (lstat(address.sun_path, &previous) == 0) {
        if (!S_ISSOCK(previous.st_mode) || previous.st_uid != getuid()) return;
        unlink(address.sun_path);
    }
    int fd = socket(AF_UNIX, SOCK_STREAM, 0); if (fd < 0) return;
    // The private parent directory protects the socket during bind/chmod without changing SpringBoard umask.
    int bound = bind(fd, (struct sockaddr *)&address, sizeof(address));
    if (bound != 0 || chmod(address.sun_path, 0600) != 0 || listen(fd, 4) != 0) { close(fd); return; }
    // On the first launch after upgrade, retire the old endpoint. Never remove
    // unknown files or follow a symlink. Notification payloads were never stored.
    NSString *legacyRoot = access("/rootfs/var/mobile", F_OK) == 0 ? @"/rootfs" : @"";
    NSString *legacyDirectory = [legacyRoot stringByAppendingString:@"/var/mobile/Library/Caches/com.82flex.trollvnc.notifications"];
    struct stat legacyInfo;
    if (lstat(legacyDirectory.fileSystemRepresentation, &legacyInfo) == 0
        && S_ISDIR(legacyInfo.st_mode) && legacyInfo.st_uid == getuid()) {
        NSString *legacySocket = [legacyDirectory stringByAppendingPathComponent:@"relay.sock"];
        if (lstat(legacySocket.fileSystemRepresentation, &legacyInfo) == 0
            && S_ISSOCK(legacyInfo.st_mode) && legacyInfo.st_uid == getuid()) unlink(legacySocket.fileSystemRepresentation);
        rmdir(legacyDirectory.fileSystemRepresentation);
    }
    fcntl(fd, F_SETFL, O_NONBLOCK);
    tvListener = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, fd, 0, tvCaptureQueue);
    dispatch_source_set_event_handler(tvListener, ^{
        // Limit each slot so the receiver cannot starve notification capture.
        for (int i = 0; i < 4; ++i) { int peer = accept(fd, NULL, NULL); if (peer < 0) break; tvServe(peer); }
    });
    dispatch_source_set_cancel_handler(tvListener, ^{ close(fd); });
    dispatch_resume(tvListener);
}

%hook BBServer
- (void)publishBulletin:(id)bulletin destinations:(unsigned long long)destinations {
    %orig;
    tvCapture(bulletin);
}
%end
%ctor {
    // Unknown signatures fail closed: no hook/socket means the capability stays unavailable.
    Method method = class_getInstanceMethod(NSClassFromString(@"BBServer"), @selector(publishBulletin:destinations:));
    if (!method || method_getNumberOfArguments(method) != 4) return;
    char resultType[8], bulletinType[8], destinationsType[8];
    method_getReturnType(method, resultType, sizeof(resultType));
    method_getArgumentType(method, 2, bulletinType, sizeof(bulletinType));
    method_getArgumentType(method, 3, destinationsType, sizeof(destinationsType));
    if (resultType[0] != 'v' || bulletinType[0] != '@' || destinationsType[0] != 'Q') return;
    tvCaptureQueue = dispatch_queue_create("com.82flex.trollvnc.notifications.capture", DISPATCH_QUEUE_SERIAL);
    tvItems = [NSMutableArray new]; tvEpoch = NSUUID.UUID.UUIDString;
    %init;
    dispatch_async(tvCaptureQueue, ^{ tvStart(); });
}
