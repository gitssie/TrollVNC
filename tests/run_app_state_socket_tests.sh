#!/bin/bash
set -euo pipefail
PROJECT_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/trollvnc-app-state-socket.XXXXXX")
trap 'rm -rf -- "$TEST_DIR"' EXIT
OBJECTS=()
for source in "$PROJECT_ROOT"/vendor/app-state/src/*.m "$PROJECT_ROOT/vendor/app-state/adapters/PXASNative.m" "$PROJECT_ROOT/vendor/app-state/core/PXAppState.m"; do
    object="$TEST_DIR/$(basename "$source").o"
    xcrun clang -fobjc-arc -Wall -Wextra -Werror -I "$PROJECT_ROOT/vendor/app-state/include" -I "$PROJECT_ROOT/vendor/app-state/src" -c "$source" -o "$object"
    OBJECTS+=("$object")
done
xcrun clang++ -std=c++20 -fobjc-arc -Wall -Wextra -Werror -framework Foundation -framework Security -framework LocalAuthentication \
    -I "$PROJECT_ROOT/vendor/app-state/include" -I "$PROJECT_ROOT/vendor/zxtouch/include" -I "$PROJECT_ROOT/src" \
    "$PROJECT_ROOT/tests/AppStateSocketTests.mm" "$PROJECT_ROOT/src/TVNCAppStateService.mm" "${OBJECTS[@]}" \
    "$PROJECT_ROOT/vendor/zxtouch/src/ZXTouchTCPServer.mm" "$PROJECT_ROOT/vendor/zxtouch/src/ZXTouchProtocol.cpp" -o "$TEST_DIR/app-state-tests"
"$TEST_DIR/app-state-tests"
python3 "$PROJECT_ROOT/tests/AppStateSocketClientTests.py" "$TEST_DIR/app-state-tests"
