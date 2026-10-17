#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
umask 077
mkdir -p "$root/build"
case "${1:-test}" in
    test)
        xcrun --sdk macosx clang -fobjc-arc -Wall -Wextra -Werror -DTVAS_DOPAMINE3=1 -I "$root/tests/runtime" \
            "$root/src/TVASRuntime.m" "$root/tests/RuntimePathsTests.m" -framework Foundation -o "$root/build/runtime-path-tests"
        "$root/build/runtime-path-tests"
        xcrun --sdk macosx clang -fobjc-arc -Wall -Wextra -Werror -I "$root/profiles" \
            "$root/profiles/TVAppProfile.m" "$root/profiles/TVVintedProfile.m" "$root/profiles/TVSessionSupplementStore.m" "$root/tests/ProfileTests.m" \
            -framework Foundation -lsqlite3 -o "$root/build/profile-tests"
        "$root/build/profile-tests"
        xcrun --sdk macosx clang -fobjc-arc -Wall -Wextra -Werror \
            "$root/core/PXAppState.m" "$root/tests/PXASFixture.m" "$root/tests/StateTests.m" \
            -framework Foundation -o "$root/build/state-tests"
        "$root/build/state-tests"
        xcrun --sdk macosx clang -fobjc-arc -Wall -Wextra -Werror \
            "$root/core/PXAppState.m" "$root/adapters/PXASNative.m" "$root/tests/NativeKeychainTests.m" \
            -framework Foundation -framework Security -framework LocalAuthentication -o "$root/build/native-keychain-tests"
        "$root/build/native-keychain-tests"
        xcrun --sdk macosx clang -fobjc-arc -Wall -Wextra -Werror \
            "$root/core/PXAppStateSession.m" "$root/tests/SessionTests.m" \
            -framework Foundation -o "$root/build/session-tests"
        "$root/build/session-tests"
        xcrun --sdk macosx clang -fobjc-arc -Wall -Wextra -Werror -I "$root/include" -I "$root/src" \
            "$root/src/TVASProtocol.m" "$root/tests/ProtocolTests.m" -framework Foundation -o "$root/build/protocol-tests"
        "$root/build/protocol-tests"
        xcrun --sdk macosx clang -fobjc-arc -Wall -Wextra -Werror \
            "$root/src/TVASAppLifecycle.m" "$root/tests/LifecycleTests.m" -framework Foundation -o "$root/build/lifecycle-tests"
        "$root/build/lifecycle-tests"
        xcrun --sdk macosx clang -fobjc-arc -Wall -Wextra -Werror -I "$root/include" -I "$root/src" \
            "$root/src/TVAppStateServices.m" "$root/src/TVASAppLifecycle.m" "$root/src/TVASRuntime.m" "$root/src/TVASProtocol.m" "$root/src/TVASProcessRunner.m" \
            "$root/core/PXAppState.m" "$root/adapters/PXASNative.m" "$root/tests/ServiceTests.m" \
            -framework Foundation -framework Security -framework LocalAuthentication -o "$root/build/service-tests"
        "$root/build/service-tests"
        xcrun --sdk macosx clang -fobjc-arc -Wall -Wextra -Werror "$root/tests/VendorWorkerTests.m" -framework Foundation -o "$root/build/vendor-supervision-tests"
        "$root/build/vendor-supervision-tests"
        ;;
    ios)
        xcrun --sdk iphoneos clang -arch arm64 -miphoneos-version-min=15.0 \
            -fobjc-arc -Wall -Wextra -Werror "$root/core/PXAppState.m" \
            "$root/adapters/PXASNative.m" "$root/cli/main.m" \
            -framework Foundation -framework Security -framework LocalAuthentication \
            -o "$root/build/app-state"
        xcrun --sdk iphoneos clang -arch arm64 -miphoneos-version-min=15.0 \
            -fobjc-arc -Wall -Wextra -Werror "$root/cli/VendorWorker.m" \
            -framework Foundation -o "$root/build/vendor-worker"
        echo 'Built unsigned iOS tools; no deployment performed.'
        ;;
    *) echo "usage: $0 test|ios" >&2; exit 2;;
esac
