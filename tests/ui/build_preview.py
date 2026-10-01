#!/usr/bin/env python3
"""Build actual native settings controllers without Xcode asset/Swift build phases."""
import os, pathlib, plistlib, shutil, subprocess, sys
root = pathlib.Path(__file__).resolve().parents[2]
output = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else '/tmp/trollvnc-settings-preview')
app = output / 'TrollVNCPreview.app'
app.mkdir(parents=True, exist_ok=True)
shutil.copytree(root / 'prefs/TrollVNCPrefs/Resources', app / 'TrollVNCPrefs.bundle', dirs_exist_ok=True)
(app / 'Info.plist').write_bytes(plistlib.dumps({
    'CFBundleIdentifier': 'com.82flex.trollvnc.ui-preview', 'CFBundleExecutable': 'TrollVNCPreview',
    'CFBundleName': 'TrollVNC Preview', 'CFBundlePackageType': 'APPL',
    'CFBundleVersion': '1', 'CFBundleShortVersionString': '1.0', 'MinimumOSVersion': '14.0',
    'UIDeviceFamily': [1, 2], 'LSRequiresIPhoneOS': True,
    'UILaunchScreen': {}, 'UISupportedInterfaceOrientations': ['UIInterfaceOrientationPortrait', 'UIInterfaceOrientationLandscapeLeft', 'UIInterfaceOrientationLandscapeRight'],
}))
sdk = subprocess.check_output(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'], text=True).strip()
source = root / 'app/TrollVNC/TrollVNC'
theos = pathlib.Path(os.environ['THEOS'])
files = ['TVNCRootListController.m', 'TVNCSettingsPageController.m', 'TVNCSettingsModel.m',
         'TVNCNetworkController.m', 'TVNCWireGuardController.m', 'TVNCClientListController.m',
         'TVNCClientCell.m', 'TVNCListItemsController.m', 'TVNCSliderCell.m',
         'StripedTextTableViewController.m', 'ZTSelfSignedCertificate.m']
# Minimal SDK stub for the installed simulator's genuine Preferences framework.
(output / 'Preferences.tbd').write_text('''--- !tapi-tbd
tbd-version: 4
targets: [ arm64-ios-simulator ]
install-name: /System/Library/PrivateFrameworks/Preferences.framework/Preferences
exports:
  - targets: [ arm64-ios-simulator ]
    objc-classes: [ PSListController, PSListItemsController, PSTableCell, PSSpecifier ]
...
''')
command = ['xcrun', 'clang', '-target', 'arm64-apple-ios14.0-simulator', '-isysroot', sdk,
           '-fobjc-arc', '-DPACKAGE_VERSION="3.2-preview"', '-DTHEOS_PACKAGE_SCHEME="rootless"',
           '-I' + str(source), '-I' + str(root / 'src'),
           '-I' + str(theos / 'vendor/include'),
           str(root / 'tests/ui/SettingsPreview.m'), *[str(source / name) for name in files],
           str(root / 'src/TVNCWireGuardConfig.m'), str(output / 'Preferences.tbd'),
           '-framework', 'UIKit', '-framework', 'Foundation', '-framework', 'Network',
           '-framework', 'SystemConfiguration', '-framework', 'Security',
           '-Wl,-undefined,dynamic_lookup', '-o', str(app / 'TrollVNCPreview')]
subprocess.run(command, check=True)
subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True)
print(app)
