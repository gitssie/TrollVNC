#import "ZXTouchDeviceInfo.h"
#include <TargetConditionals.h>
#include <dlfcn.h>
#include <sys/utsname.h>

NSString *ZXTouchDeviceGUID(void) {
#if TARGET_OS_SIMULATOR
    return nil;
#else
    static void *library; static dispatch_once_t once;
    dispatch_once(&once, ^{ library = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_LAZY | RTLD_LOCAL); });
    CFTypeRef (*copyAnswer)(CFStringRef) = library ? dlsym(library, "MGCopyAnswer") : NULL;
    id value = copyAnswer ? CFBridgingRelease(copyAnswer(CFSTR("UniqueDeviceID"))) : nil;
    if (![value isKindOfClass:NSString.class] || ![value length] || [value length] > 128) return nil;
    if ([value rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF-"] invertedSet]].location != NSNotFound) return nil;
    return [value lowercaseString];
#endif
}
NSDictionary *ZXTouchDeviceInfo(NSString *name, NSString *systemName, NSString *version) {
    NSString *guid = ZXTouchDeviceGUID();
    struct utsname info = {0}; uname(&info);
    return @{@"name":name ?: @"", @"system_name":systemName ?: @"", @"os_version":version ?: @"",
        @"model":@(info.machine), @"guid":guid ?: (id)NSNull.null,
        @"guid_source":@"MobileGestalt.UniqueDeviceID", @"guid_status":guid ? @"available" : @"unavailable"};
}
