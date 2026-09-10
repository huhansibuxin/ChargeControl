//
//  ChargeControl Tweak.xm — 强制满血快充（解除 80% 涓流 / 无视发热）
//
//  剥离自 CPUthermal MitigationHook：仅保留充电相关逻辑，删除全部温度屏蔽代码。
//  注入目标：powerd + thermalmonitord（见 ChargeControl.plist）。
//  机制：hook IOKit 电池注册表读写 + 2s 周期兜底，清掉 powerd/BMS 落的热停充/原因码/
//        80% 优化(涓流)标签，并把被热控压低的充电电流上限提回设备原生满量。
//
#import <Foundation/Foundation.h>
#import <notify.h>
#import <mach/mach.h>
#import <dlfcn.h>
#import <substrate.h>
#import <CoreFoundation/CoreFoundation.h>
#import <IOKit/IOKitLib.h>
#import "ChargeControlPaths.h"
#include <stdio.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <sys/time.h>

static const int SafeCurrentMA = 5000;
static const int PeriodicSec   = 2;

static kern_return_t (*orig_SetCFProp)(io_registry_entry_t, CFStringRef, CFTypeRef) = NULL;
static kern_return_t (*orig_SetCFProps)(io_registry_entry_t, CFTypeRef) = NULL;
static CFTypeRef      (*orig_SingleProp)(io_registry_entry_t, CFStringRef, CFAllocatorRef, uint32_t) = NULL;
static kern_return_t (*orig_MultiProps)(io_registry_entry_t, CFMutableDictionaryRef *, CFAllocatorRef, uint32_t) = NULL;

static NSArray<NSString *> *kPauseKeys;
static NSArray<NSString *> *kReasonKeys;
static NSArray<NSString *> *kLimitKeys;
static NSArray<NSString *> *kOptimKeys;   // 80% 优化充电/涓流停 相关布尔 → 清 NO
static BOOL gPowerd = NO;
static uint64_t gLastBreakNS = 0;
static dispatch_source_t gPeriodicTimer = nil;

#pragma mark - 轻量诊断日志（验证 tweak 是否真的挂在 powerd/thermal 内运行）
static NSString *diagLogPath(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = @"/var/mobile/ChargeControl";
    if (![fm fileExistsAtPath:dir]) [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return [dir stringByAppendingPathComponent:@"force.log"];
}
static void logDiag(NSString *fmt, ...) {
    NSString *path = diagLogPath();
    int fd = open(path.fileSystemRepresentation, O_WRONLY|O_CREAT|O_APPEND, 0644);
    if (fd<0) return;
    va_list ap; va_start(ap, fmt);
    NSString *body = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    struct timeval tv; gettimeofday(&tv,NULL);
    NSString *proc = [[NSProcessInfo processInfo] processName];
    NSString *line = [NSString stringWithFormat:@"[%lld.%03d][%@] %@\n",(long long)tv.tv_sec,(int)(tv.tv_usec/1000),proc,body];
    const char *cs = line.UTF8String;
    if (cs) (void)write(fd,cs,strlen(cs));
    close(fd);
}

static void initKeySets(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        kPauseKeys = @[ @"ChargingPaused", @"ChargeInhibit", @"ChargeBlocked",
                        @"BatteryChargingInterrupted", @"BatteryChargingInterruptedCount",
                        @"ChargingCriticalTemperature", @"ForceDisableCharge" ];
        kReasonKeys = @[ @"NotChargingReason", @"BatteryNotChargingReason",
                         @"ChargeStateReason", @"ChargingLimitReasonCode" ];
        // 仅“控制上限”字段；ChargingCurrent 是只读状态，绝不当作控制值回写。
        kLimitKeys = @[ @"ChargeCurrentLimit", @"ExternalChargeCurrentLimit",
                        @"MaxChargeCurrent", @"NominalChargeCurrent",
                        @"AppleSmartBatteryMaxCurrent", @"ConfiguredChargeCurrent" ];
        kOptimKeys = @[ @"PredictiveChargingInhibit", @"SmartChargeState", @"OptimizedChargingValue" ];
    });
}

