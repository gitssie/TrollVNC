#import <Foundation/Foundation.h>
#import "TVNCAppleService.h"
#import "ZXTouchTCPServer.h"
// Isolated loopback listener. No production daemon replacement or UI handling.
int main(int argc,const char **argv) { @autoreleasepool {
    if (argc != 2) return 2;
    int port = atoi(argv[1]);
    if (port < 1024 || port > 65535) return 2;
    TVNCAppleService *adapter = [TVNCAppleService new];
    ZXTouchTCPServer *server = [[ZXTouchTCPServer alloc] initWithHandler:^NSData *(const zxtouch::Command &command, NSUInteger client) {
        (void)client;
        if (command.task != 31) return [@"-1;;unsupported\r\n" dataUsingEncoding:NSUTF8StringEncoding];
        NSString *payload = [[NSString alloc] initWithBytes:command.payload.data() length:command.payload.size() encoding:NSUTF8StringEncoding];
        return payload ? [adapter handlePayload:payload] : [@"-1;;invalid UTF-8\r\n" dataUsingEncoding:NSUTF8StringEncoding];
    } disconnected:^(NSUInteger client) { (void)client; }];
    NSError *error = nil;
    if (![server startOnHost:@"127.0.0.1" port:port error:&error]) { fprintf(stderr,"listen failed: %ld\n",(long)error.code); return 1; }
    puts("READY"); fflush(stdout);
    [[NSRunLoop currentRunLoop] run];
} return 0; }
