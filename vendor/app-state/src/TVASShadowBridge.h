#import <Foundation/Foundation.h>
FOUNDATION_EXPORT NSDictionary *TVASInvokeShadow(NSString *action, NSString *bundle, NSDictionary *request, NSError **error);
FOUNDATION_EXPORT NSDictionary *TVASInvokeShadowWithProgress(NSString *action, NSString *bundle, NSDictionary *request, void (^progress)(NSDictionary *), NSError **error);
