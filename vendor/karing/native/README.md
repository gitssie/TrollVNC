# Karing native helper

Production module for the native capabilities absent from Karing's Clash API.
It builds `karing-native-helper`, installs it at
`/usr/libexec/trollvnc/karing-native-helper`, and signs it independently of the
TrollVNC daemon. It is an executable, not an application or a network listener.
ZXTouch spawns it on demand through `TVKaringHelperClient`, with fixed argv,
bounded output and a 50-second process deadline. No shell or password is used.

The helper identity is `TNPM9PFX3W.com.nebula.karing`, with the Karing App Group,
packet-tunnel entitlement, platform/VPN access and container-file access. This matches the installed
Karing distribution verified on the test phone; other distributions or OS
versions must be verified separately. Do not copy these entitlements into the
daemon or grant this helper account/keychain privileges. Root alone does not
provide the required application identity.

## HTTP interface

All routes require the existing VNC control Bearer token, use `POST` with `{}`,
and return JSON. Unknown parameters are rejected. Device VNC capabilities
advertise `http_karing_native: true`; simulator builds report false.

| Route | Response |
| --- | --- |
| `/api/karing-native/status` | `data`: complete native core status/connection response |
| `/api/karing-native/config` | `data`: complete `service_core.json`, including unknown fields |
| `/api/karing-native/profiles` | `data`: documents keyed by `karing_subscribe.json`, `karing_subscribe_use.json`, `karing_setting.json` |
| `/api/karing-native/reload` | `outcome: succeeded`, `reloadVerified: true`, `sameConfig: true` after observed reload |

Native config/profile responses contain the original private configuration,
including credentials. Consumers must not log them. This is separate from the
existing `/api/karing/*` raw proxy, which continues preserving HTTP methods,
paths, parameters and response bodies without interpreting them.

Discovery selects only `com.nebula.karing.karingService`, creates its native
VPN session, then uses the installed LibVpnCore string-message protocol:
`clashiApiConnections`/`true` for reads and `restart`/empty for reload.
Reload requires readable core status and configuration before submission,
submits once, then checks changed core `startTime` and unchanged configuration.
Concurrent reloads reject as busy; an uncertain result returns `outcome: unknown`
and HTTP 504. Reads and unrelated operations are not blocked by that result.
Preflight/unavailable errors return HTTP 503; unsupported routes return 404.

Documents are read through fixed filenames, `O_NOFOLLOW`, descriptor-based file
checks and an 8 MiB per-document limit. They are not normalized or rewritten.
The module currently reads configuration and reloads it; it does not implement
subscription downloads, node edits, chain edits or VPN start/stop.

Dopamine 3 uses real App Group container paths and a helper installed in the
rootless bootstrap. There is no RootHide path-conversion library or `/rootfs`
fallback. The helper retains its independent signature and mode 0755; it is not
setuid. Device evidence below predates the Dopamine 3 migration.

## Retained tests

From the TrollVNC repository:

```sh
rtk proxy bash vendor/karing/native/tests/run_tests.sh
rtk proxy python3 vendor/karing/native/tests/run_device.py
rtk proxy python3 vendor/karing/native/tests/run_device.py --allow-reload
```

Host tests link the production document reader/client. USB tests build a caller
with the daemon's real entitlements and the production helper with its own
identity, then exercise status, full config and profiles. `--allow-reload` adds
exactly one reload of the existing configuration after those reads pass.
Sudo credentials come from a hidden prompt/stdin; only filtered summaries are
printed. Temporary device files are cleaned; no reports are written and the
installed daemon is not replaced. These tests exercise the client/helper chain,
not deployment of the new HTTP routes on the resident daemon.
