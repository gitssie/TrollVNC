// SPDX-License-Identifier: GPL-2.0-only
// Native probe used by mock-server regression and USB device integration tests.
#import "TVKaringClient.h"
#import "TVNCKaringService.h"
#include <iostream>
#include <sstream>
int main() {
    @autoreleasepool {
        std::ostringstream input; input << std::cin.rdbuf();
        std::string text = input.str();
        NSData *data = [NSData dataWithBytes:text.data() length:text.size()];
        NSDictionary *config = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![config isKindOfClass:NSDictionary.class] || ![config[@"baseURL"] isKindOfClass:NSString.class] || ![config[@"secret"] isKindOfClass:NSString.class]) return 2;
        TVKaringClient *client = [[TVKaringClient alloc] initWithBaseURL:config[@"baseURL"] secret:config[@"secret"] timeout:[config[@"timeoutMs"] doubleValue] / 1000.0];
        TVNCKaringService *service = [[TVNCKaringService alloc] initWithClient:client];
        NSMutableArray *results = [NSMutableArray array];
        for (NSString *payload in config[@"tasks"]) {
            NSDate *start = [NSDate date];
            NSData *reply = [service handlePayload:payload];
            NSString *wire = [[NSString alloc] initWithData:reply encoding:NSUTF8StringEncoding];
            NSMutableDictionary *row = [@{@"task": payload, @"elapsedMs": @(-[start timeIntervalSinceNow] * 1000), @"ok": @([wire hasPrefix:@"0"])} mutableCopy];
            // Sample log contents can contain private connection details; report only size.
            NSArray *fields = [payload componentsSeparatedByString:@";;"];
            NSString *task = fields.firstObject;
            if ([task isEqualToString:@"34"] && fields.count > 1) task = fields[1];
            if ([task isEqualToString:@"60"] && [wire hasPrefix:@"0"])
                row[@"logBytes"] = @(reply.length);
            else row[@"wire"] = wire ?: @"";
            [results addObject:row];
        }
        NSData *output = [NSJSONSerialization dataWithJSONObject:results options:0 error:nil];
        if (!output) return 3;
        std::cout.write((const char *)output.bytes, output.length);
        std::cout << "\n";
    }
    return 0;
}
