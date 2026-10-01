#pragma once
#import <Foundation/Foundation.h>
#include <rfb/rfb.h>

BOOL tvScreenUnlockSupported(void);
BOOL tvScreenLockSupported(void);
// Lightweight state read for passive notifications; never inspects AX elements.
BOOL tvScreenReadLocked(BOOL *locked);
NSDictionary *tvScreenLock(NSString **error);
NSDictionary *tvScreenUnlockState(NSString **error);
NSDictionary *tvScreenUnlockPrepare(NSString **error);
NSDictionary *tvScreenUnlockArm(rfbClientPtr client, NSUInteger digits, NSString **error);
// 0: ordinary key; 1: private unlock key; -1: reject. Never log private keys.
int tvScreenUnlockKey(rfbClientPtr client, BOOL down, uint32_t key);
void tvScreenUnlockClose(rfbClientPtr client);
