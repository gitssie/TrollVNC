#import <Foundation/Foundation.h>

/// Process-local HTTP credentials, independent of desktop/RFB client lifetime.
@interface ZXTouchControlAuth : NSObject
- (instancetype)initWithPasswordCheck:(BOOL (^)(NSString *password))check;
- (instancetype)initWithPasswordCheck:(BOOL (^)(NSString *password))check clock:(NSTimeInterval (^)(void))clock;
- (NSString *)connectWithPassword:(NSString *)password;
- (BOOL)authorize:(NSString *)token;
- (void)disconnect:(NSString *)token;
- (void)invalidate;
@end
