# Phone control transport

See [HTTP API and integration](../docs/control-http.md).

Hyper/h2 handles HTTP/2 framing/multiplexing and forwards Karing bodies as streams. A C ABI invokes the existing Objective-C dictionary/native facades. No task socket framing is used by the daemon or RV.

- `cargo test --manifest-path control-http/Cargo.toml`
- `python3 control-http/tests/live_integration.py --sudo-password-stdin`
- iOS build prerequisite: `rustup target add aarch64-apple-ios`
- Simulator prerequisites: `rustup target add aarch64-apple-ios-sim x86_64-apple-ios`

[Retained device report](tests/reports/device-2026-10-12.json): 11 PASS. The isolated iOS probe exercises the production engine, settings discovery and live Karing upstream; it does not deploy the VNC/native authorization facade. Unit tests cover raw method/query/binary/status/header preservation and stream cancellation. RV regressions include refused-stream no-replay.
