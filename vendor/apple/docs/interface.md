# Interface v1

`TVAppleServices` is the sole public facade. It owns no network listener and accepts no VNC or HTTP types. Host adapters call Objective-C methods and serialize result dictionaries if needed.

| Method | Parameters | Completion |
| --- | --- | --- |
| `enableICloudAppleID:password:devicePasscode:verificationCodeProvider:completion:` | matching Apple ID, password, local device passcode, optional external code provider | native CDP completion and fresh primary-cloud/dataclass/Find My verification |
| `signInAppStoreAppleID:password:verificationCodeProvider:completion:` | Apple ID, password, optional asynchronous code provider | verified login result; failure/unknown with resulting account domains when readable |
| `signOutICloudAppleID:localDataPolicy:completion:` | explicit target Apple ID; remove/keep enum | verifies only target primary iCloud logout; returns actual state |
| `disableFindMyAppleID:password:completion:` | matching primary Apple ID and its password | fresh Find My state verification; idempotent if already disabled |
| `queryState:` | none | account state, domain summaries and fresh name/email sections; per-section failures, or fatal account read error |
| `signOutAppleID:localDataPolicy:completion:` | explicit target Apple ID; remove/keep enum | verified result; unknown result plus error; preflight error without result |

Callbacks execute exactly once on the chosen callback queue. Calls from all instances are serialized. Read-only calls do not change credentials or account settings. This version has no module-owned credential storage, persisted jobs or transport-specific request IDs. A host may assign its own job IDs without replaying account operations.

## State

- `schema_version`: 1.
- `accounts`: array of records containing `identifier`, `apple_id`, `domain`, `selected`, `primary`, `enabled_dataclasses`, `authenticated`.
- `domain`: `icloud`, `identity`, `media`.
- `selected`: primary cloud, identity records and current active media record; historical media records are false.
- `authenticated`: media authentication status only; false in other domains is not a phone login indicator.
- `icloud.find_my_enabled` in public `queryState` (top-level `find_my_enabled` in internal/mutation snapshots): conservative OR of native FindMyDevice daemon state, shared fmipActive, and enabled DeviceLocator dataclasses. Missing or unrecognized daemon state fails the query.
- `capabilities`: `sign_out_icloud`, query/complete signout true if runtime prerequisites succeeded; App Store login has its own runtime capability; separate whole-device login remains false; `enable_icloud` reflects effective authentication/CDP/passcode entitlements. Runtime selector checks also run before authentication. Capability true does not mean a particular account passes Find My or data-policy preflight.

An entitlement or query failure is an error, never an empty signed-out state. The media cache is correlated with identifiers from a new Accounts query: a cached media account no longer in the system query is ignored.

## Signout result

`outcome` is `succeeded` or `unknown`. `completed_domains` reports completed callbacks in cloud → identity → active-media order. Account state is the sole verification criterion; no UI refresh check is performed. Success also includes `state` and `already_signed_out`. If removal completion is uncertain, the result also includes fresh state and target_signed_out when readable, while retaining unknown and the write fence; an unreadable state does not produce a target_signed_out assertion. `warnings` retains sanitized data-action metadata, including when outcome remains unknown. On the validated iCloud removal path, native YES plus Accounts error 17 can report account removal and a failed dataclass action together. Only that exact callback shape, with a fresh absent target account and Find My disabled, is reconciled as account-logout success; it includes a `dataclass_action_failed` warning and does not guarantee every requested local data action completed. False callbacks, other errors and timeouts remain unknown. Error messages are sanitized; no native error userInfo/description or authentication objects are exported.

All target deletion contexts are preflighted before changes. A mid-flow system failure may produce partial logout; it cannot be rolled back. The process fences further mutations after uncertain outcomes. Timeouts do not cancel Apple daemon operations; reconnect/retry is not an automatic recovery strategy.

Local data removal applies to system-supplied iCloud dataclass actions, not arbitrary files, caches or media history. Actions are selected by the observed system names on the validated OS; missing or ambiguous options refuse execution. Keep explicitly permits merge; remove never falls back to keep.

