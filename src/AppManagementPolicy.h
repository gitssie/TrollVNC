#pragma once
#import <Foundation/Foundation.h>
#include <sys/types.h>

// Shared by the advertised App capabilities and the command execution guard.
NS_INLINE BOOL tvAppCanTerminate(NSString *identifier) {
    if (identifier.length == 0) return NO;
    NSString *lower = identifier.lowercaseString;
    // Safari, Photos, Settings and ProjectX are ordinary launchable Apps.
    // Protect the UI/session infrastructure specifically, not all Apple Apps.
    return ![lower isEqualToString:@"com.apple.springboard"] &&
        ![lower isEqualToString:@"com.apple.backboardd"] &&
        ![lower containsString:@"trollvnc"] && ![lower containsString:@"roothide"] &&
        ![lower containsString:@"dopamine"] && ![lower isEqualToString:@"org.coolstar.sileostore"];
}

NS_INLINE BOOL tvAppCanInspectProcess(uid_t processUID, uid_t serverUID) {
    // Launch-daemon sessions run as mobile (501); interactive root sessions
    // must still find mobile Apps rather than report an empty successful close.
    return processUID == serverUID || (serverUID == 0 && processUID == 501);
}
