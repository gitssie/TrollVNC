#!/bin/bash
set -euo pipefail
module_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
temporary_root=$(mktemp -d)
trap 'rm -rf "$temporary_root"' EXIT
xcrun clang -fobjc-arc -Wall -Wextra -Werror -framework Foundation -framework NetworkExtension \
  -I"$module_root/include" "$module_root/tests/NativeTests.m" \
  "$module_root/src/Documents.m" "$module_root/src/Client.m" "$module_root/src/Helper.m" -o "$temporary_root/native-tests"
"$temporary_root/native-tests"
