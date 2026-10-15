// SPDX-License-Identifier: GPL-2.0-only
// Objective-C friendly wrapper for Karing API - pure ObjC, no C++ types
// Include this in .m/.h files; use TVKaringClient.mm for implementation

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Forward declaration of C++ config (defined in KaringProtocol.hpp)
struct KaringConfig;

// Opaque pointer to C++ client
typedef struct KaringClientOpaque *KaringClientRef;

// Error codes matching C++ enum
typedef NS_ENUM(NSInteger, TVKaringErrorCode) {
    TVKaringErrorOK = 0,
    TVKaringErrorInvalidArgument = -1,
    TVKaringErrorNetworkError = -2,
    TVKaringErrorHTTPError = -3,
    TVKaringErrorJSONParseError = -4,
    TVKaringErrorAuthError = -5,
    TVKaringErrorTimeout = -6,
    TVKaringErrorNotConnected = -7,
    TVKaringErrorUnsupported = -8,
    TVKaringErrorResultMismatch = -9
};

// Objective-C friendly wrapper for the C++ client
@interface TVKaringClient : NSObject

@property (nonatomic, readonly) BOOL connected;

// Reads the existing device configuration/App Group; does not save credentials.
+ (instancetype)clientWithDeviceSettings;

// Initialize with base URL, secret, and timeout
- (instancetype)initWithBaseURL:(NSString *)baseURL secret:(NSString *)secret timeout:(NSTimeInterval)timeout;

// System info
- (BOOL)getVersion:(NSDictionary *_Nullable *_Nonnull)out error:(NSError **)error;
- (BOOL)getTraffic:(NSDictionary *_Nullable *_Nonnull)out error:(NSError **)error;

// Config management
- (BOOL)getConfigs:(NSString *_Nullable *_Nonnull)outRawJSON error:(NSError **)error;
- (BOOL)putConfigsWithJSON:(NSString *)configJSON error:(NSError **)error;
- (BOOL)patchConfigsWithJSON:(NSString *)patchJSON error:(NSError **)error;

// Proxy groups
- (BOOL)getProxies:(NSDictionary<NSString *, id> *_Nullable *_Nonnull)out error:(NSError **)error;
- (BOOL)getProxyWithName:(NSString *)name result:(NSDictionary *_Nullable *_Nonnull)out error:(NSError **)error;
- (BOOL)putProxyGroup:(NSString *)groupName selectNode:(NSString *)nodeName error:(NSError **)error;
- (BOOL)testProxyDelay:(NSString *)nodeName delayMs:(NSInteger *_Nullable)outDelayMs error:(NSError **)error;

// Connections
- (BOOL)getConnections:(NSArray<id> *_Nullable *_Nonnull)out error:(NSError **)error;
- (BOOL)deleteAllConnections:(NSError **)error;
- (BOOL)deleteConnectionWithID:(NSString *)id error:(NSError **)error;

// Rules
- (BOOL)getRules:(NSArray<id> *_Nullable *_Nonnull)out error:(NSError **)error;

// Providers
- (BOOL)getProviders:(NSDictionary<NSString *, id> *_Nullable *_Nonnull)out error:(NSError **)error;
- (BOOL)getProviderWithName:(NSString *)name result:(NSDictionary *_Nullable *_Nonnull)out error:(NSError **)error;
- (BOOL)putProvider:(NSString *)providerName selectNode:(NSString *)nodeName error:(NSError **)error;
- (BOOL)getProviderHealthCheck:(NSString *)name delays:(NSDictionary<NSString *, NSNumber *> *_Nullable *_Nonnull)out error:(NSError **)error;

// DNS
- (BOOL)queryDNSName:(NSString *)name type:(NSString *)type result:(NSDictionary *_Nullable *_Nonnull)out error:(NSError **)error;

// Logs
- (BOOL)getLogs:(NSString *_Nullable *_Nonnull)outRawText lines:(NSInteger)lines error:(NSError **)error;

// High-level fault tolerance
- (BOOL)testAndFailoverGroup:(NSString *)groupName
                    thresholdMs:(NSInteger)thresholdMs
                  maxFailCount:(NSInteger)maxFailCount
                  switchedToNode:(NSString *_Nullable *_Nonnull)switchedToNode
                         error:(NSError **)error;

// Convenience: set routing mode
- (BOOL)setRoutingMode:(NSString *)mode error:(NSError **)error;  // "rule" | "global" | "direct"

@end

NS_ASSUME_NONNULL_END
