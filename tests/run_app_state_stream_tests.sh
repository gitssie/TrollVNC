#!/bin/bash
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
build=$(mktemp -d "${TMPDIR:-/tmp}/app-state-stream.XXXXXX")
trap 'rm -rf -- "$build"' EXIT
xcrun clang -fobjc-arc -Wall -Wextra -Werror -I "$root/vendor/app-state/include" \
    -c "$root/vendor/app-state/src/TVASProtocol.m" -o "$build/protocol.o"
xcrun clang++ -std=c++20 -fobjc-arc -Wall -Wextra -Werror \
    -I "$root/src" -I "$root/control-http/include" -I "$root/vendor/app-state/include" \
    "$root/tests/AppStateStreamTests.mm" "$root/src/TVNCAppStateStream.mm" "$root/src/TVNCAppStateService.mm" \
    "$build/protocol.o" -framework Foundation -o "$build/stream-tests"
"$build/stream-tests"
