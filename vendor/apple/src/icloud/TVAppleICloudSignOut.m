#import "TVAppleScopedSignOut.h"
@implementation TVAppleServices (ICloudSignOut)
- (void)signOutICloudAppleID:(NSString *)appleID localDataPolicy:(TVAppleLocalDataPolicy)policy completion:(TVAppleCompletion)completion {
    [self enqueueSignOutAppleID:appleID localDataPolicy:policy iCloudOnly:YES completion:completion];
}
@end
