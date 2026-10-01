#!/bin/bash
set -euo pipefail
PROJECT_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/trollvnc-app-policy.XXXXXX")
trap 'rm -rf -- "$TEST_DIR"' EXIT
xcrun clang++ -std=c++20 -fobjc-arc -framework Foundation -I "$PROJECT_ROOT/src" \
    "$PROJECT_ROOT/tests/AppManagementPolicyTests.mm" -o "$TEST_DIR/app-policy-tests"
"$TEST_DIR/app-policy-tests"
