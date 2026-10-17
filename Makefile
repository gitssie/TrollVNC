export PACKAGE_VERSION := 4.0-2
# Device releases target Dopamine 3's standard rootless bootstrap only.
ifeq ($(THEOS_DEVICE_SIMULATOR),)
THEOS_PACKAGE_SCHEME ?= rootless
ifneq ($(THEOS_PACKAGE_SCHEME),rootless)
$(error Only Dopamine 3 rootless packages are supported)
endif
ifneq ($(THEBOOTSTRAP),)
$(error Standalone/bootstrap packages are no longer supported)
endif
endif
export THEOS_PACKAGE_SCHEME

ifeq ($(THEOS_DEVICE_SIMULATOR),1)
ARCHS := arm64 x86_64
TARGET := simulator:clang:latest:15.0
IPHONE_SIMULATOR_ROOT := $(shell devkit/sim-root.sh)
else
ARCHS := arm64
TARGET := iphone:clang:16.5:15.0
endif

GO_EASY_ON_ME := 1

include $(THEOS)/makefiles/common.mk

TOOL_NAME += trollvncserver

ifeq ($(THEOS_DEVICE_SIMULATOR),)
include vendor/karing/native/native.mk
endif

trollvncserver_USE_MODULES := 0

trollvncserver_FILES += src/trollvncserver.mm
trollvncserver_FILES += src/TVNCWireGuardConfig.m
APPLE_MODULE_ROOT := vendor/apple
include $(APPLE_MODULE_ROOT)/apple.mk
trollvncserver_FILES += $(APPLE_MODULE_FILES)
trollvncserver_CFLAGS += $(APPLE_MODULE_CFLAGS)
APP_STATE_ROOT := vendor/app-state
include $(APP_STATE_ROOT)/app-state.mk
trollvncserver_FILES += $(APP_STATE_FILES) src/TVNCAppStateService.mm src/TVNCAppStateStream.mm
trollvncserver_CFLAGS += $(APP_STATE_CFLAGS)

ONETUN_ROOT := wgbridge-onetun
include $(ONETUN_ROOT)/onetun.mk
trollvncserver_CFLAGS += -I$(ONETUN_ROOT)/include

trollvncserver_FILES += src/TVNCHTTPServer.mm src/TVNCKaringSettings.mm
trollvncserver_CFLAGS += -Icontrol-http/include
ifeq ($(THEOS_DEVICE_SIMULATOR),1)
trollvncserver_OBJ_FILES += control-http/build/libtvnc_control_http-sim.a
else
trollvncserver_OBJ_FILES += control-http/build/libtvnc_control_http.a
endif
trollvncserver_FRAMEWORKS += SystemConfiguration
trollvncserver_FRAMEWORKS += Security LocalAuthentication
ifeq ($(THEOS_DEVICE_SIMULATOR),)
trollvncserver_CFLAGS += -DTVAS_DOPAMINE3=1 -DTVAPPLE_DOPAMINE3=1
TOOL_NAME += app-state-worker app-state-idfv-worker
TOOL_NAME += cazer-apple-searchparty-recover
cazer-apple-searchparty-recover_FILES := $(APPLE_MODULE_ROOT)/src/icloud/TVAppleSearchPartyRecovery.c
cazer-apple-searchparty-recover_CFLAGS := -Wall -Wextra -Werror
cazer-apple-searchparty-recover_INSTALL_PATH := /usr/bin
cazer-apple-searchparty-recover_CODESIGN_FLAGS := -S$(APPLE_MODULE_ROOT)/recovery.entitlements
app-state-worker_FILES := $(APP_STATE_WORKER_FILES)
app-state-worker_CFLAGS := $(APP_STATE_CFLAGS) -DTVAS_DOPAMINE3=1 -Wall -Wextra -Werror
app-state-worker_FRAMEWORKS := Foundation Security LocalAuthentication
app-state-worker_LIBRARIES := sqlite3
app-state-worker_INSTALL_PATH := /usr/libexec/trollvnc
app-state-worker_CODESIGN_FLAGS := -S$(APP_STATE_ROOT)/product/worker.entitlements
app-state-idfv-worker_FILES := $(APP_STATE_ROOT)/cli/VendorWorker.m
app-state-idfv-worker_CFLAGS := -fobjc-arc -Wall -Wextra -Werror
app-state-idfv-worker_FRAMEWORKS := Foundation
app-state-idfv-worker_INSTALL_PATH := /usr/libexec/trollvnc
app-state-idfv-worker_CODESIGN_FLAGS := -S$(APP_STATE_ROOT)/product/idfv.entitlements
endif
trollvncserver_FILES += src/TVNCAppleService.mm
trollvncserver_FILES += src/TVNCZXTouchService.mm
trollvncserver_FILES += vendor/zxtouch/src/ZXTouchProtocol.cpp
trollvncserver_FILES += vendor/zxtouch/src/ZXTouchImage.cpp
trollvncserver_FILES += vendor/zxtouch/src/ZXTouchProcessRunner.mm
trollvncserver_FILES += vendor/zxtouch/src/ZXTouchUIBridge.mm
trollvncserver_FILES += vendor/zxtouch/src/ZXTouchDeviceInfo.m
trollvncserver_FILES += vendor/zxtouch/src/ZXTouchControlAuth.m
trollvncserver_CFLAGS += -Ivendor/zxtouch/include
trollvncserver_FILES += src/FileManagement.c
trollvncserver_FILES += src/AppManagement.mm
trollvncserver_FILES += src/NotificationBridge.mm
trollvncserver_FILES += src/ScreenUnlock.mm
trollvncserver_FILES += src/PhotoLibrary.m
trollvncserver_FILES += src/BulletinManager.mm
trollvncserver_FILES += src/ClipboardManager.mm
trollvncserver_FILES += src/ScreenCapturer.mm
trollvncserver_FILES += src/STHIDEventGenerator.mm
trollvncserver_FILES += src/OhMyJetsam.mm

