#import "../src/TVASRuntime.h"
#include <assert.h>
int main(void) { @autoreleasepool {
    NSDictionary *paths = TVASRuntimePaths();
    assert([paths[@"backup"] isEqual:@"/var/mobile/Media/AppStateBackups"]);
    assert([paths[@"root"] isEqual:@"/bootstrap/var/mobile/Library/TrollVNC/AppState/Operations"]);
    assert([paths[@"worker"] isEqual:@"/bootstrap/usr/libexec/trollvnc/app-state-worker"]);
    assert([paths[@"association"] isEqual:@"/bootstrap/var/mobile/Library/TrollVNC/AppState/associations.plist"]);
    assert([paths[@"system_groups"] isEqual:@"/var/containers/Shared/SystemGroup"]);
    assert([paths[@"sudo"] isEqual:@"/bootstrap/usr/bin/sudo"]);
    assert([paths[@"ldid"] isEqual:@"/bootstrap/usr/bin/ldid"]);
    puts("PASS shared backup root and isolated runtime paths");
} return 0; }
