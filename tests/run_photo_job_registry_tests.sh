#!/bin/bash
set -euo pipefail
PROJECT_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/trollvnc-photo-registry.XXXXXX")
trap 'rm -rf -- "$TEST_DIR"' EXIT
xcrun clang++ -std=c++20 -fobjc-arc -Wall -Wextra -Werror -framework Foundation -I "$PROJECT_ROOT/src" \
    "$PROJECT_ROOT/tests/PhotoJobRegistryTests.mm" -o "$TEST_DIR/photo-registry-tests"
"$TEST_DIR/photo-registry-tests"
