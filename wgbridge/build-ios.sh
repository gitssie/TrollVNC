#!/bin/sh
set -eu

cd "$(dirname "$0")"
sdk=$(xcrun --sdk iphoneos --show-sdk-path)
clang=$(xcrun --sdk iphoneos --find clang)
mkdir -p build

export GOOS=ios GOARCH=arm64 CGO_ENABLED=1 CC="$clang"
export CGO_CFLAGS="-isysroot $sdk -arch arm64 -miphoneos-version-min=14.0"
export CGO_LDFLAGS="$CGO_CFLAGS"
go build -trimpath -buildmode=c-archive -o build/libtvncwg.a .
