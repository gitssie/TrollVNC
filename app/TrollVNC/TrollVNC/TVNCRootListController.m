/*
 This file is part of TrollVNC
 Copyright (c) 2025 82Flex <82flex@gmail.com> and contributors

 This program is free software; you can redistribute it and/or modify
 it under the terms of the GNU General Public License version 2
 as published by the Free Software Foundation.

 This program is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 GNU General Public License for more details.

 You should have received a copy of the GNU General Public License
 along with this program. If not, see <https://www.gnu.org/licenses/>.
*/

#import <Foundation/Foundation.h>
#import <Network/Network.h>
#import <Preferences/PSSpecifier.h>
#import <SystemConfiguration/SystemConfiguration.h>
#import <UIKit/UIKit.h>
#import <arpa/inet.h>
#import <dlfcn.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <notify.h>
#import <signal.h>
#import <stdlib.h>
#import <string.h>

#import "StripedTextTableViewController.h"
#import "TVNCClientListController.h"
#import "TVNCRootListController.h"
#import "TVNCUtil.h"
#import "TVNCServiceStatus.h"
#import "TVNCSettingsModel.h"
#import "TVNCSettingsAppearance.h"
#import "TVNCSettingsPageController.h"
#import "ZTSelfSignedCertificate.h"

#ifdef THEBOOTSTRAP
#import "GitHubReleaseUpdater.h"
#endif

NS_INLINE BOOL TVNCIsValidBindHostLiteral(NSString *host) {
    if (!host)
        return YES;

    NSString *trimmed = [host stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0)
        return YES; // Empty means bind any interface

    const char *cstr = trimmed.UTF8String;
    if (!cstr || cstr[0] == '\0')
        return YES;

    struct in_addr v4;
    if (inet_pton(AF_INET, cstr, &v4) == 1)
        return YES;

    // Allow optional IPv6 scope suffix (e.g. fe80::1%en0)
    char addrBuf[INET6_ADDRSTRLEN + 1] = {0};
    const char *pct = strchr(cstr, '%');
    size_t copyLen = pct ? (size_t)(pct - cstr) : strlen(cstr);
    if (copyLen >= sizeof(addrBuf))
        copyLen = sizeof(addrBuf) - 1;
    memcpy(addrBuf, cstr, copyLen);
    addrBuf[copyLen] = '\0';

    struct in6_addr v6;
    return inet_pton(AF_INET6, addrBuf, &v6) == 1;
}

@interface TVNCRootListController ()

@property(nonatomic, strong) nw_path_monitor_t monitor;

@property(nonatomic, strong) UINotificationFeedbackGenerator *notificationGenerator;
@property(nonatomic, strong) UIColor *primaryColor;
@property(nonatomic, copy) NSString *jbrootPath;

@property(nonatomic, strong) PSSpecifier *firstGroupSpecifier;
@property(nonatomic, strong) NSTimer *statusTimer;
@property(nonatomic, strong) NSDictionary *serviceStatus;
@property(nonatomic, assign) BOOL fetchingStatus;
@property(nonatomic, strong) PSSpecifier *certSpecifier;
@property(nonatomic, strong) PSSpecifier *keysSpecifier;
@property(nonatomic, strong) PSSpecifier *exportCertSpecifier;

@property(nonatomic, copy) NSString *defaultFooterText;

@end

@implementation TVNCRootListController {
    int _notifyToken;
}

#ifdef THEBOOTSTRAP
@synthesize bundle = _bundle;

- (NSBundle *)bundle {
    if (!_bundle) {
        _bundle = [NSBundle bundleWithPath:[[NSBundle mainBundle] pathForResource:@"TrollVNCPrefs" ofType:@"bundle"]];
    }
    return _bundle;
}
#endif

/* clangd behavior workarounds */
#define STRINGIFY(x) #x
#define EXPAND_AND_STRINGIFY(x) STRINGIFY(x)
#define MYNSSTRINGIFY(x)                                                                                               \
    ^{                                                                                                                 \
        NSString *str = [NSString stringWithUTF8String:EXPAND_AND_STRINGIFY(x)];                                       \
        if ([str hasPrefix:@"\""])                                                                                     \
            str = [str substringFromIndex:1];                                                                          \
        if ([str hasSuffix:@"\""])                                                                                     \
            str = [str substringToIndex:str.length - 1];                                                               \
        return str;                                                                                                    \
    }()

