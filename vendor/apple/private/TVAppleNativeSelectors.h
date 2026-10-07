#import <Foundation/Foundation.h>
// Minimal independently declared selectors. Never expose credentials via this header.
@interface NSObject (TVAppleNativeSelectors)
+ (id)defaultStore;
+ (id)sharedInstance;
- (BOOL)fmipActive;
- (NSArray *)accountsWithAccountTypeIdentifiers:(NSArray *)types error:(NSError **)error;
- (id)aa_primaryAppleAccount;
- (id)accountType;
- (NSString *)identifier;
- (NSString *)username;
- (NSSet *)enabledDataclasses;
- (NSDictionary *)dataclassActionsForAccountDeletion:(id)account error:(NSError **)error;
- (void)removeAccount:(id)account withCompletionHandler:(void (^)(BOOL, NSError *))completion;
- (void)removeAccount:(id)account withDataclassActions:(NSDictionary *)actions completion:(void (^)(BOOL, NSError *))completion;
- (id)activeAccount;
- (id)backingAccount;
- (NSString *)accountName;
- (BOOL)isLocalAccount;
- (BOOL)isAuthenticated;
- (void)reloadAccounts;
- (void)removeAccount:(id)account completion:(void (^)(BOOL, NSError *))completion;
- (BOOL)isDestructive;
@end
