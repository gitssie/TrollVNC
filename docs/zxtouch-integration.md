# ZXTouch control integration

The integrated service runs inside `trollvncserver`. It provides the ZXTouch
TCP protocol on a separate port, directly over Wi-Fi or through the same
userspace WireGuard network as VNC. It does not include ZXTouch's Web dashboard,
recording, recorded-event playback, recording editor or the ZXTouch management UI.
Automation dialogs and toasts are supplied by a small jailbreak adapter.

## Enable without UI

ZXTouch is off by default. CLI examples:

```sh
trollvncserver -zxtouch on                 # VNC plus ZXTouch on TCP 6000
trollvncserver -zxtouch-only               # ZXTouch without a VNC listener
trollvncserver -zxtouch on -zxtouch-bind 127.0.0.1  # loopback / WG access
```

`-zxtouch-port` accepts a port from 1 to 65535. The original Python client
uses port 6000, so changing it requires a client that supports another port.
`-zxtouch-bind` accepts a numeric IPv4 or IPv6 address. The default is `::`
(dual stack, including IPv4 Wi-Fi and local loopback).

Daemon mode reads the existing `com.82flex.trollvnc` preferences domain:

| Key | Default | Meaning |
| --- | --- | --- |
| `ZXTouchEnabled` | false | Enable the integrated TCP service |
| `ZXTouchPort` | 6000 | Independent ZXTouch TCP port |
| `ZXTouchBindAddress` | `::` | Numeric listener address |
| `Enabled` | existing VNC setting | Enable VNC independently |
| `WireGuardEnabled` / `WireGuardConfig` | existing settings | Shared WG tunnel |

Persist these keys using the same preferences file/domain used by the existing
deployment, then restart the server (or use the existing Apply action). Setting
`Enabled=false` and `ZXTouchEnabled=true` leaves ZXTouch available. Neither
service needs an active VNC viewer to accept ZXTouch commands or capture images.
In daemon mode CLI flags are ignored, consistent with existing daemon behavior.

WG forwards only enabled service ports to local loopback. A listener bound to a
specific Wi-Fi address remains available on Wi-Fi but is skipped for WG; use a
wildcard or loopback listener to support WG. VNC reverse connection can coexist
with a ZXTouch-only WG route. The bridge does not create an iOS system VPN or
route unrelated script traffic through WG.

The integrated service must own its port; stop a standalone ZXTouch listener
on 6000 before enabling this one. Port conflicts with VNC, HTTP and control
listeners fail startup. ZXTouch preserves the original protocol without an
authentication handshake; VNC passwords do not authenticate ZXTouch commands.

## Client and supported commands

