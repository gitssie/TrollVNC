#import "TVNCBindAddress.h"
#import "TVNCServiceSnapshot.h"
// Shared native UI helpers. GPL-2.0-only.
#pragma once
#import <Foundation/Foundation.h>
#import "Control.h"
#import <arpa/inet.h>
#import <errno.h>
#import <fcntl.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <poll.h>
#import <sys/socket.h>
#import <unistd.h>

NS_INLINE int TVNCParseServicePort(id value, BOOL allowZero) {
    if (![value isKindOfClass:NSString.class] && ![value isKindOfClass:NSNumber.class]) return -1;
    NSString *text = [value description];
    if (!text.length || [text rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"0123456789"].invertedSet].location != NSNotFound) return -1;
    long long number = text.longLongValue;
    return ((allowZero && number == 0) || (number >= 1024 && number <= 65535)) ? (int)number : -1;
}
NS_INLINE BOOL TVNCServicePortsValid(int vnc, int zx, int http) {
    if (vnc < 1024 || vnc > 65535 || zx < 1024 || zx > 65535 ||
        (http && (http < 1024 || http > 65535))) return NO;
    if (vnc == zx || (http && (http == vnc || http == zx))) return NO;
    return vnc != kTvAlivePort && vnc != kTvDefaultCtlPort && zx != kTvAlivePort &&
        zx != kTvDefaultCtlPort && http != kTvAlivePort && http != kTvDefaultCtlPort;
}
NS_INLINE BOOL TVNCSharedBindAllowsWireGuard(NSString *host) {
    NSString *bind = [host stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return TVNCIPv4BindAllowsWireGuard(bind);
}
// Call on a worker queue. One absolute deadline bounds connect and fragmented reads.
NS_INLINE NSDictionary *TVNCFetchServiceStatus(int port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return nil;
    fcntl(fd, F_SETFD, FD_CLOEXEC);
    fcntl(fd, F_SETFL, O_NONBLOCK);
    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
    struct sockaddr_in address = {0};
    address.sin_len = sizeof(address); address.sin_family = AF_INET;
    address.sin_port = htons((uint16_t)port); address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + 2;
    int result = connect(fd, (struct sockaddr *)&address, sizeof(address));
    BOOL connected = result == 0;
    if (!connected && errno == EINPROGRESS) {
        struct pollfd ready = {fd, POLLOUT, 0};
        if (poll(&ready, 1, 1000) > 0) {
            int error = 0; socklen_t length = sizeof(error);
            connected = getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0 && error == 0;
        }
    }
    if (!connected) { close(fd); return nil; }
    const char command[] = "status\n";
    size_t sent = 0;
    while (sent < sizeof(command) - 1) {
        int remaining = (int)((deadline - CFAbsoluteTimeGetCurrent()) * 1000);
        struct pollfd ready = {fd, POLLOUT, 0};
        if (remaining <= 0 || poll(&ready, 1, remaining) <= 0) break;
        ssize_t n = send(fd, command + sent, sizeof(command) - 1 - sent, 0);
        if (n > 0) sent += (size_t)n;
        else if (n < 0 && (errno == EINTR || errno == EAGAIN)) continue;
        else break;
    }
    NSMutableData *data = [NSMutableData data];
    BOOL complete = NO;
    while (sent == sizeof(command) - 1 && data.length < 16384) {
        int remaining = (int)((deadline - CFAbsoluteTimeGetCurrent()) * 1000);
        struct pollfd ready = {fd, POLLIN, 0};
        if (remaining <= 0 || poll(&ready, 1, remaining) <= 0) break;
        char buffer[1024]; ssize_t n = recv(fd, buffer, sizeof(buffer), 0);
        if (n > 0) {
            [data appendBytes:buffer length:(NSUInteger)n];
            if (memchr(buffer, '\n', (size_t)n)) { complete = YES; break; }
        } else if (n < 0 && (errno == EINTR || errno == EAGAIN)) continue;
        else break;
    }
    close(fd);
    if (!complete) return nil;
    id status = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![status isKindOfClass:NSDictionary.class]) return nil;
    return TVNCServiceSnapshotValid(status) ? status : nil;
}
NS_INLINE NSString *TVNCServiceSocket(NSString *address, NSNumber *port) {
    return [address containsString:@":"] ? [NSString stringWithFormat:@"[%@]:%@", address, port] : [NSString stringWithFormat:@"%@:%@", address, port];
}
