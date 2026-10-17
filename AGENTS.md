## 2026-10-17 / 4.0-2: first Dopamine 3 device install

User explicitly authorized installation on the USB-forwarded phone. Verified
previously pinned SSH key, iPhone9,2/iOS15.8.8 and Dopamine basebin3.0.11.
4.0-1 exposed Procursus visudo missing its private library search path; visudo
itself is installed/functional.4.0-2 scopes DYLD_LIBRARY_PATH to the fixed
/var/jb/usr/libexec/sudo directory for visudo only, checks library existence,
retains sudoers validation/atomic replacement and adds no trustcache workaround.
Ten installer regressions and independent fix review pass; package build passes.

Installed4.0-2 plus missing ldid/libplist3 dependencies; dpkg install ok installed,
sudoers parsed OK. One SpringBoard reload. Service persists with one launch/no
exit; VNC handshake348x620, HTTP2auth/authorize/info/apps/screenshot/disconnect,
actual scoped-worker read-only Karing catalog and native Karing config/status pass.
Notification socket mobile-owned0700parent/0600socket. No new startup/probe error
lines. No account writes, backups/restores/IDFV mutation, Karing reload, Photos
writes or input/delivery acceptance. Detailed evidence:docs/dopamine3.md.
Credentials/tokens held only in memory; uploaded installers/temp probes removed,
SSH/control sessions closed. Installed service left running. No repo publication.

## 2026-10-17: Dopamine 3 only development

This branch targets Dopamine 3 standard rootless only (first development package
4.0-1, iphoneos-arm64). Use standard `/opt/workspace/github/theos`, with
`THEOS_PACKAGE_SCHEME=rootless`, `THEBOOTSTRAP=` and `THEOS_DEVICE_SIMULATOR=`.
Do not reuse historical RootHide build, install, trust or device-acceptance claims
below. Reference source is `/opt/workspace/github/Dopamine`, 448ff1a (3.0.11).
Package paths use rootless resolution; real system/container/backup paths stay on
`/var`. Scoped workers no longer need `.jbroot` dependency anchors. Notification
socket uses the short `/var/jb/var/mobile/.tvnc-run/n.sock` alias on both ends.
See `docs/dopamine3.md`. No publication, phone installation or restart in this task.
Final standard-Theos build/package passed:218 entries numeric0:0,172 regular
control/data files match staging bytes/modes, all payload under/var/jb. Recovery
helper4755, other helpers0755; both adapters have arm64+arm64e, no RootHide dylib
dependency. Actual package repository rendering validates in a temporary directory.
Installer/maintainer9, repository7, App-state native/socket, Apple and Karing native
host suites pass; two independent reviews found no important blockers. Device
runtime acceptance remains pending; do not infer it from host/build evidence.

## 2026-10-17: remove location privacy module

User removed `vendor/privacy-guard` because location manipulation is outside
TrollVNC's project scope. Its source/tests, locationd injection, CLI, settings
bridge/switch/translations, build integration and sudoers installer are removed.
Earlier privacy implementation instructions are superseded. No device cleanup or
repository publication is implied by this source change; already installed versions
retain their behavior until updated and their loaded module is unloaded/restarted.

Validation: five installer regressions and settings-model checks (37 retained
settings) pass; plist/localization and maintainer-script syntax checks pass. Clean
RootHide package build passes; all 216 archive entries have numeric owner 0:0,
with no removed-module filenames or symbols in control/data payloads. Independent
removal review found no important blockers. Local build only, no publication.

## 2026-10-16 / 3.2-338: no Cache storage

User explicitly removed disk photo receipts: Photos tasks/results now live only in
the existing bounded memory registry. Restart/expiry yields an unavailable/unknown
result, deliberately different from RV's old exact TaskNotFound error so a missing
memory entry cannot imply an import was never submitted. Never auto-replay imports.
Notification contents remain memory-only; shared socket path now resolves inside
RootHide's /var/mobile/.tvnc-run/n.sock, with adapter/server sharing one definition.
Verified phone bootstrap /var/mobile resolves inside bootstrap, not real mobile.
New adapter retires only the owned legacy cache socket after binding successfully;
adapter reload/respring is needed after update. Old photo receipt directory may be
cleared in varClean after update; no more receipts are created. Singleton markers
also leave Caches: validated uid-private temporary directory, openat/O_NOFOLLOW,
owner/type/nlink/mode checks and no privilege-crossing fchown. Adversarial tests pass.

## 2026-10-16 / 3.2-335: explicit WireGuard activation and final lifecycle fixes

User clarified network IP rows must have one icon-only button copying the raw IP, not duplicate VNC/ZXTouch endpoint actions. Removed copy/add explanatory captions and shortened restart notes. First configuration save explicitly leaves WireGuardEnabled=NO; editing preserves the existing switch state. Disabled saves only persist configuration, with no service restart; editing an enabled configuration restarts running services once. Only the network switch enables/disables the interface.

Review fixes: WG table refresh tracks displayed service liveness/running state and ServerPID, guards row indices and verifies the displayed row kind before acting, preventing stale address/remove rows after process exit from crashing or triggering a shifted destructive action. RV releases photo_busy/revision on connection teardown and reports incomplete Photos work without rewriting a committed import as failed; host regression passed and rv-app test type-check passed. No phone operations or installation performed.

RootHide335 builds with the final IP-copy/default-off changes. Package216 entries root:root,169 payload files match staging content/modes, helper4755. Published to the existing foreground local Sileo server; all five repository files match byte-for-byte over LAN.

## 2026-10-16 / 3.2-334: WireGuard setup and restart feedback

Unconfigured WireGuard shows one Add configuration entry rather than a disabled switch plus separate empty status/details rows. Configured state places status/icon directly below the switch, keeps configuration details and a single live IP/copy row, and retains explicit removal confirmation. Shared native settings cells, Dynamic Type and system colors are reused.

Port/listen edits explicitly require Restart on Home. WireGuard toggles/removal retain automatic restart; the page shows a spinner while observing the replacement PID, live services and matching reported enable flag, then confirms completion (or exposes the actual WireGuard start failure). A20-second observation deadline releases the switch and reports an unconfirmed restart without replaying it. When services were already stopped, settings are saved and the UI explicitly asks to start from Home. Polling is limited to visible restart observation and stops on departure/completion. Config-save notices distinguish automatic restart from a stopped service. Existing interface-running status does not claim a verified peer handshake.

RootHide334 build, bilingual strings/plist lint and diff checks pass. Package216 entries root:root, all169 staged files match bytes/modes, recovery helper4755. Published through existing foreground local Sileo server; all five repository files match via LAN. No phone installation or UI automation performed.

