#import "TVApplePolicy.h"
#import "TVAppleNativeSelectors.h"
NSDictionary *TVAppleChooseDataclassActions(NSDictionary *options, TVAppleLocalDataPolicy policy, NSError **error) {
    if (![options isKindOfClass:NSDictionary.class] ||
        (policy != TVAppleLocalDataRemove && policy != TVAppleLocalDataKeep)) {
        *error = TVAppleError(TVAppleErrorInvalidRequest, @"Invalid dataclass policy."); return nil;
    }
    NSSet *expected = policy == TVAppleLocalDataRemove
        ? [NSSet setWithArray:@[@"ACDataclassActionDeleteSyncData", @"ACDataclassActionLoseNonUploadedData"]]
        : [NSSet setWithObject:@"ACDataclassActionMergeSyncDataIntoLocalData"];
    NSMutableDictionary *chosen = [NSMutableDictionary new];
    for (id key in options) {
        if (![key isKindOfClass:NSString.class] || ![options[key] isKindOfClass:NSArray.class]) {
            *error = TVAppleError(TVAppleErrorUnsupported, @"Malformed dataclass options."); return nil;
        }
        id match = nil;
        for (id action in options[key]) {
            // Exact system names observed on the validated OS, never substring matches.
            if ([expected containsObject:[action description]] && [action respondsToSelector:@selector(isDestructive)] &&
                (policy == TVAppleLocalDataRemove || ![action isDestructive])) {
                if (match) { *error = TVAppleError(TVAppleErrorUnsupported, @"Deletion actions are ambiguous."); return nil; }
                match = action;
            }
        }
        if (!match) { *error = TVAppleError(TVAppleErrorUnsupported, @"The requested local data policy is unsupported for a dataclass."); return nil; }
        chosen[key] = match;
    }
    return [chosen copy];
}
