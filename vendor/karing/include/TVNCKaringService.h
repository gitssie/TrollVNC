// SPDX-License-Identifier: GPL-2.0-only
#import <Foundation/Foundation.h>
@class TVKaringClient;
NS_ASSUME_NONNULL_BEGIN

@interface TVNCKaringService : NSObject
- (instancetype)initWithClient:(TVKaringClient *)client;
- (NSData *)handlePayload:(NSString *)payload;
- (void)stop;
@end

NS_ASSUME_NONNULL_END