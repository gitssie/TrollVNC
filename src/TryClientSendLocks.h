// GPL-2.0-only.
#pragma once
#include <pthread.h>

// The iterator retains only its current client. Retain each locked client
// separately, since it may disconnect after the iterator advances.
class TryClientSendLocks {
    rfbClientIteratorPtr iterator;
    rfbClientPtr locked[64];
    size_t count = 0;
    bool acquired = true;

public:
    explicit TryClientSendLocks(rfbScreenInfoPtr screen) : iterator(rfbGetClientIterator(screen)) {
        rfbClientPtr client;
        while ((client = rfbClientIteratorNext(iterator))) {
            if (count == sizeof(locked) / sizeof(locked[0]) || pthread_mutex_trylock(&client->sendMutex) != 0) {
                acquired = false;
                break;
            }
            rfbIncrClientRef(client);
            locked[count++] = client;
        }
    }
    ~TryClientSendLocks() {
        for (size_t i = 0; i < count; ++i)
            pthread_mutex_unlock(&locked[i]->sendMutex);
        while (count) rfbDecrClientRef(locked[--count]);
        rfbReleaseClientIterator(iterator);
    }
    TryClientSendLocks(const TryClientSendLocks &) = delete;
    TryClientSendLocks &operator=(const TryClientSendLocks &) = delete;
    explicit operator bool() const { return acquired; }
};
