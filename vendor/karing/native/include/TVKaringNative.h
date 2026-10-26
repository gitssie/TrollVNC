#import <Foundation/Foundation.h>

// One-shot helper only. All NetworkExtension callbacks are marshalled to main.
NSDictionary *TVKaringNativeRequest(NSString *operation);
NSDictionary *TVKaringNativeRequestWithParameters(NSString *operation, NSDictionary *parameters);
// Kept public for filesystem regression tests; filename is a fixed allowlist.
NSDictionary *TVKaringReadDocument(NSString *container, NSString *filename);
NSDictionary *TVKaringSelectionDocuments(NSDictionary *documents, NSDictionary *selection);
BOOL TVKaringWriteDocument(NSString *container, NSString *filename, id document);
NSDictionary *TVKaringConnectionState(NSInteger status);

@interface TVKaringHelperClient : NSObject
- (instancetype)initWithExecutable:(NSString *)executable;
- (NSDictionary *)request:(NSString *)operation;
- (NSDictionary *)request:(NSString *)operation parameters:(NSDictionary *)parameters;
@end
