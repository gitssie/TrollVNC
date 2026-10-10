// GPL-2.0-only.
#pragma once
#import <Foundation/Foundation.h>

static inline BOOL TVAppControlOperation(NSUInteger op) {
    return op <= 6 || op == 12 || op == 16;
}
static inline BOOL TVAppControlMutation(NSUInteger op) {
    return (op >= 2 && op <= 4) || op == 12 || op == 16;
}
static inline NSDictionary *TVAppControlDecode(NSString *encoded) {
    if (![encoded isKindOfClass:NSString.class] || encoded.length > 12288) return nil;
    NSData *data = [[NSData alloc] initWithBase64EncodedString:encoded options:0];
    if (!data || data.length > 8192) return nil;
    id request = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![request isKindOfClass:NSDictionary.class]) return nil;
    for (NSString *key in @[@"version", @"op", @"id"]) {
        id number = request[key];
        if (![number isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)number) == CFBooleanGetTypeID() ||
            [number doubleValue] < 0 || [number doubleValue] > UINT32_MAX ||
            [number doubleValue] != [number unsignedLongLongValue]) return nil;
    }
    NSString *token = request[@"token"];
    id payload = request[@"payload"];
    NSUInteger op = [request[@"op"] unsignedIntegerValue];
    if ([request[@"version"] intValue] != 1 || !TVAppControlOperation(op) ||
        ((op == 0) != ([request[@"id"] unsignedIntValue] == 0)) ||
        ![token isKindOfClass:NSString.class] || token.length != 64 ||
        ![payload isKindOfClass:NSDictionary.class]) return nil;
    NSData *body = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    return body && body.length <= 4096 ? request : nil;
}
static inline NSData *TVAppControlEncode(NSDictionary *request, NSDictionary *result, NSString *error) {
    NSDictionary *reply = @{@"version":@1, @"op":request[@"op"], @"id":request[@"id"],
        @"status":result ? @0 : @1, @"payload":result ?: @{@"error":error ?: @"Operation result unknown"}};
    NSData *json = [NSJSONSerialization dataWithJSONObject:reply options:0 error:nil];
    if (!json || json.length > 1024 * 1024) {
        reply = @{@"version":@1, @"op":request[@"op"], @"id":request[@"id"], @"status":@1,
            @"payload":@{@"error":@"Control response too large"}};
        json = [NSJSONSerialization dataWithJSONObject:reply options:0 error:nil];
    }
    return [[NSString stringWithFormat:@"0;;%@\r\n", [json base64EncodedStringWithOptions:0]] dataUsingEncoding:NSUTF8StringEncoding];
}
