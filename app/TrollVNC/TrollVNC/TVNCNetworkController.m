// GPL-2.0-only.
#import "TVNCNetworkController.h"
#import "TVNCServiceStatus.h"
#import "TVNCWireGuardController.h"

@interface TVNCNetworkController ()
@property(nonatomic, strong) NSDictionary *status;
@property(nonatomic, strong) NSArray<NSString *> *localAddresses;
@property(nonatomic, strong) NSTimer *timer;
@property(nonatomic, assign) BOOL fetching;
@end
@implementation TVNCNetworkController
- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }
- (NSString *)text:(NSString *)key {
    return NSLocalizedStringFromTableInBundle(key, @"Localizable", self.localizationBundle ?: [NSBundle bundleForClass:self.class], nil);
}
- (void)viewDidLoad {
    [super viewDidLoad]; self.title = [self text:@"Network settings"];
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 52;
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
    if (section == 0) return 3;
    if (section == 1) return MAX(1, self.localAddresses.count) * 2;
    return [self.status[@"WireGuardStarted"] boolValue] ? 4 : 2;
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return [self text:(section == 0 ? @"Service" : section == 1 ? @"Local network" : @"WireGuard")];
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0) return [self text:@"VNC and ZXTouch always run together. The addresses below reflect the running service, not unapplied edits."];
    if (section == 1) return [self text:@"Both protocols share the same network. Tap an address to copy it."];
    if (self.status && [self.status[@"WireGuardConfigured"] boolValue] && ![self.status[@"WireGuardStarted"] boolValue])
        return self.status[@"WireGuardError"];
    return [self text:@"One WireGuard configuration provides access to both ports. Saving a configuration restarts TrollVNC; removing it keeps local access available."];
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    cell.detailTextLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    cell.textLabel.adjustsFontForContentSizeCategory = YES; cell.detailTextLabel.adjustsFontForContentSizeCategory = YES;
    cell.textLabel.numberOfLines = 0; cell.detailTextLabel.numberOfLines = 0;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    NSInteger row = indexPath.row;
    if (indexPath.section == 0) {
        if (row == 0) {
            cell.textLabel.text = [self text:self.status ? @"Running" : @"Service status unavailable"];
            cell.detailTextLabel.text = @"TrollVNC · Dopamine rootless";
        } else {
            NSString *name = row == 1 ? @"VNC" : @"ZXTouch";
            cell.textLabel.text = name;
            cell.detailTextLabel.text = self.status ? [NSString stringWithFormat:@"TCP %@", self.status[row == 1 ? @"VNCPort" : @"ZXTouchPort"]] : @"—";
        }
    } else if (indexPath.section == 1) {
        cell.textLabel.text = row % 2 ? @"ZXTouch" : @"VNC";
        if (self.localAddresses.count) {
            cell.detailTextLabel.text = TVNCServiceSocket(self.localAddresses[row / 2], self.status[row % 2 ? @"ZXTouchPort" : @"VNCPort"]);
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        } else cell.detailTextLabel.text = [self text:@"Address unavailable"];
    } else if (row == 0) {
        NSString *state = !self.status ? @"Service status unavailable" :
            [self.status[@"WireGuardStarted"] boolValue] ? @"Interface running" :
            [self.status[@"WireGuardConfigured"] boolValue] ? @"Network failed to start" : @"No configuration";
        cell.textLabel.text = [self text:state];
        if ([self.status[@"WireGuardStarted"] boolValue]) cell.detailTextLabel.text = self.status[@"WireGuardAddress"];
    } else if (row == 1) {
        cell.textLabel.text = [self text:@"WireGuard configuration…"];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    } else {
        cell.textLabel.text = row == 2 ? @"VNC" : @"ZXTouch";
        cell.detailTextLabel.text = TVNCServiceSocket(self.status[@"WireGuardAddress"], self.status[row == 2 ? @"VNCPort" : @"ZXTouchPort"]);
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    }
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 2 && indexPath.row == 1) {
        TVNCWireGuardController *controller = [TVNCWireGuardController new];
        controller.localizationBundle = self.localizationBundle;
        [self.navigationController pushViewController:controller animated:YES];
    } else if ((indexPath.section == 1 && self.localAddresses.count) || (indexPath.section == 2 && indexPath.row >= 2)) {
        NSString *address = indexPath.section == 1 ? self.localAddresses[indexPath.row / 2] : self.status[@"WireGuardAddress"];
        BOOL isZX = indexPath.section == 1 ? indexPath.row % 2 : indexPath.row == 3;
        UIPasteboard.generalPasteboard.string = TVNCServiceSocket(address, self.status[isZX ? @"ZXTouchPort" : @"VNCPort"]);
        UINotificationFeedbackGenerator *feedback = [UINotificationFeedbackGenerator new];
        [feedback notificationOccurred:UINotificationFeedbackTypeSuccess];
        [tableView cellForRowAtIndexPath:indexPath].detailTextLabel.text = [self text:@"Copied"];
    }
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
}
@end
