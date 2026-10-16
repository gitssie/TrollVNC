# Phone control HTTP API

The phone control listener uses HTTP/2 cleartext prior knowledge (h2c) on the configured `ZXTouchPort` (default 6000). The task/CRLF socket listener is removed from the daemon build. VNC continues carrying screen/input and its existing unlock/notification extensions. RV uses a normal HTTP client for app management and native Apple/app-state services.

## Authorization and discovery

`POST /api/control/connect` with `{"password":"…"}` exchanges the existing full-control VNC password for a signed HS256 JWT. No VNC connection is required. The response contains `access_token`, `token_type: "Bearer"`, `expires_in: 3600` and `capabilities`; its `zx_control` has `version: 3`, `protocol: "http2"`, the configured port and the same token. Classic credentials retain their existing first-eight-UTF-8-byte semantics. If VNC password protection is disabled (no password list), the submitted password is ignored, matching VNC authentication behavior; the server still issues and validates a JWT for subsequent control requests. View-only passwords cannot obtain control tokens.

The HTTP/2 routing layer forwards this exact POST login route to password validation before requiring any Bearer token; all other routes remain protected.

Subsequent requests use `Authorization: Bearer <access_token>`. The server verifies signature, issuer, audience, scope, expiry and active session identity. `POST /api/control/disconnect` with `{}` revokes that token only; other controllers and VNC windows remain active. Daemon restart invalidates outstanding tokens. RV shares one HTTP/2 client across each phone's operations, renews authentication before expiry, and retries authentication after outages. Submitted and queued mutations are not replayed on recovery. This is a local password-to-Bearer exchange, not a complete OAuth authorization server. The LAN transport stays plaintext h2c as requested; JWTs are signed, not encrypted.

RV's homepage owns the control lifetime for each saved device, reads device metadata and foreground state independently, and uses the same control session for App environment/backup/profile actions. Opening or closing a remote desktop window does not change homepage availability. Passwords reuse RV's existing encrypted SQLite storage; no new password file or keychain dependency is introduced.

Existing VNC-window capabilities still advertise a version-2 token tied to that VNC connection for their retained controls. They do not own or revoke the independent version-3 JWT sessions.

The configuration key/CLI flag `ZXTouchPort` / `-zxtouch-port` is retained as a port setting. Clients using the old task socket framing must migrate to HTTP URLs; there is no legacy socket listener.

## Karing

`/api/karing/<path>` strips only `/api/karing` and proxies to the phone loopback controller discovered from Karing AppGroup `service_core.json` (default 127.0.0.1:3057). The local Karing secret is injected as the upstream Bearer token; it is not sent to RV.

Method, encoded path, query, request bytes, response status, end-to-end headers and response bytes are preserved. The proxy performs no JSON schema conversion, field filtering, retries, redirects, decompression, mode validation, read-after-write verification or failover. HTTP hop headers and the incoming control Authorization/Host are replaced as required for proxying. Upstream connection failures return HTTP502; Karing HTTP errors pass through unchanged.

Examples: `GET /api/karing/version`, `GET /api/karing/proxies`, `PUT /api/karing/proxies/<encoded group>`, `PATCH /api/karing/configs`, `GET /api/karing/traffic`, `GET /api/karing/logs?level=error`. Traffic and logs stay as streams; client cancellation closes the upstream connection. WebSocket Upgrade is not proxied; use Karing's regular HTTP streaming forms.

The separately signed [Karing native helper](../vendor/karing/native/README.md)
adds `POST /api/karing-native/status`, `/config`, `/profiles` and `/reload`, each
with `{}`. Reads return complete native data under `data`; full config/profile
responses include private configuration and must not be logged. Reload submits
one native restart and verifies changed core startTime plus unchanged config;
unknown results return HTTP 504 without replay. Existing control authorization
applies. These routes do not alter the raw `/api/karing/*` forwarding behavior.

## Native services

All native actions use `POST`, `Content-Type: application/json`, plain JSON request/response bodies, and named URLs. There is no numeric task, base64 request, CRLF framing or `;;` decoding on the network.

