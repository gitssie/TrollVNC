#!/bin/bash
set -e
if [ "$THEOS_PACKAGE_SCHEME" = "rootless" ]; then
    python3 "$(dirname "$0")/../scripts/normalize_deb_ownership.py" \
        "$(dirname "$0")/../packages/com.82flex.trollvnc_${PACKAGE_VERSION}_iphoneos-arm64.deb"
fi