## Independent iCloud logout

`signOutICloudAppleID:localDataPolicy:completion:` directly removes only the matching selected primary iCloud account. It shares the complete signout worker, preflight, mutation fence, and final-query verification, but does not directly delete idms or media records. Native system side effects may affect other domains; inspect the returned `state`. An absent matching primary iCloud account succeeds idempotently even if the same Apple ID remains signed in to App Store.

Remove selects exactly `ACDataclassActionDeleteSyncData` or `ACDataclassActionLoseNonUploadedData` supplied by the system. The latter was observed for Notes on the tested device and explicitly discards data not yet uploaded. Keep accepts only `ACDataclassActionMergeSyncDataIntoLocalData`. Missing or ambiguous matching actions reject the operation. Deletion action sets are checked again immediately before removal.

## App Store login

The Store → AuthKit bootstrap → Store retry algorithm is adapted from pinned appstorectl `cli/login.m` and `cli/authkit.m` with MIT notice retained. Terminal input is replaced by an injected provider. Only a specific rejected Store response (-5000) permits one bootstrap; other failures do not trigger blind retries. The provider is optional for already-trusted accounts.

Success requires an active authenticated media record correlated to a new Accounts query. `signed_in_domains` reports actual primary-cloud, identity and active-media records matching the target, including partial login on post-authentication failure. A failed final read or malformed response produces `unknown` and fences subsequent writes. No UI verification is performed.

The manual provider separates credentials from verification input. Create `TVAppleManualCodeProvider` with a challenge handler, then pass it to the login call. When Apple requests a code, the handler receives `kind: apple_two_factor`, `verification_method: trusted_device`, `attempt: 1`, a unique `challenge_id`, and `expires_in: 90`. This adapter accepts trusted-device codes; SMS verification is not implemented. The host obtains the code externally and calls `submitCode:forChallengeID:error:` on the same provider. No URL, HTTP client, baseline read or polling exists inside the module.

Submission accepts six ASCII digits and the pending identifier. A successful submission acknowledges delivery, not successful login; await the original login completion. Invalid format or mismatched identifier leaves the challenge pending. Duplicate, expired or cancelled submissions fail. `cancelChallengeID:error:` abandons a pending challenge. Native completion or timeout invalidates pending manual input through `cancelAuthentication`. Custom providers may implement the same optional cancellation method. The operation adapter calls the manual provider's `invalidate` when the whole operation finishes or the service stops: this permanently closes it and immediately rejects late prepare/request calls. `cancelAuthentication` remains reusable across authentication stages within one operation.

Preparation waits at most 30 seconds, Store attempts 120 seconds each, AuthKit 180 seconds and final verification 5 seconds. Timeouts do not cancel Apple daemon work. Login may establish phone identity; independent iCloud enablement is not implied. AuthKit uses the exact native command-line context with process-local adapters for owned contexts; unsupported prompt shapes fail closed. These adapters are not installed in Apple daemons.

## Authenticated Find My disable

The tool requires the primary iCloud Apple ID and its password. AuthKit supplies a native AKPassword credential, bound only to a copied account for AAFMIPAuthenticateRequest. The AARequest callback is `(request, AAResponse, NSError)`; HTTP status comes from AAResponse.httpResponse. Only a verified successful response containing a wipe token and DSID may proceed to FindMyDevice.disableFMIPUsingToken:inContext:completion: (native Settings context 1 on the validated iOS 15 device). No account flags are changed offline. Credentials and tokens are never persisted or returned.

The current tool uses existing device trust and has no external code provider. A new 2FA challenge fails explicitly. Completion succeeds only after fresh queries show Find My disabled for the unchanged primary account. Authentication or daemon timeouts and unverified outcomes fence subsequent mutations.

## iCloud enablement

The native pipeline is AuthKit authentication results → AASignInFlowController with automatic saving → CoreCDP → dataclass activation. No custom authentication HTTP requests or UI automation are used. The supplied local passcode is verified by MCProfileConnection before constructing CDPLocalSecret. Native simple type -1 maps to CDP complex type 3; other nonnegative simple types map to 2. Passcodes are not retained after completion/timeout.

