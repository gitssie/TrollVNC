// GPL-2.0-only.
#import "TVNCNetworkController.h"
#import "TVNCServiceStatus.h"
#import "TVNCServiceState.h"
#import "TVNCWireGuardController.h"
#import "TVNCSettingsAppearance.h"
#import "TVNCSettingsModel.h"
#import "TVNCUtil.h"
#import "TVNCWireGuardConfig.h"

@interface TVNCNetworkController ()
@property(nonatomic, strong) NSDictionary *displayedStatus;
@property(nonatomic, assign) BOOL displayedServiceRunning;
@property(nonatomic, strong) NSTimer *restartTimer;
@property(nonatomic, strong) NSDate *restartDeadline;
@property(nonatomic, strong) NSNumber *restartPID;
@property(nonatomic, assign) BOOL restartExpectedEnabled;
@property(nonatomic, copy) NSString *restartNotice;
@end
static BOOL TVNCStatusFieldEqual(NSDictionary *left, NSDictionary *right, NSString *key) {
    return left[key] == right[key] || [left[key] isEqual:right[key]];
}
@implementation TVNCNetworkController
- (instancetype)init { self = [super init]; if (self) self.categoryIdentifier = @"network"; return self; }
- (NSDictionary *)status { return [TVNCServiceState sharedState].status; }
- (NSArray<NSString *> *)localAddresses { return self.status[@"LocalAddresses"] ?: @[]; }
- (void)viewDidLoad {
    [super viewDidLoad]; self.title = [self text:@"Network settings"];
    TVNCStyleSettingsTable(self.tableView);
    self.refreshControl = [UIRefreshControl new];
    [self.refreshControl addTarget:self action:@selector(refreshStatus) forControlEvents:UIControlEventValueChanged];
    self.displayedStatus = self.status;
    self.displayedServiceRunning = [TVNCServiceState sharedState].running && TVNCServiceSnapshotProcessAlive(self.status);
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.displayedStatus = self.status;
    self.displayedServiceRunning = [TVNCServiceState sharedState].running && TVNCServiceSnapshotProcessAlive(self.status);
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(serviceStateChanged:)
        name:TVNCServiceStateDidChangeNotification object:[TVNCServiceState sharedState]];
    [[TVNCServiceState sharedState] startObserving];
    if (self.restartDeadline) [self observeRestart];
}
- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    [self.restartTimer invalidate]; self.restartTimer = nil;
    [[NSNotificationCenter defaultCenter] removeObserver:self name:TVNCServiceStateDidChangeNotification
        object:[TVNCServiceState sharedState]];
    [[TVNCServiceState sharedState] stopObserving];
}
- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }
- (void)refreshStatus {
    __weak typeof(self) weakSelf = self;
    [[TVNCServiceState sharedState] refreshWithCompletion:^{
        [weakSelf.refreshControl endRefreshing];
        [weakSelf updateRestartStatus];
    }];
}
- (void)serviceStateChanged:(NSNotification *)notification {
    NSDictionary *previous = self.displayedStatus;
    NSDictionary *status = self.status;
    BOOL localChanged = !TVNCStatusFieldEqual(previous, status, @"LocalAddresses") ||
        !TVNCStatusFieldEqual(previous, status, @"VNCPort") ||
        !TVNCStatusFieldEqual(previous, status, @"ZXTouchPort");
    BOOL serviceRunning = [TVNCServiceState sharedState].running && TVNCServiceSnapshotProcessAlive(status);
    BOOL wireGuardChanged = serviceRunning != self.displayedServiceRunning;
    for (NSString *key in @[@"ServerPID", @"WireGuardStarted", @"WireGuardEnabled", @"WireGuardConfigured",
                            @"WireGuardAddress", @"WireGuardError", @"VNCPort", @"ZXTouchPort"]) {
        if (!TVNCStatusFieldEqual(previous, status, key)) wireGuardChanged = YES;
    }
    self.displayedStatus = status;
    self.displayedServiceRunning = serviceRunning;
    NSMutableIndexSet *sections = [NSMutableIndexSet indexSet];
    if (localChanged) [sections addIndex:1];
    if (wireGuardChanged) [sections addIndex:2];
    if (sections.count) [self.tableView reloadSections:sections withRowAnimation:UITableViewRowAnimationNone];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 3; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return [super tableView:tableView numberOfRowsInSection:section];
    if (section == 1) return MAX(1, self.localAddresses.count);
    return self.wireGuardRows.count;
}
- (NSArray<NSString *> *)wireGuardRows {
    if (![self.preferences dictionaryForKey:@"WireGuardConfig"]) return @[@"add"];
    NSMutableArray *rows = [NSMutableArray arrayWithArray:@[@"toggle", @"configuration"]];
    if ([self.status[@"WireGuardStarted"] boolValue] && [TVNCServiceState sharedState].running &&
        TVNCServiceSnapshotProcessAlive(self.status) && !self.restartDeadline) [rows addObject:@"address"];
    [rows addObject:@"remove"];
    return rows;
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
    if (section == 0) return [self text:@"Restart from Home to apply."];
    if (section == 1) return nil;
    if (self.restartDeadline) return nil;
    if (self.restartNotice.length) return [self text:self.restartNotice];
    if (![self.preferences dictionaryForKey:@"WireGuardConfig"]) return nil;
    if (self.status && [self wireGuardEnabledInStatus] && ![self.status[@"WireGuardStarted"] boolValue]) {
        NSString *error = self.status[@"WireGuardError"];
        if (error.length) return error;
    }
    return [self text:@"Changes restart services automatically."];
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0) return [super tableView:tableView cellForRowAtIndexPath:indexPath];
    TVNCSettingsValueCell *cell = [[TVNCSettingsValueCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    NSInteger row = indexPath.row;
    if (indexPath.section == 1) {
        [self configureAddressCell:cell address:self.localAddresses.count ? self.localAddresses[row] : nil];
    } else {
        NSArray<NSString *> *rows = self.wireGuardRows;
        if (row >= rows.count) return cell;
        NSString *kind = rows[row];
        cell.accessibilityIdentifier = kind;
        if ([kind isEqualToString:@"add"]) {
            cell.nameLabel.text = [self text:@"Add configuration"];
            cell.nameLabel.textColor = TVNCAccentColor();
            cell.valueLabel.hidden = YES;
            [cell addLeadingSymbol:@"plus.circle"];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        } else if ([kind isEqualToString:@"toggle"]) {
            cell.nameLabel.text = @"WireGuard";
            cell.valueLabel.hidden = YES;
            UISwitch *toggle = [UISwitch new];
            toggle.onTintColor = TVNCAccentColor();
            toggle.on = TVNCWGShouldStart([self.preferences dictionaryForKey:@"WireGuardConfig"],
                [self.preferences objectForKey:@"WireGuardEnabled"]);
            toggle.enabled = self.restartDeadline == nil;
            toggle.accessibilityLabel = [self text:@"Enable WireGuard"];
            [toggle addTarget:self action:@selector(toggleWireGuard:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = toggle;
            [self addDetailView:self.wireGuardStatusView toCell:cell];
        } else if ([kind isEqualToString:@"configuration"]) {
            cell.nameLabel.text = [self text:@"Configuration details"];
            NSArray *peers = [self.preferences dictionaryForKey:@"WireGuardConfig"][@"Peers"];
            if ([peers isKindOfClass:NSArray.class])
                cell.valueLabel.text = peers.count == 1 ? [self text:@"1 peer"] :
                    [NSString stringWithFormat:[self text:@"%lu peers"], (unsigned long)peers.count];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        } else if ([kind isEqualToString:@"remove"]) {
            cell.nameLabel.text = [self text:@"Remove configuration"];
            cell.nameLabel.textColor = UIColor.systemRedColor;
            cell.selectionStyle = self.restartDeadline ? UITableViewCellSelectionStyleNone : UITableViewCellSelectionStyleDefault;
        } else {
            [self configureAddressCell:cell address:self.status[@"WireGuardAddress"]];
        }
    }
    return cell;
}
- (void)addDetailView:(UIView *)detail toCell:(TVNCSettingsValueCell *)cell {
    NSUInteger index = [cell.rowStack.arrangedSubviews indexOfObject:cell.nameLabel];
    [cell.rowStack removeArrangedSubview:cell.nameLabel];
    [cell.nameLabel removeFromSuperview];
    UIStackView *labels = [[UIStackView alloc] initWithArrangedSubviews:@[cell.nameLabel, detail]];
    labels.axis = UILayoutConstraintAxisVertical;
    labels.spacing = 4;
    [cell.rowStack insertArrangedSubview:labels atIndex:index];
}
- (UIView *)wireGuardStatusView {
    BOOL serviceRunning = [TVNCServiceState sharedState].running && TVNCServiceSnapshotProcessAlive(self.status);
    NSString *state = self.restartDeadline ? @"Restarting services…" :
        !self.status ? @"Checking service" :
        !serviceRunning ? @"Services stopped" :
        [self.status[@"WireGuardStarted"] boolValue] ? @"Interface running" :
        ![self wireGuardEnabledInStatus] ? @"Interface disabled" : @"Network failed to start";
    UILabel *label = TVNCSettingsLabel(UIFontTextStyleFootnote, UIColor.secondaryLabelColor);
    label.text = [self text:state];
    UIView *icon;
    if (self.restartDeadline) {
        UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        [spinner startAnimating]; icon = spinner;
    } else {
        BOOL running = serviceRunning && [self.status[@"WireGuardStarted"] boolValue];
        BOOL failed = self.status && (!serviceRunning || ([self wireGuardEnabledInStatus] && !running));
        UIImageView *image = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:
            running ? @"checkmark.circle.fill" : failed ? @"exclamationmark.triangle.fill" : @"circle"]];
        image.tintColor = running ? UIColor.systemGreenColor : failed ? UIColor.systemOrangeColor : UIColor.tertiaryLabelColor;
        icon = image;
    }
    UIStackView *status = [[UIStackView alloc] initWithArrangedSubviews:@[icon, label]];
    status.axis = UILayoutConstraintAxisHorizontal;
    status.alignment = UIStackViewAlignmentCenter;
    status.spacing = 6;
    [icon setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    return status;
}
- (void)observeRestart {
    [self.restartTimer invalidate];
    __weak typeof(self) weakSelf = self;
    self.restartTimer = [NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *timer) {
        [weakSelf refreshStatus];
    }];
    [self refreshStatus];
}
- (void)updateRestartStatus {
    if (!self.restartDeadline) return;
    NSDictionary *status = self.status;
    BOOL replaced = ![status[@"ServerPID"] isEqual:self.restartPID] &&
        TVNCServiceSnapshotProcessAlive(status) && [TVNCServiceState sharedState].running;
    BOOL applied = [status[@"WireGuardEnabled"] isKindOfClass:NSNumber.class] &&
        [status[@"WireGuardEnabled"] boolValue] == self.restartExpectedEnabled &&
        (self.restartExpectedEnabled || ![status[@"WireGuardStarted"] boolValue]);
    if (replaced && applied) {
        self.restartNotice = nil;
    } else if (self.restartDeadline.timeIntervalSinceNow > 0) return;
    else self.restartNotice = @"Restart unconfirmed. Refresh or restart from Home.";
    self.restartDeadline = nil;
    [self.restartTimer invalidate]; self.restartTimer = nil;
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:2] withRowAnimation:UITableViewRowAnimationNone];
}
- (void)restartForWireGuardChange {
    self.restartNotice = nil;
    if (TVNCServiceSnapshotProcessAlive(self.status)) {
        self.restartPID = self.status[@"ServerPID"];
        self.restartExpectedEnabled = TVNCWGShouldStart([self.preferences dictionaryForKey:@"WireGuardConfig"],
            [self.preferences objectForKey:@"WireGuardEnabled"]);
        self.restartDeadline = [NSDate dateWithTimeIntervalSinceNow:20];
        TVNCRestartVNCService();
        [self observeRestart];
    } else {
        self.restartNotice = @"Saved. Start services from Home.";
    }
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:2] withRowAnimation:UITableViewRowAnimationNone];
}