- (BOOL)hasManagedConfiguration {
    static BOOL sIsManaged = NO;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *presetPath = [self.bundle pathForResource:@"Managed" ofType:@"plist"];
        if (presetPath) {
            NSDictionary *presetDict = [NSDictionary dictionaryWithContentsOfFile:presetPath];
            if (presetDict) {
                sIsManaged = YES;
            }
        }
    });
    return sIsManaged;
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray<PSSpecifier *> *specifiers = nil;

        if (!specifiers) {
            if ([self hasManagedConfiguration]) {
                specifiers = [self loadSpecifiersFromPlistName:@"ManagedRoot" target:self];
            }
        }

        if (!specifiers) {
            specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
        }

        PSSpecifier *firstGroup = [specifiers firstObject];
        _firstGroupSpecifier = firstGroup;

        for (PSSpecifier *specifier in specifiers) {
            NSString *actionName = [specifier propertyForKey:@"action"];
            if ([actionName isEqualToString:@"exportCertificate"]) {
                _exportCertSpecifier = specifier;
                break;
            }

            NSString *keyName = [specifier propertyForKey:@"key"];
            if ([keyName isEqualToString:@"SslCertFile"]) {
                _certSpecifier = specifier;
            } else if ([keyName isEqualToString:@"SslKeyFile"]) {
                _keysSpecifier = specifier;

            }
        }

        _specifiers = specifiers;
        [self updateFirstGroupAndReload:NO];
    }

    return _specifiers;
}

- (void)dealloc {
    [_statusTimer invalidate];
    if (_monitor) {
        nw_path_monitor_cancel(_monitor);
    }
    if (_notifyToken) {
        notify_cancel(_notifyToken);
    }
}

// Add Apply button in nav bar
- (void)viewDidLoad {
    [super viewDidLoad];

    _notificationGenerator = [[UINotificationFeedbackGenerator alloc] init];
    _primaryColor = TVNCAccentColor();
    [[UISwitch appearanceWhenContainedInInstancesOfClasses:@[
        [self class],
    ]] setOnTintColor:_primaryColor];
    [[UISlider appearanceWhenContainedInInstancesOfClasses:@[
        [self class],
    ]] setMinimumTrackTintColor:_primaryColor];
    [self.view setTintColor:_primaryColor];

    self.navigationItem.backBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"TrollVNC"
                                                                             style:UIBarButtonItemStylePlain
                                                                            target:nil
                                                                            action:nil];
    self.navigationItem.backBarButtonItem.tintColor = _primaryColor;

    if ([self hasManagedConfiguration]) {
        return;
    }

    UIBarButtonItem *applyItem = [[UIBarButtonItem alloc]
        initWithTitle:NSLocalizedStringFromTableInBundle(@"Apply", @"Localizable", self.bundle, nil)
                style:UIBarButtonItemStyleDone
               target:self
               action:@selector(applyChanges)];
    applyItem.tintColor = _primaryColor;

    self.navigationItem.rightBarButtonItem = applyItem;
    UITableView *settingsTable = [self settingsTableView];
    TVNCStyleSettingsTable(settingsTable);
    self.title = @"TrollVNC";
    UILabel *subtitle = TVNCSettingsLabel(UIFontTextStyleCaption1, UIColor.secondaryLabelColor);
    subtitle.text = @"Dopamine · rootless"; subtitle.textAlignment = NSTextAlignmentCenter;
    subtitle.frame = CGRectMake(0, 0, settingsTable.bounds.size.width, 28);
    settingsTable.tableHeaderView = subtitle;

    self.monitor = nw_path_monitor_create();
    nw_path_monitor_set_queue(self.monitor, dispatch_get_main_queue());

    __weak typeof(self) weakSelf = self;
    nw_path_monitor_set_update_handler(self.monitor, ^(nw_path_t _Nonnull path) {
        [weakSelf updateFirstGroupAndReload:YES];
    });
    nw_path_monitor_start(self.monitor);

    notify_register_dispatch(TVNC_NOTIFY_PREFS_CHANGED, &_notifyToken, dispatch_get_main_queue(), ^(int token) {
        [weakSelf refreshServiceStatus];
    });
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];

    [self refreshServiceStatus];
    [_statusTimer invalidate];
    __weak typeof(self) weakSelf = self;
    _statusTimer = [NSTimer scheduledTimerWithTimeInterval:3 repeats:YES block:^(NSTimer *timer) {
        [weakSelf refreshServiceStatus];
    }];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    [_statusTimer invalidate]; _statusTimer = nil;
}

