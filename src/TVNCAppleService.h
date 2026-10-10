#import <Foundation/Foundation.h>
@class TVAppleServices;
NS_ASSUME_NONNULL_BEGIN
// No socket ownership or credential persistence. Operation IDs permit reconnect.
@interface TVNCAppleService : NSObject
- (instancetype)initWithServices:(TVAppleServices *)services;
- (NSData *)handlePayload:(NSString *)payload;
- (void)stop;
@end
NS_ASSUME_NONNULL_END
