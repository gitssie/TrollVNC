// GPL-2.0-only.
#import "TVNCSettingsPageController.h"
#import "TVNCSettingsModel.h"
#import "TVNCSettingsAppearance.h"

@implementation TVNCSettingsValueCell
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)identifier {
    self = [super initWithStyle:UITableViewCellStyleDefault reuseIdentifier:identifier];
    if (!self) return nil;
    self.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
    _nameLabel = TVNCSettingsLabel(UIFontTextStyleBody, UIColor.labelColor);
    _valueLabel = TVNCSettingsLabel(UIFontTextStyleSubheadline, UIColor.secondaryLabelColor);
    _valueLabel.textAlignment = NSTextAlignmentRight;
    [_nameLabel setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    _rowStack = [[UIStackView alloc] initWithArrangedSubviews:@[_nameLabel, _valueLabel]];
    _rowStack.axis = UILayoutConstraintAxisHorizontal; _rowStack.alignment = UIStackViewAlignmentCenter; _rowStack.spacing = 12;
    _contentStack = [[UIStackView alloc] initWithArrangedSubviews:@[_rowStack]];
    _contentStack.axis = UILayoutConstraintAxisVertical; _contentStack.spacing = 12;
    _contentStack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:_contentStack];
    UILayoutGuide *margins = self.contentView.layoutMarginsGuide;
    [NSLayoutConstraint activateConstraints:@[
        [_contentStack.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
        [_contentStack.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
        [_contentStack.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:12],
        [_contentStack.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-12],
        [self.contentView.heightAnchor constraintGreaterThanOrEqualToConstant:48]
    ]];
    self.selectionStyle = UITableViewCellSelectionStyleDefault;
    return self;
}
- (void)addLeadingSymbol:(NSString *)name {
    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:name]];
    icon.tintColor = TVNCAccentColor(); icon.contentMode = UIViewContentModeScaleAspectFit;
    [NSLayoutConstraint activateConstraints:@[[icon.widthAnchor constraintEqualToConstant:24], [icon.heightAnchor constraintEqualToConstant:24]]];
    [self.rowStack insertArrangedSubview:icon atIndex:0];
}
- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    BOOL accessible = UIContentSizeCategoryIsAccessibilityCategory(self.traitCollection.preferredContentSizeCategory);
    self.rowStack.axis = accessible ? UILayoutConstraintAxisVertical : UILayoutConstraintAxisHorizontal;
    self.rowStack.alignment = accessible ? UIStackViewAlignmentLeading : UIStackViewAlignmentCenter;
    self.valueLabel.textAlignment = accessible ? NSTextAlignmentLeft : NSTextAlignmentRight;
}
@end

@interface TVNCSettingSwitch : UISwitch
@property(nonatomic, strong) NSDictionary *setting;
@end
@implementation TVNCSettingSwitch
@end
@interface TVNCSettingSlider : UISlider
@property(nonatomic, strong) NSDictionary *setting;
@property(nonatomic, weak) UILabel *valueLabel;
@end
@implementation TVNCSettingSlider
@end

