#!/bin/bash
set -euo pipefail
MODULE=$(cd "$(dirname "$0")/.." && pwd)
BUILD=$(mktemp -d)
trap 'rm -rf "$BUILD"' EXIT
xcrun clang -fobjc-arc -fblocks -Wall -Wextra -Werror -framework Foundation -framework Security \
    -I "$MODULE/include" "$MODULE/src/ZXTouchControlAuth.m" "$MODULE/tests/ControlAuthTests.m" -o "$BUILD/control-auth-tests"
"$BUILD/control-auth-tests"
