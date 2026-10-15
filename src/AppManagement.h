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
NSDictionary *tvAppHTTPRequest(NSString *token, unsigned char op, NSDictionary *payload, BOOL (^cancelled)(void), NSString **error);
NSDictionary *tvAppHTTPConnect(NSString *password);
void tvAppHTTPDisconnect(NSString *token);
#endif