@interface TVNCSettingsPageController ()
@property(nonatomic, strong, readwrite) NSDictionary *category;
@end
@implementation TVNCSettingsPageController
- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }
- (NSString *)text:(NSString *)key { return TVNCUIString(self.localizationBundle ?: [NSBundle bundleForClass:self.class], key); }
- (void)viewDidLoad {
    [super viewDidLoad];
    self.preferences = self.preferences ?: [[NSUserDefaults alloc] initWithSuiteName:@"com.82flex.trollvnc"];
    self.category = TVNCSettingsCatalog(self.localizationBundle ?: [NSBundle bundleForClass:self.class])[self.categoryIdentifier] ?: @{};
    self.title = [self text:self.category[@"title"] ?: @"TrollVNC"];
    TVNCStyleSettingsTable(self.tableView);
    self.navigationItem.backBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"TrollVNC" style:UIBarButtonItemStylePlain target:nil action:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(settingsChanged:) name:TVNCSettingsDidChangeNotification object:nil];
}
- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated]; [self.preferences synchronize]; [self.tableView reloadData];
}
- (void)settingsChanged:(NSNotification *)notification { [self.tableView reloadData]; }
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return [self.category[@"groups"] count]; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return [self.category[@"groups"][section][@"rows"] count];
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    NSString *title = self.category[@"groups"][section][@"title"]; return title.length ? [self text:title] : nil;
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    NSString *footer = self.category[@"groups"][section][@"footer"]; return footer.length ? [self text:footer] : nil;
}
- (NSDictionary *)settingAtIndexPath:(NSIndexPath *)indexPath {
    return self.category[@"groups"][indexPath.section][@"rows"][indexPath.row];
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *row = [self settingAtIndexPath:indexPath];
    TVNCSettingsValueCell *cell = [[TVNCSettingsValueCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.nameLabel.text = [self text:row[@"title"]];
    NSString *kind = row[@"kind"];
    if ([kind isEqualToString:@"info"]) {
        cell.nameLabel.textColor = TVNCAccentColor(); cell.nameLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
        [cell addLeadingSymbol:row[@"symbol"]]; cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if ([kind isEqualToString:@"action"]) {
        cell.nameLabel.textColor = TVNCAccentColor();
        [cell addLeadingSymbol:row[@"symbol"]];
    } else if ([kind isEqualToString:@"switch"]) {
        TVNCSettingSwitch *toggle = [TVNCSettingSwitch new]; toggle.setting = row;
        toggle.onTintColor = TVNCAccentColor(); toggle.on = [TVNCSettingValue(self.preferences, row) boolValue];
        toggle.accessibilityLabel = cell.nameLabel.text;
        [toggle addTarget:self action:@selector(toggleSetting:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle; cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else {
        cell.valueLabel.text = TVNCSettingDisplay(self.preferences, row, self.localizationBundle);
        if ([kind isEqualToString:@"slider"]) {
            TVNCSettingSlider *slider = [TVNCSettingSlider new]; slider.setting = row; slider.valueLabel = cell.valueLabel;
            slider.minimumValue = [row[@"min"] floatValue]; slider.maximumValue = [row[@"max"] floatValue];
            slider.value = [TVNCSettingValue(self.preferences, row) floatValue];
            slider.minimumTrackTintColor = TVNCAccentColor(); slider.accessibilityLabel = cell.nameLabel.text;
            slider.continuous = YES;
            [slider addTarget:self action:@selector(previewSlider:) forControlEvents:UIControlEventValueChanged];
            [slider addTarget:self action:@selector(saveSlider:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
            [cell.contentStack addArrangedSubview:slider];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            cell.valueLabel.accessibilityLabel = cell.nameLabel.text;
        } else cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    cell.accessibilityIdentifier = row[@"key"] ?: row[@"action"];
    return cell;
}
- (void)showSettingError:(NSError *)error {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:[self text:@"Unable to save"] message:[self text:error.localizedDescription] preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:[self text:@"OK"] style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)toggleSetting:(TVNCSettingSwitch *)sender {
    NSError *error = nil;
    if (!TVNCWriteSetting(self.preferences, sender.setting, @(sender.on), &error)) {
        sender.on = !sender.on; [self showSettingError:error];
    }
}
- (void)previewSlider:(TVNCSettingSlider *)sender {
    double number = sender.value;
    if ([sender.setting[@"integer"] boolValue]) number = round(number);
    if ([sender.setting[@"key"] isEqualToString:@"KeepAliveSec"] && number > 0 && number < 15) number = number < 7.5 ? 0 : 15;
    sender.value = number;
    sender.valueLabel.text = [NSString stringWithFormat:[self text:sender.setting[@"format"]], number];
    sender.accessibilityValue = sender.valueLabel.text;
    if (!sender.tracking) {
        NSError *error = nil;
        if (!TVNCWriteSetting(self.preferences, sender.setting, @(number), &error)) [self showSettingError:error];
    }
}
- (void)saveSlider:(TVNCSettingSlider *)sender {
    NSError *error = nil;
    if (!TVNCWriteSetting(self.preferences, sender.setting, @(sender.value), &error)) [self showSettingError:error];
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *row = [self settingAtIndexPath:indexPath]; NSString *kind = row[@"kind"];
    if ([kind isEqualToString:@"action"]) { if (self.actionHandler) self.actionHandler(row[@"action"]); return; }
    if ([kind isEqualToString:@"switch"] || [kind isEqualToString:@"slider"] || [kind isEqualToString:@"info"]) return;
    NSString *title = [self text:row[@"title"]];
    if ([kind isEqualToString:@"choice"]) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:nil preferredStyle:UIAlertControllerStyleActionSheet];
        NSArray *values = row[@"choiceValues"], *titles = row[@"choiceTitles"];
        for (NSUInteger i = 0; i < values.count; i++) {
            [alert addAction:[UIAlertAction actionWithTitle:[self text:titles[i]] style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                NSError *error = nil; if (!TVNCWriteSetting(self.preferences, row, values[i], &error)) [self showSettingError:error];
            }]];
        }
        [alert addAction:[UIAlertAction actionWithTitle:[self text:@"Cancel"] style:UIAlertActionStyleCancel handler:nil]];
        alert.popoverPresentationController.sourceView = [tableView cellForRowAtIndexPath:indexPath];
        alert.popoverPresentationController.sourceRect = alert.popoverPresentationController.sourceView.bounds;
        [self presentViewController:alert animated:YES completion:nil]; return;
    }
    NSString *message = row[@"min"] ? [NSString stringWithFormat:@"%@ – %@", row[@"min"], row[@"max"]] : nil;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.text = [TVNCSettingValue(self.preferences, row) description];
        field.placeholder = row[@"placeholder"];
        field.secureTextEntry = [kind isEqualToString:@"secret"];
        field.autocorrectionType = UITextAutocorrectionTypeNo; field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        if ([kind isEqualToString:@"port"]) field.keyboardType = UIKeyboardTypeNumberPad;
        if ([kind isEqualToString:@"number"]) field.keyboardType = [row[@"integer"] boolValue] ? UIKeyboardTypeNumberPad : UIKeyboardTypeDecimalPad;
        field.accessibilityLabel = title;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:[self text:@"Cancel"] style:UIAlertActionStyleCancel handler:nil]];
    __weak UIAlertController *weakAlert = alert;
    [alert addAction:[UIAlertAction actionWithTitle:[self text:@"Save"] style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSError *error = nil;
        if (!TVNCWriteSetting(self.preferences, row, weakAlert.textFields.firstObject.text ?: @"", &error)) [self showSettingError:error];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
@end
