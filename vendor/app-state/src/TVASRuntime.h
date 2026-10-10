#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT NSDictionary<NSString *,NSString *> *TVASRuntimePaths(void);
@protocol TVASProcessRunning <NSObject>
- (BOOL)runExecutable:(NSString *)path arguments:(NSArray<NSString *> *)arguments timeout:(NSTimeInterval)timeout standardOutput:(NSData * _Nullable * _Nullable)output error:(NSError **)error;
@end
@interface TVASProcessRunner : NSObject <TVASProcessRunning>
@end
NS_ASSUME_NONNULL_END
