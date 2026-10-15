#!/bin/bash
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
BUILD=$(mktemp -d "${TMPDIR:-/tmp}/tvnc-screen-http.XXXXXX")
trap 'rm -rf "$BUILD"' EXIT
xcrun clang++ -fobjc-arc -fblocks -std=c++17 -Wall -Wextra -Werror \
    "$HERE/screen_http_tests.mm" -framework Foundation -o "$BUILD/screen-http-tests"
"$BUILD/screen-http-tests"
