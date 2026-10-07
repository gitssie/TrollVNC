#import "TVAppleBackend.h"
NS_ASSUME_NONNULL_BEGIN
@protocol TVAppleFindMyBackend <NSObject>
- (BOOL)disableFindMyAppleID:(NSString *)appleID password:(NSString *)password error:(NSError **)error;
@end
FOUNDATION_EXPORT BOOL TVAppleNativeReadFindMyState(BOOL *enabled, NSError **error);
FOUNDATION_EXPORT BOOL TVAppleNativeDisableFindMy(NSString *appleID, NSString *password, NSError **error);
NS_ASSUME_NONNULL_END
