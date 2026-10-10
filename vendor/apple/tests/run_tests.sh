#!/bin/bash
set -euo pipefail
MODULE_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/apple-module-tests.XXXXXX")
trap 'rm -rf -- "$TEST_DIR"' EXIT
xcrun clang -fobjc-arc -Wall -Wextra -Werror -framework Foundation \
    -I "$MODULE_ROOT/include" -I "$MODULE_ROOT/private" \
    "$MODULE_ROOT/src/common/TVAppleErrors.m" \
    "$MODULE_ROOT/src/common/TVAppleNativeBackend.m" \
    "$MODULE_ROOT/src/appstore/TVAppleStoreReview.m" \
    "$MODULE_ROOT/src/appstore/TVAppleStoreSignIn.m" \
    "$MODULE_ROOT/src/appleid/TVAppleServices.m" \
    "$MODULE_ROOT/src/appleid/TVAppleEmailSettings.m" \
    "$MODULE_ROOT/src/appleid/TVAppleEmailActions.m" \
    "$MODULE_ROOT/src/appleid/TVAppleNameSettings.m" \
    "$MODULE_ROOT/src/appleid/TVAppleSignInWithApple.m" \
    "$MODULE_ROOT/src/icloud/TVAppleICloudDevices.m" \
    "$MODULE_ROOT/src/appleid/TVAppleStateAggregation.m" \
    "$MODULE_ROOT/src/icloud/TVAppleDataclassPolicy.m" \
    "$MODULE_ROOT/src/icloud/TVAppleICloudSignOut.m" \
    "$MODULE_ROOT/src/icloud/TVAppleICloudEnablement.m" \
    "$MODULE_ROOT/src/icloud/TVAppleSearchParty.m" \
    "$MODULE_ROOT/src/icloud/TVAppleFindMy.m" \
    "$MODULE_ROOT/src/appstore/TVAppleStoreAuthentication.m" \
    "$MODULE_ROOT/src/appstore/TVAppleManualCodeProvider.m" \
    "$MODULE_ROOT/tests/AppleServicesTests.m" -o "$TEST_DIR/tests"
for test_case in independent_progress email_native_success email_native_error email_native_timeout email_native_conflict email_native_identity email_native_response_identity email_response email_query email_query_invalid signout_warning_success signout_warning_unknown native_remove_dataclass_warning native_remove_clean native_remove_denied native_remove_present native_remove_read_failure native_remove_findmy native_remove_wrong_domain native_remove_other_error native_cloud_simple native_cloud_complex native_cloud_wrong_passcode native_cloud_no_passcode native_cloud_bad_type native_cloud_closed native_cloud_repeat native_cloud_recovery enable_cloud_success enable_cloud_already enable_cloud_conflict enable_cloud_invalid enable_cloud_rejected enable_cloud_unknown enable_cloud_stale enable_cloud_read_failure enable_cloud_findmy_before enable_cloud_findmy_after native_findmy_state findmy_success findmy_disabled findmy_conflict findmy_rejected findmy_timeout findmy_unverified findmy_verification_read icloud_unknown_removed icloud_success icloud_empty icloud_findmy icloud_stale icloud_verification_read store_signout success keep query empty findmy preflight read policy invalid unknown stale verification_read dataclass_policy \
    manual_code manual_cancel manual_finish login_success login_other_cloud login_trust login_conflict login_rejected login_timeout login_unverified login_inactive \
    login_trust_rejected login_trust_read_failure; do
    "$TEST_DIR/tests" "$test_case"
done

xcrun clang -fobjc-arc -Wall -Wextra -Werror -framework Foundation \
    -I "$MODULE_ROOT/include" -I "$MODULE_ROOT/private" \
    "$MODULE_ROOT/src/common/TVAppleErrors.m" \
    "$MODULE_ROOT/tests/AuthChallengeTests.m" -o "$TEST_DIR/challenges"
"$TEST_DIR/challenges"

xcrun clang -fobjc-arc -Wall -Wextra -Werror -framework Foundation \
    -I "$MODULE_ROOT/include" -I "$MODULE_ROOT/private" \
    "$MODULE_ROOT/src/common/TVAppleErrors.m" \
    "$MODULE_ROOT/src/icloud/TVAppleSearchParty.m" \
    "$MODULE_ROOT/tests/SearchPartyTests.m" -o "$TEST_DIR/searchparty"
"$TEST_DIR/searchparty"

xcrun clang -Wall -Wextra -Werror "$MODULE_ROOT/tests/RecoveryHelperTests.c" -o "$TEST_DIR/recovery"
"$TEST_DIR/recovery"

