#import "TVAppleBackend.h"
NS_ASSUME_NONNULL_BEGIN
// Shared native Settings transport/signing owner. No credentials leave this object.
@interface TVAppleNativeSettingsSession : NSObject
- (nullable NSDictionary *)beginEmail:(NSString *)email appleID:(NSString *)appleID error:(NSError **)error;
- (nullable NSDictionary *)verifyChallenge:(NSString *)challenge code:(NSString *)code appleID:(NSString *)appleID error:(NSError **)error;
- (nullable NSDictionary *)setForwardingEmail:(NSString *)email appleID:(NSString *)appleID error:(NSError **)error;
@end
// Internal extension used by Settings feature categories. Caller holds the owner lock.
@interface TVAppleNativeSettingsSession (Transport)
- (BOOL)beginSettingsOperation:(NSString *)appleID error:(NSError **)error;
- (void)finishSettingsOperation;
- (BOOL)identityMatches:(NSError **)error;
- (nullable id)get:(NSString *)link error:(NSError **)error;
- (nullable id)load:(NSMutableURLRequest *)request mutation:(BOOL)mutation error:(NSError **)error;
- (NSURL *)origin;
- (nullable NSDictionary *)freshEmailSettings:(NSString *)appleID error:(NSError **)error;
@end
NS_ASSUME_NONNULL_END
