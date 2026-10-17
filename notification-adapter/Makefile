include $(THEOS)/makefiles/common.mk
TWEAK_NAME = TVNCNotificationAdapter
TVNCNotificationAdapter_FILES = Adapter.xm
TVNCNotificationAdapter_CFLAGS = -fobjc-arc
TVNCNotificationAdapter_FRAMEWORKS = Foundation
TVNCNotificationAdapter_USE_MODULES = 0
ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
TVNCNotificationAdapter_CFLAGS += -DTVAS_ROOTHIDE=1
TVNCNotificationAdapter_LDFLAGS += -lroothide
endif
include $(THEOS_MAKE_PATH)/tweak.mk
