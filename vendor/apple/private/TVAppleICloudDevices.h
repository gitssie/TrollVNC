#import "TVAppleSettingsSession.h"
NS_ASSUME_NONNULL_BEGIN
@protocol TVAppleICloudDevicesBackend<NSObject>
- (nullable NSDictionary *)iCloudDevicesForAppleID:(NSString *)appleID error:(NSError **)error;
- (nullable NSDictionary *)removeOtherICloudDevicesForAppleID:(NSString *)appleID error:(NSError **)error;
@end
@interface TVAppleServices(ICloudDevicesInternal)
- (void)enqueueICloudDevices:(NSString *)appleID mutation:(BOOL)mutation completion:(TVAppleCompletion)completion;
@end
@interface TVAppleNativeSettingsSession(ICloudDevices)
- (nullable NSDictionary *)queryICloudDevices:(NSString *)appleID error:(NSError **)error;
- (nullable NSDictionary *)removeOtherICloudDevices:(NSString *)appleID error:(NSError **)error;
@end
FOUNDATION_EXPORT NSArray * _Nullable TVAppleDeviceLinks(id model, NSURL *origin, NSError **error);
FOUNDATION_EXPORT NSDictionary * _Nullable TVAppleDeviceInfo(id model, NSString *deviceID, NSError **error);
FOUNDATION_EXPORT NSString * _Nullable TVAppleCurrentDeviceID(NSArray *devices, NSError **error);
FOUNDATION_EXPORT NSDictionary * _Nullable TVAppleDeviceConfirmationFromXML(NSData *xml, NSString *deviceID);
FOUNDATION_EXPORT void TVAppleCaptureDeviceConfirmation(id loader,id model);
FOUNDATION_EXPORT void TVAppleAttachDeviceConfirmation(id model,NSDictionary *button);
FOUNDATION_EXPORT NSMutableURLRequest * _Nullable TVAppleDeviceRemovalRequest(id model,NSString *deviceID,NSURL *origin,NSError **error);
NS_ASSUME_NONNULL_END
