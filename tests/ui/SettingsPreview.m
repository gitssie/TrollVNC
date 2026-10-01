// GPL-2.0-only. Simulator-only visual harness; never part of the installed package.
#import <UIKit/UIKit.h>
#import "TVNCRootListController.h"
#import "TVNCNetworkController.h"
#import "TVNCSettingsPageController.h"

static NSDictionary *FixtureStatus(void) {
    return @{@"VNCPort": @5901, @"ZXTouchPort": @6000, @"VNCRunning": @YES, @"ZXTouchRunning": @YES,
        @"VNCAcceptsIPv4": @YES, @"VNCAcceptsIPv6": @YES, @"WireGuardConfigured": @YES,
        @"WireGuardStarted": @YES, @"WireGuardAddress": @"10.99.0.2", @"WireGuardError": @"", @"BindHost": @"", @"ClientCount": @2};
}
@interface TVNCRootListController (PreviewHooks)
- (void)updateFirstGroupAndReload:(BOOL)reload;
- (void)refreshServiceStatus;
- (void)openNetworkSettings;
@end
@interface TVNCNetworkController (PreviewHooks)
- (void)refreshStatus;
@end
@interface TVNCPreviewNetwork : TVNCNetworkController
@end
@implementation TVNCPreviewNetwork
- (void)refreshStatus {
    [self setValue:FixtureStatus() forKey:@"status"];
    [self setValue:@[@"192.168.1.23"] forKey:@"localAddresses"];
    [self.tableView reloadData];
}
@end
@interface TVNCPreviewRoot : TVNCRootListController
@property(nonatomic, strong) NSBundle *previewBundle;
@end
@implementation TVNCPreviewRoot
- (NSBundle *)bundle { return self.previewBundle; }
- (void)setBundle:(NSBundle *)bundle { self.previewBundle = bundle; }
- (void)refreshServiceStatus {
    [self setValue:FixtureStatus() forKey:@"serviceStatus"];
    [self updateFirstGroupAndReload:YES];
}
- (void)openNetworkSettings {
    TVNCPreviewNetwork *page = [TVNCPreviewNetwork new]; page.localizationBundle = self.bundle;
    [self.navigationController pushViewController:page animated:NO];
}
@end
@interface PreviewDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@end
@implementation PreviewDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    NSBundle *bundle = [NSBundle bundleWithPath:[NSBundle.mainBundle pathForResource:@"TrollVNCPrefs" ofType:@"bundle"]];
    NSUserDefaults *preferences = [[NSUserDefaults alloc] initWithSuiteName:@"com.82flex.trollvnc"];
    [preferences setObject:@"example" forKey:@"FullPassword"];
    [preferences setObject:@"example" forKey:@"ViewOnlyPassword"];
    [preferences setObject:@{@"Address": @[@"10.99.0.2/32"]} forKey:@"WireGuardConfig"];
    [preferences synchronize];
    TVNCPreviewRoot *root = [TVNCPreviewRoot new]; root.bundle = bundle;
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:root];
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds]; self.window.rootViewController = navigation;
    NSDictionary *environment = NSProcessInfo.processInfo.environment;
    if ([environment[@"TVNC_UI_DARK"] boolValue]) self.window.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    [self.window makeKeyAndVisible];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        NSArray *pages = @[@"network", @"security", @"display", @"input", @"connections", @"performance", @"web"];
        NSUInteger index = [pages indexOfObject:environment[@"TVNC_UI_PAGE"] ?: @"home"];
        if (index != NSNotFound) {
            UITableView *table = (UITableView *)root.view;
            [root tableView:table didSelectRowAtIndexPath:[NSIndexPath indexPathForRow:index inSection:1]];
        }
    });
    return YES;
}
@end
int main(int argc, char *argv[]) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(PreviewDelegate.class)); }
}
