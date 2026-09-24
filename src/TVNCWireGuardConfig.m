#import "TVNCWireGuardConfig.h"

#import <arpa/inet.h>

static NSString *const TVNCWGErrorDomain = @"com.82flex.trollvnc.wireguard";

static BOOL TVNCWGFail(NSError **error, NSUInteger line, NSString *message) {
    if (error) {
        *error = [NSError errorWithDomain:TVNCWGErrorDomain
                                    code:1
                                userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Line %lu: %@", (unsigned long)line, message]}];
    }
    return NO;
}

static NSString *TVNCWGTrim(NSString *value) {
    return [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static NSArray<NSString *> *TVNCWGValues(NSString *value) {
    NSMutableArray *result = [NSMutableArray array];
    for (NSString *item in [value componentsSeparatedByString:@","]) {
        NSString *trimmed = TVNCWGTrim(item);
        if (trimmed.length) [result addObject:trimmed];
    }
    return result;
}

static BOOL TVNCWGValidKey(NSString *value) {
    NSData *decoded = [[NSData alloc] initWithBase64EncodedString:value options:0];
    return decoded.length == 32;
}

static BOOL TVNCWGValidPrefix(NSString *value, BOOL requireHost) {
    NSArray *parts = [value componentsSeparatedByString:@"/"];
    if (parts.count != 2) return NO;
    const char *literal = [parts[0] UTF8String];
    struct in_addr v4;
    struct in6_addr v6;
    int maxBits = inet_pton(AF_INET, literal, &v4) == 1 ? 32 :
                  inet_pton(AF_INET6, literal, &v6) == 1 ? 128 : -1;
    if (maxBits < 0) return NO;
    NSString *bitsText = parts[1];
    NSCharacterSet *nonDigits = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
    if (!bitsText.length || [bitsText rangeOfCharacterFromSet:nonDigits].location != NSNotFound) return NO;
    NSInteger bits = bitsText.integerValue;
    return bits >= 0 && bits <= maxBits && (!requireHost || bits > 0);
}

static BOOL TVNCWGValidEndpoint(NSString *value) {
    NSString *host = nil;
    NSString *port = nil;
    if ([value hasPrefix:@"["]) {
        NSRange close = [value rangeOfString:@"]:"];
        if (close.location == NSNotFound) return NO;
        host = [value substringWithRange:NSMakeRange(1, close.location - 1)];
        port = [value substringFromIndex:NSMaxRange(close)];
    } else {
        NSRange colon = [value rangeOfString:@":" options:NSBackwardsSearch];
        if (colon.location == NSNotFound) return NO;
        host = [value substringToIndex:colon.location];
        port = [value substringFromIndex:colon.location + 1];
        if ([host containsString:@":"]) return NO;
    }
    NSCharacterSet *nonDigits = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
    return host.length && port.length &&
           [port rangeOfCharacterFromSet:nonDigits].location == NSNotFound &&
           port.integerValue >= 1 && port.integerValue <= 65535;
}

NSDictionary *TVNCWGParseConfiguration(NSString *text, NSError **error) {
    NSMutableDictionary *interface = [NSMutableDictionary dictionary];
    NSMutableArray<NSMutableDictionary *> *peers = [NSMutableArray array];
    NSMutableDictionary *section = nil;
    NSArray<NSString *> *lines = [text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    for (NSUInteger index = 0; index < lines.count; index++) {
        NSString *line = TVNCWGTrim(lines[index]);
        NSRange comment = [line rangeOfString:@"#"];
        if (comment.location != NSNotFound) line = TVNCWGTrim([line substringToIndex:comment.location]);
        if (!line.length) continue;
        if ([line caseInsensitiveCompare:@"[Interface]"] == NSOrderedSame) {
            if (interface[@"_seen"]) { TVNCWGFail(error, index + 1, @"Only one [Interface] is supported"); return nil; }
            interface[@"_seen"] = @YES;
            section = interface;
            continue;
        }
        if ([line caseInsensitiveCompare:@"[Peer]"] == NSOrderedSame) {
            NSMutableDictionary *peer = [NSMutableDictionary dictionary];
            [peers addObject:peer];
            section = peer;
            continue;
        }
        if ([line hasPrefix:@"["]) { TVNCWGFail(error, index + 1, @"Unsupported section"); return nil; }
        if (!section) { TVNCWGFail(error, index + 1, @"Expected [Interface] or [Peer]"); return nil; }
        NSRange equal = [line rangeOfString:@"="];
        if (equal.location == NSNotFound) { TVNCWGFail(error, index + 1, @"Expected key = value"); return nil; }
        NSString *key = TVNCWGTrim([line substringToIndex:equal.location]);
        NSString *value = TVNCWGTrim([line substringFromIndex:equal.location + 1]);
        BOOL isInterface = section == interface;
        NSArray *allowed = isInterface ? @[@"PrivateKey", @"Address", @"ListenPort", @"MTU", @"DNS"] :
                                       @[@"PublicKey", @"PresharedKey", @"Endpoint", @"AllowedIPs", @"PersistentKeepalive"];
        NSString *canonical = nil;
        for (NSString *candidate in allowed) {
            if ([key caseInsensitiveCompare:candidate] == NSOrderedSame) { canonical = candidate; break; }
        }
        if (!canonical) { TVNCWGFail(error, index + 1, [NSString stringWithFormat:@"Unsupported option %@", key]); return nil; }
        if (section[canonical]) { TVNCWGFail(error, index + 1, [NSString stringWithFormat:@"Duplicate %@", canonical]); return nil; }
        if (!value.length) { TVNCWGFail(error, index + 1, [NSString stringWithFormat:@"%@ is empty", canonical]); return nil; }
        if ([canonical isEqualToString:@"PrivateKey"] || [canonical isEqualToString:@"PublicKey"] ||
            [canonical isEqualToString:@"PresharedKey"]) {
            if (!TVNCWGValidKey(value)) { TVNCWGFail(error, index + 1, [NSString stringWithFormat:@"Invalid %@", canonical]); return nil; }
        } else if ([canonical isEqualToString:@"Address"] || [canonical isEqualToString:@"AllowedIPs"]) {
            NSArray *values = TVNCWGValues(value);
            if (!values.count) { TVNCWGFail(error, index + 1, @"Empty address list"); return nil; }
            for (NSString *item in values) {
                if (!TVNCWGValidPrefix(item, [canonical isEqualToString:@"Address"])) {
                    TVNCWGFail(error, index + 1, [NSString stringWithFormat:@"Invalid %@ entry", canonical]); return nil;
                }
            }
            section[canonical] = values;
            continue;
        } else if ([canonical isEqualToString:@"Endpoint"]) {
            if (!TVNCWGValidEndpoint(value)) { TVNCWGFail(error, index + 1, @"Invalid Endpoint"); return nil; }
        } else if ([canonical isEqualToString:@"ListenPort"] || [canonical isEqualToString:@"MTU"] ||
                   [canonical isEqualToString:@"PersistentKeepalive"]) {
            NSCharacterSet *nonDigits = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
            if ([value rangeOfCharacterFromSet:nonDigits].location != NSNotFound) {
                TVNCWGFail(error, index + 1, [NSString stringWithFormat:@"Invalid %@", canonical]); return nil;
            }
            NSInteger number = value.integerValue;
            BOOL valid = [canonical isEqualToString:@"MTU"] ? (number >= 576 && number <= 65535) :
                         [canonical isEqualToString:@"ListenPort"] ? (number >= 0 && number <= 65535) :
                         (number >= 0 && number <= 65535);
            if (!valid) { TVNCWGFail(error, index + 1, [NSString stringWithFormat:@"Invalid %@", canonical]); return nil; }
            section[canonical] = @(number);
            continue;
        }
        section[canonical] = value;
    }
    if (!interface[@"_seen"] || !interface[@"PrivateKey"] || !interface[@"Address"] || !peers.count) {
        TVNCWGFail(error, lines.count, @"[Interface] with Address and PrivateKey plus at least one [Peer] is required");
        return nil;
    }
    for (NSUInteger i = 0; i < peers.count; i++) {
        NSDictionary *peer = peers[i];
        if (!peer[@"PublicKey"] || !peer[@"AllowedIPs"]) {
            TVNCWGFail(error, lines.count, [NSString stringWithFormat:@"Peer %lu needs PublicKey and AllowedIPs", (unsigned long)(i + 1)]);
            return nil;
        }
    }
    [interface removeObjectForKey:@"_seen"];
    interface[@"Peers"] = peers;
    return interface;
}

NSString *TVNCWGConfigurationText(NSDictionary *configuration) {
    NSMutableArray<NSString *> *lines = [NSMutableArray arrayWithObject:@"[Interface]"];
    for (NSString *key in @[@"PrivateKey", @"Address", @"ListenPort", @"MTU", @"DNS"]) {
        id value = configuration[key];
        if ([value isKindOfClass:[NSArray class]]) value = [value componentsJoinedByString:@", "];
        if (value) [lines addObject:[NSString stringWithFormat:@"%@ = %@", key, value]];
    }
    for (NSDictionary *peer in configuration[@"Peers"]) {
        [lines addObject:@""];
        [lines addObject:@"[Peer]"];
        for (NSString *key in @[@"PublicKey", @"PresharedKey", @"Endpoint", @"AllowedIPs", @"PersistentKeepalive"]) {
            id value = peer[key];
            if ([value isKindOfClass:[NSArray class]]) value = [value componentsJoinedByString:@", "];
            if (value) [lines addObject:[NSString stringWithFormat:@"%@ = %@", key, value]];
        }
    }
    return [[lines componentsJoinedByString:@"\n"] stringByAppendingString:@"\n"];
}

NSString *TVNCWGPrimaryAddress(NSDictionary *configuration) {
    NSString *first = nil;
    for (NSString *prefix in configuration[@"Address"]) {
        NSString *address = [[prefix componentsSeparatedByString:@"/"] firstObject];
        if (!first) first = address;
        if (![address containsString:@":"]) return address;
    }
    return first;
}
