# ZXTouch control integration

The integrated service runs inside `trollvncserver`. It provides the ZXTouch
TCP protocol on a separate port, directly over Wi-Fi or through the same
userspace WireGuard network as VNC. It does not include ZXTouch's Web dashboard,
recording, recording editor, phone-side script player or app UI.

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

Use the existing ZXTouch Python client from a computer:

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
| 18 | Per-connection sleep, up to 60 seconds, cancellable on service stop |
| 21 | Template matching, absolute template path on the phone; up to eight scale attempts |
| 23 | Pick an RGB color at a screen pixel |
| 24 | Insert text, move cursor, delete, paste, get/set text clipboard |
| 25 | Screen size/orientation/scale, device and battery information |
| 27 | Vision OCR of a region and supported-language query |
| 28 | RGB range search in a region |
| 30 | Fresh JPEG screenshot with binary length framing |

Coordinates refer to full-resolution pixels in the current interface
orientation, independent of VNC scaling and orientation offsets. A client's
unchanged fingers are carried as stationary events; disconnect and service
stop cancel its active fingers. Invalid touch packets close the connection;
invalid phase transitions release that client's fingers without adding a
response to its fire-and-forget stream.

Keyboard commands serialize separately from the main runloop. ASCII uses HID
events; Unicode uses the system pasteboard and Command-V, leaving the pasted
text on the clipboard. Insert commands accept up to 256 UTF-16 units at a time;
the Python client's per-character `insert_text` remains compatible. Actual
insertion depends on the focused app accepting hardware keyboard/paste events.

Template matching uses coarse normalized correlation followed by native-pixel
refinement. Templates must be at most 16 MiB and 4096 pixels per axis. It does
not reproduce every upstream matching heuristic. OCR uses native Vision;
debug-image file output is excluded. Empty width/height regions extend to the
screen edge. Unknown and excluded tasks return a framed error rather than
leaving clients waiting. Tasks 12/13/14/15/16/17/19/20/22/26/29/90/99 and
keyboard visibility task 24/2 are not implemented.

## Structure and verification

`vendor/zxtouch` is an independently implemented, source-built protocol,
transport and image core. `TVNCZXTouchService` adapts it to TrollVNC's HID
generator and on-demand screen capture. No SpringBoard tweak or Python runtime
is bundled. Upstream implementation files were not copied; see the vendor
README for provenance and licensing.

Run `bash tests/run_zxtouch_tests.sh` for sanitized core tests and native macOS
TCP transport tests. Run `go test -race ./...` in `wgbridge` for real userspace
WG tests, including independent VNC/ZXTouch routes, connection cleanup and a
ZXTouch-only tunnel. The iOS server is compiled with the normal Theos build.
Device input injection, screen orientation, Unicode paste and OCR still require
physical-device acceptance testing; host transport tests use a mock command
handler and do not verify these native capabilities.
