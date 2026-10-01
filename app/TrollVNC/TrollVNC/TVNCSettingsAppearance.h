// GPL-2.0-only.
#pragma once
#import <UIKit/UIKit.h>
NS_INLINE UIColor *TVNCAccentColor(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        return traits.userInterfaceStyle == UIUserInterfaceStyleDark ?
            [UIColor colorWithRed:0.25 green:0.79 blue:0.82 alpha:1] :
            [UIColor colorWithRed:0 green:0.49 blue:0.55 alpha:1];
    }];
}
NS_INLINE void TVNCStyleSettingsTable(UITableView *table) {
    table.backgroundColor = UIColor.systemGroupedBackgroundColor;
    table.tintColor = TVNCAccentColor();
    table.rowHeight = UITableViewAutomaticDimension;
    table.estimatedRowHeight = 52;
    table.sectionHeaderHeight = UITableViewAutomaticDimension;
    table.sectionFooterHeight = UITableViewAutomaticDimension;
    table.estimatedSectionHeaderHeight = 28;
    table.estimatedSectionFooterHeight = 24;
    table.cellLayoutMarginsFollowReadableWidth = YES;
}
NS_INLINE UILabel *TVNCSettingsLabel(UIFontTextStyle style, UIColor *color) {
    UILabel *label = [UILabel new];
    label.font = [UIFont preferredFontForTextStyle:style];
    label.adjustsFontForContentSizeCategory = YES;
    label.textColor = color; label.numberOfLines = 0;
    return label;
}
@interface TVNCSettingsValueCell : UITableViewCell
@property(nonatomic, strong) UILabel *nameLabel;
@property(nonatomic, strong) UILabel *valueLabel;
@property(nonatomic, strong) UIStackView *rowStack;
@property(nonatomic, strong) UIStackView *contentStack;
- (void)addLeadingSymbol:(NSString *)name;
@end
