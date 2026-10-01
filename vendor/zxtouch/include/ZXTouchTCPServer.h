// SPDX-License-Identifier: GPL-2.0-only
#import <Foundation/Foundation.h>
#include "ZXTouchProtocol.hpp"

NS_ASSUME_NONNULL_BEGIN

typedef NSData * _Nullable (^ZXTouchCommandHandler)(const zxtouch::Command &, NSUInteger client);
typedef void (^ZXTouchDisconnectHandler)(NSUInteger client);

// start/stop on the main thread. Commands execute serially per connection on
// background workers. stop shuts down sockets without waiting on the main thread.
@interface ZXTouchTCPServer : NSObject
- (instancetype)initWithHandler:(ZXTouchCommandHandler)handler
                   disconnected:(ZXTouchDisconnectHandler)disconnected;
- (BOOL)startOnHost:(NSString *)host port:(int)port error:(NSError * _Nullable * _Nullable)error;
- (BOOL)isClientConnected:(NSUInteger)client;
- (void)stop;
@end

NS_ASSUME_NONNULL_END