## 2026-10-16 / 3.2-333: compact network addresses and About

Network settings displays each local/WireGuard IP once, with independent native VNC/ZXTouch copy buttons that still copy the full host:port using the live service ports. WireGuard running status no longer repeats its IP; configuration and error state stay separate. About removes the source-link action (including the legacy preference entry/handler), adds a concise feature/connectivity description, and retains version, author and GPLv2 attribution. English/Chinese strings updated.

RootHide333 builds with the shared controllers for arm64/arm64e; plist/string lint and diff checks pass. Package216 entries root:root, all169 staged payload files match content/modes, recovery helper4755. Published to the existing ordinary foreground Sileo server, all five repo files verified byte-for-byte through LAN. No phone installation or UI automation performed.

## 2026-10-16 / 3.2-332: Photos navigation capacity recovery

Completed Photos tasks were retained for ten minutes and incorrectly counted as pending work against the 64-task admission limit. Serial album browsing (multiple transport pages per view) could therefore exhaust admission without any active backlog. PhotoJobRegistry.inc now counts only unfinished work for admission, bounds completed memory results to the latest64 with the existing TTL, preserves active work, and loads durable import receipts directly without growing the memory cache. Photos delete and independent ZXTouch confirmation remain separate.

RV navigation is single-flight: atomic FileTransferClient admission publishes busy before another click/client clone can submit, menu callbacks ignore selection while busy, the standard button loading effect and left-bottom status spinner show progress, and overlapping view requests are discarded rather than queued. Failure clears busy and permits a fresh explicit selection; no automatic request replay. Internal transport pagination stays sequential.

Foundation-only production registry regressions cover2,000 completed serial requests, bounded result retention, true active saturation, and recovery. RV Photos/lifecycle/admission regressions and app test type-check/style pass. RootHide332 builds and is published to the existing local Sileo server;216 entries root:root, all169 payload files match staging content/modes and helper4755. All five repo files match over LAN. No device installation, UI automation or phone mutations performed.

## 2026-10-16 / 3.2-331: independent HTTP/2 tap and RV Photos orchestration

Normal VNC remote input stays unchanged. Phone PhotoLibrary deletion source is unchanged: no Photos-specific ZXTouch endpoint, task registry, claim or coupled delete/tap function was added. RV starts a cancellable observer only after FileTransfer accepts a Photos delete task; it uses HTTP/2 OCR, matches the requesting daemon plus delete-photo text and the paired deny/delete button row, then sends one generic POST /api/device/tap. Ordinary file deletion, Photos import/list/export and view-only sessions do not start it. Original FileTransfer terminal result remains authoritative; a successful tap is not a successful deletion.

Generic tap takes x/y and the OCR frame {width,height,orientation}, advertises device_tap:1 via authorize, validates bounds/frame on main, and emits a native HID press/release without VNC transport. It rejects active touches or cancelled requests, uses a response producer to detect request-stream cancellation before queued down, and completes release after a dispatched down. OCR frame metadata comes from the same snapshot capture. RV never replays the tap or deletion when recognition/transport fails. Prior raw /device/touch live tests recognized the dialog but failed to activate it; the only live dismissal was the removed VNC comparison and does not validate the new endpoint. New phone endpoint still requires real-device acceptance after update.

RV130 session tests passed, including real local HTTP/2 peer and lifecycle/recognition tests; targeted tests repeated after frame binding. Native cancellation transport regression and RV test type-check pass. RootHide331 package builds. Published to local Sileo using the existing foreground server; all five repository files verified byte-for-byte through LAN. Package212 entries owner0:0, all169 files match staging bytes/modes, helper4755. No new real-device deletion or UI test was performed for this implementation.

## VNC / ZXTouch transport boundary (user clarification)

Retain normal VNC remote screen, pointer and keyboard input. ZXTouch module calls must exclusively use authenticated HTTP/2; never use RFB input/device extensions or the historical ZXTouch TCP server as a fallback or live-test substitute. Production TVNCZXTouchService starts TVNCHTTPServer; historical TCP fixtures do not establish an active legacy production listener. Sharing native HID/capture helpers is valid and does not imply shared transport. Photos auto-confirmation uses ZXTouch HTTP/2 OCR/touch for an existing user-requested delete. The live prompt disappeared only after the now-removed VNC comparison; HTTP/2 touch still needs diagnosis and must not be reported as successful.

## 2026-10-16 / 3.2-330: preserve native App-state error diagnostics

The reported delete operation completed with code2 and only initial prepare progress. This proves a known worker failure, not its root cause. The adapter had discarded the worker's localized error description; it now preserves a bounded native error message and source_domain/source_code, without exporting arbitrary userInfo or request/result payloads. Worker propagates its original error domain/code through the facade. Delete reports validate before backend validation and remove immediately before archive removal. RV console includes these fields at ERROR level. Initial prepare remains a default, not evidence of the exact failed step. No live phone/UI tests or installation were performed. RootHide3.2-330 is published to local Sileo; existing foreground HTTP server reused, all five repository files verified byte-for-byte through LAN. Package212 entries have uid/gid0, all169 payload files match staging bytes/modes, helper4755. Native173+245+52+42 assertions and socket/stream tests pass; RV console capture tests and test type-check pass.

## 2026-10-16 / 3.2-329: recover after failed App-state operations

Removed permanent uncertainty latches in the socket adapter and native lifecycle facade. Only actual execution blocks concurrent work; explicit later requests are allowed after terminal failures or late completion. Native codes2/3 are definite failures even with partial-state flags; code4 remains unknown and is never automatically replayed. Archive deletion accepts current and pending targets, removes only the archive, detaches references, and preserves restorePending for incomplete live data. Restore copy failures now export a bounded numeric POSIX cause without paths.

Host-only validation covers terminal classification, follow-up requests, archive deletion, late lifecycle completion and errno propagation. RV switch/delete use one confirmation/progress/result dialog and refresh catalog after errors. No UI or phone operations were performed for this fix. Version329 supersedes earlier permanent-fence/current-archive deletion policies below. RootHide package329 is published to the local Sileo source; all212 archive entries have owner0:0, all169 payload files match staging bytes/modes, helper4755. All five repository files match via the LAN endpoint. The HTTP server is an ordinary foreground exec session, not an Orca Terminal or detached process. RV125 session tests, native173+245+52+42 assertions, lifecycle/helper/socket/stream regressions, RV build and test compilation, and UI style policy pass. Actual phone copy failure cause remains unverified; safe POSIX causes are now exposed for the next reported failure.

## 2026-10-15 / 3.2-328: App-state HTTP/2 progress

