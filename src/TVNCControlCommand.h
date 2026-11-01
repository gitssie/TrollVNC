// GPL-2.0-only.
#pragma once
#import <Foundation/Foundation.h>
#include <poll.h>
#include <sys/socket.h>
#include <errno.h>
#include <stdint.h>
#include <string.h>

// Accepted Darwin sockets may inherit O_NONBLOCK. Wait for command bytes even
// when accept runs before the client or SSH forwarding layer has sent them.
NS_INLINE size_t TVNCReadControlCommand(int fd, uint8_t *buffer, size_t capacity, int timeoutMS) {
    CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + timeoutMS / 1000.0;
    size_t used = 0;
    while (used < capacity) {
        int remaining = (int)((deadline - CFAbsoluteTimeGetCurrent()) * 1000);
        if (remaining <= 0) break;
        struct pollfd ready = {fd, POLLIN, 0};
        int polled = poll(&ready, 1, remaining);
        if (polled < 0 && errno == EINTR) continue;
        if (polled <= 0) break;
        ssize_t count = recv(fd, buffer + used, capacity - used, 0);
        if (count < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK)) continue;
        if (count <= 0) break;
        used += (size_t)count;
        if (memchr(buffer, '\n', used)) break;
    }
    return used;
}
