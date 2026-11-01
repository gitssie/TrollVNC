# Device public IPv4

`POST /api/device/public-ip`, authenticated using the existing ZXTouch control token, accepts an empty JSON object. Capability: `device_public_ip=1` from `/api/control/authorize`.

The phone queries `https://ipv4.is` with an ephemeral, cache-disabled NSURLSession. The service returns plain text; only a valid IPv4 is accepted. No host-side fallback or previously successful IP is used. Request timeout is 12 seconds and resource timeout is 15 seconds. A success describes the egress of this one request, not a guarantee that a later request uses the same network.

Success (HTTP 200):

```json
{"ok":true,"ip":"203.0.113.42","ip_version":4,"source":"https://ipv4.is","checked_at":"2026-10-31T12:00:00Z"}
```

Query failure (also HTTP 200):

```json
{"ok":false,"ip":null,"source":"https://ipv4.is","checked_at":"2026-10-31T12:00:00Z","error":{"error_code":"network_unavailable","message":"Phone could not query its public IP; the network or VPN may be changing","retryable":true}}
```

Codes: `timeout`, `network_unavailable`, `network_error` (retryable); `tls_error`, `invalid_response` (requires investigation); `upstream_http_error` (includes `upstream_status`, retryable for 408, 429 and 5xx). Network errors cannot establish whether a VPN switch caused them.

The Python SDK exposes `device.device.public_ip()`. If its control connection drops or times out, the SDK returns `device_unreachable`, `ip=None`, `retryable=True`, with an SDK-generated `checked_at`. It never retries automatically. Authentication and unsupported-route errors remain exceptions. The SDK constructor still raises connection errors before a client exists.

Validation: native result tests cover IPv4 parsing, malformed/NUL/IPv6 responses, HTTP status and URL network/TLS errors; SDK tests cover both network legs and no replay. These simulated failures do not establish live-device VPN transition behavior.

Device deployment (2026-10-31): installed TrollVNC 4.0-18 on the previously verified iPhone13 (iPhone14,5). dpkg reports install ok installed; Shadow 4.0.6 and HookKit 3.0.6-1 remain installed. Authenticated Python SDK query returned device_public_ip=1 and a valid IPv4 result from the phone. All 136 pre-existing backup files retained their SHA256 hashes after installation. No VPN transition was performed; live transition failure behavior remains unverified. Temporary uploaded package and verification files were removed.
