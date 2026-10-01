// SPDX-License-Identifier: GPL-2.0-only
#import "ZXTouchTCPServer.h"
#include <arpa/inet.h>
#include <fcntl.h>
#include <netdb.h>
#include <sys/socket.h>
#include <unistd.h>
#include <atomic>

@implementation ZXTouchTCPServer {
    ZXTouchCommandHandler _handler;
    ZXTouchDisconnectHandler _disconnected;
    dispatch_source_t _acceptSource;
    NSMutableSet<NSNumber *> *_sockets;
    NSUInteger _nextClient;
    std::atomic<bool> _running;
    std::atomic<NSUInteger> _generation;
}
- (instancetype)initWithHandler:(ZXTouchCommandHandler)handler disconnected:(ZXTouchDisconnectHandler)disconnected {
    if ((self = [super init])) {
        _handler = [handler copy];
        _disconnected = [disconnected copy];
        _sockets = [NSMutableSet set];
    }
    return self;
}
- (BOOL)startOnHost:(NSString *)host port:(int)port error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"Start ZXTouch on main thread");
    if (_acceptSource || port < 1 || port > 65535) {
        if (error) *error = [NSError errorWithDomain:@"TrollVNC.ZXTouch" code:EINVAL userInfo:nil];
        return NO;
    }
    struct addrinfo hints = {}, *addresses = nullptr;
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_flags = AI_NUMERICHOST | AI_NUMERICSERV;
    int result = getaddrinfo(host.UTF8String, std::to_string(port).c_str(), &hints, &addresses);
    int fd = -1, savedError = EADDRNOTAVAIL;
    if (!result) {
        for (auto address = addresses; address; address = address->ai_next) {
            fd = socket(address->ai_family, SOCK_STREAM, 0);
            if (fd < 0) { savedError = errno; continue; }
            int yes = 1, no = 0;
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
            if (address->ai_family == AF_INET6) setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &no, sizeof(no));
            if (!bind(fd, address->ai_addr, address->ai_addrlen) && !listen(fd, 16) &&
                fcntl(fd, F_SETFL, O_NONBLOCK) != -1) break;
            savedError = errno;
            close(fd);
            fd = -1;
        }
        freeaddrinfo(addresses);
    }
    if (fd < 0) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:savedError userInfo:nil];
        return NO;
    }
    _running = true;
    ++_generation;
    _acceptSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, fd, 0, dispatch_get_main_queue());
    __weak ZXTouchTCPServer *weakSelf = self;
    dispatch_source_set_event_handler(_acceptSource, ^{ [weakSelf acceptConnections:fd]; });
    dispatch_source_set_cancel_handler(_acceptSource, ^{ close(fd); });
    dispatch_resume(_acceptSource);
    return YES;
}
- (void)acceptConnections:(int)listener {
    // Bound work on the main queue even under a continuous connection flood.
    for (int accepted = 0; accepted < 32; ++accepted) {
        int fd = accept(listener, nullptr, nullptr);
        if (fd < 0) { if (errno == EINTR) continue; return; }
        @synchronized(_sockets) {
            if (_sockets.count >= 16) { close(fd); continue; }
            [_sockets addObject:@(fd)];
        }
        // Accepted sockets are blocking on Darwin; enforce it explicitly.
        fcntl(fd, F_SETFL, 0);
        int yes = 1;
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
        struct timeval timeout = {60, 0};
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
        NSUInteger client = ++_nextClient;
        NSUInteger generation = _generation;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ [self serve:fd client:client generation:generation]; });
    }
}
static BOOL ZXWrite(int fd, NSData *data) {
    const char *bytes = (const char *)data.bytes;
    NSUInteger remaining = data.length;
    while (remaining) {
        ssize_t count = send(fd, bytes, remaining, 0);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) return NO;
        bytes += count;
        remaining -= count;
    }
    return YES;
}
- (void)serve:(int)fd client:(NSUInteger)client generation:(NSUInteger)generation {
    zxtouch::Framer framer;
    char bytes[4096];
    BOOL running = YES;
    while (running && _running && generation == _generation) {
        ssize_t count = recv(fd, bytes, sizeof(bytes), 0);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0 || !framer.append(bytes, count)) break;
        std::string line;
        while (_running && generation == _generation && framer.next(line)) {
            @autoreleasepool {
                zxtouch::Command command;
                std::string error;
                NSData *response = nil;
                if (!zxtouch::parse(line, command, error)) {
                    // A touch client never reads a reply: close invalid touches
                    // rather than corrupting the next response in its stream.
                    if (command.task == 10) { running = NO; break; }
                    response = [[NSString stringWithFormat:@"-1;;%s\r\n", error.c_str()] dataUsingEncoding:NSUTF8StringEncoding];
                } else {
                    @try { response = _handler(command, client); }
                    @catch (NSException *exception) {
                        if (command.task == 10) { running = NO; break; }
                        response = [@"-1;;ZXTouch command failed\r\n" dataUsingEncoding:NSUTF8StringEncoding];
                    }
                }
                if (response && !ZXWrite(fd, response)) { running = NO; break; }
            }
        }
    }
    _disconnected(client);
    @synchronized(_sockets) {
        [_sockets removeObject:@(fd)];
        close(fd);
    }
}
- (void)stop {
    NSAssert(NSThread.isMainThread, @"Stop ZXTouch on main thread");
    _running = false;
    ++_generation;
    if (_acceptSource) { dispatch_source_cancel(_acceptSource); _acceptSource = nil; }
    @synchronized(_sockets) { for (NSNumber *socket in _sockets) shutdown(socket.intValue, SHUT_RDWR); }
}
@end