Published RootHide 3.2-328 to local Sileo source `http://172.16.20.203:18766/`, reusing the existing ordinary foreground HTTP service (no Orca Terminal). Authorization advertises app_state_stream:1; `/api/app-state/stream` accepts invoke or result envelopes and emits bounded NDJSON state/heartbeat events over HTTP/2. Atomic service subscription, coalesced progress, terminal backpressure, authorization/disconnect cleanup and first-terminal late-callback guards preserve the original operation; reconnect observes its cached snapshot without another invoke. Apple/task31 streaming remains a separate unimplemented design.

Native host stream and existing adapter checks pass; RV local HTTP/2 checks verify progress before completion, immediate terminal handling before EOF, and no request replay. Resume authorization failure remains unknown with a manual query entry, rather than marking the original mutation failed. RV's switch Dialog becomes the persistent progress/result/error panel after confirmation; the backup list contains environment records only. User performs UI/phone acceptance; no window automation, phone mutation or installation in this update.

Clean RootHide package built; all216 archive entries numeric owner0:0, all169 payload files match staging bytes/modes, recovery helper4755. Deploy verifies successfully, all five repo files including the328 deb match byte-for-byte via the LAN endpoint. RV compilation passes; third-party block0.1.6 future-compat warning remains unrelated.

## 2026-10-15 / 3.2-327: version baseline deletion

Published RootHide 3.2-327 to local Sileo source `http://172.16.20.203:18766/`, reusing the existing HTTP service. Explicit delete accepts a listed baseline version as well as an inactive snapshot. Worker routes baseline deletion to strict bundle/path/kind/version/format manifest validation; edit/profile remain snapshot-only. Current snapshot and the exact pending restore target cannot be deleted. Catalog maps `pendingReference` to `pending_backup_id`. Partial archive deletion keeps its uncertainty flag. Deleting a baseline allows explicit recreation of the same installed version; no automatic replacement or phone installation.

Host module checks pass (173 core, 245 mocked native keychain, 52 session, protocol/lifecycle/service/supervision suites). Full clean RootHide package passed; 216 archive entries owner0:0, all169 payload files match staging bytes/modes, recovery helper4755. RV displays baseline versions separately from snapshots, uses standard component menus and current-item check icon. Independent scoped review found no important deletion issue. User requested to perform UI/phone acceptance themselves; no computer-use testing or phone mutations performed for this update.

## 2026-10-15 / 3.2-326: iCloud terminal handling published locally

Published RootHide 3.2-326 to the existing local Sileo source `http://172.16.20.203:18766/`. Includes the iCloud provider-error/total-completion first-terminal gate, preserved definite failure across account-read failure, sanitized native domain/code, normalized adapter failure outcome, and irreversible per-operation manual-code provider invalidation. Duplicate/late completion or challenges cannot reopen a finished operation. The recoverable HTTP/2 operation stream remains design only (`docs/apple-operation-stream.md`), not an advertised or implemented capability.

Full Apple native suite, adapter plus two historical TCP fixtures, and five package-install fixtures passed; prior independent scoped review had no remaining important issues. Clean RootHide package build passed. All 216 archive entries are owner 0:0, all 169 payload files match staging bytes/modes, recovery helper remains 4755. Deploy/verify/status healthy; all five repository files, including the deb, match over the LAN endpoint. HTTP runs in ordinary foreground exec session (no Orca Terminal/no detached nohup). This publishes the repo only; no phone installation or live-device acceptance performed.

## 2026-10-14 / 3.2-325: sudo library trust before visudo

Phone screenshot of 324 confirms visudo abort134: dyld found native `/usr/libexec/sudo/libsudo_util.0.dylib` but rejected its code signature (errno1). This is not a missing-library error. Installer now registers that fixed existing library with `/basebin/jbctl trustcache add` using the jbroot-derived native path before visudo. RootHide source supports this command; no re-signing or skipped sudoers validation. Trust registration failure retains the previous rule and reports its stage.

325 built/published to the same LAN source; package 216 entries owner0:0,169 payload files match staging bytes/modes, recovery helper4755. `rtk proxy python3 tests/package_install_tests.py` passes five fixture tests including modeled old abort134/new ordering, failed trust, failed validation and missing library; these do not prove real dyld acceptance. Scoped independent review found no important issues. Five repo files match disk byte-for-byte over LAN and status healthy; ordinary exec persistent session. Phone installation not performed by agent; await user device result.

## 2026-10-14 / 3.2-324: installation configuration diagnostics

User reported 3.2-323 unpacking successfully then failing postinst with exit 1. The actual package required visudo without declaring sudo; device-specific failing command is still unconfirmed because postinst suppressed stderr. RootHide before-package now appends sudo to staged Depends idempotently. postinst/prerm retain stderr; app-state configuration reports missing executables and failed stages, preserves RootHide library resolution and validates the temporary sudo rule before replacement. Missing helper is an error rather than silent success.

3.2-324 built and published at `http://172.16.20.203:18766/`, ordinary exec persistent session, no Orca Terminal. Shell syntax and fixture checks passed for dependency idempotence/scheme isolation, missing visudo, failed validation/error propagation/temp cleanup, successful reconfiguration/removal. Independent scoped review found no important issues. Package 216 entries owner 0:0; 169 payload files match staging bytes/modes, recovery helper 4755. Five repository files verified byte-for-byte over LAN; status healthy. No phone installation or claim that the original device failure is resolved.

## 2026-10-12 / 3.2-318: Rust WireGuard bridge published

Production daemon links only `wgbridge-onetun` (BoringTun + smoltcp); the four C entry points and existing JSON configuration remain compatible. A dedicated Rust worker owns transport and TCP state. Seven retained local tests cover encrypted IPv4/IPv6 dual-service forwarding, PSK, multi-peer dispatch, 256 KiB payload, stop/restart, C ABI, AllowedIPs source checks, half-close, refused local service, incomplete handshake reclamation and Closed-buffer backpressure. Independent review fixes verified. These are local tests, not physical-phone acceptance; user requested no new test report.

RootHide 3.2-318 built and published at `http://172.16.20.203:18766/`, reusing the ordinary foreground exec HTTP session. Package 215 entries have owner 0:0, all 168 payload files match staging and modes, recovery helper remains 4755; all five repository files verified byte-for-byte over LAN. Deploy/status healthy. No phone installation by agent.

## 2026-10-12 / 3.2-317: HTTP/2 screen lock/unlock

