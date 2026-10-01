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

#import "CCTrollVNC.h"
#import "TVNCUtil.h"

#import <notify.h>

@implementation CCTrollVNC

- (UIImage *)iconGlyph {
    return [UIImage imageNamed:@"icon"
                             inBundle:[NSBundle bundleForClass:[self class]]
        compatibleWithTraitCollection:nil];
}

- (UIColor *)selectedColor {
    return [UIColor colorWithRed:35 / 255.0 green:158 / 255.0 blue:171 / 255.0 alpha:1.0];
}

// The unified daemon is always running. This tile is a restart action.
- (BOOL)isSelected { return YES; }
- (void)setSelected:(BOOL)selected {
    TVNCRestartVNCService();
    notify_post(TVNC_NOTIFY_PREFS_CHANGED);
}

@end
