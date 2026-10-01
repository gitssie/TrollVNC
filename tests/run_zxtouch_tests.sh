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
python3 - "$TEST_DIR/runtime-tests" "$PROJECT_ROOT/layout/usr/share/trollvnc/python" <<'PY_RUNTIME'
import subprocess, sys
# A PATH launch or exec caller can supply argv[0] independently of the binary.
subprocess.run(['spoofed-server-name', sys.argv[2]], executable=sys.argv[1], check=True)
PY_RUNTIME

python3 "$PROJECT_ROOT/tests/ZXTouchClientTests.py"

xcrun clang++ -std=c++20 -fobjc-arc -framework Foundation \
    -I "$PROJECT_ROOT/app/TrollVNC/TrollVNC" \
    "$PROJECT_ROOT/tests/TVNCServiceStatusTests.mm" -o "$TEST_DIR/status-tests"
"$TEST_DIR/status-tests"

xcrun clang++ -x objective-c++ -std=c++20 -fobjc-arc -framework Foundation \
    -I "$PROJECT_ROOT/app/TrollVNC/TrollVNC" \
    "$PROJECT_ROOT/tests/TVNCSettingsModelTests.mm" \
    "$PROJECT_ROOT/app/TrollVNC/TrollVNC/TVNCSettingsModel.m" -o "$TEST_DIR/settings-tests"
"$TEST_DIR/settings-tests" "$PROJECT_ROOT/prefs/TrollVNCPrefs/Resources/SettingsCatalog.plist"
