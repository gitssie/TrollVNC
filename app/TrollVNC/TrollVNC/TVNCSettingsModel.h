// GPL-2.0-only.
#import <Foundation/Foundation.h>
FOUNDATION_EXPORT NSNotificationName const TVNCSettingsDidChangeNotification;
FOUNDATION_EXPORT NSString *TVNCUIString(NSBundle *bundle, NSString *key);
FOUNDATION_EXPORT NSDictionary *TVNCSettingsCatalog(NSBundle *bundle);
FOUNDATION_EXPORT id TVNCSettingValue(NSUserDefaults *preferences, NSDictionary *row);
FOUNDATION_EXPORT NSString *TVNCSettingDisplay(NSUserDefaults *preferences, NSDictionary *row, NSBundle *bundle);
FOUNDATION_EXPORT BOOL TVNCWriteSetting(NSUserDefaults *preferences, NSDictionary *row, id value, NSError **error);
