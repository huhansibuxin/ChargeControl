#ifndef CHARGE_CONTROL_PATHS_H
#define CHARGE_CONTROL_PATHS_H

#import <Foundation/Foundation.h>
#import <notify.h>
#include <stdint.h>

#define S(str) [NSString stringWithUTF8String:(str)]

// 设置变更通知（FRootListController 在开关变化时 post，ChargeControlTool 监听后即时重算）
static const char *kChargeControlSettingsChangedNotifC = "com.chargecontrol/settingsChanged";

static inline NSString *ChargeControlPrefPath(void) {
    return @"/var/mobile/Library/Preferences/com.chargecontrol.plist";
}

static inline NSMutableDictionary *ChargeControlReadMutablePrefs(void) {
    return [NSMutableDictionary dictionaryWithContentsOfFile:ChargeControlPrefPath()];
}

static inline NSDictionary *ChargeControlReadPrefs(void) {
    return ChargeControlReadMutablePrefs();
}

static inline BOOL ChargeControlWritePrefs(NSDictionary *prefs) {
    if (!prefs) return NO;
    return [prefs writeToFile:ChargeControlPrefPath() atomically:YES];
}

#endif
