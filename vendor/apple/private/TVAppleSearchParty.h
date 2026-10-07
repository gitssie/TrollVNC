#import "TVAppleBackend.h"
typedef NS_ENUM(NSUInteger, TVAppleServiceHealth) { TVAppleServiceHealthy=1, TVAppleServiceUnresponsive, TVAppleServiceUnavailable };
@protocol TVAppleSearchPartyDriver <NSObject>
- (TVAppleServiceHealth)probeWithTimeout:(NSTimeInterval)timeout;
- (BOOL)restartWithTimeout:(NSTimeInterval)timeout error:(NSError **)error;
@end
@interface TVAppleSearchPartyGuard : NSObject
@property (readonly) BOOL recovered;
- (instancetype)initWithDriver:(id<TVAppleSearchPartyDriver>)driver;
- (BOOL)prepare:(NSError **)error;
@end
FOUNDATION_EXPORT TVAppleServiceHealth TVAppleSearchPartyProbeManager(id manager, NSTimeInterval timeout);
FOUNDATION_EXPORT BOOL TVApplePrepareSearchParty(BOOL *recovered, NSError **error);