User retained RV framebuffer screenshots and legacy VNC unlock/lock, and requested new HTTP/2 unlock/lock. `POST /api/device/unlock` accepts a six-digit passcode; `POST /api/device/lock` accepts `{}`. Both return bounded NDJSON progress with observed terminal screen state. `http_screen_control` capability makes RV choose this flow; older servers retain VNC behavior. Never automatically replay or fall back after submitting HTTP input. Passcodes still come from existing local configuration; no keychain dependency. Cancellation stops future digits/delayed presentation, releases current keypress, and reports unknown when no terminal observation arrives. Authorization runs on the worker and is followed by a quick cancellation recheck; main callbacks/HID keyboard mutex must never synchronously wait on the app authorization queue. The synchronized completion gate protects delayed callbacks from freed stream producers.

Retained checks: `tests/run_screen_http_tests.sh` exercises production ScreenHTTPControl.inc with deterministic screen/HID primitives (11 scenarios); control-http has 5 real HTTP/2 transport tests; RV session has 101 tests and unlock UI has 11 tests, including legacy flow, fragmented progress, EOF/inconsistent state/no replay and cancellation. RootHide package and RV executable build passed; independent review found no remaining important issues. These checks do not claim a physical-phone passcode unlock in this version. RV output is `../rv/target/debug/rv`, without app bundling.

Local Sileo publishing: 316 first published HTTP/2 migration; 317 now supersedes it at `http://172.16.20.203:18766/`. Foreground ordinary exec HTTP session reused (no Orca Terminal/no detached nohup). Final 317 deb: 215 control/data entries numeric owner 0:0, recovery helper 4755, all 168 payload files match staging content/mode; all 5 repository files verified byte-for-byte over LAN. deploy/verify/status healthy. No phone installation performed by agent in this publish.

## 2026-10-12: HTTP/2 phone control supersedes network task protocol

Validation: RootHide arm64 full build passed; RV session 97 tests and production HTTP engine 3 tests passed. Retained iOS HTTP/2 probe reported 11 PASS (control-http/tests/reports/device-2026-10-12.json). Probe uses production settings discovery with RootHide path conversion and daemon entitlements; temporary binaries/process are cleaned. Production daemon not installed/replaced in this migration. RV built as target/debug/rv, no app packaging.

User explicitly replaced the network task/CRLF protocol with ordinary HTTP URL routing. The resident daemon builds `control-http` (locked Hyper/h2/Tokio Rust static library) and `src/TVNCHTTPServer.mm`; it no longer builds ZXTouchTCPServer or typed vendor/karing service. `/api/karing/*` is a raw streaming reverse proxy, never JSON normalization/post-verification/failover. Native Apple/app-state dictionary facades are invoked by named POST URLs. VNC capability token discovery is version2; RV must build/update together. Existing local password/passcode settings remain authoritative. See [control HTTP API](docs/control-http.md) for routes and retained tests. Old task documentation/tests and Python scripts are historical, not a supported listener. Internal SpringBoard IPC/native helper kinds may still use existing private identifiers.

# TrollVNC 开发与真机测试记忆

RV/VNC 密码与设备解锁密码复用现有本地配置，不添加系统钥匙串保存、读取、迁移或依赖。

## Apple 模块位置与边界

- `vendor/apple/` 是独立 Objective-C / Foundation 原生账户模块；修改前读取 [模块 AGENTS.md](vendor/apple/AGENTS.md)、[接口](vendor/apple/docs/interface.md)、[验证记录](vendor/apple/docs/validation.md)。
- `vendor/appstorectl/` 是平级 vendor，保留完整固定上游快照及许可；不得移进 apple/third_party 或增加 upstream 层。
- Apple 模块通过 src/TVNCAppleService.mm 接入 ZXTouch task 31，内部仍使用 Apple 原生框架；不使用触控、坐标点击或页面刷新完成账户操作。协议和测试见 docs/apple-zxtouch.md。
- 公共入口：[TVAppleServices.h](vendor/apple/include/TVAppleServices.h)。`src/appleid/` 为共享编排，`src/icloud/` 为 iCloud 开通、退出、Find My 和数据策略，`src/appstore/` 为 Store/AuthKit 适配，`src/common/` 为原生后端。

## 已提供的接口

| 方法 | 用途 |
| --- | --- |
| `enableICloudAppleID:password:devicePasscode:verificationCodeProvider:completion:` | 原生认证、本机密码验证、CoreCDP、数据服务开通，保持 Find My 关闭 |
| `queryAppleIDEmailSettings:completion:` | fresh AuthKit联系邮箱与公共隐藏邮箱forwarding_email；非iCloud Mail |
| `beginAddingContactEmail:appleID:completion:` / `verifyContactEmailChallenge:code:appleID:completion:` | 新增联系邮箱，外部单独提交邮箱验证码，同一Services实例 |
| `setSignInWithAppleForwardingEmail:appleID:completion:` | 已验证邮箱设为全局SIWA隐藏邮箱转发地址，fresh查询验证 |
| `queryState:` | 聚合主 iCloud、idms、App Store、Find My、能力及原生姓名/邮箱（分项状态） |
| `disableFindMyAppleID:password:completion:` | Apple ID 密码验证、取得原生令牌、关闭本机 Find My 并查询验证 |
| `signOutICloudAppleID:localDataPolicy:completion:` | 仅直接删除指定主 iCloud 账户；最终查询验证 |
| `signOutAppleID:localDataPolicy:completion:` | 指定账户的主 iCloud → idms → 当前媒体退出 |
| `signInAppStoreAppleID:password:verificationCodeProvider:completion:` | Store/AuthKit 登录；验证码由调用方单独提交 |

Settings 主 iCloud、idms 和 App Store 必须分别判断；不能将媒体登录说成 iCloud 开通。非媒体记录的 `authenticated=false` 不是未登录判据。历史 `selected=false` 媒体记录不代表当前登录。独立开通 iCloud 已提供，须验证原生 CDP 完成。

## 主机测试与真机工具构建

以下命令从 **TrollVNC 目录**运行，需要 macOS、Xcode SDK，真机工具签名需要 ldid。

```bash
rtk proxy bash vendor/apple/tests/run_tests.sh
rtk proxy bash vendor/apple/tests/build_device_probe.sh /tmp/apple-state
rtk proxy bash vendor/apple/tests/build_device_probe.sh /tmp/apple-login apple-login.m
rtk proxy bash vendor/apple/tests/build_device_probe.sh /tmp/apple-findmy-disable apple-findmy-disable.m
rtk proxy bash vendor/apple/tests/build_device_probe.sh /tmp/apple-icloud-logout apple-icloud-logout.m
rtk proxy bash vendor/apple/tests/build_device_probe.sh /tmp/apple-logout apple-logout.m
rtk proxy bash vendor/apple/tests/build_device_probe.sh /tmp/apple-icloud-enable apple-icloud-enable.m
```

