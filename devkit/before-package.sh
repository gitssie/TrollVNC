#!/bin/bash

set -e

if [ "$THEOS_PACKAGE_SCHEME" = "rootless" ]; then
    chmod 4755 "$THEOS_STAGING_DIR/usr/bin/cazer-apple-searchparty-recover"
    /usr/libexec/PlistBuddy -c 'Set :ProgramArguments:0 /var/jb/usr/bin/trollvncserver' "$THEOS_STAGING_DIR/Library/LaunchDaemons/com.82flex.trollvnc.plist"
    /usr/libexec/PlistBuddy -c 'Set :StandardOutPath /var/jb/tmp/trollvnc-stdout.log' "$THEOS_STAGING_DIR/Library/LaunchDaemons/com.82flex.trollvnc.plist"
    /usr/libexec/PlistBuddy -c 'Set :StandardErrorPath /var/jb/tmp/trollvnc-stderr.log' "$THEOS_STAGING_DIR/Library/LaunchDaemons/com.82flex.trollvnc.plist"
fi

exit 0
