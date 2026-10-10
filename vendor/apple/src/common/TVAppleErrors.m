#import "TVAppleBackend.h"
NSString *const TVAppleErrorDomain = @"org.trollvnc.apple";
NSError *TVAppleError(TVAppleErrorCode code, NSString *message) {
    return [NSError errorWithDomain:TVAppleErrorDomain code:code
                          userInfo:@{NSLocalizedDescriptionKey:message, @"TVAppleDiagnosticMessage":message}];
}

NSString *TVAppleDiagnosticMessage(NSError *error) {
    if (![error.domain isEqual:TVAppleErrorDomain]) return nil;
    id message = error.userInfo[@"TVAppleDiagnosticMessage"];
    return [message isKindOfClass:NSString.class] && [message length] <= 1024 ? message : nil;
}
