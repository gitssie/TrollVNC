#import "TVNCHTTPServer.h"
@class TVNCAppStateService;
// Disconnecting the observer never cancels or repeats the native operation.
TVNCHTTPResponse TVNCAppStateStreamResponse(TVNCAppStateService *service, NSDictionary *request, BOOL (^active)(void));
