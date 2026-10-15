#!/bin/bash
set -euo pipefail
project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
output_path=${1:?output executable required}
sdk_path=$(xcrun --sdk iphoneos --show-sdk-path)
xcrun clang -target arm64-apple-ios15.0 -isysroot "$sdk_path" \
  -fobjc-arc -Wall -Wextra -Werror -framework Foundation -framework NetworkExtension \
  "$project_root/tests/karing_ipc_probe.m" -o "$output_path"
entitlements_path=${2:-"$project_root/src/trollvncserver.entitlements"}
ldid -S"$entitlements_path" "$output_path"
