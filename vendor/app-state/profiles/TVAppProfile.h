#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@protocol TVAppProfileReading <NSObject>
- (NSDictionary *)inspectRecords:(NSArray *)records;
@end
@interface TVVintedProfileReader : NSObject <TVAppProfileReading>
@end
@interface TVSessionSupplementStore : NSObject
- (instancetype)initWithRoot:(NSString *)root;
- (nullable NSDictionary *)loadBundle:(NSString *)bundle idfv:(NSString *)idfv error:(NSError **)error;
- (BOOL)saveState:(NSDictionary *)state bundle:(NSString *)bundle idfv:(NSString *)idfv error:(NSError **)error;
- (nullable NSArray *)mergeRecords:(NSArray *)records manifest:(NSDictionary *)manifest error:(NSError **)error;
- (nullable NSArray *)mergeRecords:(NSArray *)records tokens:(NSDictionary *)tokens error:(NSError **)error;
@end
// Called exclusively by the scoped AppState worker while holding its store lock.
FOUNDATION_EXPORT NSDictionary * _Nullable TVReadAppProfile(NSString *directory,
    NSDictionary *manifest, NSArray *records, TVSessionSupplementStore *store, NSError **error);
NS_ASSUME_NONNULL_END
