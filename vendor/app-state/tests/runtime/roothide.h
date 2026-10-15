#import <Foundation/Foundation.h>
// Model the two distinct RootHide path domains without accessing a device.
static inline NSString *rootfs(NSString *path) { return [@"/rootfs" stringByAppendingString:path]; }
static inline NSString *jbroot(NSString *path) { return [@"/bootstrap" stringByAppendingString:path]; }
