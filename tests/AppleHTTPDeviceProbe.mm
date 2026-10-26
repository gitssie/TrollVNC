#import <Foundation/Foundation.h>
#include <unistd.h>
#import "TVNCAppleService.h"
#import "TVNCHTTPServer.h"
// Test-only loopback server. Supply a random bearer secret on private stdin.
// Apple operations use the production adapter and native facade.
NSDictionary *TVNCKaringDeviceSettings(void) { return @{@"address":@"127.0.0.1:1",@"secret":@""}; }
int main(int argc, const char **argv) { @autoreleasepool {
    if (argc != 2 || atoi(argv[1]) < 1024 || atoi(argv[1]) > 65535) return 2;
    char input[256]; if (!fgets(input, sizeof(input), stdin)) return 2;
    NSString *secret=[[@(input) stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] copy];
    memset(input, 0, sizeof(input)); if (secret.length < 32) return 2;
    TVNCAppleService *adapter=[TVNCAppleService new];
    TVNCHTTPServer *server=[[TVNCHTTPServer alloc] initWithHandler:^TVNCHTTPResponse(NSString *path, NSData *body, NSString *token, NSUInteger client) {
        (void)client;
        if (![token isEqual:secret]) return TVNCHTTPJSON(@{@"error":@"unauthorized"},401);
        if ([path isEqual:@"/api/control/authorize"]) return TVNCHTTPJSON(@{@"apple_password_change":@1},200);
        if (![path hasPrefix:@"/api/apple/"]) return TVNCHTTPJSON(@{@"error":@"route_unavailable"},404);
        NSString *method=[path substringFromIndex:11];
        if (!method.length || [method containsString:@"/"]) return TVNCHTTPJSON(@{@"error":@"route_unavailable"},404);
        id input=[NSJSONSerialization JSONObjectWithData:body options:0 error:nil];
        if (![input isKindOfClass:NSDictionary.class]) return TVNCHTTPJSON(@{@"error":@"invalid_request"},400);
        NSDictionary *request;
        if ([@[@"result",@"submit_code",@"cancel_challenge"] containsObject:method]) {
            NSMutableDictionary *action=[input mutableCopy]; action[@"action"]=method; request=action;
        } else request=@{@"action":@"invoke",@"method":method,@"params":input};
        NSDictionary *result=[adapter request:request];
        return TVNCHTTPJSON(result,result[@"error"] ? 400 : 200);
    } disconnected:^(NSUInteger client){(void)client;}];
    NSError *error=nil;
    if (![server startOnHost:@"127.0.0.1" port:atoi(argv[1]) error:&error]) return 1;
    printf("READY %d\n",getpid()); fflush(stdout); [[NSRunLoop currentRunLoop] run];
} return 0; }