#pragma mark - 开关（带 2s 刷新节流，避免每次注册表读都读 plist）
static BOOL gForceCache = NO;
static uint64_t gForceTS = 0;
static BOOL forceOn(void) {
    uint64_t now = dispatch_time(DISPATCH_TIME_NOW,0);
    if (now - gForceTS < (uint64_t)(2.0*NSEC_PER_SEC)) return gForceCache;
    gForceTS = now;
    NSDictionary *d = ChargeControlReadPrefs();
    id f = [d objectForKey:@"forceChargeEnabled"];
    gForceCache = [f respondsToSelector:@selector(boolValue)] ? [f boolValue] : NO;
    return gForceCache;
}
static BOOL protectOn(void) { return forceOn(); }

static BOOL keyHit(NSString *k, NSArray<NSString *> *ks) {
    for (NSString *c in ks)
        if ([k rangeOfString:c options:NSCaseInsensitiveSearch|NSLiteralSearch].location != NSNotFound) return YES;
    return NO;
}

#pragma mark - 读边界（powerd 与 thermalmonitord 都可挂）
static CFTypeRef hk_Single(io_registry_entry_t e, CFStringRef key, CFAllocatorRef a, uint32_t o){
    if (key && protectOn()){
        NSString *k=(__bridge NSString*)key;
        if (keyHit(k,kReasonKeys)){ int z=0; return CFNumberCreate(kCFAllocatorDefault,kCFNumberIntType,&z); }
        if (keyHit(k,kPauseKeys)) return (CFTypeRef)CFRetain(kCFBooleanFalse);
    }
    return orig_SingleProp?orig_SingleProp(e,key,a,o):NULL;
}