The package installs an independently authored, drop-in Python client under
`/usr/share/trollvnc/python` (with the deployment's root prefix). For a computer,
add `layout/usr/share/trollvnc/python` to `PYTHONPATH`. The original client also
uses the same protocol, but its missing clipboard constants 5/6/7 are corrected
in the bundled client. All its public method names are preserved, including
recording methods that return an explicit exclusion error.

Example:

```python
from zxtouch.client import zxtouch
from zxtouch.touchtypes import TOUCH_DOWN, TOUCH_UP

device = zxtouch("192.168.1.23")  # or the phone's WG address
print(device.get_screen_size())
device.touch(TOUCH_DOWN, 0, 100, 200)
device.touch(TOUCH_UP, 0, 100, 200)
with open("screen.jpg", "wb") as output:
    output.write(device.screenshot())
device.disconnect()
```

| Task | Supported behavior |
| --- | --- |
| 10 | Down/move/up; up to nine updates per packet, 20 active fingers across clients |
| 11 | Open an application by bundle identifier |
| 12 | Native alert with title, content and dismissal duration (adapter) |
| 13 | Shell command, waits for exit, runs as service user `mobile` |
| 14/15 | Recording explicitly excluded |
| 18 | Per-connection sleep, up to 60 seconds, cancellable on disconnect/stop |
| 19/20 | Start/stop an on-device Python script or Python `.bdl` bundle |
| 21 | Template matching, absolute template path on the phone; up to eight scale attempts |
| 22 | Severity toast, duration, position and font size (adapter) |
| 23 | Pick an RGB color at a screen pixel |
| 24 | Insert text, cursor, delete, paste, clipboard; exact show/hide via app adapter |
| 25 | Screen size/orientation/scale, device/battery information and runtime status (32) |
| 26 | Show/hide physical and injected touch indicators; reload color/coordinate configuration (adapter) |
| 27 | Vision OCR, supported-language query and annotated debug-image output |
| 28 | RGB range search in a region |
| 29 | Native text-input prompt, user cancel/120-second timeout (adapter) |
| 30 | Fresh JPEG screenshot with binary length framing |

Coordinates refer to full-resolution pixels in the current interface
orientation, independent of VNC scaling and orientation offsets. A client's
unchanged fingers are carried as stationary events; disconnect and service
stop cancel its active fingers. Invalid touch packets close the connection;
invalid phase transitions release that client's fingers without adding a
response to its fire-and-forget stream.

Without app injection, keyboard commands serialize separately from the main runloop. ASCII uses HID
events; Unicode uses the system pasteboard and Command-V, leaving the pasted
text on the clipboard. Insert commands accept up to 256 UTF-16 units at a time;
the Python client's per-character `insert_text` remains compatible. With the
jailbreak adapter installed, insert/cursor/delete/paste execute directly through
the foreground app's keyboard implementation. Actual
insertion depends on the focused app accepting hardware keyboard/paste events.

Template matching uses coarse normalized correlation followed by native-pixel
refinement. Templates must be at most 16 MiB and 4096 pixels per axis. It does
not reproduce every upstream matching heuristic. OCR uses native Vision;
an absolute debug path writes a PNG (for `.png`) or JPEG with recognition boxes. Empty width/height regions extend to the
screen edge. Unknown and excluded tasks return a framed error rather than
leaving clients waiting. Deprecated/reserved tasks 16/17 remain unsupported. Task 99 answers a diagnostic
request. Task 90 reloads legacy dark-mode configuration; script settings are read
on each start. The legacy volume-popup setting has no management panel to toggle.
Text fields can contain bare LF/CR, but `;;`, NUL and embedded CRLF are reserved
by the wire format. Shell commands and script paths consume the entire payload
and can contain `;;`. Outbound CRLF is normalized to LF and `;;` to `; `.

### Python scripts and platform requirements

`play_script` accepts an absolute `.py` file or a bundle directory whose
`info.plist` names a Python `Entry`. Entry paths must stay within that bundle,
including through symlinks. `FrontApp` is opened if the legacy
`switch_app_before_run_script` configuration allows it. Per-bundle
`individual_configs` in `script_play_settings.plist` retain `repeat_times`
(extra repeats, 0 means once) and `interval` (seconds). Recorded `.raw` playback
is excluded. Python 3.9–3.13 or `python3` must already be installed in the
jailbreak/runtime prefix; the interpreter is not bundled. A missing interpreter
returns an error. Scripts run with their directory as cwd, the bundled client
on `PYTHONPATH`, and `ZXTOUCH_PORT` set to the configured local service port.

Only one script runs at a time. Start replies after spawning; runtime task 25/32
reports foreground bundle, script-running flag and recording flag (always 0).
Shell commands and scripts inherit TrollVNC's `mobile` privileges. stdout/stderr
append to `/var/mobile/Library/Logs/TrollVNC/zxtouch-process.log`; nonzero shell
exit returns an error. Disconnect cancels a synchronous shell request; script
execution is independent of the requesting connection and stops via task 20 or
service shutdown, which kills the owned process group.

Jailbreak packages include `TVNCZXTouchAdapter`, loaded into SpringBoard and
UIKit applications. This module owns no TCP listener. Correlated distributed
notifications execute native UI operations and return their result; timeout,
disconnect and service stop dismiss pending prompts. In a TrollStore standalone
deployment without app injection, alerts/toasts/prompts/indicators and exact
keyboard visibility return an adapter error. HID input, capture, clipboard and
the server-side commands remain available subject to their runtime dependencies.
No settings screen has been added.

## Structure and verification

`vendor/zxtouch` is an independently implemented, source-built protocol,
transport and image core. `TVNCZXTouchService` adapts it to TrollVNC's HID
generator and on-demand screen capture. The adapter and Python client are
bundled for jailbreak packages; the Python interpreter is external. Upstream implementation files were not copied; see the vendor
README for provenance and licensing.

Run `bash tests/run_zxtouch_tests.sh` for sanitized core tests and native macOS
TCP transport tests, process/IPC lifecycle tests and real-socket Python client
method/return-shape tests. Run `go test -race ./...` in `wgbridge` for real userspace
WG tests, including independent VNC/ZXTouch routes, connection cleanup and a
ZXTouch-only tunnel. The iOS server is compiled with the normal Theos build.
Device input injection, screen orientation, Unicode paste and OCR still require
physical-device acceptance testing, including SpringBoard scenes, dialogs,
keyboard selectors and global touch monitoring; host transport tests use a mock command
handler and do not verify these native capabilities.