Preflight refuses conflicting selected identities and enabled/unknown Find My. The flow's findMyActivationAction is 2 (disabled). Terms, recovery keys, beneficiary keys, remote secrets and adoption prompts are rejected explicitly; encrypted data is never reset as a fallback. External trusted-device 2FA uses the existing provider only when Apple requests it.

A matching pre-existing primary account does not skip authentication/CDP. `already_enabled` only reports the initial presence of a matching primary with dataclasses. `succeeded` requires a successful native callback with no provider failure, then a fresh matching primary with nonempty enabled dataclasses and Find My disabled. Results include actual `signed_in_domains` and state. AuthKit rejection is failed; uncertainty after the flow starts is unknown and fences writes because Apple may already have saved a partial account. Native authentication waits at most 180 seconds; the iCloud flow waits 240 seconds and final verification 5 seconds. Timeout does not cancel daemon work.

### SearchParty preflight recovery

Both cloud-only and complete logout prepare the native SearchParty service before account removal. A read-only beaconingStateWithCompletion probe has a 5s deadline. If unresponsive, a fixed-purpose privileged helper is attempted once (5s outer deadline, 4s internal command deadline), followed by a 10s probe. An unavailable interface, missing effective beaconmanager entitlement, untrusted helper or failed recovery rejects preflight without submitting account deletion. A healthy probe does not promise every later plugin call will succeed; existing 60s removal deadline, fresh-state verification and unknown write fence still apply. There is no automatic deletion retry.

Successful recovery is reported as `service_recoveries: [{service: searchpartyd, stage: before_account_removal}]`; healthy operations report an empty array. The helper accepts no parameters, validates protected native paths, and only restarts `system/com.apple.icloud.searchpartyd`. Deploy it separately with root ownership, mode4755, signing and trustcache; module behavior does not depend on a sudo password or caller environment configuration.


## Apple ID email settings (read-only)

`queryAppleIDEmailSettings:completion:` fetches fresh AuthKit server information for the matching primary phone identity on the shared worker. It returns `apple_id`, nullable `server_account_name` and `primary_email`, `reachable_emails`, nullable `forwarding_email`, and `source=authkit_server`. An omitted or malformed reachable-email list is a read error, not an empty list. The account identifier and username are checked again after the response; conflicting server account names reject the result. Native request errors, timeout and malformed responses fail the read without returning native userInfo or tokens. Duplicate/late callbacks are ignored.

`forwarding_email` reports AuthKit's parsed `forwardTo` field. It does not describe iCloud Mail inbox forwarding. This read API does not modify email settings; the separate email actions below perform contact addition and relay changes. Local `AKAccountManager` email setters and AuthKit cache-update methods are not server mutation APIs.

Read-only device tool: `rtk proxy bash vendor/apple/tests/build_device_probe.sh /tmp/apple-email-settings apple-email-settings.m`; deploy/sign/trust as other module tools, then run through `tests/device-ssh.sh` with the target `apple_id` in stdin JSON.


## Contact email and Sign in with Apple forwarding

Use the same `TVAppleServices` instance for the two contact-email steps:

1. `beginAddingContactEmail:appleID:completion:` sends a native Settings email-verification request. `requires_email_verification` returns an opaque `challenge_id`, the destination `email`, and `expires_in=300`. This is not a completed addition.
2. `verifyContactEmailChallenge:code:appleID:completion:` supplies the six-digit **email** code for that challenge. Format/mismatched identifiers and unsupported actions do not consume it. A valid prepared submission consumes it once; no automatic retry or email polling occurs. Expiration releases the pending native model and signing state. `succeeded` requires a fresh AuthKit reachable-email response containing the destination and unchanged primary identities.
3. `setSignInWithAppleForwardingEmail:appleID:completion:` selects an already verified contact address as the common private-relay destination. It succeeds only after a fresh server query confirms `forwarding_email`. An existing matching destination returns `already_configured=true` without a POST. This is account-wide, not an individual App forwarding switch or iCloud Mail inbox rule.

