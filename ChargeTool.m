#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <notify.h>
#import <signal.h>
#import <string.h>
#import <unistd.h>
#import "ChargeControlPaths.h"

// 限制充电到指定百分比核心：SmartBatteryAPI + 智能停充 + 停充自动禁流。
// 与「强制充电」(Tweak 注入 powerd) 互斥，请勿同开。
static BOOL gOwnsInhibit = NO;
static BOOL gOwnsInflowDisable = NO;
static BOOL gOwnershipPreferSmart = YES;
static int gNotifyToken = 0;

static BOOL BoolPreference(NSDictionary *prefs, NSString *key, BOOL fallback) {
    id value = prefs[key];
    return [value respondsToSelector:@selector(boolValue)] ? [value boolValue] : fallback;
}

static NSInteger IntegerPreference(NSDictionary *prefs, NSString *key, NSInteger fallback) {
    id value = prefs[key];
    return [value respondsToSelector:@selector(integerValue)] ? [value integerValue] : fallback;
}

static void LoadOwnership(void) {
    NSDictionary *prefs = ChargeControlReadPrefs() ?: @{};
    gOwnsInhibit = [prefs[@"__ccOwnsInhibit"] boolValue];
    gOwnsInflowDisable = [prefs[@"__ccOwnsInflowDisable"] boolValue];
    id source = prefs[@"__ccOwnershipPreferSmart"];
    gOwnershipPreferSmart = [source respondsToSelector:@selector(boolValue)] ? [source boolValue] : YES;
}

static void SaveOwnership(void) {
    NSMutableDictionary *prefs = [ChargeControlReadMutablePrefs() ?: [NSMutableDictionary dictionary] mutableCopy];
    if (gOwnsInhibit) prefs[@"__ccOwnsInhibit"] = @YES;
    else [prefs removeObjectForKey:@"__ccOwnsInhibit"];
    if (gOwnsInflowDisable) prefs[@"__ccOwnsInflowDisable"] = @YES;
    else [prefs removeObjectForKey:@"__ccOwnsInflowDisable"];
    if (gOwnsInhibit || gOwnsInflowDisable) prefs[@"__ccOwnershipPreferSmart"] = @(gOwnershipPreferSmart);
    else [prefs removeObjectForKey:@"__ccOwnershipPreferSmart"];
    ChargeControlWritePrefs(prefs);
}

static io_service_t BatteryService(BOOL preferSmart) {
    io_service_t service = IO_OBJECT_NULL;
    if (preferSmart)
        service = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("AppleSmartBattery"));
    if (service == IO_OBJECT_NULL)
        service = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("IOPMPowerSource"));
    if (service == IO_OBJECT_NULL && !preferSmart)
        service = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("AppleSmartBattery"));
    return service;
}

static NSDictionary *BatteryProperties(io_service_t service) {
    if (service == IO_OBJECT_NULL) return nil;
    CFMutableDictionaryRef raw = NULL;
    if (IORegistryEntryCreateCFProperties(service, &raw, kCFAllocatorDefault, 0) != KERN_SUCCESS || !raw) return nil;
    return CFBridgingRelease(raw);
}

static BOOL AdapterConnected(NSDictionary *properties) {
    NSDictionary *adapter = [properties[@"AdapterDetails"] isKindOfClass:[NSDictionary class]] ? properties[@"AdapterDetails"] : nil;
    NSString *description = [adapter[@"Description"] isKindOfClass:[NSString class]] ? adapter[@"Description"] : nil;
    if (adapter.count && ![description isEqualToString:@"batt"]) return YES;
    return [properties[@"ExternalConnected"] boolValue] || [properties[@"ExternalChargeCapable"] boolValue];
}

static BOOL SetProperties(BOOL preferSmart, NSDictionary *properties) {
    io_service_t service = BatteryService(preferSmart);
    if (service == IO_OBJECT_NULL) return NO;
    kern_return_t result = IORegistryEntrySetCFProperties(service, (__bridge CFTypeRef)properties);
    IOObjectRelease(service);
    return result == KERN_SUCCESS;
}

