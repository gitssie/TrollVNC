> Production integration moved to [HTTP/2 control](../../docs/control-http.md). `/api/karing/*` now streams raw HTTP through `control-http`; the typed client/task34 code below is retained as a historical fixture and is not built into the daemon.

The independently signed [native helper](native/README.md) supplies complete
configuration/profile reads and native core reload through
`/api/karing-native/*`. It is built into the same TrollVNC package and does not
replace or reinterpret the raw HTTP proxy.

# Karing Management Module

Native Objective-C++/Foundation adapter for the Karing sing-box Clash-compatible
REST API. Client code may run on macOS over a USB SSH tunnel, or on the iPhone
against its local controller. No additional SDK/runtime is needed on the phone.

## Architecture

- `KaringProtocol.cpp`: typed response parsing, capability checks, verified writes.
- `TVKaringClient.mm`: NSURLSession transport and Objective-C collections.
- `TVNCKaringService.mm`: ZXTouch task 34 serialization, using Foundation JSON.
- `third_party/json/` and `jsoncpp-src/`: pinned JsonCpp 1.9.5 headers/implementation.
- `karing.mk`: Theos module source list, included by TrollVNC Makefile.

## Device compatibility (verified 2026-10-12)

The connected phone runs `sing-box 1.13.19.2705`. REST API compatibility does not
imply all Clash features exist:

| Task | Operation | Behavior |
| --- | --- | --- |
| 1 | Version | Preserves boolean `meta`/`premium` |
| 2 | Traffic | Reads one complete stream record, then cancels |
| 3 | Configs | Validated JSON, including `mode-list` |
| 4 | Config reload | Unsupported (-8); this backend's PUT is a 204 no-op |
| 5 / 80 | Patch / set mode | Checks mode-list, then verifies returned mode |
| 10 / 11 | Proxy list / detail | Preserves actual type; synthetic GLOBAL detail uses list fallback |
| 12 | Switch node | Only real Selector groups, member validation + post-write verification |
| 13 | Delay | Explicit HTTPS test URL and timeout query parameters |
| 20 / 21 / 22 | Connections / close all / close one | Parses root.connections + metadata + start; DELETE status preserved |
| 30 | Rules | Parses root.rules; absent hits is zero |
| 40 / 41 | Providers / detail | Empty providers works; absent detail returns HTTP error |
| 42 / 43 | Provider selection / healthcheck | Unsupported (-8) on Karing sing-box |
| 50 | DNS | Converts Answer/data/TTL and rejects nonzero DNS rcode |
| 60 | Logs | Bounded live sample (up to 2 seconds); no historical log API |
| 70 | Failover | Selector only; node timeout can advance to alternatives; switch is verified |

This device publishes only `mode-list=["Rule"]`, a synthetic `GLOBAL` and a
`URLTest` group, with no real Selector or providers. global/direct, manual node
switching and failover therefore return Unsupported, not fabricated success.
No log events were emitted during the live sample; timeout (-6) was returned.
Selector success/failover and log streaming are exercised by controlled fixtures.

## Credentials and transport

API credentials use `Authorization: Bearer <secret>`, independent of SSH login.
Device initialization reads the existing ZXTouch `karing.plist` override or
Karing App Group `service_core.json`; it discovers the container by metadata,
with a RootHide `/rootfs` fallback. No keychain or credential persistence is added.

A local test config (outside the repository, permission 0600) contains `baseURL`,
`secret`, `timeoutMs`. The probe receives it over stdin. Do not commit secrets.

For an existing iproxy `2222 -> 22`, keep this tunnel running:

```sh
rtk proxy ssh -N -T -p 2222 -o BatchMode=yes -o ExitOnForwardFailure=yes \
  -L 127.0.0.1:3057:127.0.0.1:3057 mobile@127.0.0.1
```

## Regression and device integration tests

From the repository root:

```sh
rtk proxy bash TrollVNC/vendor/karing/tests/run_tests.sh
rtk proxy python3 TrollVNC/vendor/karing/tests/live_integration.py \
  --report /tmp/karing-live-results.json
```

`run_tests.sh` compiles the actual production C++ implementation, not copied
functions. It also links the actual NSURLSession client and task 34 service,
then tests HTTP/auth/stream/cancellation against a controlled local server.

The live script compiles the same native probe, queries the USB-connected phone,
and checks normalized returns and capability errors. Add `--allow-writes` to
exercise supported mode/Selector changes (with restoration) and close connections.
Closing connections may interrupt phone traffic. Default is read-only.
Use `--config <path>` to choose another existing local JSON credential file.
Logs are represented by byte count in probe reports, not raw private log messages.
Expected unsupported operations count as PASS; unavailable success paths count
as SKIP. Any unexpected response exits nonzero. Retained device report:
`tests/reports/device-2026-10-12.json`.

The live probe runs on the host and exercises HTTP -> C++ -> Objective-C -> task34.
It does not establish a ZXTouch TCP connection or replace the installed daemon.
The successful Selector/failover paths remain fixture-only on this device.

## ZXTouch

Wire payload: `34;;<subtask>;;<args>`. The dispatcher passes the portion after 34.
The service also accepts complete payloads for test tools. Replies retain the
existing `0;;json\r\n`, `0\r\n`, and `-1;;error (code N)\r\n` formats.
JSON write fields use the existing `;;` -> `; ` escaping convention.

Error codes: -1 invalid argument, -2 network, -3 HTTP, -4 JSON schema, -5 auth,
-6 timeout, -7 not connected, -8 unsupported, -9 acknowledged write not applied.
