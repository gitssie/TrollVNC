#import <Foundation/Foundation.h>
// GUID is the physical device UDID, never this daemon's IDFV.
FOUNDATION_EXPORT NSString *ZXTouchDeviceGUID(void);
FOUNDATION_EXPORT NSDictionary *ZXTouchDeviceInfo(NSString *name, NSString *systemName, NSString *version);
