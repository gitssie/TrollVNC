#!/bin/bash
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
build=$(mktemp -d "${TMPDIR:-/tmp}/app-state-stream.XXXXXX")
trap 'rm -rf -- "$build"' EXIT
objects=()
for source in "$root/vendor/app-state/src/TVASProtocol.m" "$root/vendor/app-state/src/TVASRuntime.m" \
    "$root/vendor/app-state/src/TVASShadowRead.m" "$root/vendor/app-state/src/TVASShadowWrite.m" \
    "$root/vendor/app-state/src/TVASShadowBridge.m" "$root/vendor/shadow/sdk/AppState/SHDWAppStateClient.m"; do
    object="$build/$(basename "$source").o"
    xcrun clang -fobjc-arc -Wall -Wextra -Werror -I "$root/vendor/app-state/include" \
        -I "$root/vendor/shadow/sdk/AppState" -c "$source" -o "$object"
    objects+=("$object")
done
xcrun clang++ -std=c++20 -fobjc-arc -Wall -Wextra -Werror \
    -I "$root/vendor/app-state/src" -I "$root/src" -I "$root/control-http/include" -I "$root/vendor/app-state/include" \
    "$root/tests/AppStateStreamTests.mm" "$root/src/TVNCAppStateStream.mm" "$root/src/TVNCAppStateService.mm" \
    "${objects[@]}" -framework Foundation -o "$build/stream-tests"
"$build/stream-tests"
