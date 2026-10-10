#import <Foundation/Foundation.h>
@interface TVASAppLifecycle : NSObject
- (NSDictionary *)execute:(NSString *)method bundle:(NSString *)bundle error:(NSError **)error;
@end
