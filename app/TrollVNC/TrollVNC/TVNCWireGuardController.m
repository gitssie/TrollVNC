#import "TVNCWireGuardController.h"

#import "TVNCUtil.h"
#import "TVNCWireGuardConfig.h"
#import "TVNCServiceStatus.h"

@interface TVNCWireGuardController () <UITextViewDelegate>
@property(nonatomic, strong) UIBarButtonItem *saveButton;
@property(nonatomic, strong) UIBarButtonItem *cancelButton;
@property(nonatomic, strong) UIScrollView *scrollView;
@property(nonatomic, strong) NSLayoutConstraint *editorBottomConstraint;
@property(nonatomic, strong) UITextView *configurationEditor;
@property(nonatomic, strong) UIBarButtonItem *editButton;
@property(nonatomic, strong) UIStackView *detailsStack;
@property(nonatomic, strong) NSUserDefaults *preferences;
@property(nonatomic, strong) NSDictionary *savedConfiguration;
@property(nonatomic, assign) BOOL editingConfiguration;
@end

@implementation TVNCWireGuardController

- (NSString *)text:(NSString *)key {
    return NSLocalizedStringFromTableInBundle(key, @"Localizable", self.localizationBundle ?: [NSBundle bundleForClass:self.class], nil);
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"WireGuard";
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    self.saveButton = [[UIBarButtonItem alloc] initWithTitle:[self text:@"Save"]
                                                      style:UIBarButtonItemStyleDone
                                                     target:self
                                                     action:@selector(saveConfiguration)];
    self.saveButton.accessibilityLabel = @"Save WireGuard configuration";
    self.cancelButton = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel
                                                                       target:self
                                                                       action:@selector(cancelEditing)];
    self.preferences = [[NSUserDefaults alloc] initWithSuiteName:@"com.82flex.trollvnc"];
    self.savedConfiguration = [self.preferences dictionaryForKey:@"WireGuardConfig"];
    self.editingConfiguration = self.savedConfiguration == nil;

    UIScrollView *scroll = [[UIScrollView alloc] initWithFrame:CGRectZero];
    self.scrollView = scroll;
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:scroll];
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
    ]];

    UIStackView *stack = [[UIStackView alloc] initWithFrame:CGRectZero];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 10;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:12],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:16],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-16],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-16],
        [stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-32]
    ]];

    self.detailsStack = [[UIStackView alloc] initWithFrame:CGRectZero];
    self.detailsStack.axis = UILayoutConstraintAxisVertical;
    self.detailsStack.spacing = 10;
    [stack addArrangedSubview:self.detailsStack];

    UIButton *removeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [removeButton setTitle:[self text:@"Remove configuration"] forState:UIControlStateNormal];
    [removeButton setTitleColor:UIColor.systemRedColor forState:UIControlStateNormal];
    [removeButton.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
    [removeButton addTarget:self action:@selector(removeConfiguration) forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:[self cardWithViews:@[removeButton]]];

    self.editButton = [[UIBarButtonItem alloc] initWithTitle:[self text:@"Edit"]
                                                      style:UIBarButtonItemStylePlain
                                                     target:self
                                                     action:@selector(editSavedConfiguration)];
    self.editButton.accessibilityLabel = @"Edit WireGuard configuration";

    self.configurationEditor = [[UITextView alloc] initWithFrame:CGRectZero];
    self.configurationEditor.translatesAutoresizingMaskIntoConstraints = NO;
    self.configurationEditor.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    self.configurationEditor.font = [UIFont monospacedSystemFontOfSize:15 weight:UIFontWeightRegular];
    self.configurationEditor.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.configurationEditor.autocorrectionType = UITextAutocorrectionTypeNo;
    self.configurationEditor.spellCheckingType = UITextSpellCheckingTypeNo;
    self.configurationEditor.smartQuotesType = UITextSmartQuotesTypeNo;
    self.configurationEditor.smartDashesType = UITextSmartDashesTypeNo;
    self.configurationEditor.delegate = self;
    self.configurationEditor.textContainerInset = UIEdgeInsetsMake(16, 16, 16, 16);
    [self.view addSubview:self.configurationEditor];
    self.editorBottomConstraint = [self.configurationEditor.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor];
    [NSLayoutConstraint activateConstraints:@[
        [self.configurationEditor.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.configurationEditor.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.configurationEditor.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        self.editorBottomConstraint
    ]];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(keyboardFrameChanged:)
                                                 name:UIKeyboardWillChangeFrameNotification
                                               object:nil];
    [self updateSummary];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)keyboardFrameChanged:(NSNotification *)notification {
    CGRect keyboardFrame = [notification.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    keyboardFrame = [self.view convertRect:keyboardFrame fromView:nil];
    CGFloat overlap = MAX(0, CGRectGetMaxY(self.view.bounds) - CGRectGetMinY(keyboardFrame));
    self.editorBottomConstraint.constant = -MAX(0, overlap - self.view.safeAreaInsets.bottom);
    NSTimeInterval duration = [notification.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    [UIView animateWithDuration:duration animations:^{ [self.view layoutIfNeeded]; }];
}

- (void)cancelEditing {
    [self.configurationEditor resignFirstResponder];
    if (!self.savedConfiguration) {
        [self.navigationController popViewControllerAnimated:YES];
        return;
    }
    self.editingConfiguration = NO;
    [self updateSummary];
}

- (UILabel *)label:(NSString *)text style:(UIFontTextStyle)style {
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.text = [self text:text];
    label.font = [UIFont preferredFontForTextStyle:style];
    label.adjustsFontForContentSizeCategory = YES;
    return label;
}

- (UIStackView *)cardWithViews:(NSArray<UIView *> *)views {
    UIStackView *card = [[UIStackView alloc] initWithArrangedSubviews:views];
    card.axis = UILayoutConstraintAxisVertical;
    card.spacing = 4;
    card.layoutMarginsRelativeArrangement = YES;
    card.directionalLayoutMargins = NSDirectionalEdgeInsetsMake(10, 14, 10, 14);
    card.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    card.layer.cornerRadius = 12;
    card.clipsToBounds = YES;
    return card;
}

- (NSString *)displayList:(id)value {
    if (![value isKindOfClass:[NSArray class]]) return @"—";
    NSMutableArray<NSString *> *items = [NSMutableArray array];
    for (id item in (NSArray *)value) {
        if ([item isKindOfClass:[NSString class]] && [item length]) [items addObject:item];
    }
    return items.count ? [items componentsJoinedByString:@", "] : @"—";
}

- (NSString *)compactPublicKey:(NSString *)key {
    if (![key isKindOfClass:[NSString class]]) return @"—";
    if (key.length <= 20) return key;
    return [NSString stringWithFormat:@"%@…%@", [key substringToIndex:8], [key substringFromIndex:key.length - 6]];
}

- (UIStackView *)detailSection:(NSString *)heading rows:(NSArray<NSArray<NSString *> *> *)rows {
    UIStackView *card = [self cardWithViews:@[]];
    card.spacing = 0;
    CGFloat separatorHeight = 1.0 / UIScreen.mainScreen.scale;

    UILabel *headingLabel = [self label:heading style:UIFontTextStyleHeadline];
    [card addArrangedSubview:headingLabel];
    [headingLabel.heightAnchor constraintGreaterThanOrEqualToConstant:30].active = YES;
    for (NSArray<NSString *> *pair in rows) {
        UIView *separator = [[UIView alloc] initWithFrame:CGRectZero];
        separator.backgroundColor = [UIColor separatorColor];
        [separator.heightAnchor constraintEqualToConstant:separatorHeight].active = YES;
        [card addArrangedSubview:separator];

        UIStackView *row = [[UIStackView alloc] initWithFrame:CGRectZero];
        row.axis = UILayoutConstraintAxisHorizontal;
        row.alignment = UIStackViewAlignmentCenter;
        row.spacing = 8;
        UILabel *name = [self label:pair[0] style:UIFontTextStyleSubheadline];
        name.numberOfLines = 0;
        [name.widthAnchor constraintEqualToConstant:86].active = YES;
        UILabel *value = [self label:pair[1] style:UIFontTextStyleSubheadline];
        value.textColor = [UIColor secondaryLabelColor];
        value.textAlignment = NSTextAlignmentRight;
        value.numberOfLines = 0;
        value.lineBreakMode = NSLineBreakByCharWrapping;
        [row addArrangedSubview:name];
        [row addArrangedSubview:value];
        [row.heightAnchor constraintGreaterThanOrEqualToConstant:36].active = YES;
        row.isAccessibilityElement = YES;
        row.accessibilityLabel = [NSString stringWithFormat:@"%@: %@", pair[0], pair.count > 2 ? pair[2] : pair[1]];
        [card addArrangedSubview:row];
    }
    return card;
}

- (void)updateConfigurationDetails {
    for (UIView *view in [self.detailsStack.arrangedSubviews copy]) {
        [self.detailsStack removeArrangedSubview:view];
        [view removeFromSuperview];
    }
    NSDictionary *configuration = self.savedConfiguration;
    if (!configuration || self.editingConfiguration) {
        self.detailsStack.hidden = YES;
        return;
    }
    self.detailsStack.hidden = NO;

    NSNumber *listenPort = configuration[@"ListenPort"];
    NSNumber *mtu = configuration[@"MTU"];
    NSString *addresses = [[self displayList:configuration[@"Address"]] stringByReplacingOccurrencesOfString:@", "
                                                                                            withString:@"\n"];
    NSMutableArray<NSArray<NSString *> *> *interfaceRows = [NSMutableArray arrayWithArray:@[
        @[@"Address", addresses],
        @[@"Listen port", listenPort.integerValue ? listenPort.stringValue : @"Automatic"],
        @[@"MTU", mtu.integerValue ? mtu.stringValue : @"1420"]
    ]];
    NSString *dns = configuration[@"DNS"];
    if ([dns isKindOfClass:[NSString class]] && dns.length) {
        [interfaceRows addObject:@[@"DNS", dns]];
    }
    [self.detailsStack addArrangedSubview:[self detailSection:@"Interface" rows:interfaceRows]];

    NSArray *peers = configuration[@"Peers"];
    if (![peers isKindOfClass:[NSArray class]]) return;
    for (NSUInteger index = 0; index < peers.count; index++) {
        NSDictionary *peer = peers[index];
        if (![peer isKindOfClass:[NSDictionary class]]) continue;
        NSString *publicKey = peer[@"PublicKey"];
        NSString *endpoint = peer[@"Endpoint"];
        NSNumber *keepalive = peer[@"PersistentKeepalive"];
        NSMutableArray<NSArray<NSString *> *> *peerRows = [NSMutableArray arrayWithArray:@[
            @[@"Endpoint", [endpoint isKindOfClass:[NSString class]] ? endpoint : @"Not set"],
            @[@"Allowed IPs", [self displayList:peer[@"AllowedIPs"]]],
            @[@"Keepalive", keepalive.integerValue ? [NSString stringWithFormat:@"%@ s", keepalive] : @"Off"],
            @[@"Public key", [self compactPublicKey:publicKey], [publicKey isKindOfClass:[NSString class]] ? publicKey : @"—"]
        ]];
        [self.detailsStack addArrangedSubview:
            [self detailSection:[NSString stringWithFormat:[self text:@"Peer %lu"], (unsigned long)(index + 1)] rows:peerRows]];
    }
}

- (void)updateSummary {
    self.scrollView.hidden = self.editingConfiguration;
    self.configurationEditor.hidden = !self.editingConfiguration;
    self.title = self.editingConfiguration ? [self text:@"Edit configuration"] : @"WireGuard";
    self.navigationItem.leftBarButtonItem = self.editingConfiguration ? self.cancelButton : nil;
    self.navigationItem.rightBarButtonItem = self.editingConfiguration ? self.saveButton : self.editButton;
    [self updateConfigurationDetails];
}

- (void)editSavedConfiguration {
    self.editingConfiguration = YES;
    self.configurationEditor.text = TVNCWGConfigurationText(self.savedConfiguration);
    [self updateSummary];
    [self.configurationEditor becomeFirstResponder];
}

- (void)showError:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:[self text:@"WireGuard configuration"]
                                                                   message:[self text:message]
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:[self text:@"OK"] style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showNotice:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"WireGuard"
                                                                   message:[self text:message]
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:[self text:@"OK"] style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)removeConfiguration {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:[self text:@"Remove configuration"]
        message:[self text:@"Remove WireGuard configuration and restart TrollVNC? Local access remains available."]
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:[self text:@"Cancel"] style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:[self text:@"Remove"] style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        NSDictionary *previous = self.savedConfiguration;
        NSNumber *previousEnabled = [self.preferences objectForKey:@"WireGuardEnabled"];
        [self.preferences removeObjectForKey:@"WireGuardConfig"];
        [self.preferences removeObjectForKey:@"WireGuardEnabled"];
        if (![self.preferences synchronize]) {
            if (previous) [self.preferences setObject:previous forKey:@"WireGuardConfig"];
            if (previousEnabled) [self.preferences setObject:previousEnabled forKey:@"WireGuardEnabled"];
            [self showError:@"Could not save the WireGuard configuration."]; return;
        }
        TVNCRestartVNCService();
        [self.navigationController popViewControllerAnimated:YES];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)saveConfiguration {
    [self.view endEditing:YES];
    NSDictionary *configuration = self.savedConfiguration;
    if (self.editingConfiguration || !configuration) {
        NSError *error = nil;
        configuration = TVNCWGParseConfiguration(self.configurationEditor.text ?: @"", &error);
        if (!configuration) { [self showError:error.localizedDescription]; return; }
    }
    NSString *bind = [self.preferences stringForKey:@"BindHost"] ?: @"";
    if (!TVNCSharedBindAllowsWireGuard(bind)) {
        [self showError:@"Use 0.0.0.0 to access both Wi-Fi and WireGuard."]; return;
    }
    int vnc = TVNCParseServicePort([self.preferences objectForKey:@"Port"] ?: @5901, NO);
    int zx = TVNCParseServicePort([self.preferences objectForKey:@"ZXTouchPort"] ?: @6000, NO);
    int http = TVNCParseServicePort([self.preferences objectForKey:@"HttpPort"] ?: @0, YES);
    if (!TVNCServicePortsValid(vnc, zx, http)) {
        [self showError:@"Ports must be distinct and within 1024–65535. HTTP may be 0. Ports 46751 and 46752 are reserved."]; return;
    }
    NSDictionary *previousConfiguration = self.savedConfiguration;
    NSNumber *previousEnabled = [self.preferences objectForKey:@"WireGuardEnabled"];
    [self.preferences setObject:configuration forKey:@"WireGuardConfig"];
    if (!previousConfiguration) [self.preferences setBool:YES forKey:@"WireGuardEnabled"];
    if (![self.preferences synchronize]) {
        if (previousConfiguration) [self.preferences setObject:previousConfiguration forKey:@"WireGuardConfig"];
        else [self.preferences removeObjectForKey:@"WireGuardConfig"];
        if (previousEnabled) [self.preferences setObject:previousEnabled forKey:@"WireGuardEnabled"];
        else [self.preferences removeObjectForKey:@"WireGuardEnabled"];
        [self showError:@"Could not save the WireGuard configuration."];
        return;
    }
    self.savedConfiguration = configuration;
    self.editingConfiguration = NO;
    self.configurationEditor.text = @"";
    [self updateSummary];
    TVNCRestartVNCService();
    [self showNotice:TVNCWGShouldStart(configuration, [self.preferences objectForKey:@"WireGuardEnabled"]) ?
        @"Saved. TrollVNC is restarting both services with the shared network configuration." :
        @"Saved. WireGuard remains off until enabled in Network settings."];
}

@end
