# Native settings preview

This harness compiles the production UIKit settings controllers into a simulator
app. Only service status and local addresses are fixtures; it does not start the
VNC server or ZXTouch adapter. It is never included in the jailbreak package.

Requires macOS, Xcode with an installed arm64 iOS simulator runtime, and `THEOS`
pointing to a Theos checkout containing `vendor/include/Preferences`.

```sh
python3 tests/ui/build_preview.py
xcrun simctl install booted /tmp/trollvnc-settings-preview/TrollVNCPreview.app
SIMCTL_CHILD_TVNC_UI_PAGE=home xcrun simctl launch --terminate-running-process booted \
  com.82flex.trollvnc.ui-preview -AppleLanguages '(zh-Hans)' -AppleLocale zh_CN
```

`TVNC_UI_PAGE` accepts `home`, `network`, `security`, `display`, `input`,
`connections`, `performance`, and `web`. Set `SIMCTL_CHILD_TVNC_UI_DARK=1` to
preview dark appearance. Page selection calls the production navigation handler;
it does not verify physical taps. Run separate tap checks from the home screen.

Compare screenshots against `docs/trollvnc-complete-ui-concept.png`, especially
row density, icon size, card spacing, and title/value alignment. Also check small
screens, accessibility text sizes, long IPv6 addresses, and landscape. Verify
port editing, switches, sliders, address copying, certificate actions, and the
Apply confirmation through actual UI input.

The host configuration tests and rootless package build passed for this redesign.
Visual and tap checks remain pending: the available simulator stalled during
system startup, and desktop automation reported blocked Accessibility access.
Neither successful compilation nor direct page selection proves visual fidelity.
