#pragma once
#include <rfb/rfb.h>
#ifdef __cplusplus
extern "C" {
#endif
void tvRegisterAppManagement(rfbScreenInfoPtr screen);
void tvUnregisterAppManagement(void);
#ifdef __cplusplus
}
#endif
