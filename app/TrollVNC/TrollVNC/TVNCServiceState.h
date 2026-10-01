// One service-state source for the Settings dashboard and network page. GPL-2.0-only.
#import <Foundation/Foundation.h>

FOUNDATION_EXPORT NSNotificationName const TVNCServiceStateDidChangeNotification;

@interface TVNCServiceState : NSObject
@property(nonatomic, strong, readonly) NSDictionary *status;
@property(nonatomic, assign, readonly, getter=isRunning) BOOL running;
+ (instancetype)sharedState;
- (void)startObserving;
- (void)stopObserving;
- (void)refreshWithCompletion:(void (^)(void))completion;
@end
