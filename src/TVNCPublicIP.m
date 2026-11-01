// SPDX-License-Identifier: GPL-2.0-only
#import "TVNCPublicIP.h"
#import <arpa/inet.h>
#include <string.h>

NSDictionary *TVNCPublicIPResult(NSData *data, NSURLResponse *response, NSError *error) {
    NSMutableDictionary *result = [@{@"ok":@NO, @"ip":NSNull.null,
        @"source":@"https://ipv4.is", @"checked_at":[NSISO8601DateFormatter.new stringFromDate:NSDate.date]} mutableCopy];
    NSString *code = nil, *message = nil;
    BOOL retryable = YES;
    if (error) {
        code = @"network_error";
        message = @"Phone could not query its public IP; the network or VPN may be changing";
        if ([error.domain isEqual:NSURLErrorDomain]) {
            if (error.code == NSURLErrorTimedOut) code = @"timeout";
            else if (error.code == NSURLErrorNetworkConnectionLost || error.code == NSURLErrorNotConnectedToInternet ||
                     error.code == NSURLErrorCannotConnectToHost || error.code == NSURLErrorCannotFindHost ||
                     error.code == NSURLErrorDNSLookupFailed) code = @"network_unavailable";
            else if (error.code == NSURLErrorSecureConnectionFailed ||
                     (error.code <= NSURLErrorServerCertificateHasBadDate && error.code >= NSURLErrorServerCertificateNotYetValid)) {
                code = @"tls_error"; retryable = NO;
            }
        }
    } else if (![response isKindOfClass:NSHTTPURLResponse.class] || [(NSHTTPURLResponse *)response statusCode] != 200) {
        code = @"upstream_http_error"; message = @"Public IP service returned an unsuccessful HTTP response";
        if ([response isKindOfClass:NSHTTPURLResponse.class]) {
            NSInteger status = [(NSHTTPURLResponse *)response statusCode];
            result[@"upstream_status"] = @(status);
            retryable = status == 408 || status == 429 || status >= 500;
        }
    } else {
        NSString *ip = data.length <= 128 ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
        ip = [ip stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        struct in_addr address;
        // Embedded NUL must not let inet_pton validate only a prefix.
        if (ip.length && [ip lengthOfBytesUsingEncoding:NSUTF8StringEncoding] == strlen(ip.UTF8String) &&
            inet_pton(AF_INET, ip.UTF8String, &address) == 1) {
            result[@"ok"] = @YES; result[@"ip"] = ip; result[@"ip_version"] = @4;
            return result;
        }
        code = @"invalid_response"; message = @"Public IP service did not return a valid IPv4 address";
        retryable = NO;
    }
    result[@"error"] = @{@"error_code":code, @"message":message, @"retryable":@(retryable)};
    return result;
}

void TVNCQueryPublicIP(void (^completion)(NSDictionary *)) {
    NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.URLCache = nil;
    configuration.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    configuration.timeoutIntervalForRequest = 12;
    configuration.timeoutIntervalForResource = 15;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://ipv4.is"]];
    [request setValue:@"text/plain" forHTTPHeaderField:@"Accept"];
    [[session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        completion(TVNCPublicIPResult(data, response, error));
        [session finishTasksAndInvalidate];
    }] resume];
}
