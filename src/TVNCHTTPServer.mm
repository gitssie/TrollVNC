#import "TVNCHTTPServer.h"
#import <errno.h>
@implementation TVNCHTTPServer {
    void *_server;
    TVNCHTTPRoute _handler;
    void (^_disconnected)(NSUInteger);
}
static TVNCHTTPResponse Request(void *context, const char *path, const unsigned char *data, size_t length, const char *token, uint64_t client) {
    @autoreleasepool {
        TVNCHTTPServer *server = (__bridge TVNCHTTPServer *)context;
        @try { return server->_handler(@(path), [NSData dataWithBytes:data length:length], @(token), client); }
        @catch (__unused NSException *exception) { return TVNCHTTPJSON(@{@"error":@"invalid_native_request"}, 400); }
    }
}
static void Disconnected(void *context, uint64_t client) {
    @autoreleasepool { TVNCHTTPServer *server = (__bridge TVNCHTTPServer *)context; server->_disconnected(client); }
}
static void Release(void *context) { CFRelease(context); }
- (instancetype)initWithHandler:(TVNCHTTPRoute)handler disconnected:(void (^)(NSUInteger))disconnected {
    if ((self = [super init])) { _handler = [handler copy]; _disconnected = [disconnected copy]; } return self;
}
- (BOOL)startOnHost:(NSString *)host port:(int)port error:(NSError **)error {
    NSDictionary *settings = TVNCKaringDeviceSettings();
    @synchronized (self) {
        _server = tvnc_http_start(host.UTF8String, port, [settings[@"address"] UTF8String], [settings[@"secret"] UTF8String], (__bridge_retained void *)self, Request, Disconnected, Release);
        if (!_server && error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EADDRINUSE userInfo:nil];
        return _server != NULL;
    }
}
- (BOOL)isClientConnected:(NSUInteger)client { @synchronized(self) { return tvnc_http_connected(_server, client); } }
- (void)stop { @synchronized(self) { void *server = _server; _server = NULL; tvnc_http_stop(server); } }
@end
TVNCHTTPResponse TVNCHTTPData(NSData *data, int status, const char *type) {
    size_t length = data.length;
    unsigned char *copy = (unsigned char *)malloc(MAX(length, 1));
    if (copy && length) memcpy(copy, data.bytes, length);
    return {copy, length, (uint16_t)status, type, NULL};
}
TVNCHTTPResponse TVNCHTTPJSON(id object, int status) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingFragmentsAllowed error:nil];
    return TVNCHTTPData(data ?: [@"{}" dataUsingEncoding:NSUTF8StringEncoding], status, "application/json");
}
