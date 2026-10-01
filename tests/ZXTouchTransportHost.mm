#import "ZXTouchTCPServer.h"
#include <cstdio>
#include <atomic>
#include <unistd.h>
static std::atomic<int> cancellations{0};

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 2) return 2;
        __block __weak ZXTouchTCPServer *weakServer = nil;
        ZXTouchTCPServer *server = [[ZXTouchTCPServer alloc] initWithHandler:^NSData *(const zxtouch::Command &command, NSUInteger client) {
            if (command.task == 97) {
                for (int i=0; i<500; ++i) {
                    if (![weakServer isClientConnected:client]) { ++cancellations; break; }
                    usleep(10000);
                }
                return [@"0\r\n" dataUsingEncoding:NSUTF8StringEncoding];
            }
            if (command.task == 96) return [[NSString stringWithFormat:@"0;;%d\r\n", cancellations.load()] dataUsingEncoding:NSUTF8StringEncoding];
            if (command.task == 98) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
                    [[NSNotificationCenter defaultCenter] postNotificationName:@"ZXTestStop" object:nil];
                });
                return [@"0\r\n" dataUsingEncoding:NSUTF8StringEncoding];
            }
            if (command.task == 10) return nil;
            if (command.task == 30) {
                NSMutableData *reply = [[@"0;;image/jpeg;;6\r\n" dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
                const unsigned char jpeg[] = {0xff, 0xd8, '\r', '\n', 0xff, 0xd9};
                [reply appendBytes:jpeg length:6];
                return reply;
            }
            NSString *reply = command.task == 14 || command.task == 15 ?
                @"-1;;Touch recording is excluded\r\n" :
                [NSString stringWithFormat:@"0;;%s\r\n", command.payload.c_str()];
            return [reply dataUsingEncoding:NSUTF8StringEncoding];
        } disconnected:^(NSUInteger client) {}];
        weakServer = server;
        NSError *error;
        if (![server startOnHost:@"0.0.0.0" port:atoi(argv[1]) error:&error]) {
            fprintf(stderr, "%s\n", error.localizedDescription.UTF8String); return 1;
        }
        id token = [[NSNotificationCenter defaultCenter] addObserverForName:@"ZXTestStop" object:nil queue:nil usingBlock:^(NSNotification *note) {
            [server stop];
            CFRunLoopStop(CFRunLoopGetMain());
        }];
        puts("ready"); fflush(stdout);
        CFRunLoopRun();
        [server stop];
        [[NSNotificationCenter defaultCenter] removeObserver:token];
    }
}
