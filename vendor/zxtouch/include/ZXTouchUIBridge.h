// SPDX-License-Identifier: GPL-2.0-only
#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
static NSString *const ZXUIRequestName = @"com.82flex.trollvnc.zxtouch.ui.request";
static NSString *const ZXUIResponseName = @"com.82flex.trollvnc.zxtouch.ui.response";
static NSString *const ZXUITouchName = @"com.82flex.trollvnc.zxtouch.ui.touches";

// iOS exposes this Foundation class privately. Use the same async distributed
// notification mechanism as the original keyboard adapter, with correlated replies.
@protocol ZXNotificationCenter <NSObject>
- (void)addObserver:(id)observer selector:(SEL)selector name:(NSString *)name object:(nullable id)object;
- (void)removeObserver:(id)observer;
- (void)postNotificationName:(NSString *)name object:(nullable id)object userInfo:(NSDictionary *)info deliverImmediately:(BOOL)immediately;
@end

@interface ZXTouchUIBridge : NSObject
- (instancetype)initWithCenter:(nullable id<ZXNotificationCenter>)center;
- (NSDictionary *)requestTask:(int)task fields:(NSArray<NSString *> *)fields target:(NSString *)target
                     timeout:(NSTimeInterval)timeout cancelled:(BOOL (^)(void))cancelled;
- (void)sendTouches:(NSArray<NSDictionary *> *)touches;
- (void)stop;
@end
NS_ASSUME_NONNULL_END
