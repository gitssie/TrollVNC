#import <Foundation/Foundation.h>
@class TVAppStateServices;
NS_ASSUME_NONNULL_BEGIN
@interface TVNCAppStateService : NSObject
- (instancetype)initWithServices:(TVAppStateServices *)services;
- (NSDictionary *)request:(NSDictionary *)request;
// Atomically invoke/watch and deliver the current snapshot before subsequent callbacks.
- (nullable NSString *)observeRequest:(NSDictionary *)request observer:(void (^)(NSDictionary *record))observer;
- (void)removeObserver:(NSString *)identifier;
- (NSData *)handlePayload:(NSString *)payload;
- (void)stop;
@end
NS_ASSUME_NONNULL_END
