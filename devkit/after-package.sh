#!/bin/bash

set -e
if [ "$THEOS_PACKAGE_SCHEME" = "roothide" ]; then
    python3 "$(dirname "$0")/../scripts/normalize_deb_ownership.py" \
        "$(dirname "$0")/../packages/com.82flex.trollvnc_${PACKAGE_VERSION}_iphoneos-arm64e.deb"
fi
if [ -z "$THEBOOTSTRAP" ]; then
    exit 0
fi

cd "$(dirname "$0")"/.. || exit 1

cd "$THEOS_STAGING_DIR"

mv Applications Payload
zip -yqr TrollVNC.tipa Payload
mv Payload Applications

cd -
mv "$THEOS_STAGING_DIR"/TrollVNC.tipa packages/TrollVNC_"$PACKAGE_VERSION".tipa