| URL | JSON body / response |
| --- | --- |
| `/api/control/connect` | `{"password":"…"}`; JWT and capabilities |
| `/api/control/disconnect` | `{}`; revoke this JWT |
| `/api/control/authorize` | `{}`; authorization probe |
| `/api/apps/list` | `{}`; installed apps |
| `/api/apps/launch`, `/stop`, `/restart`, `/icon` | `{"bundle_id":"…"}` |
| `/api/apps/foreground`, `/api/device/home` | `{}` |
| `/api/device/clipboard` | `{"token":"<ack UUID>","text":"…"}` |
| `/api/apple/<native method>` | Native method parameters directly, e.g. `queryAccountState` with `{}` or `queryName` with `{"apple_id":"…"}` |
| `/api/app-state/<native method>` | Native method parameters directly, e.g. `listApps` |
| `/api/apple/result`, `/api/app-state/result` | `{"operation_id":"…"}` |
| `/api/apple/submit_code`, `/cancel_challenge` | Existing operation/challenge/code parameters directly |
| `/api/device/touch` | `{"touches":[{"type":1,"finger":0,"x":100,"y":200}]}`; type 0=end, 1=begin, 2=move |
| `/api/device/screenshot` | `{}`; raw `image/jpeg` |
| `/api/device/keyboard`, `/info`, `/toast`, `/vibrate`, `/alert`, `/ocr`, `/color`, `/colors`, `/image-match`, `/foreground-pid`, `/respring` | `{"fields":["…"]}`; native helper argument order |
| `/api/scripts/shell`, `/start`, `/stop`, `/api/device/sleep` | `{"fields":["…"]}`; stop accepts `{}` |

Generic native helpers retain their existing argument order as a JSON array; their text result is returned as `{"value":"…"}` without delimiter replacement. Touch clients keep their HTTP connection alive, await begin/move/end requests in order, and receive cleanup on TCP disconnect. Internal SpringBoard IPC/native helper identifiers remain private implementation details.

Long operations return an operation record with `operation_id`, then clients query `/result`, or subscribe to the App-state stream below. Disconnect does not replay a submitted write. RV explicitly disables HTTP retries and redirects, uses finite native request deadlines and reports interrupted mutations as unknown.

## Generic OCR-frame-bound tap (3.2-331)

`POST /api/control/authorize` advertises `device_tap:1`. Coordinate OCR replies include `frame:{width,height,orientation}` captured with the image; orientation is the ZXTouch normalized quadrant0–3. Independent authenticated `POST /api/device/tap` takes `{x,y,frame}` in those native screenshot pixels, validates the frame against current orientation/size on main, and presses/releases once using the shared native HID generator. No VNC input or Photos method is invoked. Success is `{ok:true}`; execution rejection is `{error:reason}` (inspect the body, not HTTP200 alone). Invalid parameters return400. In-flight response ownership permits checking request cancellation before dispatching touch-down; a dispatched finger is still released on cancellation.

RV's Photos deletion observer is host-side orchestration: FileTransfer submits/queries deletion, separate HTTP/2 OCR/tap handles a matching confirmation dialog. No task ID, asset ID or Photos-delete state is sent to the generic tap endpoint. RV stops the observer on the original operation's terminal result/disconnect and never replays a mutation. Only explicit Photos delete starts this observer; ordinary file deletion is unchanged. Unsupported capabilities/unrecognized prompts remain manually confirmable. The new endpoint awaits device acceptance.

## App-state error diagnostics (3.2-330)

Completed failures include the bounded native localized `error.message` plus original worker `source_domain` and `source_code` when available. These fields preserve the specific error behind facade code2; arbitrary NSError userInfo and operation payloads are not exported. Native descriptions may contain relevant filesystem paths. The delete progress stages are `delete/validate` and `delete/remove`; the initial `prepare/prepare` snapshot alone does not identify a failed step. RV records the error fields and operation ID to its existing console logger.

## App-state failure recovery (3.2-329)

Completed native codes2/3 report a definite failure, including partial filesystem changes; code4 reports an unknown outcome. These outcomes terminate the individual operation and never permanently block later explicit requests. Actual active execution still excludes concurrent mutations, and late lifecycle completion releases its pending gate. Unknown operations are never automatically replayed. Restore copy errors may include safe reason `file_copy_failed` and bounded numeric `posix_code`.

Deleting a backup or baseline removes its archive only. Current/pending references are detached when applicable; incomplete live data retains `restorePending`, so it cannot overwrite a complete backup. Switching with `discard_current` can explicitly recover that live state.

## App-state progress stream (3.2-328)

`/api/control/authorize` advertises `app_state_stream: 1`. Authenticated `POST /api/app-state/stream` accepts the native request envelope: `{"action":"invoke","method":"save","params":{"bundle_id":"…","name":"…"}}`, or `{"action":"result","operation_id":"…"}` to observe an existing operation without executing it again. The response is HTTP/2 `application/x-ndjson`, with `{"event":"state","record":{…}}` and five-second `{"event":"heartbeat"}` records. An HTTP 200 starts observation; only the completed operation record establishes the outcome. Initial state and subscription are atomic. Completed cached results return immediately, and the first terminal result remains final despite late callbacks.

