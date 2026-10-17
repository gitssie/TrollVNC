#!/bin/bash
set -euo pipefail
project=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
testdir=$(mktemp -d)
trap 'rm -rf "$testdir"' EXIT
xcrun clang -Wall -Wextra -Werror -I"$project/src" "$project/tests/SingletonLockTests.c" -o "$testdir/locks"
"$testdir/locks"
