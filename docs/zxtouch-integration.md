# ZXTouch control integration

The integrated service runs inside `trollvncserver`. It provides the ZXTouch
TCP protocol on a separate port, directly over Wi-Fi or through the same
userspace WireGuard network as VNC. It does not include ZXTouch's Web dashboard,
recording, recorded-event playback, recording editor or the ZXTouch management UI.
Automation dialogs and toasts are supplied by a small jailbreak adapter.

## Unified service and native settings (Dopamine rootless)

VNC and ZXTouch always start together inside the launchd-managed server, even
when no VNC viewer is connected. The native Settings pane has no protocol enable
switches. Default TCP ports are VNC **5901** and ZXTouch **6000**. Both use the
existing `BindHost` setting; its default is `0.0.0.0` for local Wi-Fi and shared WG access.

After both listeners start, the daemon publishes one runtime snapshot containing
the active ports, bind address, local addresses and WireGuard state. The Settings
dashboard icon and Network settings consume that same snapshot immediately, then
refresh it through the control socket. A missed control reply keeps the last
valid snapshot; only changed fields redraw. Local IPv4 addresses are resolved
again from the active bind address when a cached snapshot is read, so a new Wi-Fi
address does not require changing the service configuration. Tap a socket address
to copy it. Pending port edits do not appear as active addresses until Apply
restarts the unified service.
WG interface startup does not imply a successful peer handshake or remote reachability.

Import or edit one WireGuard configuration in Network settings. Saving a new
configuration enables the shared userspace WG network by default. The Network
settings switch can disable or re-enable WG while retaining its configuration;
changing it restarts TrollVNC. The details page shows the interface address,
listen port, MTU, DNS and peers. Removing the configuration restarts the
service with local access. WG startup errors are shown while local listeners
remain available. The bridge does not create an iOS system VPN or route unrelated
script traffic through WG. On shutdown local sockets close immediately; WG has
a bounded 250 ms window to transmit queued TCP close packets. An offline peer
may still need its own TCP timeout.

| Preference | Default | Meaning |
| --- | --- | --- |
| `Port` | 5901 | VNC TCP port |
| `ZXTouchPort` | 6000 | ZXTouch TCP port |
| `BindHost` | `0.0.0.0` | Shared IPv4 listener address |
| `WireGuardConfig` | absent | Shared WG configuration |
| `WireGuardEnabled` | enabled when configured | Enables or disables WG without deleting its configuration |

Obsolete `Enabled`, `ZXTouchEnabled` and `ZXTouchBindAddress` settings are ignored.
Legacy independent-mode CLI flags are
rejected; `-zxtouch-port` selects the ZXTouch port, and the existing VNC bind
option applies to both protocols. Daemon mode uses persisted preferences.
Ports must be distinct, within 1024–65535, and not conflict with HTTP or reserved
control ports 46751/46752. A configured reverse VNC connection keeps the local
listeners running and retries the outbound peer without restarting local services.
The Control Center tile is a restart action, not an enable switch. Stop any standalone ZXTouch listener on 6000 before using
this package. ZXTouch preserves the original protocol without an authentication
handshake; VNC passwords do not authenticate ZXTouch commands.

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
orientation, independent of VNC scaling and orientation offsets. Capture, touch
normalization and screen-size replies share the render surface dimensions rather
than mixing them with potentially different physical `nativeBounds`. A client's
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
service shutdown, which kills the owned process group. When the top-level
command exits, remaining children in that group are terminated before its PID
is reaped. Cleanup covers descendants that remain in the owned process group;
a process that deliberately starts a new session/group is outside that group.

Jailbreak packages include `TVNCZXTouchAdapter`, loaded into SpringBoard and
UIKit applications. This module owns no TCP listener. Correlated distributed
notifications execute native UI operations and return their result; timeout,
disconnect and service stop dismiss pending prompts. In a TrollStore standalone
deployment without app injection, alerts/toasts/prompts/indicators and exact
keyboard visibility return an adapter error. HID input, capture, clipboard and
the server-side commands remain available subject to their runtime dependencies.
The native network settings page manages the unified service; no ZXTouch recording or Web management UI is included.

## Structure and verification

`vendor/zxtouch` is an independently implemented, source-built protocol,
transport and image core. `TVNCZXTouchService` adapts it to TrollVNC's HID
generator and on-demand screen capture. The adapter and Python client are
bundled for jailbreak packages; the Python interpreter is external. Upstream implementation files were not copied; see the vendor
README for provenance and licensing.

Run `bash tests/run_zxtouch_tests.sh` for sanitized core tests and native macOS
TCP transport tests, process/IPC lifecycle tests and real-socket Python client
method/return-shape tests, plus unified-port validation and fragmented/timeout status-query tests. Run `go test -race ./...` in `wgbridge` for real userspace
WG tests, including simultaneous VNC/ZXTouch routes, explicit loopback destinations, connection cleanup and route shutdown. The iOS server is compiled with the normal Theos build. VNC, ZXTouch and the optional VNC HTTP viewer listen on IPv4; an empty bind address uses `0.0.0.0`.
Device input injection, screen orientation, Unicode paste and OCR still require
physical-device acceptance testing, including SpringBoard scenes, dialogs,
keyboard selectors and global touch monitoring; host transport tests use a mock command
handler and do not verify these native capabilities.
