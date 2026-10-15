#!/bin/sh
set -eu
module=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
output=${1:?output binary required}
sh "$module/build-ios.sh"
sdk=$(xcrun --sdk iphoneos --show-sdk-path)
xcrun --sdk iphoneos clang++ -arch arm64 -isysroot "$sdk" -miphoneos-version-min=15.0 -fobjc-arc -std=c++20 -DTVAS_ROOTHIDE=1 -DTHEOS_PACKAGE_SCHEME_ROOTHIDE=1 -I"$THEOS/vendor/include" -L"$THEOS/vendor/lib/iphone/roothide" -lroothide -I"$module/include" -I"$module/../src"     "$module/tests/probe.mm" "$module/../src/TVNCHTTPServer.mm" "$module/../src/TVNCKaringSettings.mm"     "$module/build/libtvnc_control_http.a" -framework Foundation -framework Security -framework SystemConfiguration -o "$output"
ldid -S"$module/../src/trollvncserver.entitlements" "$output"