2026-10-07 主机测试 71 项通过，ARC、`-Wall -Wextra -Werror`。包含账户域隔离、策略、未知结果写栅栏、认证挑战及正式 Find My 状态 reader 的回归；不能代替真机私有 API 验证。

`apple-state` 默认只读；`--self-test` 仅用随机不存在的目标验证幂等空操作。其余工具会实际修改设备。参数通过标准输入 JSON 传入：

- icloud-enable：`apple_id`、`password`、`device_passcode`；验证码同 login 外部提交。
- login / findmy-disable：`apple_id`、`password`。
- logout / icloud-logout：`apple_id`、显式 `local_data_policy`（`remove` / `keep`）。remove 不合并，允许系统提供的删除/丢弃未上传数据动作。
- login 验证码：收到挑战后再提交 `challenge_id`、`code`；取码在模块外完成，模块不存 URL、不轮询。

不要把密码、验证码、令牌或取码 URL 写入源码、文档、命令参数、环境变量或日志。原生 error userInfo/请求 body/headers 也不输出。

## 通用 SSH 脚本

固定脚本：[tests/device-ssh.sh](vendor/apple/tests/device-ssh.sh)。换设备时只修改顶部 `DEVICE_HOST`、`DEVICE_PORT`、`DEVICE_USER`、`DEVICE_KNOWN_HOSTS`；这些是脚本内部变量，不导出环境变量，不配置密码。

```bash
rtk proxy bash vendor/apple/tests/device-ssh.sh /usr/bin/apple-state
rtk proxy bash vendor/apple/tests/device-ssh.sh /usr/bin/apple-findmy-disable
rtk proxy bash vendor/apple/tests/device-ssh.sh /usr/bin/apple-icloud-logout
```

脚本接受远端程序和参数，逐项引用；不解释管道/重定向等 shell 表达式。敏感输入走 stdin。交互终端关闭回显，正常退出、失败或信号中断后恢复原终端状态。使用 SSH 密钥、`-T`、`BatchMode=yes`、`StrictHostKeyChecking=yes`；应预先独立核对并保存 host key，不能为换机而关闭校验。

当前临时连接为 mobile@10.17.12.17:2222，known-hosts 为 `/tmp/cazer-iproxy-10.17.12.17-known-hosts`；以后必须核对实际地址，不能当作永久配置。

SCP 示例（同样按实际连接调整）：

```bash
rtk proxy scp -o BatchMode=yes -o StrictHostKeyChecking=yes \
  -o UserKnownHostsFile=/tmp/cazer-iproxy-10.17.12.17-known-hosts \
  -P 2222 /tmp/apple-state mobile@10.17.12.17:/tmp/apple-state
```

测试系统为 Dopamine / RootHide、iOS 15.8.8、arm64。上传后在设备 root shell 用 `cp -f` 安装到 jailbreak `/usr/bin/`、`chmod 755`，并用 `jbctl trustcache add` 加入**实际原生 jailbreak root**路径的 trustcache。RootHide shell 路径与原生路径可能不同；不要硬编码旧的 `.jbroot-*`。root 不代替 entitlement；Find My 工具按原生 Settings 路径以 mobile 身份执行。

本次设备已部署的工具名为 `/usr/bin/cazer-apple-state-icloud-v1`、`/usr/bin/cazer-apple-findmy-disable-v3`、`/usr/bin/cazer-apple-icloud-logout-v6`、`/usr/bin/cazer-apple-icloud-enable-v3`。这些是临时测试版本，重新编译后应使用新名称并重新签名、信任。

## 真机结果与必须记住的细节

- Find My 已真实关闭：AuthKit 的 `AKPassword` 绑定主账户副本 → `AAFMIPAuthenticateRequest` → `fmipWipeToken` → `FMDFMIPManager.disableFMIPUsingToken:inContext:completion:`，此机 Settings context 为 1。不能用带 nil UDID 的配对设备接口关闭本机。
- `AARequest` 回调是 `(request, AAResponse, NSError)`；HTTP 响应在 `AAResponse.httpResponse`，不是第一个参数。令牌不保存、不返回。
- 此机原生状态 0/1 表示开启，3 表示关闭；2/4/其他状态或任意 error 均拒绝。关闭实测 daemon=3/error=nil、shared fmipActive=false、Settings 原生缓存 enabled=false；修正工具返回 succeeded/already_disabled=true。
- 独立 iCloud remove 策略已真实提交；全新查询确认目标主 iCloud 消失，idms 和活动已认证 App Store 仍在，Find My 关闭。首次退出工具返回 unknown，当时未记录回调元数据；本次同症状的 YES+Accounts/17 已定位，见文末；之后确认状态，再用新工具验证 succeeded/already_signed_out=true。
- unknown 不等于没有副作用。删除不确定时附带 fresh state 和 `target_signed_out`（可查询时），仍保持 unknown 与写栅栏，不自动重放。最终报告要区分实际账户退出、回调异常与幂等复验。
- 最终修正版尚未从重新开启 Find My / 重新登录 iCloud 的状态完整复跑，不能把分段验证说成一轮全流程回归。
- iCloud 开通已在正式模块完成：原生 AuthKit → AASignInFlowController → CoreCDP 本机密码验证 → dataclasses。首次部分保存后密码验证失败，返回 unknown；补 keystore.device 后再完成原生 CDP，返回 succeeded/already_enabled=true，Find My=false。两阶段验证，不是一次全流程回归。已有账户不能跳过 CDP；provider.failure 必须覆盖 Apple 的 non-fatal 保存成功。详见模块 AGENTS.md。
- App Store 登录已真机确认；正式 bootstrap 尚未在全新未信任设备完整回归。

账户退出只验证全新账户状态，不需要 Settings 页面刷新验证。系统日志诊断仅保留时间、进程、静态 format、错误 domain/code；不导出完整 composed message 或认证材料。详细证据、权限与局限持续更新到模块 AGENTS.md 和 docs/validation.md。

2026-10-07 开通后整机退出集成测试入口为 `vendor/apple/tests/apple-logout.m`，直接复用现有 signOutAppleID，无新增生产退出逻辑。首次 iCloud 删除回调 unknown 但全新查询确认主账户消失；确认后新进程只处理剩余 identity/media，返回 succeeded、verified_all_domains_signed_out=true、selected_accounts=[]，Find My=false。这是两阶段完整退出，iCloud 删除回调异常仍待排查。当前部署 `/usr/bin/cazer-apple-logout-v2`。输入要求显式 remove/keep，不存凭据。

