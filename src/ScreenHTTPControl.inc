// Shared operation runner. Included after the native screen/HID primitives.
void tvScreenHTTPControl(BOOL locking, NSString *passcode, BOOL (^active)(void), BOOL (^authorized)(void), BOOL (^emit)(NSDictionary *)) {
    tvUnlockInit();
    [tvLeaseLock lock];
    BOOL busy = tvHTTPActive;
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    for (NSDictionary *lease in tvLeases.allValues) {
        if ([lease[@"until"] doubleValue] > now) busy = YES;
    }
    if (!busy) tvHTTPActive = YES;
    [tvLeaseLock unlock];
    if (busy) { emit(@{@"phase":@"failed", @"error":@"Screen operation busy"}); return; }
    NSObject *gate = [NSObject new];
    __block BOOL finished = NO;
    __block BOOL writable = YES;
    NSTimeInterval deadline = now + 12;
    BOOL (^running)(void) = ^BOOL {
        @synchronized(gate) { return !finished && writable && active() && NSProcessInfo.processInfo.systemUptime < deadline; }
    };
    // Authorization may wait on the app queue. Never invoke it from main callbacks
    // or while holding the HID keyboard mutex; those paths use running() only.
    BOOL (^checked)(void) = ^BOOL { return running() && authorized() && running(); };
    BOOL (^event)(NSString *, NSDictionary *, NSString *) = ^BOOL(NSString *phase, NSDictionary *state, NSString *error) {
        NSMutableDictionary *value = [@{@"phase":phase} mutableCopy];
        if (state) value[@"state"] = state;
        if (error) value[@"error"] = error;
        @synchronized(gate) { writable = emit(value); return writable; }
    };
    @try {
        if (!checked()) return;
        NSString *error = nil;
        if (locking) {
            if (!event(@"locking", nil, nil)) return;
            NSDictionary *state = tvScreenLockImpl(&error, running);
            if (running()) event(state ? @"locked" : @"failed", state, error);
            return;
        }
        if (passcode.length != 6 || [passcode rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789"] invertedSet]].location != NSNotFound) {
            event(@"failed", nil, @"Only 6 digit passcodes are supported"); return;
        }
        if (!event(@"preparing", nil, nil)) return;
        NSDictionary *state = nil;
        NSUInteger ready = 0;
        while (checked()) {
            state = tvScreenUnlockPrepareImpl(&error, running);
            if (!state) { event(@"failed", nil, error); return; }
            if (![state[@"locked"] boolValue]) { event(@"unlocked", state, nil); return; }
            if ([state[@"input_ready"] boolValue] && ![state[@"input_empty"] boolValue]) {
                event(@"failed", state, @"密码框已有输入，请先清空"); return;
            }
            ready = [state[@"input_ready"] boolValue] && [state[@"input_empty"] boolValue] ? ready + 1 : 0;
            if (ready >= 2) break;
            usleep(250000);
        }
        if (!checked()) { if (active() && writable) event(@"failed", nil, @"解锁超时，请检查手机"); return; }
        [tvLeaseLock lock];
        BOOL cooldown = NSProcessInfo.processInfo.systemUptime - tvLastAttempt < 8.0;
        if (!cooldown) tvLastAttempt = NSProcessInfo.processInfo.systemUptime;
        [tvLeaseLock unlock];
        if (cooldown) { event(@"failed", state, @"请稍后再尝试解锁"); return; }
        if (!event(@"input_ready", state, nil) || !event(@"entering", nil, nil)) return;
        STHIDEventGenerator *gen = [STHIDEventGenerator sharedGenerator];
        for (NSUInteger index = 0; index < 6; index++) {
            if (!checked()) return;
            BOOL locked, required;
            if (!tvReadLock(&locked, &required) || !locked || !required) {
                state = tvScreenUnlockState(&error);
                event(state && ![state[@"locked"] boolValue] ? @"unlocked" : @"failed", state, error ?: @"Screen state changed during input"); return;
            }
            NSString *digit = [passcode substringWithRange:NSMakeRange(index, 1)];
            [gen performKeyboardSequence:^{ if (running()) [gen keyPress:digit]; }];
            usleep(100000);
        }
        passcode = nil;
        if (!event(@"checking", nil, nil)) return;
        while (checked()) {
            state = tvScreenUnlockState(&error);
            if (!state) { event(@"failed", nil, error); return; }
            if (![state[@"locked"] boolValue]) { event(@"unlocked", state, nil); return; }
            usleep(250000);
        }
        if (active() && writable) event(@"failed", state, @"解锁未完成，请检查密码和手机状态");
    } @catch (__unused NSException *exception) {
        if (active() && writable) event(@"failed", nil, @"Screen operation failed");
    } @finally {
        @synchronized(gate) { finished = YES; }
        [tvLeaseLock lock]; tvHTTPActive = NO; [tvLeaseLock unlock];
    }
}
