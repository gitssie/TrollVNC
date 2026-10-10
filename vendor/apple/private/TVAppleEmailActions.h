#import "TVAppleEmailSettings.h"
#import "TVAppleSettingsSession.h"
NS_ASSUME_NONNULL_BEGIN
@protocol TVAppleEmailActionsBackend <NSObject>
- (nullable NSDictionary *)beginContactEmail:(NSString *)email appleID:(NSString *)appleID error:(NSError **)error;
- (nullable NSDictionary *)verifyContactEmail:(NSString *)challenge code:(NSString *)code appleID:(NSString *)appleID error:(NSError **)error;
- (nullable NSDictionary *)setRelayEmail:(NSString *)email appleID:(NSString *)appleID error:(NSError **)error;
@end
@interface TVAppleServices (EmailActionWorker)
- (void)enqueueEmailAction:(NSString *)action appleID:(NSString *)appleID value:(NSString *)value code:(nullable NSString *)code completion:(TVAppleCompletion)completion;
@end
FOUNDATION_EXPORT BOOL TVAppleValidEmailAddress(id value);
FOUNDATION_EXPORT NSMutableURLRequest * _Nullable TVAppleEmailPostbackRequest(id model,id element,NSDictionary *values,NSURL *origin,NSString *expectedPath,NSError **error);
FOUNDATION_EXPORT NSMutableURLRequest * _Nullable TVAppleRelayForwardingRequest(id form,NSString *email,NSURL *origin,NSError **error);
// Injectable production observer for terminal ordering / headless regressions.
@interface TVAppleEmailLoad : NSObject
@property id _Nullable model;
@property BOOL rejected,closed,finished,parserProbePending;
@property NSError * _Nullable failure;
@property NSError * _Nullable nativeAlertError;
@property NSInteger status;
- (BOOL)complete;
- (void)loader:(id)loader loadResourcesForObjectModel:(id)model completion:(void(^)(BOOL,NSError * _Nullable))completion;
- (void)loader:(id)loader receivedObjectModel:(id)model topActionSignal:(nullable id)signal;
- (void)loader:(id)loader didReceiveHTTPResponse:(NSHTTPURLResponse *)response;
- (void)loader:(id)loader didFinishLoadWithError:(nullable NSError *)error;
@end
FOUNDATION_EXPORT void TVAppleObserveEmailParserAlert(id loader,TVAppleEmailLoad *load,BOOL mutation);
FOUNDATION_EXPORT id _Nullable TVAppleFinishEmailLoad(TVAppleEmailLoad *load,BOOL terminalObserved,BOOL mutation,NSError **error);
NS_ASSUME_NONNULL_END
