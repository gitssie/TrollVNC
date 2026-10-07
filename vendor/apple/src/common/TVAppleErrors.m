#import "TVAppleBackend.h"
NSString *const TVAppleErrorDomain = @"org.trollvnc.apple";
NSError *TVAppleError(TVAppleErrorCode code, NSString *message) {
    return [NSError errorWithDomain:TVAppleErrorDomain code:code
                          userInfo:@{NSLocalizedDescriptionKey:message}];
}