xcrun clang -fobjc-arc -Wall -Wextra -Werror -framework Foundation \
    -I "$MODULE_ROOT/include" -I "$MODULE_ROOT/private" \
    "$MODULE_ROOT/src/common/TVAppleErrors.m" \
    "$MODULE_ROOT/src/common/TVAppleNativeBackend.m" \
    "$MODULE_ROOT/src/appstore/TVAppleStoreReview.m" \
    "$MODULE_ROOT/src/appstore/TVAppleStoreSignIn.m" \
    "$MODULE_ROOT/src/appleid/TVAppleServices.m" \
    "$MODULE_ROOT/src/appleid/TVAppleEmailSettings.m" \
    "$MODULE_ROOT/src/appleid/TVAppleEmailActions.m" \
    "$MODULE_ROOT/src/appleid/TVAppleNameSettings.m" \
    "$MODULE_ROOT/src/appleid/TVAppleSignInWithApple.m" \
    "$MODULE_ROOT/src/icloud/TVAppleICloudDevices.m" \
    "$MODULE_ROOT/src/appleid/TVAppleStateAggregation.m" \
    "$MODULE_ROOT/src/icloud/TVAppleDataclassPolicy.m" \
    "$MODULE_ROOT/src/icloud/TVAppleICloudSignOut.m" \
    "$MODULE_ROOT/src/icloud/TVAppleICloudEnablement.m" \
    "$MODULE_ROOT/src/icloud/TVAppleSearchParty.m" \
    "$MODULE_ROOT/src/icloud/TVAppleFindMy.m" \
    "$MODULE_ROOT/src/appstore/TVAppleStoreAuthentication.m" \
    "$MODULE_ROOT/src/appstore/TVAppleManualCodeProvider.m" \
    "$MODULE_ROOT/tests/EmailActionsTests.m" -o "$TEST_DIR/email-actions"
"$TEST_DIR/email-actions"

xcrun clang -fobjc-arc -Wall -Wextra -Werror -framework Foundation \
    -I "$MODULE_ROOT/include" -I "$MODULE_ROOT/private" \
    "$MODULE_ROOT/src/common/TVAppleErrors.m" \
    "$MODULE_ROOT/src/appleid/TVAppleStateAggregation.m" \
    "$MODULE_ROOT/tests/StateAggregationTests.m" -o "$TEST_DIR/state-aggregation"
"$TEST_DIR/state-aggregation"

xcrun clang -fobjc-arc -Wall -Wextra -Werror -framework Foundation \
    -I "$MODULE_ROOT/include" -I "$MODULE_ROOT/private" \
    "$MODULE_ROOT/src/common/TVAppleErrors.m" \
    "$MODULE_ROOT/src/common/TVAppleNativeBackend.m" \
    "$MODULE_ROOT/src/appstore/TVAppleStoreReview.m" \
    "$MODULE_ROOT/src/appstore/TVAppleStoreSignIn.m" \
    "$MODULE_ROOT/src/appleid/TVAppleServices.m" \
    "$MODULE_ROOT/src/appleid/TVAppleEmailSettings.m" \
    "$MODULE_ROOT/src/appleid/TVAppleEmailActions.m" \
    "$MODULE_ROOT/src/appleid/TVAppleNameSettings.m" \
    "$MODULE_ROOT/src/appleid/TVAppleSignInWithApple.m" \
    "$MODULE_ROOT/src/icloud/TVAppleICloudDevices.m" \
    "$MODULE_ROOT/src/appleid/TVAppleStateAggregation.m" \
    "$MODULE_ROOT/src/icloud/TVAppleDataclassPolicy.m" \
    "$MODULE_ROOT/src/icloud/TVAppleICloudSignOut.m" \
    "$MODULE_ROOT/src/icloud/TVAppleICloudEnablement.m" \
    "$MODULE_ROOT/src/icloud/TVAppleSearchParty.m" \
    "$MODULE_ROOT/src/icloud/TVAppleFindMy.m" \
    "$MODULE_ROOT/src/appstore/TVAppleStoreAuthentication.m" \
    "$MODULE_ROOT/src/appstore/TVAppleManualCodeProvider.m" \
    "$MODULE_ROOT/tests/SignInWithAppleTests.m" -o "$TEST_DIR/siwa"
"$TEST_DIR/siwa"

