#pragma once

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// PhotoKit work runs on a serial background queue. No rfbClientPtr is retained.
// Operations: 4 import remote path, 5 list page, 6 export original asset,
// 9 delete one or more Photos assets in a single change transaction.
int tvPhotoStart(unsigned char op, const char *root, const char *value,
                 const char *expected_sha256, char *token, size_t token_capacity,
                 char *error, size_t error_capacity);
// Returns 1 while running, 0 with JSON payload, -1 with an error. Caller frees
// returned strings with free(). Jobs remain queryable briefly after completion.
int tvPhotoPoll(const char *token, char **payload, char **error);
int tvPhotoCleanupExport(const char *remote_path);

#ifdef __cplusplus
}
#endif
