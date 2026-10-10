#!/bin/bash
set -euo pipefail
PROJECT_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
OUTPUT_PATH=${1:?Specify an output executable path}
BUILD_DIR=$(mktemp -d "${TMPDIR:-/tmp}/trollvnc-apple-socket-build.XXXXXX")
trap 'rm -rf -- "$BUILD_DIR"' EXIT
SDK_PATH=$(xcrun --sdk iphoneos --show-sdk-path)
OBJECTS=()
while IFS= read -r source; do
    object="$BUILD_DIR/$(basename "$source").o"
    xcrun clang -target arm64-apple-ios15.0 -isysroot "$SDK_PATH" -fobjc-arc -Wall -Wextra -Werror \
        -I "$PROJECT_ROOT/vendor/apple/include" -I "$PROJECT_ROOT/vendor/apple/private" -c "$source" -o "$object"
    OBJECTS+=("$object")
done < <(find "$PROJECT_ROOT/vendor/apple/src" -name '*.m' -type f)
xcrun clang++ -target arm64-apple-ios15.0 -isysroot "$SDK_PATH" -std=c++20 -fobjc-arc -Wall -Wextra -Werror -framework Foundation \
    -I "$PROJECT_ROOT/vendor/apple/include" -I "$PROJECT_ROOT/vendor/zxtouch/include" -I "$PROJECT_ROOT/src" \
    "$PROJECT_ROOT/src/TVNCAppleService.mm" "$PROJECT_ROOT/vendor/zxtouch/src/ZXTouchTCPServer.mm" \
    "$PROJECT_ROOT/vendor/zxtouch/src/ZXTouchProtocol.cpp" "$PROJECT_ROOT/tests/AppleSocketDeviceProbe.mm" "${OBJECTS[@]}" -o "$OUTPUT_PATH"
ldid -S"$PROJECT_ROOT/src/trollvncserver.entitlements" "$OUTPUT_PATH"
