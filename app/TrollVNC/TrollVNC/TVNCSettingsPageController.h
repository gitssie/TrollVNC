// GPL-2.0-only.
#import <UIKit/UIKit.h>
@interface TVNCSettingsPageController : UITableViewController
@property(nonatomic, strong) NSBundle *localizationBundle;
@property(nonatomic, copy) NSString *categoryIdentifier;
@property(nonatomic, strong) NSUserDefaults *preferences;
@property(nonatomic, copy) void (^actionHandler)(NSString *action);
@property(nonatomic, strong, readonly) NSDictionary *category;
- (NSString *)text:(NSString *)key;
- (NSDictionary *)settingAtIndexPath:(NSIndexPath *)indexPath;
- (void)showSettingError:(NSError *)error;
@end