后续已定位 iCloud 删除 unknown 的原因：原生回调 YES + com.apple.accounts/17，对应 dataclass 动作错误；账户已经移除。修复仅在该确切组合并全新确认账户消失/FindMy关闭时返回账户退出成功，同时保留 warnings/dataclass_action_failed；不保证全部本地数据动作完成。其他错误/false/超时仍unknown。当前整机测试工具 cazer-apple-logout-v4；诊断版本仅用于复现，不能用于正式服务。

修正版真机一次整机退出已通过，warnings保留数据动作17。循环中SearchParty daemon挂起曾令账户保留/超时，测试时仅重启 com.apple.icloud.searchpartyd 后恢复；当时模块未自动恢复；现已补充删除前健康检查及一次 SearchParty 恢复，见下文，不跳过FindMy或账户验证。defaultStore对照无效并撤回。正式已部署 cazer-apple-logout-v5、cazer-apple-login-v5、cazer-apple-icloud-enable-v4；测试详情见模块 docs/validation.md。

修复后的登录复测已完成：全退出后 App Store 原生登录 succeeded，无新验证码；接着 iCloud 一次开通 succeeded/already_enabled=false，最终 icloud/identity/media 全部选中、主账户数据服务启用、Find My关闭。设备保留此登录/开通状态。71项主机回归和arm64工具编译签名通过，退出误判修复已独立审查。

SearchParty 自动恢复已实现于 `vendor/apple/src/icloud/TVAppleSearchParty.m`：iCloud 删除前5秒原生只读探测，无响应时固定 root helper 恢复一次，复检10秒通过才提交删除；失败在预检返回，不重复提交。helper 用 `vendor/apple/tests/build_service_recovery.sh` 构建，部署 root:wheel/4755 到 bootstrap `/usr/bin/cazer-apple-searchparty-recover` 并加入实际 native trustcache；RootHide 使用真实路径解析，无环境变量配置。helper 自己监督固定 launchctl 子进程4秒期限。需要 beaconmanager entitlement，见模块 AGENTS.md。真机暂停 SearchParty 的故障整机退出、正常登录→开通→退出均通过，恢复元数据为 `service_recoveries`。健康诊断入口 `apple-searchparty-health.m` 也会在无响应时执行一次恢复。当前正式退出测试工具为 `/usr/bin/cazer-apple-logout-v11`；账户删除后仍保留 Accounts/17 数据动作警告。


Apple ID 邮箱工具：`rtk proxy bash vendor/apple/tests/build_device_probe.sh /tmp/apple-email-actions apple-email-actions.m`，部署/签名/trustcache后用 `rtk proxy bash vendor/apple/tests/device-ssh.sh /usr/bin/apple-email-actions`。同一个进程stdin依次给action=begin（email/ apple_id）、verify（challenge_id/code/apple_id）、forward（email/apple_id）或query；同一 Services 实例保留5分钟原生邮箱会话。这里要邮箱验证码，不能用受信任设备2FA码，不取码/轮询。独立只读工具 apple-email-settings.m 也可构建。新增/验证码/全局forward真机已分段执行成功，服务端reachable_emails与forwarding_email验证通过；随后用户确认实际邮件投递正常；模块自身不发信/查收。生产与测试细节见模块AGENTS.md，`tests/EmailActionsTests.m`覆盖原生postback/终止顺序/超时/精确forward表单/challenge/写栅栏。公共forward入口来自AKURLBag.privateEmailManageURL，不能用个人信息表单或Vinted单个App详情入口替代。


Apple ID Settings 姓名工具：公共 `queryAppleIDNameSettings` / `setAppleIDFirstName:lastName:appleID` 在 `vendor/apple`。构建 `rtk proxy bash vendor/apple/tests/build_device_probe.sh /tmp/apple-name-settings apple-name-settings.m`，部署/trustcache后用device-ssh.sh运行；stdin JSON action=query/apple_id，或set/apple_id/first_name/last_name。保留表单Middle Name，原生Settings签名与POST后全新服务端查询验证；unknown共用写栅栏，不做UI操作。真机已将First=jack、Last=ma保存并独立查询确认，Middle为空保持不变，同值幂等通过。技术细节与验证边界见模块AGENTS.md/docs/validation.md。


queryState现聚合apple_settings.name/email及app_store/icloud/identity摘要，保留原始accounts/FindMy/能力与独立查询。分项status/data/error用于区分失败和未登录；基础读取失败顶层error。前后账户变化丢弃旧profile，返回最终state与姓名/邮箱分项冲突错误。只读工具apple-state.m无需账号密码输入，等待180秒；mutation内部snapshot不聚合网络请求。具体schema、测试及设备工具见模块AGENTS.md/docs/interface.md。

聚合只读工具已部署 `/usr/bin/cazer-apple-state-aggregate-v1`；无需stdin输入，实际queryState返回complete/consistent=true，三个账户域、姓名jack/ma、联系邮箱与转发目标全部取得。主机聚合13场景与原有回归通过。

公共queryState的Find My字段统一为 `icloud.find_my_enabled`，不再放聚合顶层；内部原生snapshot及登录/退出返回state保留原顶层字段。

按用户最新要求，queryState不暴露collection_status/collection_consistent；一次接口调用返回一个汇总JSON。Find My在icloud.find_my_enabled。内部仍核对账户身份，分项失败用该分项status/error表示。旧v1的complete/consistent仅为历史测试记录。

当前聚合工具 `/usr/bin/cazer-apple-state-aggregate-v3` 已真机确认icloud.find_my_enabled=false、姓名/邮箱available，顶层FindMy及两个collection标记均不存在；14个聚合场景及原有回归通过。该改动仅JSON层级，无账户写入。

SCP固定包装 `vendor/apple/tests/device-scp.sh`：`rtk proxy bash vendor/apple/tests/device-scp.sh /tmp/tool /tmp/tool` 上传，`--download <remote-path> <local-path>` 下载，`--recursive` 传目录。顶部DEVICE_*集中配置，与device-ssh.sh换机时一并修改，无环境变量/密码；BatchMode+严格host key。


Sign in with Apple授权工具：vendor/apple公共querySignInWithAppleApps / stopUsingAppleIDForBundleID:appleID，queryState新增apple_settings.sign_in_with_apple/apps/bundle_ids。原生Settings授权列表及确认按钮POST后fresh确认目标消失；不退出整机、不替代成停止email转发/本地cache删除。工具apple-siwa.m经builder构建、device-scp.sh上传、device-ssh.sh运行，stdin query/apple_id 或stop/apple_id/bundle_id。读取原生GET/POST query会话参数，不输出token/URL；schema与边界见模块AGENTS.md。聚合apple-state外层等待现300秒。

