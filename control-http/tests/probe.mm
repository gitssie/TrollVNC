#import "TVNCHTTPServer.h"
#include <atomic>
#include <signal.h>
#include <unistd.h>
static std::atomic<bool> stopping(false);
static void Signal(int) { stopping = true; }
static TVNCHTTPResponse ProbeRequest(void *context, const char *path, const unsigned char *bytes, size_t length, const char *token, uint64_t) {
    @autoreleasepool {
        NSDictionary *config = (__bridge NSDictionary *)context;
        if (![@(token) isEqual:config[@"token"]]) return TVNCHTTPJSON(@{@"error":@"unauthorized"}, 401);
        if (strcmp(path, "/api/control/authorize") == 0) return TVNCHTTPJSON(@{@"ok":@YES}, 200);
        return TVNCHTTPData([NSData dataWithBytes:bytes length:length], 200, "application/json");
    }
}
static void Disconnect(void *, uint64_t) {}
static void Release(void *context) { CFRelease(context); }
int main() { @autoreleasepool {
    fprintf(stderr, "probe: entered main\n");
    NSData *input = [NSFileHandle.fileHandleWithStandardInput readDataToEndOfFile];
    NSDictionary *config = [NSJSONSerialization JSONObjectWithData:input options:0 error:nil];
    if (![config[@"token"] isKindOfClass:NSString.class] || [config[@"token"] length] != 64) return 2;
    fprintf(stderr, "probe: input read\n");
    NSDictionary *settings = TVNCKaringDeviceSettings();
    fprintf(stderr, "probe: settings discovered\n");
    int port = [config[@"port"] intValue];
    if (port < 40000 || port > 49999) return 2;
    void *server = tvnc_http_start("127.0.0.1", port, [settings[@"address"] UTF8String], [settings[@"secret"] UTF8String], (__bridge_retained void *)config, ProbeRequest, Disconnect, Release);
    if (!server) return 3;
    signal(SIGTERM, Signal); signal(SIGINT, Signal);
    printf("READY HTTP/2 %d %d\n", port, getpid()); fflush(stdout);
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:120];
    while (!stopping && [deadline timeIntervalSinceNow] > 0) [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.1]];
    tvnc_http_stop(server); return 0;
} }