Both selected iCloud and phone identities must match the target. Native Settings credentials and signing delegates stay in memory; they are released after completion or expired challenges. Native failure after a POST, unresolved alerts and a missing terminal callback produce `unknown` and the shared write fence. Read queries remain available. Completion callbacks execute on the configured callback queue.

The adapter obtains `AKURLBag.privateEmailManageURL` and follows the verified private-email RUI entry. Only the exact `/appleid/settings/account/manage/forwardemail/put` action, `forwardToEmail` radio group and native `ak-button`/`ak-action=read` save shape are accepted. No iCloud Mail form, substring route match, local account-cache setter, UI interaction, custom authentication or subscription-upsell action is used.

Build `tests/apple-email-actions.m` with the normal device builder, then run through `tests/device-ssh.sh`. The process accepts successive stdin JSON lines with `action` and `apple_id`: `begin` also has `email`; `verify` has `challenge_id` and `code`; `forward` has `email`; `query` reads the fresh profile. Keep the same process alive between begin and verify. Codes are not arguments/environment variables and are never logged.

Server state confirms configuration, not delivery of a message. Delivery testing requires a participating App to send to its private-relay alias and confirmation in the destination inbox; this module does not send email.


## Apple ID Settings name

`queryAppleIDNameSettings:completion:` reads fresh native Settings personal information and returns `apple_id`, `first_name`, `last_name`, `middle_name`, and `source=native_settings_server`. It requires matching primary iCloud and phone identities, with identifiers checked after the response. A conflicting server accountName is rejected. No cached display name is used as verification.

`setAppleIDFirstName:lastName:appleID:completion:` accepts both names explicitly. Names must contain nonblank text, no control characters, and at most 128 UTF-16 units each; Unicode and internal spaces are supported. Values are not lowercased or trimmed. It follows the server-advertised `/appleid/settings/account/manage/name` entry and accepts the observed three editable fields plus the native ak-button/read POST `/appleid/settings/account/manage/person/name/put`. The form's `middleName` is preserved through native postback serialization; opaque serverInfo and native signing remain intact.

Success returns `outcome=succeeded`, `already_configured`, and fresh `settings`. Matching current First/Last skips the Settings POST but still refreshes native AuthKit user information. After a save, all three server names must match the requested First/Last and preserved Middle. The adapter then calls native fetchUserInformationForAltDSID, verifies the returned names, and requires cached getUserInformation plus primary AuthKit and primary iCloud given/family names to converge before success. Both account identities are pinned throughout; refresh/verification is bounded by a shared 30-second deadline. It does not manually write account properties or send a partial user-information update. Unreadable/mismatched profiles, unverifiable AuthKit synchronization or uncertain native POST return unknown and fence further writes. This API shares the serialized account worker, callback queue and native Settings session with email actions. A pending email verification must complete or expire before starting another operation in that session. No UI refresh or UI interaction is required.

Build `tests/apple-name-settings.m` through the usual device builder. It accepts stdin JSON lines: `action=query` and `apple_id`, or `action=set` with `apple_id`, `first_name`, `last_name`. Run through `tests/device-ssh.sh`; credentials are neither required in this trusted session nor stored by this tool. A newly required Apple authentication prompt is not automatically handled by the name adapter.


## Aggregated `queryState`

The independent email/name methods remain available. Public `queryState:` adds the following fields to the original account snapshot (schema_version remains 1; Find My moves from the top level to `icloud.find_my_enabled`, while other original fields keep their meanings):

| Field | Meaning |
| --- | --- |
| `app_store`, `icloud`, `identity` | `{status, account}` for selected media, selected primary cloud, and phone identity respectively; account is the original account record or null. `icloud` also contains `find_my_enabled` (the native device value), even when not signed in. |
| `apple_settings` | `{status, apple_id, name, email, sign_in_with_apple}` for the unambiguous phone identity, falling back to primary cloud when no phone identity exists |
| `apple_settings.name` / `.email` / `.sign_in_with_apple` | `{status: available, data: <independent query result>}`; `not_signed_in` has null data; `error` has null data and sanitized `{domain, code}` |

