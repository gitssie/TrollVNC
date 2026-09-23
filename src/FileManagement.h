#pragma once

#ifdef __cplusplus
extern "C" {
#endif

// TrollVNC's opt-in RFB file-management extension. Register only while
// TightVNC file transfer is enabled; clients must advertise the matching
// pseudo encoding before they can send a management request.
void tvRegisterFileManagement(const char *root);
void tvUnregisterFileManagement(void);

#ifdef __cplusplus
}
#endif
