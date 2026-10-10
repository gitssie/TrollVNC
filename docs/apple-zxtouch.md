# Apple services over ZXTouch

Task **31** extends the existing ZXTouch listener (default port 6000). Its entire payload is one Base64-encoded UTF-8 JSON object; the response is `0;;<Base64 JSON>\r\n`. Base64 is framing, not encryption. Existing commands remain unchanged. Use the existing controlled network path: this protocol inherits ZXTouch's lack of an authentication handshake and is not authenticated by the VNC password.

`src/TVNCAppleService.mm` adapts requests to one persistent `TVAppleServices` instance. `vendor/apple` does not depend on sockets or TrollVNC. No shell command or UI automation is used. `vendor/apple/apple.mk` supplies sources; the daemon now has its own entitlement file instead of a symlink to the app's entitlement file. Native permission checks still apply. SearchParty's separate privileged recovery helper must already be deployed as described in the Apple module documentation.

## Client usage

```python
from zxtouch.client import zxtouch

device = zxtouch("PHONE_ADDRESS")
op = device.apple.invoke("queryState")
state = device.apple.wait(op["operation_id"])
print(state["result"])
```

`invoke` starts the operation and immediately returns `operation_id`, `method`, and `status`. `result` reads its current state. `wait` queries progress until completion or a login verification challenge; it never fetches codes or retries a mutation. Client timeout leaves the operation running; retain the ID and call `result` again, including after reconnecting.

```python
op = device.apple.invoke("signInAppStore", {
    "apple_id": apple_id, "password": password,
})
state = device.apple.wait(op["operation_id"])
if state["status"] == "requires_verification_code":
    device.apple.submit_code(op["operation_id"],
        state["challenge"]["challenge_id"], externally_obtained_code)
    state = device.apple.wait(op["operation_id"])
```

Submission `accepted=true` means the code was handed to the native flow, not that Apple accepted it. `cancel_challenge` cancels only the outstanding login code input, not a submitted native mutation. No general mutation cancellation is exposed.

Email verification is a different flow: invoke `beginAddingContactEmail`, wait for completion with `result.outcome=requires_email_verification`, then invoke `verifyContactEmail` using its `result.challenge_id` and the email code. The same service keeps this session alive for 300 seconds; conflicting mutations return `email_verification_pending`. Successful verification allows the subsequent `setForwardingEmail`.

## Methods and required params

| Method | Required params |
| --- | --- |
| queryState | none |
| signInAppStore | apple_id, password |
| enableICloud | apple_id, password, device_passcode |
| signOutAppleID / signOutICloud | apple_id, local_data_policy (`remove` or `keep`) |
| disableFindMy | apple_id, password |
| queryName / queryEmail | apple_id |
| setName | apple_id, first_name, last_name |
| beginAddingContactEmail / setForwardingEmail | apple_id, email |
| verifyContactEmail | apple_id, challenge_id, code |
| querySignInWithAppleApps / queryICloudDevices / removeOtherICloudDevices | apple_id |
| stopUsingAppleID | apple_id, bundle_id |

Unknown methods, missing/extra fields and non-string params are rejected. Local-data policy is explicit; there is no implicit merge. One native operation runs at a time; overlapping invocations return `busy` rather than queueing credentials. Completed records are retained in memory for 600 seconds, with a maximum of 64 retained records. A full store rejects new invocations instead of evicting an unexpired result. Email addition reserves the last slot for the separate verification call; intervening reads cannot consume that slot. IDs cannot survive daemon restart and should be treated as opaque capabilities; no enumeration endpoint exists.

Completed operations contain native `result` and/or sanitized `error` (domain/code only). Check both: partial native results and `unknown` must not be treated as success. The native shared unknown-result write fence remains in effect; read-only queries stay available. Request/credential data are not included in operation records or logged. Disconnect does not cancel/replay operations; service shutdown rejects new work and invalidates pending login input without claiming native cancellation.

## Validation