Domain/Settings status is `signed_in`, `not_signed_in`, or `conflict`. A media record must additionally be authenticated for verified App Store login; domain status alone does not assert authentication. Historical unselected media stays in accounts but is excluded from summaries and cannot be selected as the Settings profile target. Media and Settings may use different Apple IDs. Multiple selected phone/cloud accounts, or different cloud and phone Apple IDs, return conflict sections rather than choosing an arbitrary profile. No phone/cloud identity means profile reads are skipped, even when App Store is signed in. Native per-feature prerequisites still apply: an identity-only state may provide email while the name query requires matching cloud as well.

Aggregation calls the same synchronous native backend operations on the existing worker, never recursively calling asynchronous public methods on that worker. Independent methods preserve their original output/behavior. Profile errors (unsupported permissions, timeout, pending email challenge, etc.) produce per-section errors, without a top-level error or mutation fence. Error descriptions/userInfo/tokens are not exported. Missing/failed initial or final account snapshots fail the whole call; they are not reported as signed out.

Accounts are fetched again after profile collection. If selected identities changed, return the final account snapshot and summaries, discard earlier profiles, and report per-section conflict. This bounds observed consistency; it is not an atomic Apple server/system transaction. Mutations' internal snapshots and completion states remain lightweight and are not enriched with network profile reads.

`tests/apple-state.m` uses this aggregate public API without inputs; its outer wait is 300s to cover the existing name signing/transport and email deadlines. The query can take longer than the original local-only state read.

No collection_status or collection_consistent fields are exposed. Callers make one queryState call and receive one JSON result; failures are represented in their individual sections, with identity consistency checks kept internal.


## Sign in with Apple applications

`querySignInWithAppleApps:completion:` returns a fresh native Settings list: `{apple_id, apps: [{bundle_id, client_id, name}], bundle_ids: [...], source: native_settings_server}`. It is also aggregated into `queryState.apple_settings.sign_in_with_apple` with the usual section status/data/error. Detail links and native session query parameters are never exported. A recognized empty connected-app section is an empty list. The observed iOS15 final-grant removal response is also recognized: connectedAppView with exactly one anonymous section whose attributes are empty and whose rows are an empty array. Other unsupported/missing structures, timeout, error or ambiguous identifiers are not an empty list.

`stopUsingAppleIDForBundleID:appleID:completion:` targets an explicit case-sensitive native application bundle ID, without stopping device iCloud/idms/media sign-in or changing the common relay destination. The selected primary cloud and phone identity must match the Apple ID. It fetches the current list, follows the selected server-advertised detail link, verifies the target label ID and native `#revokeConnectedApp` action, and accepts only that named alert's unique destructive removeButton POST `/appleid/settings/account/manage/security/apps/<client_id>/delete`. Native postback serialization, Settings signing, and RemoteUI loader handle the submission. No UIKit button is clicked/presented and no local-only AuthKit cache deletion is used as server revocation.

On iOS15 the named RUIAlertView stores button attributes inside UIKit action blocks rather than exposing a usable button object. During the native resource callback, the adapter checks the observed RUILoader `_parser` and RUIParser.xmlData interface, parses only the matching confirmation alert, and associates its four whitelisted button attributes with the model. The full XML, serverInfo and authentication objects are not stored/exported by this adapter. Missing/duplicate/changed confirmation shapes refuse before submission. Native GET/POST session query parameters are preserved from the advertised links, while HTTPS origin, exact client/path/method and fragment rejection are enforced.

Success includes outcome=succeeded, already_stopped, bundle_id and fresh settings containing the remaining apps. If the target is already absent from a successfully read recognized list, already_stopped=true and no POST is sent. A fresh post-save list must confirm absence for unchanged identities. Native POST uncertainty, remaining target or unverifiable final read returns unknown and fences subsequent writes; read queries remain available. No automatic revoke retry occurs. This adapter validates the observed native app schema (row ID=bundle ID; client ID=bundle ID+.app). Other service/web/grouped form shapes are unsupported rather than being guessed as native bundle IDs. Additional Apple authentication prompts are not automatically handled.

