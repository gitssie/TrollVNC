// GPL-2.0-only.
#import "TVNCNetworkController.h"
#import "TVNCServiceStatus.h"
#import "TVNCWireGuardController.h"
#import "TVNCSettingsAppearance.h"
#import "TVNCSettingsModel.h"
#import "TVNCUtil.h"

@interface TVNCNetworkController ()
@property(nonatomic, strong) NSDictionary *status;
@property(nonatomic, strong) NSArray<NSString *> *localAddresses;
@property(nonatomic, strong) NSTimer *timer;
@property(nonatomic, assign) BOOL fetching;
@end
@implementation TVNCNetworkController
- (instancetype)init { self = [super init]; if (self) self.categoryIdentifier = @"network"; return self; }
- (void)viewDidLoad {
    [super viewDidLoad]; self.title = [self text:@"Network settings"];
    TVNCStyleSettingsTable(self.tableView);
    self.refreshControl = [UIRefreshControl new];
    [self.refreshControl addTarget:self action:@selector(refreshStatus) forControlEvents:UIControlEventValueChanged];
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated]; [self refreshStatus];
    [self.timer invalidate]; __weak typeof(self) weakSelf = self;
    self.timer = [NSTimer scheduledTimerWithTimeInterval:3 repeats:YES block:^(NSTimer *timer) { [weakSelf refreshStatus]; }];
}
- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated]; [self.timer invalidate]; self.timer = nil;
}
- (void)dealloc { [_timer invalidate]; }
- (void)refreshStatus {
    if (self.fetching) return; self.fetching = YES;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSDictionary *status = TVNCFetchServiceStatus(kTvDefaultCtlPort);
        NSArray *addresses = status ? TVNCWiFiAddresses(status[@"BindHost"], [status[@"VNCAcceptsIPv4"] boolValue], [status[@"VNCAcceptsIPv6"] boolValue]) : @[];
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf; if (!strongSelf) return;
            strongSelf.fetching = NO; strongSelf.status = status; strongSelf.localAddresses = addresses;
            [strongSelf.refreshControl endRefreshing]; [strongSelf.tableView reloadData];
        });
    });
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 3; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return [super tableView:tableView numberOfRowsInSection:section];
    if (section == 1) return MAX(1, self.localAddresses.count) * 2;
    BOOL configured = [self.preferences dictionaryForKey:@"WireGuardConfig"] != nil;
    return ([self.status[@"WireGuardStarted"] boolValue] ? 4 : 2) + (configured ? 1 : 0);
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 0) return [super tableView:tableView titleForHeaderInSection:section];
    return [self text:section == 1 ? @"Local network" : @"WireGuard"];
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0) return [self text:@"Both protocols always run. Ports must differ. Apply port edits from the home screen."];
    if (section == 1) return [self text:@"Both protocols share the same network. Tap an address to copy it."];
    if (self.status && [self.status[@"WireGuardConfigured"] boolValue] && ![self.status[@"WireGuardStarted"] boolValue])
        return self.status[@"WireGuardError"];
    return [self text:@"One WireGuard configuration provides access to both ports. Saving a configuration restarts TrollVNC; removing it keeps local access available."];
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0) return [super tableView:tableView cellForRowAtIndexPath:indexPath];
    TVNCSettingsValueCell *cell = [[TVNCSettingsValueCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    NSInteger row = indexPath.row;
    if (indexPath.section == 1) {
        cell.nameLabel.text = row % 2 ? @"ZXTouch" : @"VNC";
        if (self.localAddresses.count) {
            cell.valueLabel.text = TVNCServiceSocket(self.localAddresses[row / 2], self.status[row % 2 ? @"ZXTouchPort" : @"VNCPort"]);
            cell.accessoryView = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"doc.on.doc"]];
            cell.accessoryView.tintColor = TVNCAccentColor();
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        } else cell.valueLabel.text = [self text:@"Address unavailable"];
    } else if ([self.preferences dictionaryForKey:@"WireGuardConfig"] && row == [self tableView:tableView numberOfRowsInSection:2] - 1) {
        cell.nameLabel.text = [self text:@"Remove configuration"];
        cell.nameLabel.textColor = UIColor.systemRedColor;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    } else if (row == 0) {
        NSString *state = !self.status ? @"Service status unavailable" :
            [self.status[@"WireGuardStarted"] boolValue] ? @"Interface running" :
            [self.status[@"WireGuardConfigured"] boolValue] ? @"Network failed to start" : @"No configuration";
        cell.nameLabel.text = [self text:state];
        if ([self.status[@"WireGuardStarted"] boolValue]) cell.valueLabel.text = self.status[@"WireGuardAddress"];
    } else if (row == 1) {
        cell.nameLabel.text = [self text:@"Configuration management"];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    } else {
        cell.nameLabel.text = row == 2 ? @"VNC" : @"ZXTouch";
        cell.valueLabel.text = TVNCServiceSocket(self.status[@"WireGuardAddress"], self.status[row == 2 ? @"VNCPort" : @"ZXTouchPort"]);
        cell.accessoryView = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"doc.on.doc"]]; cell.accessoryView.tintColor = TVNCAccentColor();
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    }
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0) { [super tableView:tableView didSelectRowAtIndexPath:indexPath]; return; }
    if (indexPath.section == 2 && [self.preferences dictionaryForKey:@"WireGuardConfig"] &&
        indexPath.row == [self tableView:tableView numberOfRowsInSection:2] - 1) {
        [self removeConfiguration];
    } else if (indexPath.section == 2 && indexPath.row == 1) {
        TVNCWireGuardController *controller = [TVNCWireGuardController new];
        controller.localizationBundle = self.localizationBundle;
        [self.navigationController pushViewController:controller animated:YES];
    } else if ((indexPath.section == 1 && self.localAddresses.count) || (indexPath.section == 2 && indexPath.row >= 2)) {
        NSString *address = indexPath.section == 1 ? self.localAddresses[indexPath.row / 2] : self.status[@"WireGuardAddress"];
        BOOL isZX = indexPath.section == 1 ? indexPath.row % 2 : indexPath.row == 3;
        UIPasteboard.generalPasteboard.string = TVNCServiceSocket(address, self.status[isZX ? @"ZXTouchPort" : @"VNCPort"]);
        UINotificationFeedbackGenerator *feedback = [UINotificationFeedbackGenerator new];
        [feedback notificationOccurred:UINotificationFeedbackTypeSuccess];
        ((TVNCSettingsValueCell *)[tableView cellForRowAtIndexPath:indexPath]).valueLabel.text = [self text:@"Copied"];
    }
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
}
- (void)removeConfiguration {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:[self text:@"Remove configuration"]
        message:[self text:@"Remove WireGuard configuration and restart TrollVNC? Local access remains available."] preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:[self text:@"Cancel"] style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:[self text:@"Remove"] style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        NSDictionary *previous = [self.preferences dictionaryForKey:@"WireGuardConfig"];
        [self.preferences removeObjectForKey:@"WireGuardConfig"];
        if (![self.preferences synchronize]) {
            if (previous) [self.preferences setObject:previous forKey:@"WireGuardConfig"];
            [self showSettingError:[NSError errorWithDomain:@"TVNCSettings" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Could not save the WireGuard configuration."}]]; return;
        }
        TVNCRestartVNCService(); [self refreshStatus];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