- (void)refreshServiceStatus {
    if (_fetchingStatus) return;
    _fetchingStatus = YES;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSDictionary *status = TVNCFetchServiceStatus(kTvDefaultCtlPort);
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf.fetchingStatus = NO;
            strongSelf.serviceStatus = status;
            [strongSelf updateFirstGroupAndReload:YES];
        });
    });
}

- (void)showClients {
    TVNCClientListController *vc = [[TVNCClientListController alloc] init];
    vc.bundle = self.bundle;
    vc.primaryColor = self.primaryColor;
    vc.notificationGenerator = self.notificationGenerator;
    UINavigationController *navController = [[UINavigationController alloc] initWithRootViewController:vc];
    [[self actionPresenter] presentViewController:navController animated:YES completion:nil];
}

- (NSString *)defaultFooterText {
    if (!_defaultFooterText) {
        NSString *packageScheme = MYNSSTRINGIFY(THEOS_PACKAGE_SCHEME);
        if (!packageScheme.length) {
            packageScheme = @"legacy";
        }

        NSString *versionString;
#ifdef THEBOOTSTRAP
        versionString = [[GitHubReleaseUpdater shared] currentVersion];
#else
        versionString = @PACKAGE_VERSION;
#endif

        NSString *footerText = [NSString
            stringWithFormat:NSLocalizedStringFromTableInBundle(@"TrollVNC (%@) v%@", @"Localizable", self.bundle, nil),
                             packageScheme, versionString];
        _defaultFooterText = footerText;
    }
    return _defaultFooterText;
}

- (NSString *)currentStatusText {
    if (!_serviceStatus) return NSLocalizedStringFromTableInBundle(@"Service status unavailable", @"Localizable", self.bundle, nil);
    return [NSString stringWithFormat:@"VNC :%@ · ZXTouch :%@\n%@", _serviceStatus[@"VNCPort"],
        _serviceStatus[@"ZXTouchPort"], NSLocalizedStringFromTableInBundle(
            [_serviceStatus[@"WireGuardStarted"] boolValue] ? @"Wi-Fi + WireGuard" : @"Local network", @"Localizable", self.bundle, nil)];
}

- (void)updateFirstGroupAndReload:(BOOL)reload {
    if (!_firstGroupSpecifier) {
        return;
    }

    if (![self hasManagedConfiguration]) {
        if (reload && self.isViewLoaded) [[self settingsTableView] reloadData];
        return;
    }
    NSString *footerText = [NSString stringWithFormat:@"%@\n%@", [self defaultFooterText], [self currentStatusText]];
    [_firstGroupSpecifier setProperty:footerText forKey:@"footerText"];

    if (reload) {
        [self reloadSpecifier:_firstGroupSpecifier animated:NO];
    }
}

#pragma mark - Actions

- (void)openNetworkSettings {
    [self.bundle load];
    Class controllerClass = NSClassFromString(@"TVNCNetworkController");
    if (!controllerClass) return;
    UIViewController *controller = [[controllerClass alloc] init];
    [controller setValue:self.bundle forKey:@"localizationBundle"];
    [self.navigationController pushViewController:controller animated:YES];
}

