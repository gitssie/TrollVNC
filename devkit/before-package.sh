#!/bin/bash

set -e

if [ "$THEOS_PACKAGE_SCHEME" = "roothide" ]; then
    chmod 4755 "$THEOS_STAGING_DIR/usr/bin/cazer-apple-searchparty-recover"
    # The RootHide app-state installer validates its rule with visudo, and
    # the runtime uses sudo to invoke the IDFV worker as root.
    control="$THEOS_STAGING_DIR/DEBIAN/control"
    awk '
        /^Depends:/ {
            count = split(substr($0, 9), dependencies, ",")
            for (i = 1; i <= count; i++) {
                if (dependencies[i] ~ /^[[:space:]]*sudo([[:space:]]|$)/) found = 1
            }
            if (!found) $0 = $0 ", sudo"
        }
        { print }
    ' "$control" > "$control.tmp"
    mv -f "$control.tmp" "$control"
fi

if [ "$THEOS_PACKAGE_SCHEME" = "rootless" ]; then
    /usr/libexec/PlistBuddy -c 'Set :ProgramArguments:0 /var/jb/usr/bin/trollvncserver' "$THEOS_STAGING_DIR/Library/LaunchDaemons/com.82flex.trollvnc.plist"
    /usr/libexec/PlistBuddy -c 'Set :StandardOutPath /var/jb/tmp/trollvnc-stdout.log' "$THEOS_STAGING_DIR/Library/LaunchDaemons/com.82flex.trollvnc.plist"
    /usr/libexec/PlistBuddy -c 'Set :StandardErrorPath /var/jb/tmp/trollvnc-stderr.log' "$THEOS_STAGING_DIR/Library/LaunchDaemons/com.82flex.trollvnc.plist"
fi

if [ -z "$THEBOOTSTRAP" ]; then
    exit 0
fi

# Set version information
GIT_COMMIT_COUNT=$(git rev-list --count HEAD)
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $GIT_COMMIT_COUNT" "$THEOS_STAGING_DIR/Applications/TrollVNC.app/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $PACKAGE_VERSION" "$THEOS_STAGING_DIR/Applications/TrollVNC.app/Info.plist"

# Collect executables
cp -rfp "$THEOS_STAGING_DIR/usr/bin/trollvncserver" "$THEOS_STAGING_DIR/Applications/TrollVNC.app/"
cp -rfp "$THEOS_STAGING_DIR/usr/bin/trollvncmanager" "$THEOS_STAGING_DIR/Applications/TrollVNC.app/"

# Independently signed native helper remains an executable, never a SpringBoard app.
mkdir -p "$THEOS_STAGING_DIR/Applications/TrollVNC.app/libexec"
cp -fp "$THEOS_STAGING_DIR/usr/libexec/trollvnc/karing-native-helper" "$THEOS_STAGING_DIR/Applications/TrollVNC.app/libexec/"

# Collect bundle resources
cp -rfp "$THEOS_STAGING_DIR/Library/PreferenceBundles/TrollVNCPrefs.bundle" "$THEOS_STAGING_DIR/Applications/TrollVNC.app/"
rm -f "$THEOS_STAGING_DIR/Applications/TrollVNC.app/TrollVNCPrefs.bundle/TrollVNCPrefs"
cp -rfp "$THEOS_STAGING_DIR/usr/share/trollvnc/webclients" "$THEOS_STAGING_DIR/Applications/TrollVNC.app/"

cp -rf "$THEOS_STAGING_DIR/usr/share/trollvnc/python" "$THEOS_STAGING_DIR/Applications/TrollVNC.app/"

# Remove unused files
rm -rf "${THEOS_STAGING_DIR:?}/usr"
rm -rf "${THEOS_STAGING_DIR:?}/Library"

# Pseudo code signing
ldid -Sapp/TrollVNC/TrollVNC/TrollVNC.entitlements "$THEOS_STAGING_DIR/Applications/TrollVNC.app"
