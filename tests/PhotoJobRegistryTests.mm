#import <Foundation/Foundation.h>
#include <assert.h>
#import "PhotoJobRegistry.inc"

static TVPhotoJob *job(BOOL finished, NSTimeInterval created) {
    TVPhotoJob *value = [TVPhotoJob new];
    value.finished = finished;
    value.created = [NSDate dateWithTimeIntervalSinceNow:created];
    value.result = @"result";
    return value;
}
int main(void) {
    @autoreleasepool {
        NSMutableDictionary *jobs = [NSMutableDictionary dictionary];
        // The real browsing pattern: serial reads complete within the old
        // ten-minute retention interval. Thousands must never exhaust admission.
        for (int i = 0; i < 2000; i++) {
            assert(tvPhotoCanStart(jobs));
            NSString *key = [NSString stringWithFormat:@"page-%d", i];
            TVPhotoJob *current = job(NO, 0);
            jobs[key] = current;
            current.finished = YES;
            assert(jobs.count <= 65);
        }
        assert(tvPhotoCanStart(jobs));
        assert(jobs.count == 64);
        assert(jobs[@"page-1999"]);
        assert(!jobs[@"page-0"]);
        [jobs removeAllObjects];
        // Active jobs must not be evicted, even when older than the cache TTL.
        for (int i = 0; i < 64; i++) jobs[@(i)] = job(NO, -700);
        jobs[@"expired"] = job(YES, -700);
        assert(!tvPhotoCanStart(jobs));
        assert(jobs.count == 64);
        TVPhotoJob *first = jobs[@0];
        first.finished = YES;
        assert(tvPhotoCanStart(jobs));
        assert(jobs.count == 63);
        assert(!jobs[@0]);
        puts("Photo registry: serial browsing, cache bounds, active limit and recovery passed");
    }
}
