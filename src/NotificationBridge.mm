#import "NotificationBridge.h"
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <unistd.h>
#include <arpa/inet.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <poll.h>
#include <errno.h>

static NSString *tvSocketPath(void) {
    return access("/rootfs/var/mobile", F_OK) == 0
        ? @"/rootfs/var/mobile/Library/Caches/com.82flex.trollvnc.notifications/relay.sock"
        : @"/var/mobile/Library/Caches/com.82flex.trollvnc.notifications/relay.sock";
}
static BOOL tvRead(int fd, void *bytes, size_t length) {
    char *out = (char *)bytes;
    while (length) { ssize_t n = read(fd, out, length); if (n <= 0) return NO; out += n; length -= n; }
    return YES;
}
NSDictionary *tvNotificationSnapshot(NSString **error) {
    struct sockaddr_un address = {}; address.sun_family = AF_UNIX;
    strlcpy(address.sun_path, tvSocketPath().fileSystemRepresentation, sizeof(address.sun_path));
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) { *error = @"Cannot create notification adapter connection"; return nil; }
    struct timeval timeout = {0, 250000};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    NSDictionary *result = nil;
    int flags = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, flags | O_NONBLOCK);
    int connected = connect(fd, (struct sockaddr *)&address, sizeof(address));
    if (connected < 0 && errno == EINPROGRESS) {
        struct pollfd wait = {fd, POLLOUT, 0};
        int failure = 0; socklen_t failureLength = sizeof(failure);
        if (poll(&wait, 1, 250) > 0 && getsockopt(fd, SOL_SOCKET, SO_ERROR, &failure, &failureLength) == 0 && !failure) connected = 0;
    }
    fcntl(fd, F_SETFL, flags);
    if (connected == 0) {
        uid_t uid; gid_t gid; pid_t pid = -1; socklen_t length = sizeof(pid);
        typedef int (*ProcPath)(int, void *, uint32_t);
        ProcPath processPath = (ProcPath)dlsym(RTLD_DEFAULT, "proc_pidpath");
        char executable[4096] = {};
        BOOL trusted = getpeereid(fd, &uid, &gid) == 0 && uid == 501
            && getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0
            && processPath && processPath(pid, executable, sizeof(executable)) > 0
            && [[NSString stringWithUTF8String:executable] hasSuffix:@"/SpringBoard.app/SpringBoard"];
        uint32_t size = 0;
        if (trusted && tvRead(fd, &size, sizeof(size))) {
            size = ntohl(size);
            if (size && size <= 768 * 1024) {
                NSMutableData *body = [NSMutableData dataWithLength:size];
                if (tvRead(fd, body.mutableBytes, size)) {
                    id value = [NSJSONSerialization JSONObjectWithData:body options:0 error:nil];
                    if ([value isKindOfClass:NSDictionary.class] && [value[@"revision"] isKindOfClass:NSString.class]
                        && [value[@"notifications"] isKindOfClass:NSArray.class] && [value[@"notifications"] count] <= 100) result = value;
                }
            }
        }
    }
    close(fd);
    if (!result) *error = @"SpringBoard notification adapter is unavailable";
    return result;
}
BOOL tvNotificationsAvailable(void) { NSString *error = nil; return tvNotificationSnapshot(&error) != nil; }