iCloud伴随设备功能：vendor/apple的queryICloudDevices/removeOtherICloudDevices，代码src/icloud/TVAppleICloudDevices.m。移除所有非本机设备，不写死iMac；原生Settings详情isCurrentDevice必须唯一真值，本机保留，每台native POST后fresh验证，unknown停止不重试。queryState新增icloud.devices，apple-state外层等待现600秒；CLI apple-icloud-devices.m stdin query/remove_others/apple_id。接口、schema与实际验证见模块AGENTS.md/docs/validation.md。

姓名设置必须刷新AuthKit：仅Settings服务端保存会留下主idms旧姓名，使Apple登录弹窗显示旧名。正式setName现保存后调用原生fetchUserInformationForAltDSID，再验证cached getUserInformation与主iCloud/idms的given/family name一致；同名无POST也刷新。不手改账户properties，不以updateUserInformation探针当刷新成功。身份变化/缓存不一致/超时返回unknown，详见模块AGENTS.md和NameRefreshTests。

Apple socket入口：TVNCZXTouchService分发task31给TVNCAppleService，Base64 JSON，invoke/result/submit_code/cancel_challenge。Python device.apple提供invoke/result/wait等；一个Services实例保留邮箱会话和unknown写栅栏。单操作busy、结果内存保留600秒/最多64条，socket断线不取消或重放native写操作。测试入口tests/run_apple_socket_tests.sh，覆盖真实TCP和客户端；构建通过vendor/apple/apple.mk纳入主daemon，src/trollvncserver.entitlements现为独立文件，应用entitlements不修改。既有ZXTouch无认证握手，使用受控网络路径。

2026-10-07 Apple socket验证：主机适配器/真实TCP Python测试、Apple模块与旧ZXTouch回归全部通过，RootHide arm64主服务编译/链接/签名成功。手机独立回环probe以daemon同等entitlements完成queryState，socket断开重连后仍可查询同一操作，三账户域signed_in、name/email/SIWA available。临时listener、SSH转发及probe文件已清理，未替换正在运行的TrollVNC；通过socket执行真实账户写操作尚未验证。构建独立probe用tests/build_apple_socket_probe.sh，细节见docs/apple-zxtouch.md。

App状态备份vendor：vendor/app-state从ProjectX/tools/app-state完整移植核心/原生adapter/session/CLI/测试/格式/许可，独立门面TVAppStateServices，原源码不修改。ZXTouch task32入口src/TVNCAppStateService.mm，Python device.app_state.invoke/result/wait；命令及必填backup_id见docs/app-state-zxtouch.md。RootHide路径、per-target短生命周期签名worker及IDFV root helper保持独立，不给daemon目标App钥匙串组。备份独立存TrollVNCAppStateBackups，不自动复用ProjectX数据。测试vendor/app-state/build.sh test与tests/run_app_state_socket_tests.sh；实际权限/备份恢复需真机验收，不能将源项目历史结果算作本模块验证。

2026-10-07 App状态模块主机验证：169核心、245模拟Security、49 session断言及协议/服务/helper监督测试通过；新task32真实TCP客户端、Apple socket和既有ZXTouch回归通过。RootHide arm64主服务/两个worker编译链接签名成功；多目标make使用-j1避免本机递归jobserver挂起。独立审查的半删除、unknown baseline及root IDFV helper超时恢复问题已修复并复审通过。真实手机未部署本模块、未做App快照切换；下一次应按vendor/app-state/docs/VALIDATION.md进行权限及数据恢复验收。设备SSH/SCP仍复用上文固定脚本，勿添加环境变量配置。

App基本操作现纳入同一task32：launch/stop/status只传bundle_id，具体实现vendor/app-state/src/TVASAppLifecycle.m。launch原生LS启动后验证main进程，stop含扩展、SIGTERM后按原PID/starttime/UID/canonical path强制停止并fresh验证；status返回installed/running/main_running/extension_process_count/pids。整体native调用6秒限时，可能迟到的mutation返回unknown；进程级pending/未知栅栏跨socket listener重启保持，禁止再启动native生命周期操作或backup mutation与之并发。主机LifecycleTests、阻塞native两实例ServiceTests、TCP命令测试及arm64编译是验证入口；实际手机launch/stop尚待验收。

## 本地 Sileo 发布

2026-10-07 后续真机验收：Windows 10.17.12.17:6000 转发至手机192.168.1.148:6000，Mac走10.17.12网段；手机访问仓库使用Windows Wi-Fi地址http://192.168.1.10:18766/，转发到Mac10.17.12.76:18766。task32在已安装308完成Vinted启动/停止/状态、save/edit/baseline/switch/delete及原快照恢复，详见vendor/app-state/docs/VALIDATION.md；不要继续将前文未部署记录当当前状态。

已更新发布并通过SSH安装3.2-309，dpkg-query确认版本，仓库verify通过。task13现在返回stdout/stderr/退出码/截断与超时标记；真机中文/分隔符/CRLF、stderr分离、exit7、正常exit0、每路100000字节输出保留65536字节并继续排空、30秒超时均通过。Pythonrun_shell_command返回(ok,dict)，异步script仍写process log。task32 status的running/main_running真机为JSON Boolean。最终309归档numeric owner0:0、helper4755、全部payload与staging一致已核对；详见docs/zxtouch-integration.md。

task31此次整机退出与新账号Store登录已真机成功，Store同时产生Settings identity；fresh确认两域目标一致、icloud尚未登录、FindMy=false，重连结果读取通过。iCloud失败已用独立原生工具对照：HTTP409/com.apple.appleaccount403，进入CDP前的alert分类为account_limit/activation。Apple开通数量限制需另一Apple设备先开通账号或提供已开通iCloud账号，不能盲重试或宣称全登录成功。姓名/邮箱/SIWA/设备查询当前Conflict7，其写功能尚未完成本轮验证。309已验证signOutICloud在cloud不存在时幂等成功且Store/identity保留，disableFindMy已关闭分支幂等成功（不覆盖真实开启→关闭认证）。取码由代理单独curl、再输入给测试/接口，tests/AppleSocketDeviceLogin.py也不收取码URL或轮询。诊断临时工具已清理，凭据不记录。

2026-10-07 已整体发布 RootHide 包 `3.2-308`，仓库 `.deploy/repo`，当前局域网源 `http://172.16.20.203:18766/`；IP随网络变化，端口来自 `.deploy/deploy.env`。构建用 `rtk proxy make -j1 clean package FINALPACKAGE=1 THEOS=/opt/workspace/github/theos-roothide THEOS_PACKAGE_SCHEME=roothide THEBOOTSTRAP= THEOS_DEVICE_SIMULATOR=`；发布 `rtk proxy bash scripts/deploy_sileo.sh deploy`，验证 `... verify` / `... status`。只发布仓库，不自动安装手机或添加源。