- (void)applyChanges {
    // Resign first responder status
    [self.view endEditing:YES];

    NSUserDefaults *preferences = [[NSUserDefaults alloc] initWithSuiteName:@"com.82flex.trollvnc"];
    [preferences synchronize];
    int port = TVNCParseServicePort([preferences objectForKey:@"Port"] ?: @5901, NO);
    int zxPort = TVNCParseServicePort([preferences objectForKey:@"ZXTouchPort"] ?: @6000, NO);
    int httpPort = TVNCParseServicePort([preferences objectForKey:@"HttpPort"] ?: @0, YES);
    NSString *bindHost = [preferences stringForKey:@"BindHost"] ?: @"";
    if (!TVNCServicePortsValid(port, zxPort, httpPort)) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:
            NSLocalizedStringFromTableInBundle(@"Invalid Port", @"Localizable", self.bundle, nil)
            message:NSLocalizedStringFromTableInBundle(@"Ports must be distinct and within 1024–65535. HTTP may be 0. Ports 46751 and 46752 are reserved.", @"Localizable", self.bundle, nil)
            preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
        [[self actionPresenter] presentViewController:alert animated:YES completion:nil]; return;
    }
    if ([preferences dictionaryForKey:@"WireGuardConfig"] && !TVNCSharedBindAllowsWireGuard(bindHost)) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"WireGuard"
            message:NSLocalizedStringFromTableInBundle(@"Clear the shared listen address to use both Wi-Fi and WireGuard.", @"Localizable", self.bundle, nil)
            preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
        [[self actionPresenter] presentViewController:alert animated:YES completion:nil]; return;
    }

    if (!TVNCIsValidBindHostLiteral(bindHost)) {
        NSString *t = NSLocalizedStringFromTableInBundle(@"Invalid Bind Address", @"Localizable", self.bundle, nil);
        NSString *msg = NSLocalizedStringFromTableInBundle(
            @"Bind address must be a valid IPv4/IPv6 literal, or empty to listen on all interfaces.",
            @"Localizable", self.bundle, nil);
        NSString *ok = NSLocalizedStringFromTableInBundle(@"OK", @"Localizable", self.bundle, nil);

        UIAlertController *alert = [UIAlertController alertControllerWithTitle:t
                                                                       message:msg
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:ok style:UIAlertActionStyleCancel handler:nil]];

        [[self actionPresenter] presentViewController:alert animated:YES completion:nil];
        return; // do not restart now
    }

    NSString *title = NSLocalizedStringFromTableInBundle(@"Apply Changes", @"Localizable", self.bundle, nil);
    NSString *message = NSLocalizedStringFromTableInBundle(@"Restart TrollVNC to apply changes to both VNC and ZXTouch?",
                                                           @"Localizable", self.bundle, nil);

    NSString *fullMessage = [NSString stringWithFormat:@"%@\n%@", message, [self currentStatusText]];
    NSString *cancel = NSLocalizedStringFromTableInBundle(@"Cancel", @"Localizable", self.bundle, nil);
    NSString *restart = NSLocalizedStringFromTableInBundle(@"Restart", @"Localizable", self.bundle, nil);

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:fullMessage
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:cancel style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:restart
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *_Nonnull action) {
                                                TVNCRestartVNCService();
                                                [weakSelf.notificationGenerator
                                                    notificationOccurred:UINotificationFeedbackTypeSuccess];
                                                [weakSelf.view endEditing:YES];
                                            }]];

    [[self actionPresenter] presentViewController:alert animated:YES completion:nil];
}

- (NSString *)jbrootPath {
    if (!_jbrootPath) {
        NSString *rootPath = [self.bundle bundlePath];
        do {
            if ([rootPath hasSuffix:@"/procursus"] || [rootPath hasSuffix:@"/var/jb"] ||
                [[rootPath lastPathComponent] hasPrefix:@".jbroot-"]) {
                // Found the jailbreak root
                break;
            }
            if ([rootPath hasPrefix:@"/private/preboot/"] && [rootPath hasSuffix:@"/jb"]) {
                // Found the jailbreak root (NathanLR)
                break;
            }
            if ([rootPath isEqualToString:@"/"] || !rootPath.length) {
                // Reached the root without finding jailbreak root
                break;
            }
            rootPath = [rootPath stringByDeletingLastPathComponent];
        } while (YES);
        _jbrootPath = rootPath;
    }
    return _jbrootPath;
}

- (void)viewLogs {
#if TARGET_IPHONE_SIMULATOR
    NSString *logsPath = [NSHomeDirectory() stringByAppendingPathComponent:@"tmp/trollvnc-stderr.log"];
#else
    NSString *logsPath = [self.jbrootPath stringByAppendingPathComponent:@"tmp/trollvnc-stderr.log"];
#endif

    StripedTextTableViewController *logsVC = [[StripedTextTableViewController alloc] initWithPath:logsPath];
    logsVC.primaryColor = self.primaryColor;

    [logsVC setAutoReload:YES];
    [logsVC setMaximumNumberOfRows:1000];
    [logsVC setMaximumNumberOfLines:20];
    [logsVC setReversed:YES];
    [logsVC setAllowDismissal:YES];
    [logsVC setAllowMultiline:YES];
    [logsVC setAllowTrash:NO];
    [logsVC setAllowSearch:YES];
    [logsVC setAllowShare:YES];
    [logsVC setPullToReload:YES];
    [logsVC setTapToCopy:YES];
    [logsVC setPressToCopy:YES];
    [logsVC setPreserveEmptyLines:NO];
    [logsVC setRemoveDuplicates:NO];

    NSRegularExpression *rowRegex =
        [NSRegularExpression regularExpressionWithPattern:@"^\\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}:\\d{2}\\b"
                                                  options:0
                                                    error:nil];

    [logsVC setRowPrefixRegularExpression:rowRegex];
    [logsVC setRowSeparator:@"\r\n"];
    [logsVC setTitle:NSLocalizedStringFromTableInBundle(@"View Logs", @"Localizable", self.bundle, nil)];
    [logsVC setLocalizationBundle:self.bundle];

    UINavigationController *navController = [[UINavigationController alloc] initWithRootViewController:logsVC];
    [[self actionPresenter] presentViewController:navController animated:YES completion:nil];
}

