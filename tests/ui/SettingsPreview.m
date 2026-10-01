// GPL-2.0-only. Simulator-only visual harness; never part of the installed package.
#import <UIKit/UIKit.h>
#import "TVNCRootListController.h"
#import "TVNCNetworkController.h"
#import "TVNCServiceSnapshot.h"
#import "TVNCSettingsPageController.h"

static NSDictionary *FixtureStatus(NSString *bindHost) {
    return @{@"VNCPort": @5901, @"ZXTouchPort": @6000, @"VNCRunning": @YES, @"ZXTouchRunning": @YES,
        @"VNCAcceptsIPv4": @YES, @"VNCAcceptsIPv6": @NO, @"WireGuardConfigured": @YES, @"WireGuardEnabled": @YES,
        @"WireGuardStarted": @YES, @"WireGuardAddress": @"10.99.0.2", @"WireGuardError": @"",
        @"BindHost": bindHost, @"ServerPID": @(getpid()), @"ClientCount": @2};
}
@interface TVNCRootListController (PreviewHooks)
- (void)openNetworkSettings;
@end
@interface TVNCPreviewRoot : TVNCRootListController
@property(nonatomic, strong) NSBundle *previewBundle;
@end
@implementation TVNCPreviewRoot
- (NSBundle *)bundle { return self.previewBundle; }
- (void)setBundle:(NSBundle *)bundle { self.previewBundle = bundle; }
- (void)openNetworkSettings {
    TVNCNetworkController *page = [TVNCNetworkController new]; page.localizationBundle = self.bundle;
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
    [preferences setObject:@{@"Address": @[@"10.99.0.2/32"], @"ListenPort": @51820,
        @"Peers": @[@{@"Endpoint": @"vpn.example.com:51820", @"AllowedIPs": @[@"0.0.0.0/0"],
            @"PersistentKeepalive": @25, @"PublicKey": @"abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG="}]}
        forKey:@"WireGuardConfig"];
    [preferences setBool:YES forKey:@"WireGuardEnabled"];
    NSString *bindHost = [NSProcessInfo.processInfo.environment[@"TVNC_UI_NO_STATUS"] boolValue] ?
        @"127.0.0.1" : @"192.168.1.23";
    [preferences setObject:bindHost forKey:@"BindHost"];
    [preferences synchronize];
    NSUserDefaults *runtime = [[NSUserDefaults alloc] initWithSuiteName:TVNCServiceRuntimeDomain];
    if ([NSProcessInfo.processInfo.environment[@"TVNC_UI_EMPTY_STATUS"] boolValue]) {
        [runtime removeObjectForKey:TVNCServiceSnapshotKey];
        [runtime synchronize];
    } else TVNCWriteServiceSnapshot(runtime, TVNCServiceSnapshotWithCurrentAddresses(FixtureStatus(bindHost)));
    TVNCPreviewRoot *root = [TVNCPreviewRoot new]; root.bundle = bundle;
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:root];
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds]; self.window.rootViewController = navigation;
    NSDictionary *environment = NSProcessInfo.processInfo.environment;
    if ([environment[@"TVNC_UI_DARK"] boolValue]) self.window.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    [self.window makeKeyAndVisible];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        NSArray *pages = @[@"network", @"security", @"display", @"input", @"connections", @"performance", @"web"];
        NSString *page = environment[@"TVNC_UI_PAGE"] ?: @"home";
        NSUInteger index = [pages indexOfObject:[page isEqualToString:@"wireguard"] ? @"network" : page];
        if (index != NSNotFound) {
            UITableView *table = (UITableView *)root.view;
            [root tableView:table didSelectRowAtIndexPath:[NSIndexPath indexPathForRow:index inSection:0]];
            if ([page isEqualToString:@"wireguard"]) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                    TVNCNetworkController *network = (TVNCNetworkController *)navigation.topViewController;
                    [network tableView:network.tableView didSelectRowAtIndexPath:[NSIndexPath indexPathForRow:2 inSection:2]];
                });
            }
        }
    });
    return YES;
}
@end
int main(int argc, char *argv[]) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(PreviewDelegate.class)); }
}
