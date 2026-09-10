export THEOS ?= /var/mobile/theos
export PATH := $(THEOS)/bin:$(PATH)
FINALPACKAGE = 1
export TARGET = iphone:clang:16.5:15.0
# scheme 由 CI/环境变量决定（rootless 默认，roothide 构建时 CI 传 roothide）；
# 必须用 ?= 条件赋值——make 里普通赋值会覆盖环境变量，roothide job 会被打回 rootless
THEOS_PACKAGE_SCHEME ?= rootless
export THEOS_PACKAGE_SCHEME
include $(THEOS)/makefiles/common.mk
# 不配置 INSTALL_TARGET_PROCESSES；安装/升级由 postinst 单独重启 powerd / thermalmonitord。
export ARCHS = arm64 arm64e

# ========== 双方案构建 ==========
# roothide 由 roothide 官方 theos 自动处理路径前缀，无需额外的 -lroothide 链接
# （与 AirPodsVolume 黄金模板一致：仅靠 THEOS_PACKAGE_SCHEME 区分）

# ---------- 1) 强制充电：注入 powerd + thermalmonitord 的 tweak ----------
TWEAK_NAME = ChargeControl
ChargeControl_FILES = Tweak.xm
ChargeControl_CFLAGS = -fobjc-arc -Iinclude -Wno-deprecated-declarations -fvisibility=hidden
ChargeControl_FRAMEWORKS = Foundation CoreFoundation IOKit
ChargeControl_LIBRARIES = substrate

# ---------- 2) 限制充电：root LaunchDaemon 后台工具 ----------
TOOL_NAME = ChargeControlTool
ChargeControlTool_FILES = ChargeTool.m
ChargeControlTool_CFLAGS = -fobjc-arc -Iinclude -Wno-deprecated-declarations
ChargeControlTool_CODESIGN_FLAGS = -STools/ChargeTool.entitlements
ChargeControlTool_INSTALL_PATH = /usr/local/bin
ChargeControlTool_FRAMEWORKS = Foundation IOKit

# ---------- 3) 设置面板：两个独立开关 ----------
BUNDLE_NAME = ChargeControlSettings
ChargeControlSettings_FILES = Settings/FRootListController.m
ChargeControlSettings_INSTALL_PATH = /Library/PreferenceBundles
ChargeControlSettings_CFLAGS = -fobjc-arc -Iinclude
ChargeControlSettings_FRAMEWORKS = UIKit Foundation IOKit CoreFoundation
ChargeControlSettings_PRIVATE_FRAMEWORKS = Preferences

# roothide 由官方 theos 自动处理路径前缀（同 AirPodsVolume 模板），无需额外链接 flag
include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/tool.mk
include $(THEOS_MAKE_PATH)/bundle.mk

before-all::
	$(ECHO_NOTHING)mkdir -p "$(THEOS_PROJECT_DIR)/layout/DEBIAN"$(ECHO_END)
	$(ECHO_NOTHING)if [ "$(THEOS_PACKAGE_SCHEME)" = "rootless" ]; then sed 's|@JBROOT@|/var/jb|g' "$(THEOS_PROJECT_DIR)/scripts/postinst.in" > "$(THEOS_PROJECT_DIR)/layout/DEBIAN/postinst"; sed 's|@JBROOT@|/var/jb|g' "$(THEOS_PROJECT_DIR)/scripts/prerm.in" > "$(THEOS_PROJECT_DIR)/layout/DEBIAN/prerm"; else sed 's|@JBROOT@||g' "$(THEOS_PROJECT_DIR)/scripts/postinst.in" > "$(THEOS_PROJECT_DIR)/layout/DEBIAN/postinst"; sed 's|@JBROOT@||g' "$(THEOS_PROJECT_DIR)/scripts/prerm.in" > "$(THEOS_PROJECT_DIR)/layout/DEBIAN/prerm"; fi$(ECHO_END)
	$(ECHO_NOTHING)chmod 0755 "$(THEOS_PROJECT_DIR)/layout/DEBIAN/postinst" "$(THEOS_PROJECT_DIR)/layout/DEBIAN/prerm"$(ECHO_END)

before-package::
	$(ECHO_NOTHING)chmod 0755 "$(THEOS_PROJECT_DIR)/layout/DEBIAN/postinst" "$(THEOS_PROJECT_DIR)/layout/DEBIAN/prerm"$(ECHO_END)

after-stage::
	$(ECHO_NOTHING)python3 -c 'import plistlib; p="$(THEOS_STAGING_DIR)/Library/LaunchDaemons/com.chargecontrol.charge.plist"; d=plistlib.load(open(p,"rb")); d["ProgramArguments"][0]="/var/jb/usr/local/bin/ChargeControlTool" if "$(THEOS_PACKAGE_SCHEME)"=="rootless" else "/usr/local/bin/ChargeControlTool"; plistlib.dump(d,open(p,"wb"),fmt=plistlib.FMT_XML,sort_keys=False)'$(ECHO_END)

after-stage::
	$(ECHO_NOTHING)mkdir -p "$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences" "$(THEOS_STAGING_DIR)/usr/local/share/ChargeControl"$(ECHO_END)
	$(ECHO_NOTHING)cp Settings/entry.plist "$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/ChargeControlSettings.plist"$(ECHO_END)
	$(ECHO_NOTHING)cp Settings/Info.plist "$(THEOS_STAGING_DIR)/Library/PreferenceBundles/ChargeControlSettings.bundle/"$(ECHO_END)
	$(ECHO_NOTHING)cp Settings/Root.plist "$(THEOS_STAGING_DIR)/Library/PreferenceBundles/ChargeControlSettings.bundle/"$(ECHO_END)