- (NSString *)cacertPath {
#if TARGET_IPHONE_SIMULATOR
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Preferences/com.82flex.trollvnc.ca-cert.pem"];
#else
    return [self.jbrootPath
        stringByAppendingPathComponent:@"var/mobile/Library/Preferences/com.82flex.trollvnc.ca-cert.pem"];
#endif
}

- (NSString *)cakeyPath {
#if TARGET_IPHONE_SIMULATOR
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Preferences/com.82flex.trollvnc.ca-key.pem"];
#else
    return [self.jbrootPath
        stringByAppendingPathComponent:@"var/mobile/Library/Preferences/com.82flex.trollvnc.ca-key.pem"];
#endif
}

- (void)exportCertificate {
    NSString *cacertPath = [self cacertPath];
    if (![[NSFileManager defaultManager] fileExistsAtPath:cacertPath]) {
        NSString *title =
            NSLocalizedStringFromTableInBundle(@"Certificate Not Found", @"Localizable", self.bundle, nil);
        NSString *message = NSLocalizedStringFromTableInBundle(
            @"You need to generate a self-signed CA certificate first before exporting it.", @"Localizable",
            self.bundle, nil);
        NSString *ok = NSLocalizedStringFromTableInBundle(@"OK", @"Localizable", self.bundle, nil);

        UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                       message:message
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:ok style:UIAlertActionStyleCancel handler:nil]];

        [[self actionPresenter] presentViewController:alert animated:YES completion:nil];
        return;
    }

    NSURL *fileURL = [NSURL fileURLWithPath:cacertPath];
    if (!fileURL) {
        return;
    }

    UIActivityViewController *activityViewController =
        [[UIActivityViewController alloc] initWithActivityItems:@[ fileURL ] applicationActivities:nil];

    PSTableCell *exportCertCell = nil;
    if (_exportCertSpecifier) {
        exportCertCell = [self cachedCellForSpecifier:_exportCertSpecifier];
    }
    activityViewController.popoverPresentationController.sourceView = exportCertCell ?: [self actionPresenter].view;
    activityViewController.popoverPresentationController.sourceRect = activityViewController.popoverPresentationController.sourceView.bounds;

    [[self actionPresenter] presentViewController:activityViewController animated:YES completion:nil];
}

- (void)generateKeys {
    NSString *cakeyPath = [self cakeyPath];
    if ([[NSFileManager defaultManager] fileExistsAtPath:cakeyPath]) {
        NSString *title =
            NSLocalizedStringFromTableInBundle(@"Overwrite Existing Keys", @"Localizable", self.bundle, nil);
        NSString *message =
            NSLocalizedStringFromTableInBundle(@"A CA private key already exists. Generating new keys will overwrite "
                                               @"the existing ones. Are you sure you want to continue?",
                                               @"Localizable", self.bundle, nil);
        NSString *cancel = NSLocalizedStringFromTableInBundle(@"Cancel", @"Localizable", self.bundle, nil);
        NSString *generate = NSLocalizedStringFromTableInBundle(@"Overwrite", @"Localizable", self.bundle, nil);

        UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                       message:message
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:cancel style:UIAlertActionStyleCancel handler:nil]];
        __weak typeof(self) weakSelf = self;
        [alert addAction:[UIAlertAction actionWithTitle:generate
                                                  style:UIAlertActionStyleDestructive
                                                handler:^(UIAlertAction *_Nonnull action) {
                                                    [weakSelf _reallyGenerateKeys];
                                                }]];
        [alert addAction:[UIAlertAction actionWithTitle:NSLocalizedStringFromTableInBundle(
                                                            @"Export Certificate…", @"Localizable", self.bundle, nil)
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *_Nonnull action) {
                                                    [weakSelf exportCertificate];
                                                }]];

        [[self actionPresenter] presentViewController:alert animated:YES completion:nil];
        return;
    }

    [self _reallyGenerateKeys];
}

