#import <Foundation/Foundation.h>

// One-shot helper only. All NetworkExtension callbacks are marshalled to main.
NSDictionary *TVKaringNativeRequest(NSString *operation);
// Kept public for filesystem regression tests; filename is a fixed allowlist.
NSDictionary *TVKaringReadDocument(NSString *container, NSString *filename);

@interface TVKaringHelperClient : NSObject
- (instancetype)initWithExecutable:(NSString *)executable;
- (NSDictionary *)request:(NSString *)operation;
@end
