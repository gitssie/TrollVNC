// Shared by the PhotoKit adapter and Foundation-only registry regressions.
@interface TVPhotoJob : NSObject
@property(nonatomic, copy) NSString *result;
@property(nonatomic, copy) NSString *error;
@property(nonatomic, assign) BOOL finished;
@property(nonatomic, assign) BOOL cancelled;
@property(nonatomic, strong) NSDate *created;
@property(nonatomic, copy) NSString *checksum;
@property(nonatomic, assign) BOOL durable;
@end
@implementation TVPhotoJob
@end


// Caller holds the registry lock. Completed results are a bounded cache, not
// pending work. Preserve active jobs and the most recent retryable results.
static BOOL tvPhotoCanStart(NSMutableDictionary<NSString *, TVPhotoJob *> *jobs) {
    NSUInteger active = 0;
    NSMutableArray<NSString *> *finished = [NSMutableArray array];
    for (NSString *key in jobs.allKeys) {
        TVPhotoJob *job = jobs[key];
        @synchronized(job) {
            if (!job.finished) {
                active++;
            } else if ([job.created timeIntervalSinceNow] < -600) {
                [jobs removeObjectForKey:key];
            } else {
                [finished addObject:key];
            }
        }
    }
    [finished sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        return [jobs[a].created compare:jobs[b].created];
    }];
    for (NSUInteger index = 0; index + 64 < finished.count; index++) {
        [jobs removeObjectForKey:finished[index]];
    }
    return active < 64;
}
