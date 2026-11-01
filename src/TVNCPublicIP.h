// SPDX-License-Identifier: GPL-2.0-only
#pragma once
#import <Foundation/Foundation.h>
#ifdef __cplusplus
extern "C" {
#endif
NSDictionary *TVNCPublicIPResult(NSData *data, NSURLResponse *response, NSError *error);
void TVNCQueryPublicIP(void (^completion)(NSDictionary *result));
#ifdef __cplusplus
}
#endif
