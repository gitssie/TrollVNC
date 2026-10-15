#import <Foundation/Foundation.h>
#import "TVNCHTTP.h"
typedef TVNCHTTPResponse (^TVNCHTTPRoute)(NSString *, NSData *, NSString *, NSUInteger);
@interface TVNCHTTPServer : NSObject
- (instancetype)initWithHandler:(TVNCHTTPRoute)handler disconnected:(void (^)(NSUInteger))disconnected;
- (BOOL)startOnHost:(NSString *)host port:(int)port error:(NSError **)error;
- (BOOL)isClientConnected:(NSUInteger)client;
- (void)stop;
@end
NSDictionary *TVNCKaringDeviceSettings(void);
TVNCHTTPResponse TVNCHTTPData(NSData *data, int status, const char *contentType);
TVNCHTTPResponse TVNCHTTPJSON(id object, int status);