- (void)_reallyGenerateKeys {
    NSString *randomUUID = [[[NSUUID UUID] UUIDString] substringFromIndex:28];
    NSString *commonName = [NSString stringWithFormat:@"TrollVNC %@", randomUUID];

    ZTSelfSignedCertificate *ca = [ZTSelfSignedCertificate generateWithCommonName:commonName];
    if (!ca) {
        NSString *title = NSLocalizedStringFromTableInBundle(@"Generation Failed", @"Localizable", self.bundle, nil);
        NSString *message = NSLocalizedStringFromTableInBundle(@"Failed to generate self-signed CA certificate.",
                                                               @"Localizable", self.bundle, nil);
        NSString *ok = NSLocalizedStringFromTableInBundle(@"OK", @"Localizable", self.bundle, nil);

        UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                       message:message
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:ok style:UIAlertActionStyleCancel handler:nil]];

        [[self actionPresenter] presentViewController:alert animated:YES completion:nil];
        return;
    }

    BOOL succeed = YES;
    NSError *error = nil;
    do {
        NSString *cacertPath = [self cacertPath];
        succeed = [ca.certificatePEM writeToFile:cacertPath atomically:YES encoding:NSUTF8StringEncoding error:&error];
        if (!succeed) {
            break;
        }

        succeed = [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions : @0600}
                                                   ofItemAtPath:cacertPath
                                                          error:&error];
        if (!succeed) {
            break;
        }

        NSString *cakeyPath = [self cakeyPath];
        succeed = [ca.privateKeyPEM writeToFile:cakeyPath atomically:YES encoding:NSUTF8StringEncoding error:&error];
        if (!succeed) {
            break;
        }

        succeed = [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions : @0600}
                                                   ofItemAtPath:cakeyPath
                                                          error:&error];
        if (!succeed) {
            break;
        }
    } while (0);

    if (!succeed) {
        NSString *title = NSLocalizedStringFromTableInBundle(@"Generation Failed", @"Localizable", self.bundle, nil);
        NSString *message =
            [NSString stringWithFormat:NSLocalizedStringFromTableInBundle(@"Failed to save generated keys: %@",
                                                                          @"Localizable", self.bundle, nil),
                                       error.localizedDescription];
        NSString *ok = NSLocalizedStringFromTableInBundle(@"OK", @"Localizable", self.bundle, nil);

        UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                       message:message
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:ok style:UIAlertActionStyleCancel handler:nil]];

        [[self actionPresenter] presentViewController:alert animated:YES completion:nil];
        return;
    }

    [super setPreferenceValue:[self cacertPath] specifier:[self certSpecifier]];
    [super setPreferenceValue:[self cakeyPath] specifier:[self keysSpecifier]];

    [self reloadSpecifiers];
    [[NSNotificationCenter defaultCenter] postNotificationName:TVNCSettingsDidChangeNotification object:nil];

    NSString *title = NSLocalizedStringFromTableInBundle(@"Generation Succeeded", @"Localizable", self.bundle, nil);
    NSString *message = NSLocalizedStringFromTableInBundle(
        @"The self-signed CA certificate and private key have been successfully generated. You need to trust this "
        @"certificate in your client browser or operating system. Restart the service to apply the changes.",
        @"Localizable", self.bundle, nil);
    NSString *ok = NSLocalizedStringFromTableInBundle(@"OK", @"Localizable", self.bundle, nil);

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:ok style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:NSLocalizedStringFromTableInBundle(@"Export Certificate…",
                                                                                       @"Localizable", self.bundle, nil)
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *_Nonnull action) {
                                                [self exportCertificate];
                                            }]];

    [[self actionPresenter] presentViewController:alert animated:YES completion:nil];
}

- (void)resetDefaults {
    NSString *title = NSLocalizedStringFromTableInBundle(@"Reset to Defaults", @"Localizable", self.bundle, nil);
    NSString *message = NSLocalizedStringFromTableInBundle(
        @"Are you sure you want to reset all settings to their defaults?", @"Localizable", self.bundle, nil);
    NSString *cancel = NSLocalizedStringFromTableInBundle(@"Cancel", @"Localizable", self.bundle, nil);
    NSString *reset = NSLocalizedStringFromTableInBundle(@"Reset", @"Localizable", self.bundle, nil);

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:cancel style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:reset
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *_Nonnull action) {
                                                [weakSelf _reallyResetDefaults];
                                            }]];

    [[self actionPresenter] presentViewController:alert animated:YES completion:nil];
}

- (void)_reallyResetDefaults {
    [[NSUserDefaults standardUserDefaults] removePersistentDomainForName:@"com.82flex.trollvnc"];
    [[NSUserDefaults standardUserDefaults] synchronize];

    [self reloadSpecifiers];
}

