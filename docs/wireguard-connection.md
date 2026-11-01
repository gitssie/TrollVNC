# WireGuard startup and connection status

TrollVNC starts a handshake immediately for peers with a configured Endpoint. It does not wait for PersistentKeepalive or an inbound service request. Configured keepalive values are preserved.

BoringTun retries within a handshake cycle. If it reports ConnectionExpired, the bridge explicitly initiates another cycle for configured outbound peers; restart attempts are bounded to at most one per five seconds per peer. Passive peers without a configured Endpoint are not made proactive by a learned endpoint.

The local management status command adds WireGuardConnected. It is true only while the worker is alive and at least one peer has a non-expired authenticated handshake younger than 180 seconds. This reports handshake validity, not application reachability or that all peers are available. The UI says Waiting for handshake until then, and Handshake established afterward. A lost network cannot always be detected immediately; expired handshakes stop reporting success. This live field is added only to the management response and is not persisted in the runtime snapshot.

Host checks:

```sh
sh tests/run_wireguard_tests.sh
bash tests/run_zxtouch_tests.sh
```

The test-clock feature is test-only; normal iOS builds use the real monotonic clock. Regression tests advance time through two unanswered retry cycles and complete an authenticated UDP handshake when the peer returns. Existing tests cover encrypted TCP service forwarding, stop/restart, half-close, backpressure and allowed source addresses. UI-state tests cover started-without-handshake, connected, expired/waiting, disabled and stopped states.

The local status command also waits for delayed/fragmented input on nonblocking accepted sockets, within one two-second deadline. This prevents an early ERR Empty response when querying status through an SSH forward and allows the UI to read live handshake state.

Device verification (2026-11-01): installed 4.0-19 on the previously verified iPhone13. Before installation, WireGuard access to 10.8.0.7:6000 and :5901 timed out; the local engine reported started. After installation, live management status reported WireGuardConnected=true and both services were reachable through WireGuard. Python SDK authenticated over the tunnel and queried device info and public IP; VNC returned its RFB banner. Phone preferences retained the exact pre-install SHA256, including the existing120-second keepalive setting; all145 existing backup file hashes also remained unchanged. Host tests cover repeated offline recovery; no deliberate live VPN switch was performed. UI state selection was host-tested and its preference bundle built; the visual appearance was not separately inspected on the device.
