#import "AppManagementPolicy.h"
#include <stdio.h>

int main(void) {
    @autoreleasepool {
        int failures = 0;
        for (NSString *identifier in @[@"com.apple.mobilesafari", @"com.apple.mobileslideshow",
                                       @"com.apple.Preferences", @"com.tencent.xin", @"com.hydra.projectx"]) {
            if (!tvAppCanTerminate(identifier)) {
                fprintf(stderr, "FAIL: ordinary App cannot close/restart: %s\n", identifier.UTF8String);
                ++failures;
            }
        }
        for (NSString *identifier in @[@"com.apple.springboard", @"com.apple.backboardd",
                                       @"com.82flex.trollvnc", @"com.zqbb.Dopamine-roothide",
                                       @"org.coolstar.SileoStore"]) {
            if (tvAppCanTerminate(identifier)) {
                fprintf(stderr, "FAIL: protected component can be terminated: %s\n", identifier.UTF8String);
                ++failures;
            }
        }
        if (!tvAppCanInspectProcess(501, 501) || !tvAppCanInspectProcess(501, 0) ||
            tvAppCanInspectProcess(0, 501) || tvAppCanInspectProcess(502, 501) ||
            tvAppCanInspectProcess(502, 0)) {
            fprintf(stderr, "FAIL: mobile App process visibility differs under a root server\n");
            ++failures;
        }
        if (failures) return 1;
        puts("App management policy tests passed");
        return 0;
    }
}
