#pragma once
#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct { unsigned char *data; size_t len; uint16_t status; const char *content_type; void *stream; } TVNCHTTPResponse;
typedef TVNCHTTPResponse (*TVNCHTTPHandler)(void *, const char *, const unsigned char *, size_t, const char *, uint64_t);
typedef void (*TVNCHTTPDisconnect)(void *, uint64_t);
typedef void (*TVNCHTTPRelease)(void *);
void *tvnc_http_start(const char *, uint16_t, const char *, const char *, void *, TVNCHTTPHandler, TVNCHTTPDisconnect, TVNCHTTPRelease);
bool tvnc_http_connected(void *, uint64_t);
void tvnc_http_stop(void *);
// Receiver is consumed by the response; producer is released exactly once by native code.
void *tvnc_http_stream_new(void **producer);
bool tvnc_http_stream_send(void *producer, const unsigned char *, size_t);
bool tvnc_http_stream_open(void *producer);
void tvnc_http_stream_release(void *producer);
#ifdef __cplusplus
}
#endif
