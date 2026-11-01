#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P)
HOST=$(rustc -vV | sed -n 's/^host: //p')
cargo test --locked --manifest-path "$ROOT/wgbridge-onetun/Cargo.toml" --target "$HOST"
cargo test --locked --manifest-path "$ROOT/wgbridge-onetun/Cargo.toml" --target "$HOST" --features test-clock handshake_tests -- --test-threads=1
