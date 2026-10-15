#import "TVASRuntime.h"
#if defined(TVAS_ROOTHIDE)
#import <roothide.h>
#endif
NSDictionary *TVASRuntimePaths(void) {
#if defined(TVAS_ROOTHIDE)
    NSString *data=jbroot(@"/var/mobile/Library/TrollVNC/AppState");
    return @{@"root":[data stringByAppendingPathComponent:@"Operations"],
        @"worker":jbroot(@"/usr/libexec/trollvnc/app-state-worker"),
        @"vendor":jbroot(@"/usr/libexec/trollvnc/app-state-idfv-worker"),
        @"bootstrap":jbroot(@"/"),@"ldid":jbroot(@"/usr/bin/ldid"),@"sudo":jbroot(@"/usr/bin/sudo"),
        @"backup":jbroot(rootfs(@"/var/mobile/Media/AppStateBackups")),
        @"system_groups":jbroot(rootfs(@"/var/containers/Shared/SystemGroup")),
        @"association":[data stringByAppendingPathComponent:@"associations.plist"]};
#else
    // RootHide-only native integration. Tests inject explicit physical paths.
    return @{};
#endif
}
