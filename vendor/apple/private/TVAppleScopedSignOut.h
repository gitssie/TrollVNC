#import "TVAppleServices.h"
NS_ASSUME_NONNULL_BEGIN
@interface TVAppleServices (ScopedSignOut)
- (void)enqueueSignOutAppleID:(NSString *)appleID
             localDataPolicy:(TVAppleLocalDataPolicy)policy
                  iCloudOnly:(BOOL)iCloudOnly
                  completion:(TVAppleCompletion)completion;
- (void)enqueueDisableFindMyAppleID:(NSString *)appleID password:(NSString *)password completion:(TVAppleCompletion)completion;
@end
NS_ASSUME_NONNULL_END
