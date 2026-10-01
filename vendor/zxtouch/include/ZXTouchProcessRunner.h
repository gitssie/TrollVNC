// SPDX-License-Identifier: GPL-2.0-only
#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface ZXTouchProcessRunner : NSObject
+ (NSDictionary<NSString *, NSString *> *)runtimePaths;
- (instancetype)initWithRuntimeRoot:(NSString *)root modulePath:(NSString *)modulePath logPath:(NSString *)logPath;
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *environment;
- (BOOL)runShell:(NSString *)command cancelled:(BOOL (^)(void))cancelled error:(NSError **)error;
- (BOOL)startScript:(NSString *)path error:(NSError **)error;
- (BOOL)stopScript:(NSError **)error;
- (BOOL)isScriptRunning;
- (void)stop;
@end
NS_ASSUME_NONNULL_END
