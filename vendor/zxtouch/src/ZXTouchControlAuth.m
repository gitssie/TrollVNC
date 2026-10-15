#import "ZXTouchControlAuth.h"
#import <Security/SecRandom.h>
#import <CommonCrypto/CommonHMAC.h>
#import <CommonCrypto/CommonDigest.h>
#include <math.h>

static NSString *Encode(NSData *data) {
    NSString *s = [data base64EncodedStringWithOptions:0];
    return [[[s stringByReplacingOccurrencesOfString:@"+" withString:@"-"] stringByReplacingOccurrencesOfString:@"/" withString:@"_"] stringByReplacingOccurrencesOfString:@"=" withString:@""];
}
static NSDictionary *Decode(NSString *s) {
    if (!s.length || [s rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"] invertedSet]].location != NSNotFound) return nil;
    NSString *padded = [[s stringByReplacingOccurrencesOfString:@"-" withString:@"+"] stringByReplacingOccurrencesOfString:@"_" withString:@"/"];
    while (padded.length % 4) padded = [padded stringByAppendingString:@"="];
    NSData *data = [[NSData alloc] initWithBase64EncodedString:padded options:0];
    if (!data || ![Encode(data) isEqual:s]) return nil;
    id value = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    return [value isKindOfClass:NSDictionary.class] ? value : nil;
}
@implementation ZXTouchControlAuth {
    BOOL (^_check)(NSString *);
    NSTimeInterval (^_clock)(void);
    NSData *_key;
    NSMutableDictionary<NSString *, NSNumber *> *_sessions;
}
- (instancetype)initWithPasswordCheck:(BOOL (^)(NSString *))check {
    return [self initWithPasswordCheck:check clock:^NSTimeInterval { return NSDate.date.timeIntervalSince1970; }];
}
- (instancetype)initWithPasswordCheck:(BOOL (^)(NSString *))check clock:(NSTimeInterval (^)(void))clock {
    if ((self = [super init])) {
        _check = [check copy]; _clock = [clock copy]; _sessions = [NSMutableDictionary new];
        uint8_t bytes[32];
        if (SecRandomCopyBytes(kSecRandomDefault, sizeof(bytes), bytes) != errSecSuccess) return nil;
        _key = [NSData dataWithBytes:bytes length:sizeof(bytes)];
    }
    return self;
}
- (NSString *)signature:(NSString *)message {
    NSData *data = [message dataUsingEncoding:NSUTF8StringEncoding];
    uint8_t bytes[CC_SHA256_DIGEST_LENGTH];
    CCHmac(kCCHmacAlgSHA256, _key.bytes, _key.length, data.bytes, data.length, bytes);
    return Encode([NSData dataWithBytes:bytes length:sizeof(bytes)]);
}
- (NSString *)connectWithPassword:(NSString *)password {
    if (![password isKindOfClass:NSString.class] || password.length > 1024 || !_check(password)) return nil;
    @synchronized(self) {
        NSTimeInterval now = floor(_clock());
        for (NSString *key in [_sessions.allKeys copy]) if (_sessions[key].doubleValue <= now) [_sessions removeObjectForKey:key];
        if (_sessions.count >= 256) return nil;
        NSString *jti = NSUUID.UUID.UUIDString;
        NSDictionary *claims = @{@"iss":@"zxtouch", @"aud":@"zxtouch-control", @"sub":@"controller",
            @"scope":@"device:control", @"iat":@(now), @"exp":@(now + 3600), @"jti":jti};
        NSString *message = [NSString stringWithFormat:@"%@.%@", Encode([NSJSONSerialization dataWithJSONObject:@{@"alg":@"HS256", @"typ":@"JWT"} options:0 error:NULL]), Encode([NSJSONSerialization dataWithJSONObject:claims options:0 error:NULL])];
        _sessions[jti] = @(now + 3600);
        return [NSString stringWithFormat:@"%@.%@", message, [self signature:message]];
    }
}
- (NSDictionary *)verifiedClaims:(NSString *)token {
    if (![token isKindOfClass:NSString.class] || token.length > 4096) return nil;
    NSArray<NSString *> *parts = [token componentsSeparatedByString:@"."];
    if (parts.count != 3) return nil;
    NSString *expected = [self signature:[NSString stringWithFormat:@"%@.%@", parts[0], parts[1]]];
    NSData *actualBytes = [parts[2] dataUsingEncoding:NSUTF8StringEncoding], *expectedBytes = [expected dataUsingEncoding:NSUTF8StringEncoding];
    if (actualBytes.length != expectedBytes.length) return nil;
    uint8_t difference = 0;
    for (NSUInteger i = 0; i < actualBytes.length; i++) difference |= ((const uint8_t *)actualBytes.bytes)[i] ^ ((const uint8_t *)expectedBytes.bytes)[i];
    if (difference) return nil;
    NSDictionary *header = Decode(parts[0]), *claims = Decode(parts[1]);
    if (![header[@"alg"] isEqual:@"HS256"] || ![header[@"typ"] isEqual:@"JWT"] || header[@"crit"] ||
        ![claims[@"iss"] isEqual:@"zxtouch"] || ![claims[@"aud"] isEqual:@"zxtouch-control"] ||
        ![claims[@"sub"] isEqual:@"controller"] || ![claims[@"scope"] isEqual:@"device:control"] ||
        ![claims[@"jti"] isKindOfClass:NSString.class] || ![claims[@"exp"] isKindOfClass:NSNumber.class] ||
        ![claims[@"iat"] isKindOfClass:NSNumber.class]) return nil;
    NSTimeInterval now = _clock(), expires = [claims[@"exp"] doubleValue], issued = [claims[@"iat"] doubleValue];
    if (!isfinite(expires) || !isfinite(issued) || expires <= now || issued > now + 30 || expires - issued != 3600) return nil;
    NSNumber *stored = _sessions[claims[@"jti"]];
    if (!stored || stored.doubleValue != expires) return nil;
    return claims;
}
- (BOOL)authorize:(NSString *)token { @synchronized(self) { return [self verifiedClaims:token] != nil; } }
- (void)disconnect:(NSString *)token { @synchronized(self) { NSDictionary *claims = [self verifiedClaims:token]; if (claims) [_sessions removeObjectForKey:claims[@"jti"]]; } }
- (void)invalidate { @synchronized(self) { [_sessions removeAllObjects]; } }
@end
