#import "TVNCWireGuardController.h"

#import "TVNCUtil.h"
#import "TVNCWireGuardConfig.h"

@interface TVNCWireGuardController () <UITextViewDelegate>
@property(nonatomic, strong) UISwitch *enabledSwitch;
@property(nonatomic, strong) UITextView *configurationEditor;
@property(nonatomic, strong) UILabel *addressLabel;
@property(nonatomic, strong) UILabel *hintLabel;
@property(nonatomic, strong) UIButton *editButton;
@property(nonatomic, strong) NSUserDefaults *preferences;
@property(nonatomic, strong) NSDictionary *savedConfiguration;
@property(nonatomic, assign) BOOL editingConfiguration;
@end

@implementation TVNCWireGuardController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"WireGuard";
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    self.preferences = [[NSUserDefaults alloc] initWithSuiteName:@"com.82flex.trollvnc"];
    self.savedConfiguration = [self.preferences dictionaryForKey:@"WireGuardConfig"];

    UIScrollView *scroll = [[UIScrollView alloc] initWithFrame:CGRectZero];
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
    stack.spacing = 12;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:20],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:20],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-20],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-24],
        [stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-40]
    ]];

    UIStackView *toggleRow = [[UIStackView alloc] initWithFrame:CGRectZero];
    toggleRow.axis = UILayoutConstraintAxisHorizontal;
    toggleRow.alignment = UIStackViewAlignmentCenter;
    UILabel *toggleTitle = [self label:@"Enable WireGuard access" style:UIFontTextStyleBody];
    [toggleRow addArrangedSubview:toggleTitle];
    self.enabledSwitch = [[UISwitch alloc] initWithFrame:CGRectZero];
    self.enabledSwitch.on = [self.preferences boolForKey:@"WireGuardEnabled"];
    [toggleRow addArrangedSubview:self.enabledSwitch];
    [stack addArrangedSubview:toggleRow];

    self.addressLabel = [self label:@"No configuration saved" style:UIFontTextStyleBody];
    self.addressLabel.numberOfLines = 0;
    [stack addArrangedSubview:self.addressLabel];
    UIButton *copyButton = [self button:@"Copy VNC address" action:@selector(copyAddress)];
    [stack addArrangedSubview:copyButton];

    [stack addArrangedSubview:[self label:@"WireGuard configuration" style:UIFontTextStyleHeadline]];
    self.hintLabel = [self label:@"Paste the complete [Interface] and [Peer] configuration below. Existing keys stay hidden until you choose Edit." style:UIFontTextStyleFootnote];
    self.hintLabel.numberOfLines = 0;
    self.hintLabel.textColor = [UIColor secondaryLabelColor];
    [stack addArrangedSubview:self.hintLabel];

    self.editButton = [self button:@"Edit saved configuration" action:@selector(editSavedConfiguration)];
    [stack addArrangedSubview:self.editButton];

    self.configurationEditor = [[UITextView alloc] initWithFrame:CGRectZero];
    self.configurationEditor.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    self.configurationEditor.font = [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightRegular];
    self.configurationEditor.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.configurationEditor.autocorrectionType = UITextAutocorrectionTypeNo;
    self.configurationEditor.spellCheckingType = UITextSpellCheckingTypeNo;
    self.configurationEditor.smartQuotesType = UITextSmartQuotesTypeNo;
    self.configurationEditor.smartDashesType = UITextSmartDashesTypeNo;
    self.configurationEditor.delegate = self;
    self.configurationEditor.layer.cornerRadius = 10;
    self.configurationEditor.textContainerInset = UIEdgeInsetsMake(12, 8, 12, 8);
    [self.configurationEditor.heightAnchor constraintEqualToConstant:300].active = YES;
    [stack addArrangedSubview:self.configurationEditor];

    UIButton *saveButton = [self button:@"Save and restart VNC" action:@selector(saveAndRestart)];
    [stack addArrangedSubview:saveButton];
    [self updateSummary];
}

- (UILabel *)label:(NSString *)text style:(UIFontTextStyle)style {
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.text = text;
    label.font = [UIFont preferredFontForTextStyle:style];
    return label;
}

- (UIButton *)button:(NSString *)title action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    [button.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (void)updateSummary {
    NSString *address = TVNCWGPrimaryAddress(self.savedConfiguration ?: @{});
    NSNumber *port = [self.preferences objectForKey:@"Port"];
    NSInteger vncPort = port.integerValue >= 1024 && port.integerValue <= 65535 ? port.integerValue : 5901;
    NSString *socket = [address containsString:@":"] ?
        [NSString stringWithFormat:@"[%@]:%ld", address, (long)vncPort] :
        [NSString stringWithFormat:@"%@:%ld", address, (long)vncPort];
    self.addressLabel.text = address.length ? [@"VNC address: " stringByAppendingString:socket] : @"No configuration saved";
    self.editButton.hidden = self.savedConfiguration == nil;
    self.configurationEditor.hidden = self.savedConfiguration != nil && !self.editingConfiguration;
    self.hintLabel.text = self.savedConfiguration && !self.editingConfiguration ?
        @"Configuration saved. Keys are hidden; tap Edit to replace or inspect it. For Karing, use Rule mode and send the WireGuard gateway IP DIRECT." :
        @"Paste the complete [Interface] and [Peer] configuration here. Keys are visible while editing. In Karing, route the WireGuard gateway IP DIRECT.";
}

- (void)editSavedConfiguration {
    self.editingConfiguration = YES;
    self.configurationEditor.text = TVNCWGConfigurationText(self.savedConfiguration);
    [self updateSummary];
}

- (void)copyAddress {
    NSString *address = TVNCWGPrimaryAddress(self.savedConfiguration ?: @{});
    if (!address.length) return;
    NSNumber *port = [self.preferences objectForKey:@"Port"];
    NSInteger vncPort = port.integerValue >= 1024 && port.integerValue <= 65535 ? port.integerValue : 5901;
    UIPasteboard.generalPasteboard.string = [address containsString:@":"] ?
        [NSString stringWithFormat:@"[%@]:%ld", address, (long)vncPort] :
        [NSString stringWithFormat:@"%@:%ld", address, (long)vncPort];
}

- (void)showError:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"WireGuard configuration"
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)saveAndRestart {
    [self.view endEditing:YES];
    NSDictionary *configuration = self.savedConfiguration;
    if (self.editingConfiguration || !configuration) {
        NSError *error = nil;
        configuration = TVNCWGParseConfiguration(self.configurationEditor.text ?: @"", &error);
        if (!configuration) { [self showError:error.localizedDescription]; return; }
    }
    if (self.enabledSwitch.on) {
        NSString *reverse = [self.preferences stringForKey:@"ReverseMode"] ?: @"none";
        NSString *bind = [self.preferences stringForKey:@"BindHost"] ?: @"";
        if (![reverse isEqualToString:@"none"]) {
            [self showError:@"Turn off Reverse Connection before enabling WireGuard access."];
            return;
        }
        if (bind.length && ![bind isEqualToString:@"127.0.0.1"] && ![bind isEqualToString:@"::1"]) {
            [self showError:@"Clear Bind Address so the local VNC bridge can reach the server."];
            return;
        }
    }
    [self.preferences setObject:configuration forKey:@"WireGuardConfig"];
    [self.preferences setBool:self.enabledSwitch.on forKey:@"WireGuardEnabled"];
    [self.preferences synchronize];
    self.savedConfiguration = configuration;
    self.editingConfiguration = NO;
    self.configurationEditor.text = @"";
    [self updateSummary];
    TVNCRestartVNCService();
}

@end
