#import <Foundation/Foundation.h>
#import <TargetConditionals.h>
// Use the stable bootstrap alias to keep the Unix socket below sun_path's limit.
// Notification content remains memory-only; only the socket lives on disk.
static inline NSString *tvNotificationDirectory(void) {
#if TARGET_OS_IPHONE && !TARGET_OS_SIMULATOR
    return @"/var/jb/var/mobile/.tvnc-run";
#else
    return @"/var/mobile/.tvnc-run";
#endif
}
static inline NSString *tvNotificationSocketPath(void) {
    return [tvNotificationDirectory() stringByAppendingPathComponent:@"n.sock"];
}