xcrun clang -fobjc-arc -Wall -Wextra -Werror -framework Foundation \
    -I "$MODULE_ROOT/include" -I "$MODULE_ROOT/private" \
    "$MODULE_ROOT/src/common/TVAppleErrors.m" \
    "$MODULE_ROOT/src/common/TVAppleNativeBackend.m" \
    "$MODULE_ROOT/src/appstore/TVAppleStoreReview.m" \
    "$MODULE_ROOT/src/appstore/TVAppleStoreSignIn.m" \
    "$MODULE_ROOT/src/appleid/TVAppleServices.m" \
    "$MODULE_ROOT/src/appleid/TVAppleEmailSettings.m" \
    "$MODULE_ROOT/src/appleid/TVAppleEmailActions.m" \
    "$MODULE_ROOT/src/appleid/TVAppleNameSettings.m" \
    "$MODULE_ROOT/src/appleid/TVAppleSignInWithApple.m" \
    "$MODULE_ROOT/src/icloud/TVAppleICloudDevices.m" \
    "$MODULE_ROOT/src/appleid/TVAppleStateAggregation.m" \
    "$MODULE_ROOT/src/icloud/TVAppleDataclassPolicy.m" \
    "$MODULE_ROOT/src/icloud/TVAppleICloudSignOut.m" \
    "$MODULE_ROOT/src/icloud/TVAppleICloudEnablement.m" \
    "$MODULE_ROOT/src/icloud/TVAppleSearchParty.m" \
    "$MODULE_ROOT/src/icloud/TVAppleFindMy.m" \
    "$MODULE_ROOT/src/appstore/TVAppleStoreAuthentication.m" \
    "$MODULE_ROOT/src/appstore/TVAppleManualCodeProvider.m" \
    "$MODULE_ROOT/tests/ICloudDevicesTests.m" -o "$TEST_DIR/icloud-devices"
"$TEST_DIR/icloud-devices"

xcrun clang -fobjc-arc -Wall -Wextra -Werror -framework Foundation \
    -I "$MODULE_ROOT/include" -I "$MODULE_ROOT/private" \
    "$MODULE_ROOT/src/common/TVAppleErrors.m" \
    "$MODULE_ROOT/src/common/TVAppleNativeBackend.m" \
    "$MODULE_ROOT/src/appstore/TVAppleStoreReview.m" \
    "$MODULE_ROOT/src/appstore/TVAppleStoreSignIn.m" \
    "$MODULE_ROOT/src/appleid/TVAppleServices.m" \
    "$MODULE_ROOT/src/appleid/TVAppleEmailSettings.m" \
    "$MODULE_ROOT/src/appleid/TVAppleEmailActions.m" \
    "$MODULE_ROOT/src/appleid/TVAppleNameSettings.m" \
    "$MODULE_ROOT/src/appleid/TVAppleSignInWithApple.m" \
    "$MODULE_ROOT/src/icloud/TVAppleICloudDevices.m" \
    "$MODULE_ROOT/src/appleid/TVAppleStateAggregation.m" \
    "$MODULE_ROOT/src/icloud/TVAppleDataclassPolicy.m" \
    "$MODULE_ROOT/src/icloud/TVAppleICloudSignOut.m" \
    "$MODULE_ROOT/src/icloud/TVAppleICloudEnablement.m" \
    "$MODULE_ROOT/src/icloud/TVAppleSearchParty.m" \
    "$MODULE_ROOT/src/icloud/TVAppleFindMy.m" \
    "$MODULE_ROOT/src/appstore/TVAppleStoreAuthentication.m" \
    "$MODULE_ROOT/src/appstore/TVAppleManualCodeProvider.m" \
    "$MODULE_ROOT/tests/NameRefreshTests.m" -o "$TEST_DIR/name-refresh"
"$TEST_DIR/name-refresh"

# Private Store Review continuation; response bytes/URLs stay inside the module.
xcrun clang -fobjc-arc -Wall -Wextra -Werror -framework Foundation \
    -I "$MODULE_ROOT/include" -I "$MODULE_ROOT/private" \
    "$MODULE_ROOT/src/common/TVAppleErrors.m" \
    "$MODULE_ROOT/src/appstore/TVAppleStoreReview.m" \
    "$MODULE_ROOT/tests/StoreReviewTests.m" -o "$TEST_DIR/store-review"
"$TEST_DIR/store-review"

xcrun clang -fobjc-arc -Wall -Wextra -Werror -framework Foundation \
    -I "$MODULE_ROOT/include" -I "$MODULE_ROOT/private" \
    "$MODULE_ROOT/src/common/TVAppleErrors.m" \
    "$MODULE_ROOT/src/appstore/TVAppleStoreAuthentication.m" \
    "$MODULE_ROOT/src/appstore/TVAppleStoreReview.m" \
    "$MODULE_ROOT/src/appstore/TVAppleStoreSignIn.m" \
    "$MODULE_ROOT/tests/StoreReviewAuthenticationTests.m" -o "$TEST_DIR/store-review-auth"
"$TEST_DIR/store-review-auth"

# Production Store login/Review branch and on-device US billing source mapping.
xcrun clang -fobjc-arc -Wall -Wextra -Werror -framework Foundation \
    -I "$MODULE_ROOT/include" -I "$MODULE_ROOT/private" \
    "$MODULE_ROOT/src/common/TVAppleErrors.m" \
    "$MODULE_ROOT/src/appstore/TVAppleStoreAuthentication.m" \
    "$MODULE_ROOT/src/appstore/TVAppleStoreReview.m" \
    "$MODULE_ROOT/src/appstore/TVAppleStoreSignIn.m" \
    "$MODULE_ROOT/tests/StoreSignInTests.m" -o "$TEST_DIR/store-signin"
"$TEST_DIR/store-signin"
