#!/bin/bash
set -euo pipefail
PROJECT_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/trollvnc-apple-socket.XXXXXX")
trap 'rm -rf -- "$TEST_DIR"' EXIT
SOURCES=()
OBJECTS=()
while IFS= read -r source; do SOURCES+=("$source"); done < <(find "$PROJECT_ROOT/vendor/apple/src" -name '*.m' -type f)
for source in "${SOURCES[@]}"; do
    object="$TEST_DIR/$(basename "$source").o"
    xcrun clang -fobjc-arc -Wall -Wextra -Werror -I "$PROJECT_ROOT/vendor/apple/include" -I "$PROJECT_ROOT/vendor/apple/private" -c "$source" -o "$object"
    OBJECTS+=("$object")
done
xcrun clang++ -std=c++20 -fobjc-arc -Wall -Wextra -Werror -framework Foundation \
    -I "$PROJECT_ROOT/vendor/zxtouch/include" -I "$PROJECT_ROOT/vendor/apple/include" -I "$PROJECT_ROOT/vendor/apple/private" -I "$PROJECT_ROOT/src" \
    "$PROJECT_ROOT/tests/AppleSocketTests.mm" "$PROJECT_ROOT/src/TVNCAppleService.mm" "${OBJECTS[@]}" "$PROJECT_ROOT/vendor/zxtouch/src/ZXTouchTCPServer.mm" "$PROJECT_ROOT/vendor/zxtouch/src/ZXTouchProtocol.cpp" -o "$TEST_DIR/apple-tests"
"$TEST_DIR/apple-tests"
python3 "$PROJECT_ROOT/tests/AppleSocketClientTests.py" "$TEST_DIR/apple-tests"