// The displayed value is a shared IP, independent of either service port.
- (void)configureAddressCell:(TVNCSettingsValueCell *)cell address:(NSString *)address {
    cell.nameLabel.text = address.length ? address : @"—";
    cell.valueLabel.hidden = YES;
    if (!address.length) return;
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setImage:[UIImage systemImageNamed:@"doc.on.doc"] forState:UIControlStateNormal];
    button.tintColor = TVNCAccentColor();
    button.accessibilityLabel = [self text:@"Copy IP address"];
    __weak UIButton *weakButton = button;
    [button addAction:[UIAction actionWithHandler:^(UIAction *action) {
        UIPasteboard.generalPasteboard.string = address;
        [[[UINotificationFeedbackGenerator alloc] init] notificationOccurred:UINotificationFeedbackTypeSuccess];
        [weakButton setImage:[UIImage systemImageNamed:@"checkmark"] forState:UIControlStateNormal];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            [weakButton setImage:[UIImage systemImageNamed:@"doc.on.doc"] forState:UIControlStateNormal];
        });
    }] forControlEvents:UIControlEventTouchUpInside];
    [button sizeToFit];
    cell.accessoryView = button;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0) { [super tableView:tableView didSelectRowAtIndexPath:indexPath]; return; }
    NSArray<NSString *> *rows = self.wireGuardRows;
    NSString *kind = indexPath.section == 2 && indexPath.row < rows.count ? rows[indexPath.row] : nil;
    // A live service change can remove an address row between display and tap.
    // Never reinterpret a stale address tap as the now-shifted Remove action.
    NSString *displayedKind = [tableView cellForRowAtIndexPath:indexPath].accessibilityIdentifier;
    if (indexPath.section == 2 && (!kind || ![displayedKind isEqualToString:kind])) {
        [tableView deselectRowAtIndexPath:indexPath animated:NO];
        [tableView reloadSections:[NSIndexSet indexSetWithIndex:2] withRowAnimation:UITableViewRowAnimationNone];
        return;
    }
    if ([kind isEqualToString:@"remove"] && !self.restartDeadline) {
        [self removeConfiguration];
    } else if ([kind isEqualToString:@"add"] || [kind isEqualToString:@"configuration"]) {
        TVNCWireGuardController *controller = [TVNCWireGuardController new];
        controller.localizationBundle = self.localizationBundle;
        [self.navigationController pushViewController:controller animated:YES];
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
    [self restartForWireGuardChange];
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
        [self restartForWireGuardChange];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
