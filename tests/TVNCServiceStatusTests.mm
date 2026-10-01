// GPL-2.0-only.
#import "TVNCServiceStatus.h"
#include <cassert>
#include <thread>
#include <chrono>

static NSDictionary *fetch(NSString *response, int delayMilliseconds = 0) {
    int listener = socket(AF_INET, SOCK_STREAM, 0); assert(listener >= 0);
    struct sockaddr_in address = {0}; address.sin_len = sizeof(address);
    address.sin_family = AF_INET; address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    assert(bind(listener, (struct sockaddr *)&address, sizeof(address)) == 0);
    assert(listen(listener, 1) == 0);
    socklen_t length = sizeof(address); assert(getsockname(listener, (struct sockaddr *)&address, &length) == 0);
    NSData *bytes = [response dataUsingEncoding:NSUTF8StringEncoding];
    std::thread server([=] {
        @autoreleasepool {
            int client = accept(listener, nullptr, nullptr); assert(client >= 0);
            int yes = 1; setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
            char command[7]; size_t used = 0;
            while (used < sizeof(command)) { ssize_t n = recv(client, command + used, sizeof(command)-used, 0); if (n <= 0) break; used += n; }
            assert(used == sizeof(command) && !memcmp(command, "status\n", 7));
            std::this_thread::sleep_for(std::chrono::milliseconds(delayMilliseconds));
            for (NSUInteger i = 0; i < bytes.length; i += 7) {
                if (send(client, (const char *)bytes.bytes + i, MIN((NSUInteger)7, bytes.length - i), 0) < 0) break;
            }
            close(client); close(listener);
        }
    });
    CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
    NSDictionary *result = TVNCFetchServiceStatus(ntohs(address.sin_port));
    assert(CFAbsoluteTimeGetCurrent() - start < 2.5);
    server.join(); return result;
}
int main(void) {
    @autoreleasepool {
        assert(TVNCServicePortsValid(5901, 6000, 0));
        assert(!TVNCServicePortsValid(6000, 6000, 0));
        assert(!TVNCServicePortsValid(5901, 6000, 6000));
        assert(!TVNCServicePortsValid(46752, 6000, 0));
        assert(!TVNCServicePortsValid(5901, 46751, 0));
        assert(TVNCParseServicePort(@"6000", NO) == 6000);
        assert(TVNCParseServicePort(@"6000abc", NO) == -1);
        assert(TVNCParseServicePort(@"65536", NO) == -1);
        assert(TVNCParseServicePort(@"999999999999999999999999999", NO) == -1);
        assert(TVNCParseServicePort(@"٠", YES) == -1);
        assert(TVNCParseServicePort(@"0", YES) == 0);
        assert(TVNCSharedBindAllowsWireGuard(@"::1"));
        assert(TVNCSharedBindAllowsWireGuard(@"0.0.0.0"));
        assert(!TVNCSharedBindAllowsWireGuard(@"192.168.1.2"));
        assert([TVNCServiceSocket(@"fe80::1%en0", @6000) isEqualToString:@"[fe80::1%en0]:6000"]);
        assert(TVNCWiFiAddresses(@"::1", YES, NO).count == 0);
        assert(TVNCWiFiAddresses(@"127.0.0.1", YES, NO).count == 1);
        NSDictionary *status = @{@"VNCPort": @5901, @"ZXTouchPort": @6000, @"VNCRunning": @YES,
            @"ZXTouchRunning": @YES, @"VNCAcceptsIPv4": @YES, @"VNCAcceptsIPv6": @NO, @"WireGuardConfigured": @YES, @"WireGuardStarted": @NO,
            @"BindHost": @"", @"WireGuardAddress": @"", @"WireGuardError": @"invalid configuration"};
        NSString *json = [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:status options:0 error:nil] encoding:NSUTF8StringEncoding];
        assert([fetch([json stringByAppendingString:@"\n"]) isEqualToDictionary:status]);
        assert(!fetch(@"{}\n")); assert(!fetch(@"invalid\n"));
        assert(!fetch(json)); assert(!fetch([json stringByAppendingString:@"\n"], 2200));
        NSLog(@"Unified service status, fragmented transport, timeout and port validation tests passed");
    }
}
