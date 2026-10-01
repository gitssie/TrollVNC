// GPL-2.0-only.
#import "TVNCServiceStatus.h"
#import "TVNCWireGuardConfig.h"
#include <cassert>
#include <climits>
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
int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc == 3 && [@(argv[1]) isEqualToString:@"--read-cache"]) {
            NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:@(argv[2])];
            NSDictionary *cached = TVNCReadServiceSnapshot(defaults);
            return [cached[@"LocalAddresses"] isEqual:@[@"127.0.0.1"]] &&
                [cached[@"VNCPort"] isEqual:@5901] && [cached[@"ZXTouchPort"] isEqual:@6000] ? 0 : 1;
        }
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
        assert([TVNCIPv4BindAddress(nil) isEqualToString:@"0.0.0.0"]);
        assert([TVNCIPv4BindAddress(@"::") isEqualToString:@"0.0.0.0"]);
        assert([TVNCIPv4BindAddress(@"::1") isEqualToString:@"127.0.0.1"]);
        assert(TVNCValidIPv4BindAddress(@"127.0.0.1"));
        assert(!TVNCValidIPv4BindAddress(@"fe80::1"));
        assert(!TVNCSharedBindAllowsWireGuard(@"192.168.1.2"));
        assert([TVNCServiceSocket(@"fe80::1%en0", @6000) isEqualToString:@"[fe80::1%en0]:6000"]);
        assert(TVNCWiFiAddresses(@"::1", YES, NO).count == 0);
        assert(TVNCWiFiAddresses(@"127.0.0.1", YES, NO).count == 1);
        assert(TVNCWGShouldStart(@{}, nil)); // Existing configurations stay enabled by default.
        assert(TVNCWGShouldStart(@{}, @YES));
        assert(!TVNCWGShouldStart(@{}, @NO));
        assert(!TVNCWGShouldStart(nil, @YES));
        NSDictionary *status = @{@"VNCPort": @5901, @"ZXTouchPort": @6000, @"VNCRunning": @YES,
            @"ZXTouchRunning": @YES, @"VNCAcceptsIPv4": @YES, @"VNCAcceptsIPv6": @NO, @"WireGuardConfigured": @YES,
            @"WireGuardEnabled": @YES, @"WireGuardStarted": @NO,
            @"BindHost": @"", @"WireGuardAddress": @"", @"WireGuardError": @"invalid configuration"};
        NSString *runtimeDomain = [@"com.82flex.trollvnc.runtime-tests." stringByAppendingString:NSUUID.UUID.UUIDString];
        NSUserDefaults *runtime = [[NSUserDefaults alloc] initWithSuiteName:runtimeDomain];
        NSMutableDictionary *published = [status mutableCopy];
        published[@"BindHost"] = @"127.0.0.1";
        published[@"ServerPID"] = @(getpid());
        published[@"LocalAddresses"] = @[];
        assert(TVNCWriteServiceSnapshot(runtime, published));
        NSUserDefaults *anotherProcessView = [[NSUserDefaults alloc] initWithSuiteName:runtimeDomain];
        NSDictionary *initial = TVNCReadServiceSnapshot(anotherProcessView);
        assert([initial[@"LocalAddresses"] isEqual:@[@"127.0.0.1"]]);
        assert([initial[@"VNCPort"] isEqual:@5901] && [initial[@"ZXTouchPort"] isEqual:@6000]);
        NSTask *reader = [NSTask new];
        reader.executableURL = [NSURL fileURLWithPath:@(argv[0])];
        reader.arguments = @[@"--read-cache", runtimeDomain];
        assert([reader launchAndReturnError:nil]);
        [reader waitUntilExit];
        assert(reader.terminationStatus == 0);
        published[@"ServerPID"] = @(INT_MAX);
        assert(TVNCWriteServiceSnapshot(runtime, published));
        assert(!TVNCReadServiceSnapshot(runtime));
        [runtime removePersistentDomainForName:runtimeDomain];
        [runtime synchronize];
        NSString *json = [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:status options:0 error:nil] encoding:NSUTF8StringEncoding];
        assert([fetch([json stringByAppendingString:@"\n"]) isEqualToDictionary:status]);
        assert(!fetch(@"{}\n")); assert(!fetch(@"invalid\n"));
        assert(!fetch(json)); assert(!fetch([json stringByAppendingString:@"\n"], 2200));
        NSLog(@"Unified service status, fragmented transport, timeout and port validation tests passed");
    }
}
