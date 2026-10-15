#!/bin/bash
set -euo pipefail
MODULE_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/karing-module-tests.XXXXXX")
trap 'rm -rf -- "$TEST_DIR"' EXIT
xcrun clang++ -std=c++17 -Wall -Wextra -Werror \
  -I "$MODULE_ROOT/include" -I "$MODULE_ROOT/third_party" \
  "$MODULE_ROOT/src/KaringProtocol.cpp" \
  "$MODULE_ROOT/third_party/jsoncpp-src/json_reader.cpp" \
  "$MODULE_ROOT/third_party/jsoncpp-src/json_value.cpp" \
  "$MODULE_ROOT/third_party/jsoncpp-src/json_writer.cpp" \
  "$MODULE_ROOT/tests/karing_cpp_tests.cpp" -o "$TEST_DIR/core-tests"
"$TEST_DIR/core-tests"
bash "$MODULE_ROOT/tests/build_probe.sh" "$TEST_DIR/probe"
python3 "$MODULE_ROOT/tests/native_transport_tests.py" --probe "$TEST_DIR/probe"
