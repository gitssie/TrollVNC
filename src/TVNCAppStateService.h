#import <Foundation/Foundation.h>
@class TVAppStateServices;
NS_ASSUME_NONNULL_BEGIN
@interface TVNCAppStateService : NSObject
- (instancetype)initWithServices:(TVAppStateServices *)services;
- (NSData *)handlePayload:(NSString *)payload;
- (void)stop;
@end
NS_ASSUME_NONNULL_END
