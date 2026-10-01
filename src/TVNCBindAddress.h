// GPL-2.0-only.
#pragma once
#import <Foundation/Foundation.h>
#import <arpa/inet.h>

NS_INLINE NSString *TVNCIPv4BindAddress(NSString *host) {
    NSString *value = [host stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!value.length || [value isEqualToString:@"::"]) return @"0.0.0.0";
    if ([value isEqualToString:@"::1"]) return @"127.0.0.1";
    return value;
}
NS_INLINE BOOL TVNCValidIPv4BindAddress(NSString *host) {
    struct in_addr address;
    return inet_pton(AF_INET, TVNCIPv4BindAddress(host).UTF8String, &address) == 1;
}
NS_INLINE BOOL TVNCIPv4BindAllowsWireGuard(NSString *host) {
    return [@[@"0.0.0.0", @"127.0.0.1"] containsObject:TVNCIPv4BindAddress(host)];
}
