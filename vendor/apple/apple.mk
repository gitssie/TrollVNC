# Opt-in source manifest. No TrollVNC, RFB, UIKit or UI automation dependency.
# Before including: APPLE_MODULE_ROOT := <path to vendor/apple>
APPLE_MODULE_FILES := $(APPLE_MODULE_ROOT)/src/common/TVAppleErrors.m \
    $(APPLE_MODULE_ROOT)/src/common/TVAppleNativeBackend.m \
    $(APPLE_MODULE_ROOT)/src/appleid/TVAppleServices.m \
    $(APPLE_MODULE_ROOT)/src/appleid/TVAppleEmailSettings.m \
    $(APPLE_MODULE_ROOT)/src/appleid/TVAppleEmailActions.m \
    $(APPLE_MODULE_ROOT)/src/appleid/TVAppleNameSettings.m \
    $(APPLE_MODULE_ROOT)/src/appleid/TVAppleSignInWithApple.m \
    $(APPLE_MODULE_ROOT)/src/icloud/TVAppleICloudDevices.m \
    $(APPLE_MODULE_ROOT)/src/appleid/TVAppleStateAggregation.m \
    $(APPLE_MODULE_ROOT)/src/icloud/TVAppleDataclassPolicy.m \
    $(APPLE_MODULE_ROOT)/src/icloud/TVAppleICloudSignOut.m \
    $(APPLE_MODULE_ROOT)/src/icloud/TVAppleICloudEnablement.m \
    $(APPLE_MODULE_ROOT)/src/icloud/TVAppleSearchParty.m \
    $(APPLE_MODULE_ROOT)/src/icloud/TVAppleFindMy.m \
    $(APPLE_MODULE_ROOT)/src/appstore/TVAppleStoreAuthentication.m \
    $(APPLE_MODULE_ROOT)/src/appstore/TVAppleManualCodeProvider.m
APPLE_MODULE_CFLAGS := -fobjc-arc -I$(APPLE_MODULE_ROOT)/include -I$(APPLE_MODULE_ROOT)/private
APPLE_MODULE_FRAMEWORKS := Foundation

# TVAppleSearchPartyRecovery.c is a separate privileged executable; never link
# its main() into the host. Build/deploy with tests/build_service_recovery.sh.
