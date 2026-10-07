#!/bin/bash
set -euo pipefail
MODULE_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
OUTPUT_PATH=${1:?Specify an output executable path}
TEST_ENTRY=${2:-apple-state.m}
case "$TEST_ENTRY" in apple-state.m|apple-login.m|apple-icloud-logout.m|apple-logout.m|apple-findmy-disable.m|apple-icloud-enable.m|apple-searchparty-health.m|apple-email-settings.m|apple-email-actions.m|apple-name-settings.m|apple-siwa.m) ;; *) exit 2 ;; esac
SDK_PATH=$(xcrun --sdk iphoneos --show-sdk-path)
xcrun clang -target arm64-apple-ios15.0 -isysroot "$SDK_PATH" \
    -fobjc-arc -Wall -Wextra -Werror -framework Foundation \
    -I "$MODULE_ROOT/include" -I "$MODULE_ROOT/private" \
    "$MODULE_ROOT/src/common/TVAppleErrors.m" \
    "$MODULE_ROOT/src/common/TVAppleNativeBackend.m" \
    "$MODULE_ROOT/src/appleid/TVAppleServices.m" \
    "$MODULE_ROOT/src/appleid/TVAppleEmailSettings.m" \
    "$MODULE_ROOT/src/appleid/TVAppleEmailActions.m" \
    "$MODULE_ROOT/src/appleid/TVAppleNameSettings.m" \
    "$MODULE_ROOT/src/appleid/TVAppleSignInWithApple.m" \
    "$MODULE_ROOT/src/appleid/TVAppleStateAggregation.m" \
    "$MODULE_ROOT/src/icloud/TVAppleDataclassPolicy.m" \
    "$MODULE_ROOT/src/icloud/TVAppleICloudSignOut.m" \
    "$MODULE_ROOT/src/icloud/TVAppleICloudEnablement.m" \
    "$MODULE_ROOT/src/icloud/TVAppleSearchParty.m" \
    "$MODULE_ROOT/src/icloud/TVAppleFindMy.m" \
    "$MODULE_ROOT/src/appstore/TVAppleStoreAuthentication.m" \
    "$MODULE_ROOT/src/appstore/TVAppleManualCodeProvider.m" \
    "$MODULE_ROOT/tests/$TEST_ENTRY" -o "$OUTPUT_PATH"
ldid -S"$MODULE_ROOT/tests/entitlements.plist" "$OUTPUT_PATH"
