#import <UIKit/UIKit.h>
#import <Preferences/Preferences.h>
#import "ChargeControlPaths.h"

@interface FRootListController : PSListController
@end

@implementation FRootListController

- (id)specifiers {
    if (_specifiers == nil) _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    return _specifiers;
}

// 任一开关/档位变化都通知守护即时重算（限制充电 daemon 监听该通知）
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    [super setPreferenceValue:value specifier:specifier];
    notify_post(kChargeControlSettingsChangedNotifC);
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    notify_post(kChargeControlSettingsChangedNotifC);
}

@end
