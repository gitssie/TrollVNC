// GPL-2.0-only.
#import "TVNCServiceState.h"
#import "TVNCServiceStatus.h"

NSNotificationName const TVNCServiceStateDidChangeNotification = @"com.82flex.trollvnc.service-state-changed";

@interface TVNCServiceState ()
@property(nonatomic, strong, readwrite) NSDictionary *status;
@property(nonatomic, assign, readwrite, getter=isRunning) BOOL running;
@property(nonatomic, strong) NSTimer *timer;
@property(nonatomic, strong) NSMutableArray *completions;
@property(nonatomic, assign) NSUInteger observers;
@property(nonatomic, assign) BOOL fetching;
@end

@implementation TVNCServiceState

+ (instancetype)sharedState {
    static TVNCServiceState *state;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ state = [TVNCServiceState new]; });
    return state;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        NSUserDefaults *runtime = [[NSUserDefaults alloc] initWithSuiteName:TVNCServiceRuntimeDomain];
        _status = TVNCReadServiceSnapshot(runtime);
        _running = [_status[@"VNCRunning"] boolValue] && [_status[@"ZXTouchRunning"] boolValue];
        _completions = [NSMutableArray array];
    }
    return self;
}

- (void)acceptStatus:(NSDictionary *)status running:(BOOL)running {
    if ((self.status == status || [self.status isEqualToDictionary:status]) && self.running == running) return;
    self.status = status;
    self.running = running;
    [[NSNotificationCenter defaultCenter] postNotificationName:TVNCServiceStateDidChangeNotification object:self];
}

- (void)startObserving {
    BOOL firstObserver = ++_observers == 1;
    NSUserDefaults *runtime = [[NSUserDefaults alloc] initWithSuiteName:TVNCServiceRuntimeDomain];
    NSDictionary *published = TVNCReadServiceSnapshot(runtime);
    if (published) [self acceptStatus:published running:[published[@"VNCRunning"] boolValue] &&
        [published[@"ZXTouchRunning"] boolValue]];
    else if (self.status && !TVNCServiceSnapshotProcessAlive(self.status))
        [self acceptStatus:TVNCServiceSnapshotWithCurrentAddresses(self.status) running:NO];
    [self refreshWithCompletion:nil];
    if (!firstObserver) return;
    __weak typeof(self) weakSelf = self;
    self.timer = [NSTimer scheduledTimerWithTimeInterval:10 repeats:YES block:^(NSTimer *timer) {
        [weakSelf refreshWithCompletion:nil];
    }];
}

- (void)stopObserving {
    if (!_observers || --_observers) return;
    [self.timer invalidate];
    self.timer = nil;
}

- (void)refreshWithCompletion:(void (^)(void))completion {
    if (completion) [self.completions addObject:[completion copy]];
    if (self.fetching) return;
    self.fetching = YES;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSDictionary *fetched = TVNCFetchServiceStatus(kTvDefaultCtlPort);
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf.fetching = NO;
            if (fetched) {
                NSMutableDictionary *status = [fetched mutableCopy];
                [status removeObjectForKey:@"ClientCount"];
                if (!status[@"LocalAddresses"])
                    status = [TVNCServiceSnapshotWithCurrentAddresses(status) mutableCopy];
                [strongSelf acceptStatus:status running:[status[@"VNCRunning"] boolValue] &&
                    [status[@"ZXTouchRunning"] boolValue]];
            } else {
                NSUserDefaults *runtime = [[NSUserDefaults alloc] initWithSuiteName:TVNCServiceRuntimeDomain];
                NSDictionary *published = TVNCReadServiceSnapshot(runtime);
                NSDictionary *retained = published ?: strongSelf.status;
                if (retained) {
                    // The active bind address is daemon-owned; only the device's current IP is re-resolved.
                    NSDictionary *updated = TVNCServiceSnapshotWithCurrentAddresses(retained);
                    [strongSelf acceptStatus:updated running:TVNCServiceSnapshotProcessAlive(retained) &&
                        [retained[@"VNCRunning"] boolValue] && [retained[@"ZXTouchRunning"] boolValue]];
                }
            }
            NSArray *completions = [strongSelf.completions copy];
            [strongSelf.completions removeAllObjects];
            for (void (^block)(void) in completions) block();
        });
    });
}

@end
