#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSDictionary *_Nullable TVNCWGParseConfiguration(NSString *text, NSError **error);
FOUNDATION_EXPORT NSString *TVNCWGConfigurationText(NSDictionary *configuration);
FOUNDATION_EXPORT NSString *_Nullable TVNCWGPrimaryAddress(NSDictionary *configuration);

NS_INLINE BOOL TVNCWGShouldStart(id _Nullable configuration, id _Nullable enabledPreference) {
    return [configuration isKindOfClass:NSDictionary.class] &&
        (![enabledPreference isKindOfClass:NSNumber.class] || [enabledPreference boolValue]);
}

NS_ASSUME_NONNULL_END
