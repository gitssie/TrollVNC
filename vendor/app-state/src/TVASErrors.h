#import <Foundation/Foundation.h>
FOUNDATION_EXPORT NSError *TVASMakeError(NSString *code, NSString *message);
FOUNDATION_EXPORT NSDictionary *TVASErrorRecord(NSError *error);
FOUNDATION_EXPORT NSDictionary *TVASHTTPError(NSError *error);
FOUNDATION_EXPORT NSInteger TVASErrorHTTPStatus(NSError *error);