- (void)support {
    NSURL *url = [NSURL URLWithString:@"https://havoc.app/search/82Flex"];
    if ([[UIApplication sharedApplication] canOpenURL:url]) {
        [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
    }
}

- (void)source {
    NSURL *url = [NSURL URLWithString:@"https://github.com/owngoal-dev/TrollVNC"];
    if ([[UIApplication sharedApplication] canOpenURL:url]) {
        [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
    }
}

#pragma mark - Dashboard

- (UIViewController *)actionPresenter { return self.navigationController.topViewController ?: self; }
// Preferences' table/tableView accessors vary between iOS versions. Resolve the
// actual UIKit table from the loaded view instead of sending a private selector.
- (UITableView *)settingsTableInView:(UIView *)view {
    if ([view isKindOfClass:UITableView.class]) return (UITableView *)view;
    for (UIView *child in view.subviews) {
        UITableView *table = [self settingsTableInView:child];
        if (table) return table;
    }
    return nil;
}
- (UITableView *)settingsTableView {
    return self.isViewLoaded ? [self settingsTableInView:self.view] : nil;
}
- (UITableViewStyle)tableViewStyle { return UITableViewStyleInsetGrouped; }
- (NSArray<NSArray<NSString *> *> *)dashboardCategories {
    return @[
        @[@"network", @"Network settings", @"Shared network, ports & addresses", @"wifi"],
        @[@"security", @"Access & security", @"Passwords, view-only, clipboard & files", @"lock"],
        @[@"display", @"Display settings", @"Scale, frame rate & orientation", @"display"],
        @[@"input", @"Input settings", @"Mouse, keyboard & touch", @"keyboard"],
        @[@"connections", @"Connections & notifications", @"Discovery, reverse connections & keepalive", @"network"],
        @[@"performance", @"Performance tuning", @"Updates, tiles & encoding", @"wrench.and.screwdriver"],
        @[@"web", @"VNC Web & TLS", @"HTTP, certificates & private keys", @"globe"]
    ];
}
- (NSString *)uiText:(NSString *)key { return TVNCUIString(self.bundle, key); }
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return [self hasManagedConfiguration] ? [super numberOfSectionsInTableView:tableView] : 3;
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if ([self hasManagedConfiguration]) return [super tableView:tableView numberOfRowsInSection:section];
    return section == 0 ? 1 : section == 1 ? self.dashboardCategories.count : 2;
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return [self hasManagedConfiguration] ? [super tableView:tableView titleForHeaderInSection:section] : nil;
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if ([self hasManagedConfiguration]) return [super tableView:tableView titleForFooterInSection:section];
    return section == 2 ? [self uiText:@"Apply changes to restart the unified service."] : nil;
}
- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    if ([self hasManagedConfiguration]) return UITableViewAutomaticDimension;
    return section == 0 ? 8 : 16;
}
- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    if ([self hasManagedConfiguration]) return UITableViewAutomaticDimension;
    return UITableViewAutomaticDimension;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if ([self hasManagedConfiguration]) return [super tableView:tableView cellForRowAtIndexPath:indexPath];
    TVNCSettingsValueCell *cell = [[TVNCSettingsValueCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    if (indexPath.section == 0) {
        [cell addLeadingSymbol:self.serviceStatus ? @"circle.fill" : @"circle.dotted"];
        UIImageView *dot = (UIImageView *)cell.rowStack.arrangedSubviews.firstObject;
        dot.image = [UIImage systemImageNamed:self.serviceStatus ? @"circle.fill" : @"circle.dotted" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:12]];
        dot.contentMode = UIViewContentModeCenter;
        dot.tintColor = self.serviceStatus ? TVNCAccentColor() : UIColor.secondaryLabelColor;
        cell.nameLabel.text = [self uiText:self.serviceStatus ? @"Service running" : @"Service status unavailable"];
        cell.nameLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
        UILabel *status = TVNCSettingsLabel(UIFontTextStyleFootnote, UIColor.secondaryLabelColor);
        status.text = [self currentStatusText];
        UIStackView *labels = [[UIStackView alloc] initWithArrangedSubviews:@[cell.nameLabel, status]];
        labels.axis = UILayoutConstraintAxisVertical; labels.spacing = 4;
        [cell.rowStack insertArrangedSubview:labels atIndex:1];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if (indexPath.section == 1) {
        NSArray *category = self.dashboardCategories[indexPath.row];
        [cell addLeadingSymbol:category[3]];
        UILabel *subtitle = TVNCSettingsLabel(UIFontTextStyleCaption1, UIColor.secondaryLabelColor);
        subtitle.text = [self uiText:category[2]];
        cell.nameLabel.text = [self uiText:category[1]];
        UIStackView *labels = [[UIStackView alloc] initWithArrangedSubviews:@[cell.nameLabel, subtitle]];
        labels.axis = UILayoutConstraintAxisVertical; labels.spacing = 2;
        [cell.rowStack insertArrangedSubview:labels atIndex:1];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.accessibilityIdentifier = [@"category." stringByAppendingString:category[0]];
    } else if (indexPath.row == 0) {
        cell.nameLabel.text = [self uiText:@"Connected clients"];
        id count = self.serviceStatus[@"ClientCount"];
        cell.valueLabel.text = [count isKindOfClass:NSNumber.class] ? [count stringValue] : @"—";
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else {
        [cell.rowStack removeArrangedSubview:cell.nameLabel]; [cell.nameLabel removeFromSuperview];
        [cell.rowStack removeArrangedSubview:cell.valueLabel]; [cell.valueLabel removeFromSuperview];
        NSArray *names = @[@"View Logs", @"Reset settings", @"About"];
        NSArray *symbols = @[@"doc.text", @"arrow.counterclockwise", @"info.circle"];
        for (NSUInteger i = 0; i < names.count; i++) {
            UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
            [button setTitle:[self uiText:names[i]] forState:UIControlStateNormal];
            [button setImage:[UIImage systemImageNamed:symbols[i]] forState:UIControlStateNormal];
            button.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
            button.titleLabel.adjustsFontForContentSizeCategory = YES;
            button.tintColor = TVNCAccentColor(); button.tag = i;
            [button.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
            [button addTarget:self action:@selector(dashboardAction:) forControlEvents:UIControlEventTouchUpInside];
            [cell.rowStack addArrangedSubview:button];
        }
        cell.rowStack.distribution = UIStackViewDistributionFillEqually;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    return cell;
}
- (NSIndexPath *)tableView:(UITableView *)tableView willSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    if ([self hasManagedConfiguration]) return [super tableView:tableView willSelectRowAtIndexPath:indexPath];
    return (indexPath.section == 1 || (indexPath.section == 2 && indexPath.row == 0)) ? indexPath : nil;
}
- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath {
    if ([self hasManagedConfiguration]) [super tableView:tableView willDisplayCell:cell forRowAtIndexPath:indexPath];
}
- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    return [self hasManagedConfiguration] ? [super tableView:tableView viewForHeaderInSection:section] : nil;
}
- (UIView *)tableView:(UITableView *)tableView viewForFooterInSection:(NSInteger)section {
    return [self hasManagedConfiguration] ? [super tableView:tableView viewForFooterInSection:section] : nil;
}
- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section {
    return [self hasManagedConfiguration] || section == 2 ? UITableViewAutomaticDimension : 0.01;
}
- (void)dashboardAction:(UIButton *)sender {
    if (sender.tag == 0) [self viewLogs];
    else if (sender.tag == 1) [self resetDefaults];
    else {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"TrollVNC" message:[self defaultFooterText] preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:[self uiText:@"View Source Code"] style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { [self source]; }]];
        [alert addAction:[UIAlertAction actionWithTitle:[self uiText:@"OK"] style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    }
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    if ([self hasManagedConfiguration]) { [super tableView:tableView didSelectRowAtIndexPath:indexPath]; return; }
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 1) {
        NSString *identifier = self.dashboardCategories[indexPath.row][0];
        if ([identifier isEqualToString:@"network"]) { [self openNetworkSettings]; return; }
        TVNCSettingsPageController *controller = [TVNCSettingsPageController new];
        controller.localizationBundle = self.bundle; controller.categoryIdentifier = identifier;
        __weak typeof(self) weakSelf = self;
        controller.actionHandler = ^(NSString *action) {
            if ([action isEqualToString:@"generateKeys"]) [weakSelf generateKeys];
            else if ([action isEqualToString:@"exportCertificate"]) [weakSelf exportCertificate];
        };
        [self.navigationController pushViewController:controller animated:YES];
    } else if (indexPath.section == 2 && indexPath.row == 0) [self showClients];
}

#pragma mark - Helper Methods

- (UILabel *)findLabelInView:(UIView *)view {
    for (UIView *subview in view.subviews) {
        if ([subview isKindOfClass:[UILabel class]]) {
            return (UILabel *)subview;
        }
        UILabel *label = [self findLabelInView:subview];
        if (label) {
            return label;
        }
    }
    return nil;
}

@end
