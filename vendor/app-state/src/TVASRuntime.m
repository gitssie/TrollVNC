#import "TVASRuntime.h"
#if defined(TVAS_DOPAMINE3)
#import <rootless.h>
#endif
NSDictionary *TVASRuntimePaths(void) {
#if defined(TVAS_DOPAMINE3)
    NSString *data=ROOT_PATH_NS(@"/var/mobile/Library/TrollVNC/AppState");
    return @{@"root":[data stringByAppendingPathComponent:@"Operations"],
        @"worker":ROOT_PATH_NS(@"/usr/libexec/trollvnc/app-state-worker"),
        @"vendor":ROOT_PATH_NS(@"/usr/libexec/trollvnc/app-state-idfv-worker"),
        @"bootstrap":ROOT_PATH_NS(@"/"),@"ldid":ROOT_PATH_NS(@"/usr/bin/ldid"),@"sudo":ROOT_PATH_NS(@"/usr/bin/sudo"),
        @"backup":@"/var/mobile/Media/AppStateBackups",
        @"system_groups":@"/var/containers/Shared/SystemGroup",
        @"association":[data stringByAppendingPathComponent:@"associations.plist"]};
#else
    // Dopamine 3 device integration. Tests inject explicit physical paths.
    return @{};
#endif
}
