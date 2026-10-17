## Dopamine 3 migration (2026-10-17)

Production helpers now use the standard rootless bootstrap and real App Group
container paths, with no RootHide library or `/rootfs` fallback. Historical device
results below predate this migration and require fresh Dopamine 3 acceptance.

# Karing module instructions

Current production: `/api/karing/*` remains the raw HTTP/2 reverse proxy.
`native/` is the separately signed, on-demand native helper and daemon client;
read [native interface](native/README.md) before modifying it. It has no app/icon,
no listener and no keychain dependency. Never log its full config/profile/status
responses. Preserve unknown configuration fields. Reload is submitted once;
empty IPC replies alone are not success. Same-config core restart requires
changed startTime plus unchanged configuration; uncertain mutations are unknown.
The historical typed/task34 sources described below are not built into the daemon.

Independent native Clash-compatible REST adapter for Karing sing-box.
Read README.md for the current API/capability table and tests.

## Production code

- include/KaringProtocol.hpp and src/KaringProtocol.cpp: C++ types and parsing.
- include/TVKaringClient.h and src/TVKaringClient.mm: Foundation HTTP transport.
- src/TVNCKaringService.mm: ZXTouch task34, Foundation JSON serialization.
- karing.mk: Theos module source list included by TrollVNC Makefile.
- third_party/json and jsoncpp-src: fixed JsonCpp1.9.5 headers and implementation.
  It is a compiled library, not header-only. Retain the upstream license.

Use `[TVKaringClient clientWithDeviceSettings]` on device. It reads the existing
ZXTouch karing.plist override or Karing App Group service_core.json, discovering
containers by metadata. RootHide has a /rootfs fallback. Reuse local config and
password files; do not add keychain storage or dependencies. Never print tokens
or Authorization headers. Live test credentials stay outside the repository.

## Verified device behavior (2026-10-12)

Core: sing-box1.13.19.2705; mode-list=["Rule"]; synthetic GLOBAL + URLTest;
no real Selector or providers. Do not claim global/direct, synthetic/URLTest
switching, config reload, or provider writes work. Unsupported operations return
-8. Mode/Selector writes verify state; GLOBAL read falls back to /proxies only
when individual GET is404 and is marked synthetic/read-only. Traffic takes one
complete record. Logs sample live events for at most2seconds, not history.
Idle logs time out (-6), not fabricated empty success. Delay needs HTTPS url and
timeout parameters. Connections/rules/DNS use the actual nested structures.
Version meta/premium are booleans. Failed node timeout408 permits failover.

## Verification

From repository root:

```sh
rtk proxy bash TrollVNC/vendor/karing/tests/run_tests.sh
rtk proxy python3 TrollVNC/vendor/karing/tests/live_integration.py --report /tmp/karing-live.json
```

The host tests link production code; never replace them with copies of production
functions. Live tests compile that same native client/task34 probe and run over
USB SSH. --allow-writes additionally tests supported mode/selector changes with
restoration and deletes connections. Reports include normalized replies but omit
raw private log payloads and API secrets. tests/reports/device-2026-10-12.json
records41PASS/3SKIP. Selector/failover success and emitted log stream are fixture
verified; they were unavailable on this phone. Host live probe does not establish
ZXTouch TCP or replace the installed daemon. Full RootHide arm64 all build passed.
