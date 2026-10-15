#!/bin/bash
set -euo pipefail
MODULE_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
OUTPUT=${1:?Usage: build_probe.sh /path/to/probe}
xcrun clang++ -std=c++17 -fobjc-arc -Wall -Wextra -Wno-unused-parameter \
  -I "$MODULE_ROOT/include" -I "$MODULE_ROOT/third_party" \
  "$MODULE_ROOT/src/KaringProtocol.cpp" \
  "$MODULE_ROOT/src/TVKaringClient.mm" \
  "$MODULE_ROOT/src/TVNCKaringService.mm" \
  "$MODULE_ROOT/third_party/jsoncpp-src/json_reader.cpp" \
  "$MODULE_ROOT/third_party/jsoncpp-src/json_value.cpp" \
  "$MODULE_ROOT/third_party/jsoncpp-src/json_writer.cpp" \
  "$MODULE_ROOT/tests/KaringTests.mm" -framework Foundation -o "$OUTPUT"