Build `tests/apple-siwa.m` with the normal builder and run through device-ssh.sh. Stdin JSON: action=query plus apple_id; or action=stop plus apple_id and bundle_id. No credentials, request links or tokens go in argv/environment. Build/upload with device-scp.sh, install/sign/trust through device-ssh.sh as other native tools. Both script configurations live at their tops, without environment configuration.

## iCloud companion device management

`queryICloudDevices:completion:` reads the native account-associated device list and each device detail. It returns `{apple_id, devices: [{device_id, name, model, current_device, find_my_enabled}], source: native_settings_server}`. Account-associated devices may have iCloud or Find My disabled. Exactly one current-device marker must be recognized; ambiguous/missing markers are errors, never an empty list. Raw links, serial numbers, machine IDs and native clientInfo are not exported.

`removeOtherICloudDevices:completion:` removes all devices whose fresh native marker is false, preserving the unique current device. It takes no device name or hardcoded target. Matching primary iCloud and phone identity are required. It preflights the initial targets, refreshes details before each native Remove from Account confirmation POST, preserves native postback/signing, and verifies target absence and unchanged current-device identity after each write. Unknown results stop further writes and activate the shared fence; confirmed partial removals are returned as removed_device_ids. Success returns `{outcome: succeeded, already_removed, removed_device_ids, settings: <fresh query>}` and requires only the original current device to remain. New devices appearing during execution cause final verification failure rather than an unbounded deletion loop.

`queryState.icloud.devices` is a section with status/data/error. Without selected primary iCloud it is not_signed_in; query failures do not discard other profiles, and changed account identity discards earlier device data. The standalone `apple-icloud-devices.m` accepts stdin action=query or remove_others plus apple_id. Its outer deadline is 3600 seconds for serial multi-device work; the aggregate state runner now waits 600 seconds.

2026-10-10 重新绑定初始化：用户主动再次beginAddingContactEmail时，服务串行核对当前账户，清空旧原生challenge/model及认证/签名会话，重新准备原生认证环境并fresh读取reachable_emails；目标已经验证则返回succeeded/already_verified，未绑定才发新请求与新challenge。只允许同一Apple ID的邮箱begin/verify未知结果通过新begin恢复，且新begin成功后才解除邮箱专属unknown标记；其它写操作未知结果不因此解锁。task31允许同账户替换旧邮箱挑战，旧challenge立即不可提交；busy仍拒绝并发，结果历史继续保留。RV提供独立「重新发送绑定」命令，保持原资料并刷新新邮件基线，旧验证码不自动重放。只读取码按钮仍不发新邮件。主机回归/编译与真机绑定验收区分，新恢复流程尚未进行真机账户写入验证。

Email verification recovery: after an OutcomeUnknown result from the submitted native verification transport, the module performs a separate fresh AuthKit server read. Success requires the requested email in reachable_emails and unchanged session identity. Missing email, unreadable state or changed identity remains unknown. The verification POST is never replayed.


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

## 2026-10-15 iCloud 明确失败与迟到回调

CDP 输入 provider 的明确错误与总 completion 共用 first-terminal gate，条款/本机密码/恢复输入拒绝立即返回，不再等待 240 秒总 completion 兜底。总 completion 明确失败返回 `TVAppleErrorNativeFailure`（code 11），仅保留白名单 native domain/code；未收到 completion 的超时或成功回调缺失 account 仍为 code 6。失败结果可能带 `account_state_may_be_partial=true`，表示原生后台可能已有部分账户副作用，不改变明确失败的 outcome。后续账户读取失败不覆盖原始明确 iCloud 错误。

ZXTouch adapter 始终记录 completed，并在缺少 result 时归一化 outcome 为 failed/unknown；完成后移除挑战、释放功能会话并永久关闭验证码 provider。重复或迟到回调不能覆盖终态或打开旧挑战。HTTP/2 可恢复状态流为独立设计，见 [设计文档](../../../docs/apple-operation-stream.md)，尚未实现或声明能力。
