#!/bin/bash
set -euo pipefail
MODULE_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
OUTPUT_PATH=${1:?Specify output path}
SDK_PATH=$(xcrun --sdk iphoneos --show-sdk-path)
xcrun clang -target arm64-apple-ios15.0 -isysroot "$SDK_PATH" -Wall -Wextra -Werror \
    "$MODULE_ROOT/src/icloud/TVAppleSearchPartyRecovery.c" -o "$OUTPUT_PATH"
ldid -S"$MODULE_ROOT/tests/entitlements.plist" "$OUTPUT_PATH"
# Provision as root: root-owned executable, mode 4755; trustcache before use.
# The library checks owner/type/mode and refuses symlinks or writable helpers.