#pragma mark - 递归 CF 清洗（原因/暂停/优化）
static CFTypeRef sanitizeNode(CFTypeRef node) {
    if (!node) return NULL;
    CFTypeID t = CFGetTypeID(node);
    if (t == CFDictionaryGetTypeID()) {
        CFDictionaryRef d = (CFDictionaryRef)node;
        CFIndex n = CFDictionaryGetCount(d);
        CFMutableDictionaryRef out = CFDictionaryCreateMutable(NULL, n, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        CFStringRef *keys = (CFStringRef *)calloc(n?n:1,sizeof(CFStringRef));
        CFTypeRef   *vals = (CFTypeRef *)calloc(n?n:1,sizeof(CFTypeRef));
        CFDictionaryGetKeysAndValues(d,(const void**)keys,(const void**)vals);
        for (CFIndex i=0;i<n;i++){
            NSString *kn=(__bridge NSString*)keys[i];
            BOOL isReason= keyHit(kn,kReasonKeys);
            BOOL isPause = keyHit(kn,kPauseKeys);
            BOOL isOptim = keyHit(kn,kOptimKeys);
            if (isReason && vals[i] && CFGetTypeID(vals[i])==CFNumberGetTypeID()){
                int zz=0; CFNumberRef z=CFNumberCreate(NULL,kCFNumberIntType,&zz);
                CFDictionarySetValue(out,keys[i],z); CFRelease(z); continue;
            }
            if ((isPause||isOptim) && vals[i] && CFGetTypeID(vals[i])==CFBooleanGetTypeID()){
                CFDictionarySetValue(out,keys[i],kCFBooleanFalse); continue;
            }
            CFTypeRef sub=sanitizeNode(vals[i]);
            if (sub){ CFDictionarySetValue(out,keys[i],sub); CFRelease(sub); }
            else CFDictionarySetValue(out,keys[i],vals[i]);
        }
        free(keys); free(vals);
        return out;
    }
    if (t == CFArrayGetTypeID()){
        CFArrayRef a=(CFArrayRef)node; CFIndex n=CFArrayGetCount(a);
        CFMutableArrayRef out=CFArrayCreateMutable(NULL,n,&kCFTypeArrayCallBacks);
        for (CFIndex i=0;i<n;i++){ CFTypeRef it=CFArrayGetValueAtIndex(a,i); CFTypeRef sub=sanitizeNode(it);
            if (sub){ CFArrayAppendValue(out,sub); CFRelease(sub);} else CFArrayAppendValue(out,it);}
        return out;
    }
    return NULL;
}

static kern_return_t hk_Multi(io_registry_entry_t e, CFMutableDictionaryRef *p, CFAllocatorRef a, uint32_t o){
    if (!orig_MultiProps) return p && !*p ? KERN_FAILURE : KERN_SUCCESS;
    kern_return_t r = orig_MultiProps(e,p,a,o);
    if (r==KERN_SUCCESS && p && *p && CFGetTypeID(*p)==CFDictionaryGetTypeID() && protectOn()){
        CFTypeRef clean=sanitizeNode(*p);
        if (clean){ CFRelease(*p); *p=(CFMutableDictionaryRef)clean; }
    }
    return r;
}

#pragma mark - 写边界（仅 powerd）清停充/原因 + 满血电流
static int readMax(io_registry_entry_t e){
    CFMutableDictionaryRef pr=NULL;
    if (orig_MultiProps && orig_MultiProps(e,&pr,kCFAllocatorDefault,0)==KERN_SUCCESS && pr){
        int mx=0;
        for (NSString *k in kLimitKeys){ CFTypeRef v=CFDictionaryGetValue(pr,(__bridge CFStringRef)k);
            if (v&&CFGetTypeID(v)==CFNumberGetTypeID()){int t=0;CFNumberGetValue((CFNumberRef)v,kCFNumberIntType,&t);if(t>mx)mx=t;}}
        CFTypeRef cd=CFDictionaryGetValue(pr,CFSTR("ChargerData"));
        if (cd&&CFGetTypeID(cd)==CFDictionaryGetTypeID()) for (NSString*k in kLimitKeys) {CFTypeRef v=CFDictionaryGetValue((CFDictionaryRef)cd,(__bridge CFStringRef)k);
            if(v&&CFGetTypeID(v)==CFNumberGetTypeID()){int t=0;CFNumberGetValue((CFNumberRef)v,kCFNumberIntType,&t);if(t>mx)mx=t;}}
        CFRelease(pr);
        if (mx>0) return mx;
    }
    return 0;
}
static kern_return_t hk_Set(io_registry_entry_t e,CFStringRef key,CFTypeRef val){
    if (!orig_SetCFProp) return KERN_FAILURE;
    if (!key) return orig_SetCFProp(e,key,val);
    // 门控：仅当“强制充电”开启才干预；否则完全放行，避免未开启时无条件改写。
    if (!protectOn()) return orig_SetCFProp(e,key,val);

    NSString *p=(__bridge NSString*)key;
    if (keyHit(p,kPauseKeys)) return orig_SetCFProp(e,key,kCFBooleanFalse);
    if (CFGetTypeID(val)==CFNumberGetTypeID() && keyHit(p,kReasonKeys)){
        int z=0;CFNumberRef n=CFNumberCreate(NULL,kCFNumberIntType,&z);
        kern_return_t r=orig_SetCFProp(e,key,n);CFRelease(n);return r;
    }
    if (CFGetTypeID(val)==CFNumberGetTypeID() && keyHit(p,kLimitKeys)){
        int v=0;CFNumberGetValue((CFNumberRef)val,kCFNumberIntType,&v);
        int m=readMax(e);
        if (m<=0) m=SafeCurrentMA;
        // 热控把上限降到 0/负 → 恢复原生量；或满血快充开启且被压到明显低于原生(<2/3) → 提回满量
        BOOL tooLowFast = (v>0 && m>0 && forceOn() && v < (m*2/3));
        if (v<=0 || tooLowFast){
            CFNumberRef n=CFNumberCreate(NULL,kCFNumberIntType,&m);
            kern_return_t r=orig_SetCFProp(e,key,n);CFRelease(n);return r;
        }
    }
    return orig_SetCFProp?orig_SetCFProp(e,key,val):KERN_FAILURE;
}

// 批量写路径：powerd/驱动可能一次写入 ChargerData{NotChargingReason=256,...}，
// 单项 SetCFProperty 看不到嵌套 key；递归只清暂停/原因/优化位，保留温度历史与真实电流。
static id cleanWriteObject(id obj){
    if ([obj isKindOfClass:[NSDictionary class]]){
        NSMutableDictionary *out=[NSMutableDictionary dictionaryWithCapacity:[obj count]];
        for (id key in obj){
            id val=[obj objectForKey:key];
            NSString *ks=[key isKindOfClass:[NSString class]]?key:nil;
            if (ks && keyHit(ks,kReasonKeys) && [val respondsToSelector:@selector(intValue)]) out[key]=@0;
            else if (ks && (keyHit(ks,kPauseKeys)||keyHit(ks,kOptimKeys)) && [val respondsToSelector:@selector(boolValue)]) out[key]=@NO;
            else out[key]=cleanWriteObject(val) ?: val;
        }
        return out;
    }
    if ([obj isKindOfClass:[NSArray class]]){
        NSMutableArray *out=[NSMutableArray arrayWithCapacity:[obj count]];
        for (id v in obj) [out addObject:cleanWriteObject(v) ?: v];
        return out;
    }
    return nil;
}
static kern_return_t hk_SetProps(io_registry_entry_t e,CFTypeRef props){
    if (!orig_SetCFProps) return KERN_FAILURE;
    if (!props || !protectOn() || CFGetTypeID(props)!=CFDictionaryGetTypeID()) return orig_SetCFProps(e,props);
    id clean=cleanWriteObject((__bridge id)props);
    if (!clean) return orig_SetCFProps(e,props);
    return orig_SetCFProps(e,(__bridge CFTypeRef)clean);
}

#pragma mark - 周期兜底（清已落地的热停充/优化标签 + 解 80% 截断）
static void periodicCleanup(void){
    if (!protectOn()) return;
    if (!orig_MultiProps || !orig_SetCFProp) return;
    mach_port_t mp=0; if (IOMasterPort(MACH_PORT_NULL,&mp)!=KERN_SUCCESS) return;
    CFMutableDictionaryRef m=IOServiceMatching("IOPMPowerSource");
    if (!m) return;
    io_service_t s=IOServiceGetMatchingService(mp,m);
    if (!s) return;
    CFMutableDictionaryRef cur=NULL;
    if (orig_MultiProps(s,&cur,kCFAllocatorDefault,0)==KERN_SUCCESS && cur){
        NSDictionary *sn=(__bridge NSDictionary*)cur;

        NSNumber *cc=[sn objectForKey:@"CurrentCapacity"];
        int pct = cc? [cc intValue] : 101;
        NSNumber *vb=[sn objectForKey:@"AppleRawBatteryVoltage"];
        if (!vb) vb=[sn objectForKey:@"Voltage"];
        int vmV = vb? [vb intValue] : 0;
        NSDictionary *cd=[sn objectForKey:@"ChargerData"];
        if (![cd isKindOfClass:[NSDictionary class]]) cd=nil;
        // VacVoltageLimit 才是本机真实 CV 上限；ChargingVoltage 只是当前目标/状态。
        double targetMV = 0; NSNumber *cvm=[cd objectForKey:@"VacVoltageLimit"];
        if (!cvm) cvm=[cd objectForKey:@"ChargeVoltageLimit"];
        if (!cvm) cvm=[sn objectForKey:@"ChargeVoltageLimit"];
        if (cvm) targetMV=[cvm doubleValue];
        if (targetMV<=0) targetMV=4360.0;
        int reasonSeen=0, pauseSeen=0;
        for (NSDictionary *mpd in @[sn, cd ?: @{}])
            for (NSString *kp in kReasonKeys){ NSNumber *nr=[mpd objectForKey:kp]; if (nr && [nr intValue]!=0) reasonSeen=1; }
        for (NSString *kp in kPauseKeys){ NSNumber *pb=[sn objectForKey:kp]; if (pb && [pb boolValue]) pauseSeen=1; }
        BOOL fully = [[sn objectForKey:@"FullyCharged"] boolValue];
        BOOL optim = NO;
        for (NSString *kp in kOptimKeys){
            id o=[sn objectForKey:kp];
            if ([o isKindOfClass:[NSNumber class]] && [o boolValue]) optim=YES;
        }

        // 一、清停充布尔 / 原因码 / 优化(涓流)位
        for (NSString *k in kPauseKeys){
            CFTypeRef v=CFDictionaryGetValue(cur,(__bridge CFStringRef)k);
            if (v && CFGetTypeID(v)==CFBooleanGetTypeID() && CFBooleanGetValue((CFBooleanRef)v))
                orig_SetCFProp(s,(__bridge CFStringRef)k,kCFBooleanFalse);
        }
        for (NSString *k in kReasonKeys){
            CFTypeRef v=CFDictionaryGetValue(cur,(__bridge CFStringRef)k);
            if (v && CFGetTypeID(v)==CFNumberGetTypeID()){
                int q=0; CFNumberGetValue((CFNumberRef)v,kCFNumberIntType,&q);
                if (q!=0){ int zz=0; CFNumberRef zz2=CFNumberCreate(NULL,kCFNumberIntType,&zz);
                           if (zz2){ orig_SetCFProp(s,(__bridge CFStringRef)k,zz2); CFRelease(zz2);} }
            }
        }
        for (NSString *k in kOptimKeys){
            CFTypeRef v=CFDictionaryGetValue(cur,(__bridge CFStringRef)k);
            if (v && CFGetTypeID(v)==CFBooleanGetTypeID() && CFBooleanGetValue((CFBooleanRef)v))
                orig_SetCFProp(s,(__bridge CFStringRef)k,kCFBooleanFalse);
        }
        if (cd && reasonSeen){
            NSDictionary *cleanCD=cleanWriteObject(cd);
            if (cleanCD) orig_SetCFProp(s,CFSTR("ChargerData"),(__bridge CFTypeRef)cleanCD);
        }

        // 二、解除 iOS 80+% 涓流提前截断（事件型，带 2s 节流；不写 External/IsCharging/原始电流）
        if (pct<100 && vmV>0 && ((double)vmV) < targetMV-90.0){
            if (fully || reasonSeen || optim || pauseSeen){
                if (fully) { orig_SetCFProp(s,CFSTR("FullyCharged"),kCFBooleanFalse); }
                uint64_t nowNS = dispatch_time(DISPATCH_TIME_NOW,0);
                if (gLastBreakNS==0 || (nowNS-gLastBreakNS) > (uint64_t)(2.0*NSEC_PER_SEC)){
                    gLastBreakNS=nowNS;
                    logDiag(@"break80limit: pct=%d v=%dmV cv-tgt=%.0fmV",pct,vmV,targetMV);
                }
            }
        }
        CFRelease(cur);
    }
    IOObjectRelease(s);
}

#pragma mark - ctor
%ctor {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *proc=[NSProcessInfo processInfo].processName;
        if ([proc isEqualToString:@"powerd"]) gPowerd=YES;
        else if (![proc isEqualToString:@"thermalmonitord"]) return;
        initKeySets();
        logDiag(@"boot proc=%@ pid=%d", proc, (int)getpid());
        void *k=dlopen("/System/Library/Frameworks/IOKit.framework/IOKit",RTLD_NOW);
        if (!k) return;
        void *wr=dlsym(k,"IORegistryEntrySetCFProperty");
        void *wrs=dlsym(k,"IORegistryEntrySetCFProperties");
        void *s1=dlsym(k,"IORegistryEntryCreateCFProperty");
        void *mn=dlsym(k,"IORegistryEntryCreateCFProperties");
        if (!mn) return;
        // 读：两进程都挂（递归清原因/暂停/优化）
        MSHookFunction(mn,(void*)hk_Multi,(void**)&orig_MultiProps);
        if (s1) MSHookFunction(s1,(void*)hk_Single,(void**)&orig_SingleProp);
        // 写停充/原因/电流上限重放：仅在 powerd（thermalmonitord 由本 tweak 同体处理）
        if (wr && gPowerd) MSHookFunction(wr,(void*)hk_Set,(void**)&orig_SetCFProp);
        if (wrs && gPowerd) MSHookFunction(wrs,(void*)hk_SetProps,(void**)&orig_SetCFProps);

        if ((gPowerd || gThermal) && !gPeriodicTimer){
            gPeriodicTimer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,
                        dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND,0));
            dispatch_source_set_timer(gPeriodicTimer,dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),
                        PeriodicSec*NSEC_PER_SEC,0.5*NSEC_PER_SEC);
            dispatch_source_set_event_handler(gPeriodicTimer,^{ periodicCleanup(); });
            dispatch_resume(gPeriodicTimer);
        }
    });
}
