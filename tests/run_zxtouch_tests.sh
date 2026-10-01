#!/bin/bash
set -euo pipefail
PROJECT_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/trollvnc-zxtouch.XXXXXX")
trap 'rm -rf -- "$TEST_DIR"' EXIT
xcrun clang++ -std=c++20 -Wall -Wextra -Werror -fsanitize=address,undefined \
    -I "$PROJECT_ROOT/vendor/zxtouch/include" \
    "$PROJECT_ROOT/tests/ZXTouchCoreTests.cpp" \
    "$PROJECT_ROOT/vendor/zxtouch/src/ZXTouchProtocol.cpp" \
    "$PROJECT_ROOT/vendor/zxtouch/src/ZXTouchImage.cpp" -o "$TEST_DIR/core-tests"
"$TEST_DIR/core-tests"
xcrun clang++ -std=c++20 -fobjc-arc -framework Foundation \
    -I "$PROJECT_ROOT/vendor/zxtouch/include" \
    "$PROJECT_ROOT/tests/ZXTouchTransportHost.mm" \
    "$PROJECT_ROOT/vendor/zxtouch/src/ZXTouchTCPServer.mm" \
    "$PROJECT_ROOT/vendor/zxtouch/src/ZXTouchProtocol.cpp" -o "$TEST_DIR/transport-host"
python3 "$PROJECT_ROOT/tests/ZXTouchTransportTests.py" "$TEST_DIR/transport-host"

xcrun clang++ -std=c++20 -fobjc-arc -framework Foundation \
    -I "$PROJECT_ROOT/vendor/zxtouch/include" \
    "$PROJECT_ROOT/tests/ZXTouchRuntimeTests.mm" \
    "$PROJECT_ROOT/vendor/zxtouch/src/ZXTouchProcessRunner.mm" \
    "$PROJECT_ROOT/vendor/zxtouch/src/ZXTouchUIBridge.mm" -o "$TEST_DIR/runtime-tests"
"$TEST_DIR/runtime-tests" "$PROJECT_ROOT/layout/usr/share/trollvnc/python"

python3 "$PROJECT_ROOT/tests/ZXTouchClientTests.py"