static BOOL SetChargeInhibited(BOOL preferSmart, BOOL inhibited) {
    BOOL ok = SetProperties(preferSmart, @{@"PredictiveChargingInhibit":@(inhibited)});
    if (ok) { if (inhibited) gOwnershipPreferSmart = preferSmart; gOwnsInhibit = inhibited; SaveOwnership(); }
    return ok;
}

static BOOL SetInflowEnabled(BOOL preferSmart, BOOL enabled) {
    BOOL ok = SetProperties(preferSmart, @{@"ExternalConnected":@(enabled)});
    if (ok) { if (!enabled) gOwnershipPreferSmart = preferSmart; gOwnsInflowDisable = !enabled; SaveOwnership(); }
    return ok;
}

static void RestoreOwnedState(void) {
    BOOL preferSmart = gOwnershipPreferSmart;
    if (gOwnsInflowDisable) SetInflowEnabled(preferSmart, YES);
    if (gOwnsInhibit) SetChargeInhibited(preferSmart, NO);
}

static void EvaluateBattery(void) {
    NSDictionary *prefs = ChargeControlReadPrefs() ?: @{};
    BOOL enabled = BoolPreference(prefs, @"limitChargeEnabled", NO);
    BOOL preferSmart = BoolPreference(prefs, @"limitChargeUseSmartBatteryAPI", YES);
    BOOL disableInflow = BoolPreference(prefs, @"limitChargeDisableInflow", NO);
    if ((gOwnsInhibit || gOwnsInflowDisable) && preferSmart != gOwnershipPreferSmart) RestoreOwnedState();
    if (!enabled) { RestoreOwnedState(); return; }

    io_service_t service = BatteryService(preferSmart);
    NSDictionary *properties = BatteryProperties(service);
    if (!properties) { if (service != IO_OBJECT_NULL) IOObjectRelease(service); return; }
    NSInteger stopLevel = MAX(70, MIN(100, IntegerPreference(prefs, @"limitChargeLevel", 90)));
    NSInteger resumeLevel = MAX(5, stopLevel - 5);
    NSInteger capacity = IntegerPreference(properties, @"CurrentCapacity", -1);
    BOOL connected = AdapterConnected(properties);
    IOObjectRelease(service);

    if (capacity < 0 || !connected) return;
    if (capacity >= stopLevel) {
        if (!gOwnsInhibit) SetChargeInhibited(preferSmart, YES);
        if (disableInflow && !gOwnsInflowDisable) SetInflowEnabled(preferSmart, NO);
        if (!disableInflow && gOwnsInflowDisable) SetInflowEnabled(preferSmart, YES);
    } else if (capacity <= resumeLevel) {
        // 先恢复输入，再恢复充电。
        if (gOwnsInflowDisable) SetInflowEnabled(preferSmart, YES);
        if (gOwnsInhibit) SetChargeInhibited(preferSmart, NO);
    }
}

static BOOL ResetCharging(void) {
    RestoreOwnedState();
    return !gOwnsInhibit && !gOwnsInflowDisable;
}

static void SignalHandler(int signalNumber) {
    (void)signalNumber;
    ResetCharging();
    _exit(0);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        LoadOwnership();
        if (argc > 1 && strcmp(argv[1], "reset") == 0) return ResetCharging() ? 0 : 2;
        signal(SIGTERM, SignalHandler); signal(SIGINT, SignalHandler); signal(SIGHUP, SignalHandler);
        notify_register_dispatch(kChargeControlSettingsChangedNotifC, &gNotifyToken, dispatch_get_main_queue(), ^(int token) {
            (void)token; @autoreleasepool { EvaluateBattery(); }
        });
        [NSTimer scheduledTimerWithTimeInterval:15.0 repeats:YES block:^(__unused NSTimer *timer) {
            @autoreleasepool { EvaluateBattery(); }
        }];
        EvaluateBattery();
        [[NSRunLoop mainRunLoop] run];
    }
    return 0;
}
