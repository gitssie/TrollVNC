#!/bin/sh
set -eu
cd "$(dirname "$0")"
mkdir -p build
case ${1:-} in
    ""|--simulator) ;;
    *) echo "Usage: $0 [--simulator]" >&2; exit 2 ;;
esac
if [ "${1:-}" = "--simulator" ]; then
    # Install once: rustup target add aarch64-apple-ios-sim x86_64-apple-ios
    IPHONEOS_DEPLOYMENT_TARGET=15.0 cargo build --locked --release --target aarch64-apple-ios-sim
    IPHONEOS_DEPLOYMENT_TARGET=15.0 cargo build --locked --release --target x86_64-apple-ios
    xcrun lipo -create target/aarch64-apple-ios-sim/release/libtvnc_wg_onetun.a target/x86_64-apple-ios/release/libtvnc_wg_onetun.a -output build/libtvnc_wg_onetun-sim.a
else
    # Install once: rustup target add aarch64-apple-ios
    IPHONEOS_DEPLOYMENT_TARGET=15.0 cargo build --locked --release --target aarch64-apple-ios
    cp -f target/aarch64-apple-ios/release/libtvnc_wg_onetun.a build/libtvnc_wg_onetun.a
fi
