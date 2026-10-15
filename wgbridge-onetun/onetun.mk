ONETUN_ROOT := wgbridge-onetun

ifeq ($(THEOS_DEVICE_SIMULATOR),1)
ONETUN_LIB := $(ONETUN_ROOT)/build/libtvnc_wg_onetun-sim.a
else
ONETUN_LIB := $(ONETUN_ROOT)/build/libtvnc_wg_onetun.a
endif

before-all::
	@sh $(ONETUN_ROOT)/build-ios.sh $(if $(filter 1,$(THEOS_DEVICE_SIMULATOR)),--simulator,)

trollvncserver_OBJ_FILES += $(ONETUN_LIB)
