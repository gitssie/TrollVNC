#import <Foundation/Foundation.h>
#if TVAS_ROOTHIDE
#import <roothide.h>
#endif

// Socket endpoint only; notification contents remain in memory. Keep this short
// enough for sockaddr_un even after RootHide expands the native bootstrap root.
static inline NSString *tvNotificationDirectory(void) {
#if TVAS_ROOTHIDE
    return jbroot(@"/var/mobile/.tvnc-run");
#else
    return @"/var/mobile/.tvnc-run";
#endif
}
static inline NSString *tvNotificationSocketPath(void) {
    return [tvNotificationDirectory() stringByAppendingPathComponent:@"n.sock"];
}
