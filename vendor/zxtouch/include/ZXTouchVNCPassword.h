#pragma once
#include <stdbool.h>
#include <string.h>

// Follow classic VNC: no password list means authentication is disabled.
// Only full-control credentials may authorize device control.
static inline bool ZXTouchVNCPasswordAccepted(const char *input, const char *const *passwords, int firstViewOnly) {
    if (!passwords) return true;
    if (!input) input = "";
    size_t inputLength = strnlen(input, 8);
    bool accepted = false;
    for (int i = 0; i < firstViewOnly && passwords[i]; i++) {
        size_t length = strnlen(passwords[i], 8);
        unsigned difference = (unsigned)(length ^ inputLength);
        for (size_t j = 0; j < 8; j++)
            difference |= (j < length ? (unsigned char)passwords[i][j] : 0) ^ (j < inputLength ? (unsigned char)input[j] : 0);
        accepted |= difference == 0;
    }
    return accepted;
}
