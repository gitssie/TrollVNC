// GPL-2.0-only.
#import "TVNCNetworkController.h"
#import "TVNCServiceStatus.h"
#import "TVNCWireGuardController.h"
#import "TVNCSettingsAppearance.h"
#import "TVNCSettingsModel.h"
#import "TVNCUtil.h"
#import "TVNCWireGuardConfig.h"

// Keep the last successful snapshot while Settings recreates this page or a poll fails.
static NSDictionary *sLastNetworkStatus;
static NSArray<NSString *> *sLastLocalAddresses;

@interface TVNCNetworkController ()
@property(nonatomic, strong) NSDictionary *status;
@property(nonatomic, strong) NSArray<NSString *> *localAddresses;
@property(nonatomic, strong) NSTimer *timer;
@property(nonatomic, assign) BOOL fetching;
@property(nonatomic, assign) BOOL statusReadCompleted;
@end
@implementation TVNCNetworkController
- (instancetype)init {
    self = [super init];
    if (self) {
        self.categoryIdentifier = @"network";
        self.status = sLastNetworkStatus;
        self.localAddresses = sLastLocalAddresses ?: @[];
        self.statusReadCompleted = self.status != nil;
    }
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad]; self.title = [self text:@"Network settings"];
    TVNCStyleSettingsTable(self.tableView);
    self.refreshControl = [UIRefreshControl new];
    [self.refreshControl addTarget:self action:@selector(refreshStatus) forControlEvents:UIControlEventValueChanged];
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated]; [self refreshStatus];
    [self.timer invalidate]; __weak typeof(self) weakSelf = self;
    self.timer = [NSTimer scheduledTimerWithTimeInterval:10 repeats:YES block:^(NSTimer *timer) { [weakSelf refreshStatus]; }];
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
        NSArray *addresses = status ? TVNCWiFiAddresses(status[@"BindHost"], [status[@"VNCAcceptsIPv4"] boolValue], NO) : @[];
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf; if (!strongSelf) return;
            strongSelf.fetching = NO;
            BOOL wasCompleted = strongSelf.statusReadCompleted;
            [strongSelf.refreshControl endRefreshing];
            if (!status) {
                // A failed control request must not erase working connection addresses.
                if (!wasCompleted) {
                    strongSelf.statusReadCompleted = YES;
                    [strongSelf.tableView reloadSections:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(1, 2)]
                        withRowAnimation:UITableViewRowAnimationNone];
                }
                return;
            }
            NSDictionary *previous = strongSelf.status;
            BOOL localChanged = ![strongSelf.localAddresses isEqualToArray:addresses] ||
                !(previous[@"VNCPort"] == status[@"VNCPort"] || [previous[@"VNCPort"] isEqual:status[@"VNCPort"]]) ||
                !(previous[@"ZXTouchPort"] == status[@"ZXTouchPort"] || [previous[@"ZXTouchPort"] isEqual:status[@"ZXTouchPort"]]);
            BOOL wireGuardChanged = !wasCompleted;
            for (NSString *key in @[@"WireGuardStarted", @"WireGuardEnabled", @"WireGuardConfigured",
                                    @"WireGuardAddress", @"WireGuardError", @"VNCPort", @"ZXTouchPort"]) {
                if (!(previous[key] == status[key] || [previous[key] isEqual:status[key]])) wireGuardChanged = YES;
            }
            strongSelf.status = status;
            strongSelf.localAddresses = addresses;
            strongSelf.statusReadCompleted = YES;
            sLastNetworkStatus = status;
            sLastLocalAddresses = addresses;
            NSMutableIndexSet *sections = [NSMutableIndexSet indexSet];
            if (localChanged) [sections addIndex:1];
            if (wireGuardChanged) [sections addIndex:2];
            if (sections.count) [strongSelf.tableView reloadSections:sections withRowAnimation:UITableViewRowAnimationNone];
        });
    });
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 3; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return [super tableView:tableView numberOfRowsInSection:section];
    if (section == 1) return MAX(1, self.localAddresses.count) * 2;
    BOOL configured = [self.preferences dictionaryForKey:@"WireGuardConfig"] != nil;
    return 3 + ([self.status[@"WireGuardStarted"] boolValue] ? 2 : 0) + (configured ? 1 : 0);
}
- (BOOL)wireGuardEnabledInStatus {
    id reported = self.status[@"WireGuardEnabled"];
    if ([reported isKindOfClass:NSNumber.class]) return [reported boolValue];
    return TVNCWGShouldStart([self.preferences dictionaryForKey:@"WireGuardConfig"],
        [self.preferences objectForKey:@"WireGuardEnabled"]);
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 0) return [super tableView:tableView titleForHeaderInSection:section];
    return [self text:section == 1 ? @"Local network" : @"WireGuard"];
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0) return [self text:@"Apply changes on the home screen."];
    if (section == 1) return [self text:@"Tap an address to copy it."];
    if (self.status && [self wireGuardEnabledInStatus] && ![self.status[@"WireGuardStarted"] boolValue]) {
        NSString *error = self.status[@"WireGuardError"];
        if (error.length) return error;
    }
    return [self text:[self.preferences dictionaryForKey:@"WireGuardConfig"] ?
        @"Changing the WireGuard switch restarts TrollVNC. Local access remains available." :
        @"Add a configuration to enable WireGuard for both protocols."];
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
        } else cell.valueLabel.text = [self text:!self.status && !self.statusReadCompleted ? @"Loading service status…" : @"Address unavailable"];
    } else if (row == 0) {
        cell.nameLabel.text = [self text:@"Enable WireGuard"];
        UISwitch *toggle = [UISwitch new];
        toggle.onTintColor = TVNCAccentColor();
        toggle.on = TVNCWGShouldStart([self.preferences dictionaryForKey:@"WireGuardConfig"],
            [self.preferences objectForKey:@"WireGuardEnabled"]);
        toggle.enabled = [self.preferences dictionaryForKey:@"WireGuardConfig"] != nil;
        toggle.accessibilityLabel = cell.nameLabel.text;
        [toggle addTarget:self action:@selector(toggleWireGuard:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
    } else if ([self.preferences dictionaryForKey:@"WireGuardConfig"] && row == [self tableView:tableView numberOfRowsInSection:2] - 1) {
        cell.nameLabel.text = [self text:@"Remove configuration"];
        cell.nameLabel.textColor = UIColor.systemRedColor;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    } else if (row == 1) {
        NSString *state = !self.status ? (self.statusReadCompleted ? @"Service status unavailable" : @"Loading service status…") :
            [self.status[@"WireGuardStarted"] boolValue] ? @"Interface running" :
            ![self wireGuardEnabledInStatus] && [self.status[@"WireGuardConfigured"] boolValue] ? @"Interface disabled" :
            [self.status[@"WireGuardConfigured"] boolValue] ? @"Network failed to start" : @"No configuration";
        cell.nameLabel.text = [self text:state];
        if ([self.status[@"WireGuardStarted"] boolValue]) cell.valueLabel.text = self.status[@"WireGuardAddress"];
    } else if (row == 2) {
        cell.nameLabel.text = [self text:@"Configuration details"];
        NSDictionary *configuration = [self.preferences dictionaryForKey:@"WireGuardConfig"];
        NSArray *peers = configuration[@"Peers"];
        if ([peers isKindOfClass:NSArray.class])
            cell.valueLabel.text = peers.count == 1 ? [self text:@"1 peer"] :
                [NSString stringWithFormat:[self text:@"%lu peers"], (unsigned long)peers.count];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    } else {
        cell.nameLabel.text = row == 3 ? @"VNC" : @"ZXTouch";
        cell.valueLabel.text = TVNCServiceSocket(self.status[@"WireGuardAddress"], self.status[row == 3 ? @"VNCPort" : @"ZXTouchPort"]);
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
    } else if (indexPath.section == 2 && indexPath.row == 2) {
        TVNCWireGuardController *controller = [TVNCWireGuardController new];
        controller.localizationBundle = self.localizationBundle;
        [self.navigationController pushViewController:controller animated:YES];
    } else if ((indexPath.section == 1 && self.localAddresses.count) ||
               (indexPath.section == 2 && indexPath.row >= 3 && indexPath.row <= 4 && [self.status[@"WireGuardStarted"] boolValue])) {
        NSString *address = indexPath.section == 1 ? self.localAddresses[indexPath.row / 2] : self.status[@"WireGuardAddress"];
        BOOL isZX = indexPath.section == 1 ? indexPath.row % 2 : indexPath.row == 4;
        UIPasteboard.generalPasteboard.string = TVNCServiceSocket(address, self.status[isZX ? @"ZXTouchPort" : @"VNCPort"]);
        UINotificationFeedbackGenerator *feedback = [UINotificationFeedbackGenerator new];
        [feedback notificationOccurred:UINotificationFeedbackTypeSuccess];
        ((TVNCSettingsValueCell *)[tableView cellForRowAtIndexPath:indexPath]).valueLabel.text = [self text:@"Copied"];
    }
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
}
- (void)toggleWireGuard:(UISwitch *)sender {
    NSNumber *previous = [self.preferences objectForKey:@"WireGuardEnabled"];
    [self.preferences setBool:sender.on forKey:@"WireGuardEnabled"];
    if (![self.preferences synchronize]) {
        if (previous) [self.preferences setObject:previous forKey:@"WireGuardEnabled"];
        else [self.preferences removeObjectForKey:@"WireGuardEnabled"];
        sender.on = !sender.on;
        [self showSettingError:[NSError errorWithDomain:@"TVNCSettings" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Could not save the WireGuard setting."}]];
        return;
    }
    TVNCRestartVNCService();
    [self refreshStatus];
}
- (void)removeConfiguration {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:[self text:@"Remove configuration"]
        message:[self text:@"Remove WireGuard configuration and restart TrollVNC? Local access remains available."] preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:[self text:@"Cancel"] style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:[self text:@"Remove"] style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        NSDictionary *previous = [self.preferences dictionaryForKey:@"WireGuardConfig"];
        NSNumber *previousEnabled = [self.preferences objectForKey:@"WireGuardEnabled"];
        [self.preferences removeObjectForKey:@"WireGuardConfig"];
        [self.preferences removeObjectForKey:@"WireGuardEnabled"];
        if (![self.preferences synchronize]) {
            if (previous) [self.preferences setObject:previous forKey:@"WireGuardConfig"];
            if (previousEnabled) [self.preferences setObject:previousEnabled forKey:@"WireGuardEnabled"];
            [self showSettingError:[NSError errorWithDomain:@"TVNCSettings" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Could not save the WireGuard configuration."}]]; return;
        }
        TVNCRestartVNCService(); [self refreshStatus];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