trollvncserver_CFLAGS += -fobjc-arc
trollvncserver_CFLAGS += -Wno-unknown-warning-option
trollvncserver_CFLAGS += -Wno-unused-but-set-variable
ifeq ($(THEOS_DEVICE_SIMULATOR),)
trollvncserver_CFLAGS += -march=armv8-a+crc
endif
trollvncserver_CCFLAGS += -std=c++20

trollvncserver_CFLAGS += -DPACKAGE_VERSION=\"$(PACKAGE_VERSION)\"
ifeq ($(THEOS_PACKAGE_SCHEME),)
trollvncserver_CFLAGS += -DTHEOS_PACKAGE_SCHEME=\"legacy\"
else
trollvncserver_CFLAGS += -DTHEOS_PACKAGE_SCHEME=\"$(THEOS_PACKAGE_SCHEME)\"
endif

ifeq ($(THEBOOTSTRAP),1)
trollvncserver_CFLAGS += -DTHEBOOTSTRAP=1
endif

trollvncserver_CFLAGS += -Iinclude-spi
ifeq ($(THEOS_DEVICE_SIMULATOR),1)
trollvncserver_CFLAGS += -Iinclude-simulator
trollvncserver_LDFLAGS += -Llib-simulator
trollvncserver_LDFLAGS += -FPrivateFrameworks
else
trollvncserver_CFLAGS += -Iinclude
trollvncserver_LDFLAGS += -Llib
endif

ifeq ($(THEOS_DEVICE_SIMULATOR),1)
trollvncserver_LIBRARIES += vncserver
trollvncserver_LIBRARIES += z
else
trollvncserver_LIBRARIES += crypto
trollvncserver_LIBRARIES += lzo2
trollvncserver_LIBRARIES += turbojpeg
trollvncserver_LIBRARIES += png18
trollvncserver_LIBRARIES += sasl2
trollvncserver_LIBRARIES += ssl
trollvncserver_LIBRARIES += vncserver
trollvncserver_LIBRARIES += z
endif

trollvncserver_FRAMEWORKS += Accelerate
trollvncserver_FRAMEWORKS += Vision
trollvncserver_FRAMEWORKS += CoreImage
trollvncserver_FRAMEWORKS += CoreGraphics
trollvncserver_FRAMEWORKS += CoreMedia
trollvncserver_FRAMEWORKS += CoreVideo
trollvncserver_FRAMEWORKS += Foundation
trollvncserver_FRAMEWORKS += Photos
trollvncserver_FRAMEWORKS += IOKit
trollvncserver_FRAMEWORKS += IOSurface
trollvncserver_FRAMEWORKS += QuartzCore
trollvncserver_FRAMEWORKS += UIKit
trollvncserver_FRAMEWORKS += UserNotifications

trollvncserver_PRIVATE_FRAMEWORKS += FrontBoardServices

ifeq ($(THEOS_DEVICE_SIMULATOR),)
trollvncserver_PRIVATE_FRAMEWORKS += Preferences
endif

ifeq ($(THEOS_DEVICE_SIMULATOR),1)
trollvncserver_CODESIGN_FLAGS += -f -s - --entitlements src/trollvncserver-simulator.entitlements
else
trollvncserver_CODESIGN_FLAGS += -Ssrc/trollvncserver.entitlements
endif

ifeq ($(THEBOOTSTRAP),1)
TOOL_NAME += trollvncmanager

trollvncmanager_FILES += src/trollvncmanager.mm
trollvncmanager_FILES += src/TRWatchDog.mm
trollvncmanager_FILES += src/TaskProcess+ObjC.swift
trollvncmanager_FILES += src/OhMyJetsam.mm

trollvncmanager_CFLAGS += -fobjc-arc
trollvncmanager_CFLAGS += -Iinclude-spi

trollvncmanager_FRAMEWORKS += Foundation
ifeq ($(THEOS_DEVICE_SIMULATOR),1)
trollvncmanager_CODESIGN_FLAGS += -f -s - --entitlements src/trollvncmanager.entitlements
else
trollvncmanager_CODESIGN_FLAGS += -Ssrc/trollvncmanager.entitlements
endif
endif

include $(THEOS_MAKE_PATH)/tool.mk

ifeq ($(THEBOOTSTRAP)$(THEOS_DEVICE_SIMULATOR),)
SUBPROJECTS += zxtouch-adapter
SUBPROJECTS += notification-adapter
endif

SUBPROJECTS += prefs/TrollVNCPrefs
SUBPROJECTS += prefs/CCTrollVNC

ifeq ($(THEBOOTSTRAP),1)
SUBPROJECTS += app/TrollVNC
endif

include $(THEOS_MAKE_PATH)/aggregate.mk

before-all::
ifeq ($(THEOS_DEVICE_SIMULATOR),1)
	@sh control-http/build-ios.sh --simulator
else
	@sh control-http/build-ios.sh
endif

export THEOS_PACKAGE_SCHEME
export THEOS_STAGING_DIR
before-package::
	@devkit/before-package.sh

export THEOS_STAGING_DIR
after-package::
	@devkit/after-package.sh
