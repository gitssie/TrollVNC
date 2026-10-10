#pragma once
#include <rfb/rfb.h>
#ifdef __cplusplus
extern "C" {
#endif
void tvRegisterAppManagement(rfbScreenInfoPtr screen, int controlPort);
void tvUnregisterAppManagement(void);
#ifdef __cplusplus
}
#endif
#ifdef __OBJC__
#import <Foundation/Foundation.h>
NSData *tvAppZXTouchRequest(NSString *encoded, BOOL (^cancelled)(void));
#endif
