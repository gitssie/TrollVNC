// SPDX-License-Identifier: GPL-2.0-only
#import <Foundation/Foundation.h>

// Independent from VNC enablement. Uses native screen pixels for coordinates.
@interface TVNCZXTouchService : NSObject
- (BOOL)startOnHost:(NSString *)host port:(int)port error:(NSError **)error;
- (void)stop;
@end
