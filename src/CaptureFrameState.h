// GPL-2.0-only.
#pragma once
#include <cstdint>

// Main-thread state. A skipped publication must retry even if CoreAnimation's
// dirty counter stays unchanged (including when the counter is zero).
class CaptureFrameState {
    int64_t lastDirtyCount = 0;
    bool forced = true;

public:
    bool shouldCapture(int64_t dirtyCount) const { return forced || dirtyCount != lastDirtyCount; }
    void didCapture(int64_t dirtyCount) {
        lastDirtyCount = dirtyCount;
        forced = false;
    }
    void retry() { forced = true; }
};