2026-10-07 installed 3.2-308 phone checks through the Windows relay: complete
signOutAppleID succeeded and a fresh query confirmed no selected cloud/identity/media
accounts. The known Accounts/17 dataclass warning remains separate. A new target
signInAppStore operation completed its trusted-device challenge and succeeded;
fresh queries confirmed both media and identity belong to the requested target.
`tests/AppleSocketDeviceLogin.py` accepts privately entered passwords/passcodes and
externally retrieved codes only. Run curl separately; neither this harness nor
the native module accepts a code URL or retrieves/polls for codes.

The following enableICloud operation returned unknown. Sanitized system logs showed
HTTP409 and com.apple.appleaccount/403 before CoreCDP. An independent native tool
failed in the same stage; temporary alert classification reported account_limit
and activation. All callbacks completed, and repeated fresh reads confirmed no
selected iCloud account with Find My false. Do not repeat activation to solve a
quota prompt. Apple documents activating the account on another Apple device or
using an account already set up with iCloud:
https://support.apple.com/en-us/101661 . Name/email/SIWA/device queries returned
Conflict (7) in this partial-login state; their mutations are not verified by this
run. Reconnect/result retention and aggregate account/schema assertions passed.
Temporary diagnostic programs were removed, with no credentials or response bodies
retained. Full iCloud-dependent socket acceptance awaits an eligible account.

Installed 3.2-309 follow-up: signOutICloud returned succeeded/already_signed_out=1
with no completed removals, and fresh queries preserved target media/identity.
The numeric idempotence flag is truthy; a test initially requiring Python identity
`is True` falsely failed, so the original operation was read again rather than
replayed. disableFindMy returned succeeded/already_disabled=true while native
Find My was already false. This validates the idempotent branch only, not a new
enabled-to-disabled password authentication cycle. No further iCloud activation
attempt was made after identifying the quota alert.

At the user's subsequent explicit request to sign everything out and log in again,
the reappeared old primary cloud/identity and the requested target's identity/media
were signed out in two successful targeted operations with remove policy. Fresh
state verified selected_accounts empty, all three domains not_signed_in and Find
My false. Store login then succeeded in operation 4B0F0705-FDE0-48C2-B584-7F56E1C0C1F6.
The explicitly requested new iCloud attempt
8854BEE5-9FF3-45BA-8287-7845805A1871 completed unknown; sanitized native logs at
2026-10-07 12:48:09 UTC confirmed the same HTTP409 / com.apple.appleaccount403
validation failure. Fresh verification confirmed media/identity both match the
requested target, cloud absent, no selected old account and Find My false. This
is partial login, not successful iCloud enablement. The login harness now also
checks the exact target identity in cloud/identity, rather than just signed_in.

Run `rtk proxy bash tests/run_apple_socket_tests.sh` from TrollVNC: production adapter tests plus real TCP tests with the production ZXTouch transport and Python client, substituting only the native Apple facade. Covered: busy rejection, reconnect, code challenge/submission/cancellation, leading-zero codes, repeated/wrong input, client timeout, sanitized native errors, duplicate completion, shutdown, and framing with Unicode/CRLF/semicolon data. Native account mutations are covered separately by `vendor/apple/tests/run_tests.sh` and its documented phone checks; host socket tests do not prove iOS account permissions or server outcomes.

For an isolated phone listener, build `rtk proxy bash tests/build_apple_socket_probe.sh /tmp/apple-socket-probe`, upload with `vendor/apple/tests/device-scp.sh`, install/sign/trust as documented for Apple tools, then run through `device-ssh.sh /usr/bin/apple-socket-probe 6007`. It binds loopback only. Forward the test port over the already verified SSH connection and use the same Python client; remove the probe after testing. This uses the production adapter/transport/native facade and the daemon's entitlements but does not replace the live TrollVNC process. The probe supports real account commands, so verification should explicitly use read-only queries unless a mutation test is intended.

2026-10-07: host adapter and real TCP client tests passed, along with the full Apple module and existing ZXTouch regressions. The complete RootHide arm64 trollvncserver compiled, linked and signed. An isolated on-phone listener using the production native facade and daemon entitlements accepted queryState, retained the operation across a socket reconnect, and completed without error: App Store/iCloud/identity signed_in; Settings name/email/Sign in with Apple sections available. This verifies native query permissions in the isolated host, not new socket-driven account mutations or replacement of the installed daemon. The phone probe was built before the final capacity guard; that guard was subsequently covered by host tests and the final arm64 daemon rebuild.

