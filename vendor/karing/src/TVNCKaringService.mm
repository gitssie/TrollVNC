// SPDX-License-Identifier: GPL-2.0-only
#import "TVNCKaringService.h"
#import "TVKaringClient.h"

static NSString *KZClean(NSString *text) {
    return [[text ?: @"" stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"]
            stringByReplacingOccurrencesOfString:@";;" withString:@"; "];
}
static NSData *KZReply(NSString *fields) {
    NSString *reply = fields ? [NSString stringWithFormat:@"0;;%@\r\n", KZClean(fields)] : @"0\r\n";
    return [reply dataUsingEncoding:NSUTF8StringEncoding];
}
static NSData *KZError(NSString *message) {
    return [[NSString stringWithFormat:@"-1;;%@\r\n", KZClean(message)] dataUsingEncoding:NSUTF8StringEncoding];
}
static BOOL integerField(NSString *field, NSInteger *value) {
    if (!field.length || [field rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet].location != NSNotFound) return NO;
    NSScanner *scanner = [NSScanner scannerWithString:field];
    return [scanner scanInteger:value] && scanner.isAtEnd;
}

@implementation TVNCKaringService {
    TVKaringClient *_client;
}
- (instancetype)initWithClient:(TVKaringClient *)client {
    if ((self = [super init])) _client = client;
    return self;
}
- (void)stop { _client = nil; }

- (NSData *)handlePayload:(NSString *)payload {
    TVKaringClient *client = _client;
    if (!client) return KZError(@"Karing client not initialized");
    NSArray<NSString *> *fields = [payload componentsSeparatedByString:@";;"];
    // ZXTouch dispatcher removes task 34; also accept a complete frame in test tools.
    if ([fields.firstObject isEqualToString:@"34"]) fields = [fields subarrayWithRange:NSMakeRange(1, fields.count - 1)];
    NSInteger task = 0;
    if (!fields.count || !integerField(fields[0], &task)) return KZError(@"Invalid Karing subtask");
    NSString *a = fields.count > 1 ? fields[1] : nil;
    NSString *b = fields.count > 2 ? fields[2] : nil;
    NSError *error = nil;
    id result = nil;
    BOOL ok = NO;
    @try {
        switch (task) {
            case 1: { NSDictionary *v = nil; ok = [client getVersion:&v error:&error]; result = v; break; }
            case 2: { NSDictionary *v = nil; ok = [client getTraffic:&v error:&error]; result = v; break; }
            case 3: { NSString *v = nil; ok = [client getConfigs:&v error:&error]; result = v; break; }
            case 4:
            case 5: {
                if (!a.length || fields.count != 2) return KZError(@"Config operation requires one JSON field");
                NSString *json = [a stringByReplacingOccurrencesOfString:@"; " withString:@";;"];
                ok = task == 4 ? [client putConfigsWithJSON:json error:&error] : [client patchConfigsWithJSON:json error:&error];
                break;
            }
            case 10: { NSDictionary *v = nil; ok = [client getProxies:&v error:&error]; if (v) result = @{@"proxies": v}; break; }
            case 11: {
                if (!a.length) return KZError(@"GetProxy requires name");
                NSDictionary *v = nil; ok = [client getProxyWithName:a result:&v error:&error]; if (v) result = @{a: v}; break;
            }
            case 12:
                if (!a.length || !b.length) return KZError(@"PutProxy requires group and node");
                ok = [client putProxyGroup:a selectNode:b error:&error]; break;
            case 13: {
                if (!a.length) return KZError(@"ProxyDelay requires node");
                NSInteger delay = 0; ok = [client testProxyDelay:a delayMs:&delay error:&error]; result = @{@"delay": @(delay)}; break;
            }
            case 20: { NSArray *v = nil; ok = [client getConnections:&v error:&error]; result = v; break; }
            case 21: ok = [client deleteAllConnections:&error]; break;
            case 22:
                if (!a.length) return KZError(@"DeleteConnection requires ID");
                ok = [client deleteConnectionWithID:a error:&error]; break;
            case 30: { NSArray *v = nil; ok = [client getRules:&v error:&error]; result = v; break; }
            case 40: { NSDictionary *v = nil; ok = [client getProviders:&v error:&error]; if (v) result = @{@"providers": v}; break; }
            case 41: {
                if (!a.length) return KZError(@"GetProvider requires name");
                NSDictionary *v = nil; ok = [client getProviderWithName:a result:&v error:&error]; if (v) result = @{a: v}; break;
            }
            case 42:
                if (!a.length || !b.length) return KZError(@"PutProvider requires provider and node");
                ok = [client putProvider:a selectNode:b error:&error]; break;
            case 43: {
                if (!a.length) return KZError(@"HealthCheck requires provider");
                NSDictionary *v = nil; ok = [client getProviderHealthCheck:a delays:&v error:&error]; result = v; break;
            }
            case 50: {
                if (!a.length) return KZError(@"DNSQuery requires name");
                NSDictionary *v = nil; ok = [client queryDNSName:a type:b ?: @"A" result:&v error:&error]; result = v; break;
            }
            case 60: {
                NSInteger lines = 100;
                if (a && !integerField(a, &lines)) return KZError(@"Invalid log count");
                NSString *v = nil; ok = [client getLogs:&v lines:lines error:&error]; result = v; break;
            }
            case 70: {
                if (!a.length) return KZError(@"Failover requires group");
                NSInteger threshold = 300, maxFail = 2;
                if ((b && !integerField(b, &threshold)) || (fields.count > 3 && !integerField(fields[3], &maxFail))) return KZError(@"Invalid failover limits");
                NSString *selected = nil;
                ok = [client testAndFailoverGroup:a thresholdMs:threshold maxFailCount:maxFail switchedToNode:&selected error:&error];
                result = selected ? @{@"switched": @YES, @"switchedTo": selected} : @{@"switched": @NO}; break;
            }
            case 80:
                if (!a.length) return KZError(@"SetRoutingMode requires mode");
                ok = [client setRoutingMode:a error:&error]; break;
            default: return KZError(@"Unsupported Karing subtask");
        }
    } @catch (NSException *exception) {
        return KZError(@"Karing response or payload is invalid");
    }
    if (!ok) return KZError(error ? [NSString stringWithFormat:@"%@ (code %ld)", error.localizedDescription, (long)error.code] : @"Karing operation failed");
    if (!result) return KZReply(nil);
    if ([result isKindOfClass:NSString.class]) return KZReply(result);
    NSData *json = [NSJSONSerialization dataWithJSONObject:result options:0 error:&error];
    return json ? KZReply([[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding]) : KZError(@"Cannot serialize Karing response");
}
@end