Only sanitized phase/stage/count progress is exported. Slow receivers get coalesced latest progress (200ms cadence); the terminal record is retained until queued or disconnected. Subscription lifetime is bounded to 600 seconds, checks session authorization, and disconnect removes the observer without cancelling or repeating the native operation. Native result retention remains 600 seconds; reconnecting reads the current snapshot rather than replaying every intermediate progress sample.

RV consumes progress as HTTP/2 DATA arrives and ends waiting on the completed record, without waiting for EOF. Early EOF/transport failure is unknown, preserves a received operation ID, and never replays invoke. Query connection failures keep the explicit query entry instead of declaring the original mutation failed. Servers without the capability retain the existing result polling path. This stream applies to App-state/task32; the separate Apple-operation stream design is not advertised as implemented.

Host checks: `bash tests/run_app_state_stream_tests.sh`, `bash tests/run_app_state_socket_tests.sh`, and RV `cargo test -p rv-session`. Native mocks cover coalescing, terminal backpressure, late callbacks, disconnect, authorization and observing the same operation without a second invoke; RV uses a real local HTTP/2 peer to verify progress before completion and terminal handling before EOF. These are not live-device acceptance tests.

## Build and validation

`rustup target add aarch64-apple-ios` is a one-time prerequisite. Theos `before-all` runs `control-http/build-ios.sh`; its locked Hyper/Tokio static library links into the native daemon. HTTP framing, streams and flow control are handled by Hyper/h2, rather than a custom HTTP/2 parser.

```sh
cargo test --manifest-path control-http/Cargo.toml
python3 control-http/tests/live_integration.py --report control-http/tests/reports/device-http2.json
```

The retained USB test builds, signs and trusts a temporary iOS loopback probe (mobile sudo password can be supplied via `--sudo-password-stdin`) using the production HTTP/2 engine, proxy and Karing settings discovery, then cleans it up. It compares live Karing bodies/statuses to direct access, checks DNS/traffic, authorization rejection and raw body preservation. Its authorization callback is a probe fixture; it does not claim deployment of the production VNC/native facade. Unit transport tests cover binary/status/header/query preservation, redirects, continuous stream multiplexing/cancellation, body bounds and shutdown. RV native challenge and non-replay regressions run against an HTTP/2 peer.

The older `vendor/karing` typed protocol/probe and task socket tests remain historical fixtures; they are not the production forwarding path. Standalone Python scripts using the old task client also require migration before calling this server.

## Screen lock/unlock streams

RV screenshots continue exporting its local VNC framebuffer. Phone-side `POST /api/device/screenshot` remains available independently and returns JPEG.

The daemon advertises `http_screen_control: true` in VNC capabilities. RV uses the following authenticated HTTP/2 routes when advertised; older servers retain the existing VNC unlock/lock flow. Transport failures never automatically fall back or replay a submitted screen mutation.

- `POST /api/device/unlock`, JSON `{"passcode":"<six digits>"}`.
- `POST /api/device/lock`, JSON `{}`.

Both return `application/x-ndjson`, one JSON event per line as work progresses. Unlock phases are `preparing`, `input_ready`, `entering`, `checking`, then `unlocked` or `failed`; lock phases are `locking`, then `locked` or `failed`. Terminal success contains `state` with the actual observed `locked` boolean; failures carry `error`. An HTTP 200 only starts the stream and does not mean the operation succeeded. Busy rejection is a terminal `failed` event. Invalid passcodes return HTTP 400 before starting a stream. Existing session Bearer authorization and control/view-only restrictions apply.

One native screen operation runs at a time and rejects active legacy unlock leases. Two ready/empty keypad samples are required before one six-digit input; the existing eight-second attempt interval remains. An already unlocked phone needs no input, and locking an already locked phone never toggles it awake. Native processing is bounded to 12 seconds. Cancelling the response stream stops subsequent digits and delayed wake/swipe/Home work; a digit already dispatched completes its release. Disconnect, timeout and early EOF may leave partial input or an unknown result; RV reports this and never retries automatically. Passcodes are not included in progress, logs or retained failure events, and RV still uses its existing local passcode configuration without keychain storage.

Regression commands:

```sh
rtk proxy bash vendor/zxtouch/tests/run_control_auth_tests.sh
rtk proxy bash tests/run_screen_http_tests.sh
rtk proxy cargo test --manifest-path control-http/Cargo.toml
rtk proxy cargo test --manifest-path ../rv/Cargo.toml -p rv-session
rtk proxy cargo test --manifest-path ../rv/Cargo.toml -p rv-app unlock_ui
```

Native runner tests use deterministic screen/HID primitives; HTTP and RV tests use real HTTP/2 peers for fragmented progress, cancellation, bounded buffering, observed terminal state, early EOF and no replay. These checks do not claim a successful passcode unlock on a physical phone.