2026-10-10：operation.error 在 domain/code 外增加可选 message，由 TVAppleDiagnosticMessage 仅导出 Apple 模块自建错误说明；不透传原生 userInfo/description、输入、请求 URL 或认证对象。已在当前设备真实 task31 queryEmail 复现旧服务丢弃错误说明，与独立原生工具错误对照一致。旧操作已丢弃的说明无法补取。新代码编译不等于当前手机服务已加载，需更新服务后再验收该字段。

2026-10-10 重新绑定初始化：用户主动再次beginAddingContactEmail时，服务串行核对当前账户，清空旧原生challenge/model及认证/签名会话，重新准备原生认证环境并fresh读取reachable_emails；目标已经验证则返回succeeded/already_verified，未绑定才发新请求与新challenge。只允许同一Apple ID的邮箱begin/verify未知结果通过新begin恢复，且新begin成功后才解除邮箱专属unknown标记；其它写操作未知结果不因此解锁。task31允许同账户替换旧邮箱挑战，旧challenge立即不可提交；busy仍拒绝并发，结果历史继续保留。RV提供独立「重新发送绑定」命令，保持原资料并刷新新邮件基线，旧验证码不自动重放。只读取码按钮仍不发新邮件。主机回归/编译与真机绑定验收区分，新恢复流程尚未进行真机账户写入验证。

## App Store 首次 Review 自动分支（2026-10-10）

现有 task31 `signInAppStore` 不新增参数：

```python
operation = device.apple.invoke("signInAppStore", {
    "apple_id": apple_id, "password": password,
})
result = device.apple.wait(operation["operation_id"], timeout=600)
```

遇到 `requires_verification_code` 仍通过原来的 `submit_code` 提交对应挑战验证码，再继续等待同一 operation。`wait` 不自行取码或提交验证码。

原生 AuthKit 取得 AKPassword 后调用 Store。若服务器返回首次 Review 路由，继续原生预转换认证、SAP priming、账单校验和单次最终转换。iOS 用 Foundation NSURLSession 直接 POST `https://www.meiguodizhi.com/api/v1/dz`，JSON 为 `{"city":"","path":"/","method":"refresh"}`；仅提取街道、城市、州、邮编及美国电话号码，电话拆为区号和七位号码。忽略工具返回的银行卡、个人姓名等其它数据，保留 Apple 原有姓名，国家 USA、支付 None、同意条款。普通已开通账户不请求地址、不重新提交 Review。

调用此登录入口授权自动完成首次 Review、同意条款及保存生成的美国账单地址。账单获取或 Apple 校验失败即返回错误；不重试最终提交。整个操作保留在同一 operation，断线可重新查询 result。成功结果包含 `authenticated=true`、`review_completed`；新转换另含 `payment_method="None"`、`billing_address`（Apple 六字段）。转换成功后若单独的 Store 登录失败，保留 `review_completed=true`、stage=`post_review_store_login`；超时结果为 `outcome=unknown`，不声明 authenticated=false，不重放转换。

实现位于 `vendor/apple/src/appstore/TVAppleStoreSignIn.m`，经 NativeBackend → Services 接入现有 socket 登录入口。主 daemon 签名增加与真机成功探针一致的 `fairplay-client`。SAP 和设备头仍由 Apple 原生框架处理。原生流程与参考见 [native-store-review.md](../vendor/apple/docs/native-store-review.md)。此接入已用另一个未开通账号完成独立 ZXTouch 服务真机验收；仍未替换运行中的正式 TrollVNC 包。

2026-10-10 新账号完整验收：媒体退出成功 → 同一 task31 登录请求/SMS submit_code → iOS 自动取址 → 原生 Review/None 保存 → Store 登录 succeeded/authenticated=true/review_completed=true。queryAccountState 确认新媒体 active/authenticated，原 iCloud 保留。预转换 type3 在合法服务器路由及原生 context 齐全时是可续接分支，不能当作最终完成。只检查 selected media 切换冲突，不要求退出不同的 iCloud/identity。
