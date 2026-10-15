# Standalone service facade. Never grants the host target keychain access groups.
APP_STATE_FILES := $(APP_STATE_ROOT)/src/TVASAppLifecycle.m $(APP_STATE_ROOT)/src/TVAppStateServices.m $(APP_STATE_ROOT)/src/TVASRuntime.m $(APP_STATE_ROOT)/src/TVASProtocol.m $(APP_STATE_ROOT)/src/TVASProcessRunner.m $(APP_STATE_ROOT)/adapters/PXASNative.m $(APP_STATE_ROOT)/core/PXAppState.m
APP_STATE_CFLAGS := -I$(APP_STATE_ROOT)/include -I$(APP_STATE_ROOT)/src -fobjc-arc
APP_STATE_WORKER_FILES := $(APP_STATE_ROOT)/product/Worker.m $(APP_STATE_ROOT)/src/TVASRuntime.m $(APP_STATE_ROOT)/core/PXAppState.m $(APP_STATE_ROOT)/core/PXAppStateSession.m $(APP_STATE_ROOT)/adapters/PXASNative.m
APP_STATE_WORKER_FILES += $(APP_STATE_ROOT)/profiles/TVAppProfile.m $(APP_STATE_ROOT)/profiles/TVVintedProfile.m $(APP_STATE_ROOT)/profiles/TVSessionSupplementStore.m
