#!/bin/bash
set -euo pipefail
module_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
output_path=${1:?output executable required}
sdk_path=$(xcrun --sdk iphoneos --show-sdk-path)
extra_flags=()
if [[ ${KARING_NATIVE_DIAGNOSTICS:-0} == 1 ]]; then
  extra_flags+=(-DTVKARING_DIAGNOSTICS=1)
fi
xcrun clang -target arm64-apple-ios15.0 -isysroot "$sdk_path" \
  -fobjc-arc -Wall -Wextra -Werror -framework Foundation -framework NetworkExtension \
  -I"$module_root/include" "$module_root/src/main.m" "$module_root/src/Helper.m" \
  "$module_root/src/Documents.m" "${extra_flags[@]}" -o "$output_path"
ldid -S"$module_root/helper.entitlements" "$output_path"
