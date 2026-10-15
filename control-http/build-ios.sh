#!/bin/sh
set -eu
cd "$(dirname "$0")"
mkdir -p build
if [ "${1:-}" = "--simulator" ]; then
    # Install once: rustup target add aarch64-apple-ios-sim x86_64-apple-ios
    IPHONEOS_DEPLOYMENT_TARGET=15.0 cargo build --locked --release --target aarch64-apple-ios-sim
    IPHONEOS_DEPLOYMENT_TARGET=15.0 cargo build --locked --release --target x86_64-apple-ios
    xcrun lipo -create target/aarch64-apple-ios-sim/release/libtvnc_control_http.a target/x86_64-apple-ios/release/libtvnc_control_http.a -output build/libtvnc_control_http-sim.a
else
    # Install once: rustup target add aarch64-apple-ios
    IPHONEOS_DEPLOYMENT_TARGET=15.0 cargo build --locked --release --target aarch64-apple-ios
    cp -f target/aarch64-apple-ios/release/libtvnc_control_http.a build/libtvnc_control_http.a
fi