完整包含主服务、Settings/Control Center、ZXTouch/notification adapters、Apple/task31、App状态/task32及Python客户端、两个app-state worker和独立SearchParty恢复helper。helper安装/usr/bin/cazer-apple-searchparty-recover，root:wheel/4755，签名仅platform-application。本机Theos dm.pl会留下numeric501:20而只把属主名字改root；devkit/after-package.sh现调用scripts/normalize_deb_ownership.py将control/data全部numeric owner归0:0，保留文件payload/mode/link，不修改Theos本身。发布前检查最终deb，不以uname=root代替numericuid验证。3.2-308最终归档的组件、签名、owner、helpermode和全部staged payload一致性已检查，HTTP所有索引/包字节与磁盘一致。手机安装及新模块真机验收仍待执行。


2026-10-10 已发布本地 RootHide Sileo 包 `3.2-310`，源 `http://172.16.20.203:18766/`，仓库 `.deploy/repo`。包含画面管线优化、固定 ZXTouch/task33 控制连接及现有 Apple/AppState 服务。ZXTouch、FramebufferPipeline、AppControlProtocol、Apple socket、AppState socket 回归通过；完整 clean package 编译签名通过；171 个 control/data 文件与 staging 的内容和权限一致，numeric owner 0:0，恢复 helper 4755，主服务/两个 worker/helper 签名 entitlements 与源文件一致。Packages/压缩索引/Release/deb 经局域网 HTTP 逐字节验证，verify/status 正常。本轮只发布仓库。

用户要求长进程通过 Orca Terminal 启动。该源的 HTTP 服务已在当前 cazer 工作区的 `TrollVNC Sileo Repo` 终端中执行 `rtk proxy bash /opt/workspace/github/cazer/TrollVNC/scripts/deploy_sileo.sh start` 启动。不要通过短生命周期 exec 工具启动并遗留后台服务，它可能被执行环境回收。后续启动/重启仓库服务继续使用 Orca Terminal；查询/校验可用普通 exec。

2026-10-10 已发布本地 RootHide Sileo 包 `3.2-311`，源 `http://172.16.20.203:18766/`。包含 task31 Apple 操作 `error.message` 返回修复与邮箱原生响应 HTTP/回调诊断；只导出模块生成的净化错误说明。通过现有 Orca Terminal 编译 package 并 deploy，源服务重新启动，verify/status healthy；包版本/架构、numeric owner0:0、daemon内修复字符串及全部HTTP索引/包字节一致性已核对。本轮只发布本地仓库，未安装手机。RV 收到邮箱挑战后3秒首读等待属于独立客户端构建，不包含在此deb。

2026-10-10 已发布3.2-312到本地Sileo源 http://172.16.20.203:18766/，包含邮箱重绑环境初始化、同账户邮箱unknown恢复、旧challenge失效与已验证邮箱幂等成功。native模块与task31真实TCP模拟回归通过；arm64服务/RV release编译通过，尚未安装手机或进行新绑定真机写入验收。源HTTP改为普通exec持久会话启动（用户明确禁止继续使用Orca Terminal），LAN全部索引/包字节核对通过，status健康；后续同样用普通exec前台持久会话运行HTTP，不用短exec启动脱离会话的nohup。RV仅在新绑定完成成功或取得有效challenge时解除重绑前unknown，拒绝/预检失败/已知失败均保留原未知状态。

2026-10-10 邮箱验证状态恢复：313已构建并发布本地Sileo源http://172.16.20.203:18766/，deploy复用现有普通exec HTTP会话（不使用Orca Terminal）。TVAppleEmailActions验证POST未知时继续fresh原生服务端读取，只有目标reachable且session identity一致才succeeded；不重发验证码POST。模块完整检查与四个生产调用链回归通过，独立审查无重要问题。真机目前312的fresh原生查询确认此前目标Outlook已绑定；313未由代理安装，不把此查询当新版本完整绑定验收。


## 2026-10-10 / 3.2-314：撤销跨功能写栅栏

本节覆盖此前关于 shared Worker、unknown 写栅栏以及全局 busy 的设计约定。用户明确要求一次操作失败不阻止其它功能。

- Services 删除静态 uncertainMutation；每次结果只由该请求的返回/错误决定，unknown 不拒绝后续写入，也不要求重启模块。
- 原生工作队列可并发；name/email/authorizations/devices 使用各自 SettingsSession。task31按具体功能维护当前请求与验证码 provider；仅同一原生会话尚在执行时返回 busy，完成（含错误）释放。账户身份预检 queryAccountState 不查询网络 profile，不被登录挑战或邮箱操作占用。
- 新 signOutAppStore 只退出选中的 media 账户，保留 iCloud、identity、历史媒体记录。媒体退出不依赖 Find My；原有云账户身份、设备及数据策略检查继续有效。
- 真机捕获的 Native Invalid Email alert 仅在 parser succeeded、HTTP200、无普通 page 且确切 title/message 匹配时返回 InvalidRequest/code3。未知原生提示仍返回 unknown；不将 HTTP200 当绑定成功。当前用户指定目标被 Apple 返回 not available，与之前已绑定目标不同，不能用旧地址的查询说明当前目标已绑定。
- 本机使用314正式包已完成安装；原生并发与原始错误分支检查、RV面板隔离检查通过。账户写操作不会因为结果未知自动重放。

314正式服务后续fresh绑定已返回requires_email_verification，等待时queryAccountState仍正常完成；没有提交验证码。此前Invalid Email是更早请求的诊断，不能作为当前绑定状态。


## 2026-10-10 / 3.2-315：接口成功直接完成

用户明确要求以 Apple 原生修改接口的成功响应决定结果，覆盖历史文档中成功后 fresh 复核、缓存同步及超时后查询恢复的完成判据。姓名、邮箱验证、转发邮箱、SIWA 撤销、设备移除，以及 Services 层 Store/iCloud 登录退出、Find My 关闭不再因成功后的查询失败或缓存陈旧返回 code 6。成功写入返回 outcome=succeeded；不输出伪造的查询 settings/state，不重发写入。原生响应必须完整、无错误及拒绝提示；HTTP 200 本身不代表原生操作成功，超时仍保留原始错误。身份、输入、服务器提供的请求路由和下一个设备写入前的预检继续保留。

RV 通过独立 queryAccountState 更新登录/退出菜单，Store 与 iCloud 分别判断，状态刷新不改写原操作结果。本次没有再次提交真机改名。
