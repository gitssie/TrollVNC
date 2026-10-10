# Validation — 2026-10-07

## Automated host checks

`rtk proxy bash vendor/apple/tests/run_tests.sh`: 43 cases passed, compiled with ARC, `-Wall -Wextra -Werror`.

Covered targeted logout order, preservation of other identities and inactive media history, explicit keep/remove policy, invalid requests, preflight rejection before any mutation, Find My refusal, read failures, uncertain native callbacks, callback success with persistent records, failed final queries, process-wide write fencing, idempotent repeated logout, and exact dataclass-action selection including malformed/ambiguous/unknown actions.

The injected backend tests exercise orchestration; the dataclass policy tests exercise the same helper compiled into the native backend. They do not substitute for a signed-in device regression of private APIs.

## Device checks

Built the complete module and standalone test executable for arm64 / iOS 15 deployment target with the iPhoneOS SDK. Ran on the connected iOS 15.8.8 device under its jailbreak trust environment.

- Native account query succeeded with effective entitlement checks.
- Initial baseline: no primary iCloud or idms account; no active media account; Find My disabled.
- Eight historical/local media records remained unselected.
- `--self-test` passed real native query and random nonexistent-target signout: `already_signed_out=true`, verified success, account identifier set unchanged.
- No Settings UI checks or UI automation performed. See the separate login attempt below.

The fresh module's actual deletion path has **not** been rerun on a signed-in phone because the device was already signed out. The underlying iCloud, identity and media removal APIs were verified earlier in the session using native probes; this module adds their sequencing, preflight and final verification. Real-account keep/remove dataclass-policy regression remains to be run on a suitable signed-in test device.

## Review and integration boundary

Independent code review completed; three important findings corrected (primary selection, incomplete media backing identity and action-name matching). Login review also identified partial-state reporting, malformed-response handling and shared-code ticket issues; all were corrected, with regression checks.

This task added `vendor/apple/` and the sibling `vendor/appstorectl/`. TrollVNC's build, transport, services and UI have not been integrated or altered by this module work. Upstream appstorectl is retained as a complete pinned snapshot in `vendor/appstorectl/` and is not compiled wholesale.

## App Store login and external code submission

The iOS 15.8.8 phone executed the complete Store → AuthKit path. The module emitted a structured `requires_verification_code` event with a unique challenge identifier. A caller-side curl fetched the supplied endpoint once; the caller submitted the code as a separate JSON line. The module performed no URL polling and did not invoke terminal input for the owned challenge.

The initial default XML flow printed `Unsupported object model found: missing page` and returned `AKAuthenticationError -7014`. Runtime inspection and differential device tests showed an alert-only XML response with no pages. Native JSON mode (`initWithVerificationType:1`) reached code verification. Its built-in branch submitted a phone/SMS request, which rejected the supplied trusted-device code with -7039. These are observations of specific private call paths, not universal error definitions.

A diagnostic adapter submitted the trusted-device request instead. Although that AuthKit attempt still returned a client-side -7014, the subsequent Store operation returned `outcome: succeeded`, `signed_in_domains: [media]`, `two_factor_bootstrap: false`. Independent native queries, including the module's state tool, confirmed the target active media record was authenticated. No selected primary iCloud account was present. **App Store login was verified; iCloud enablement was not.** The successful Store attempt used trust established by the earlier diagnostic request.

The production adapter now creates and signs the trusted-device request through native helpers and forwards the actual HTTP response through the native verifier. Runtime/machine-code inspection established the NSNumber code callback and HTTP-response/body/error ordering. Host regression checks exercise request path/body, leading zeros, native signing, actual response forwarding, unsupported preflight, passive getters, shared challenge input and late-input cancellation. Both device tools compile with the current source.

The production adapter's complete bootstrap has **not yet been rerun on a fresh untrusted device**. The diagnostic device success and host adapter tests must not be described as that remaining end-to-end regression. Compatibility with other OS versions and server-provided authentication pages also remains unverified.

## Native iCloud investigation and manual Settings baseline (historical; superseded by formal enablement below)

The native diagnostic tool obtained real AuthKit authentication results and passed them to `AASignInFlowController.signInWithIDMSAuthenticationResults:completion:`. AppleAccount generated the network request. Attempts failed before CoreCDP: historical logs show NAC/Absinthe context initialization failure (`com.apple.AppleAccount.Error/-4403`) followed by login validation failure (`com.apple.appleaccount/400`). Changing the temporary AuthKit service/configuration flags did not resolve it. A signing-context or entitlement difference remains a hypothesis, not a confirmed fix.

The user then completed iCloud login manually in Settings: Apple ID password followed by the device unlock passcode, with no additional 2FA prompt reported. Historical native logs on 2026-10-07, China time, show:

- 13:38:00: new iCloud account sign-in and `InitializeAbsinthe` begin; provisioning response arrives at 13:38:06.
- 13:38:20–13:38:26: CoreCDP requests and receives the local secret.
- 13:38:42: silent escrow recovery reports `joinAfterRestore succeeded`.
- 13:38:44: `Validating iCDP succeeded! Proceeding with iCloud sign-in...`.
- 13:38:51: dataclass save stage completes.
- 13:39:05: `AAUISignInController signed in with authentication results successfully!`.

A fresh module query after the manual operation confirms the target primary iCloud account, enabled cloud dataclasses. The initial dataclass-based Find My check reported disabled; subsequent FindMyDevice shared state reported active, and the native deletion plugin refused removal during its FMIP check. This validates the manual baseline; **the module's own iCloud enablement remains unverified and unavailable**. The earlier independent iCloud logout attempts made while Find My was still active did not remove the account; see the subsequent post-disable validation below. The diagnostic tool had not submitted the device passcode because it failed earlier.

## Authenticated Find My disable — device verification

The formal module first obtained a native AuthKit credential and a Find My wipe token. The paired-device API rejected a nil device UDID with FindMyDevice error 1. The implementation now uses the native Settings path, disableFMIPUsingToken:inContext:completion:, context 1 on iOS 15.8.8.

The second formal execution completed native disable. Its initial final verification rejected state 3 because the reader had an incorrect enum boundary. Independent native reads confirmed daemon state 3 with no error, fmipActive=false, and Settings cache available=true/enabled=false. The reader now accepts only observed states 0/1 (on) and 3 (off); state 2, state 4, other states, and any NSError fail closed. A regression test exercises the production reader, including duplicate callbacks.

The rebuilt formal tool returned outcome=succeeded, already_disabled=true, find_my_enabled=false, while the primary iCloud account remained present. Thus the real on-to-off native operation and the corrected final-state/idempotence path are verified in separate runs; the final enum fix has not been rerun from an enabled state. No UI automation or credential persistence was used.

## Independent iCloud logout — real signed-in device

After authenticated Find My disable, the signed formal iCloud logout tool executed with explicit remove policy on iOS 15.8.8. The invocation returned unknown without a successful deletion callback. A subsequent fresh module query confirmed the primary iCloud account was absent, while selected idms and authenticated App Store accounts remained; Find My stayed disabled. Native logs record iCloud account deletion and related AIDA cleanup at 14:23:55 China time. The exact callback failure/timeout cause remains unresolved; ancillary CloudDocs logout logs include NSCocoaErrorDomain/4097, which does not establish causation.

The module now includes fresh state and target_signed_out in an unknown removal result when the read succeeds, without clearing its mutation fence or treating an uncertain callback as success. Late/duplicate native removal callbacks are ignored after ticket closure. The rebuilt tool was run only after independent state verification, and returned succeeded/already_signed_out=true with media/idms preserved. This verifies actual account removal and subsequent idempotence separately; the final reporting revision has not been rerun against a newly signed-in account. The selected remove actions were submitted; deletion of every local file was not separately audited.

The repeated invocation used tests/device-ssh.sh successfully. The script stores only editable connection parameters, takes remote program/arguments, accepts sensitive input on stdin, uses verified host keys and key-based BatchMode, and restores terminal state on exit.

## Native iCloud enablement — formal module, 2026-10-07

The module executed native AuthKit → AASignInFlowController → CoreCDP on iOS 15.8.8. The first run created the primary iCloud account and dataclasses, but local passcode verification failed. Apple treated this CDP input error as nonfatal and continued saving; the module correctly retained unknown because provider.failure overrides native success.

The signed second tool added effective com.apple.keystore.device alongside CDP/profiled-access permissions and ran full authentication/CDP again against that partial primary. It returned succeeded, already_enabled=true, signed_in_domains=[icloud, identity, media], find_my_enabled=false. The already_enabled flag did not skip the native flow. Static native log evidence (China time): 14:40:40 local-secret prompt; 14:40:41 local secret received and silent recovery attempted; 14:40:56 successful silent recovery; 14:40:58 backup recovery reports success and dataclass/account save completes. No additional 2FA challenge occurred.

The final provider explicitly rejects recovery-key, beneficiary-key, EDP, remote-device and multiple-ICSC interaction branches. Eight direct production provider regressions supplement ten service enablement checks, bringing the host suite to 61 passing checks. Current state and enablement tools compile/sign for arm64 iOS15. The device success was achieved in two runs; the final provider rejection additions have not been rerun as fresh signed-out onboarding, nor has a fresh untrusted account or another OS version been validated. No credentials, native response bodies or composed authentication log messages were retained in project files.

## Complete logout integration test after formal iCloud enablement

Added only tests/apple-logout.m and its build entry; production logout logic is reused unchanged via signOutAppleID:localDataPolicy:completion:. The device integration test validates no selected matching identity remains across iCloud, identity and media in the returned fresh state. Credentials are supplied on stdin and remove policy is explicit.

On iOS15.8.8, the first invocation removed primary iCloud but returned unknown at its native deletion callback, so the module correctly stopped before identity/media. A separate fresh read confirmed iCloud absent and only identity/media selected, with Find My disabled. After that completed call and independent observation, a new test invocation processed only those remaining domains and returned succeeded, completed_domains=[identity,media], verified_all_domains_signed_out=true, selected_accounts=[], find_my_enabled=false. This is a complete verified logout achieved in two controlled invocations, not a successful single-call full logout; the iCloud callback issue remains unresolved. No merge or UI verification was used.

## iCloud deletion callback reconciliation — 2026-10-07

A targeted formal reproduction captured a timely callback with native success=YES and NSError=com.apple.accounts/17. Xcode Accounts/ACError.h calls 17 ACErrorDeniedByPlugin. Native static logs distinguish accepted account removal from subsequently failed dataclass actions: Plugins did not deny removal, followed by Failed to perform dataclass actions (17), then Account removed. The old ok&&!error predicate incorrectly treated this known account-deletion result as unknown.

The production backend now reconciles only primary-iCloud YES plus that exact domain/code, after a fresh query verifies both the old identifier and matching primary are absent and Find My disabled. It returns a sanitized dataclass_action_failed warning; this is account-logout success, not a guarantee that all local data actions completed. False callbacks, other errors, unreadable state, remaining accounts and Find My enabled remain unknown. Known warnings are retained even in unknown results. The actual backend-boundary regression failed before the fix, then passed; ten added callback/warning checks bring the host suite to 71. Independent review found a warning-loss branch, which was corrected and covered.

Further repeated device cycles exposed a separate daemon hang: the SearchPartyAccountNotificationPlugin waited for searchpartyd.removeLocalAccountDataWithCompletion and received no callback within 60 seconds, leaving the primary account present. Reusing ACAccountStore.defaultStore did not solve it and that experiment was reverted. Sender-image metadata identified SearchParty; the test operator restarted only system/com.apple.icloud.searchpartyd via launchctl kickstart -k. At that stage no restart was added. The subsequent bounded preflight recovery is documented below; no Find My bypass was added.

After recovery, the same production logic (instrumented test runner) returned succeeded in one call, completed_domains=[icloud,identity,media], warnings=[icloud dataclass_action_failed Accounts/17], selected_accounts=[], verified_all_domains_signed_out=true, Find My=false. A separate fresh read also confirmed no selected account. This validates the account callback fix on a real deletion, while retaining the separate daemon-hang and incomplete-data-action limits. Final production sources contain no temporary DEBUG-cloud-remove instrumentation. The clean standalone logout runner is cazer-apple-logout-v5.

## Post-fix login retest

After the one-call complete logout and an independent empty-selected-account read, the clean App Store runner cazer-apple-login-v5 returned succeeded, two_factor_bootstrap=false, signed_in_domains=[media]. A separate account query confirmed selected authenticated media, no primary iCloud/idms yet, and Find My disabled on this device. App Store may affect Settings identity on other paths; the test therefore queries all domains rather than assuming media-only side effects or treating a visible Settings header as proof of CoreCDP completion. The subsequent separate enablement retest uses cazer-apple-icloud-enable-v4.

The post-fix iCloud call returned succeeded, already_enabled=false, signed_in_domains=[icloud,identity,media], find_my_enabled=false. Thus this clean login cycle successfully performed Store login followed by fresh primary-cloud/CoreCDP enablement, without the earlier partial-account repair path or a new verification-code prompt. The final device is intentionally left signed in with iCloud enabled and Find My disabled.


## SearchParty automatic recovery (2026-10-07)

A deliberately SIGSTOP-paused searchpartyd reproduced an unresponsive native health call. The formal module restored only that launchd job before submitting removal, reprobed successfully, and returned succeeded with service_recoveries containing one before_account_removal item, completed_domains=[icloud,identity,media], selected_accounts=[], verified_all_domains_signed_out=true and Find My disabled. Accounts/17 dataclass warning remains separately reported. No deletion was replayed.

A subsequent ordinary Store login and iCloud enablement both succeeded; complete logout then succeeded in one call with service_recoveries=[] without operator restart. The final root helper's internal command supervision was separately exercised with another paused daemon; health CLI returned ready=true/recovered=true. These tests cover complete daemon unresponsiveness and a normal account cycle, not every possible internal SearchParty plugin deadlock.

Initial native manager lifecycle and same-session-queue probes exposed private framework assertion/notification crashes. Formal code now retains one description owner without starting its beacon observers and probes an independent FMXPCSession through an adapter queue. Host tests cover closed late/duplicate callbacks and blocked proxy deadlines. The helper's actual supervision function is tested with normal/nonzero children and a stalled child killed/reaped within its deadline. Existing 71 host checks plus the SearchParty and helper suites pass; arm64 iOS15 tools build and sign. Other iOS/jailbreak versions remain untested.


## Apple ID email settings discovery and read query (2026-10-07)

The formal arm64 iOS15 `apple-email-settings` v3 tool completed a fresh native AuthKit fetch on the signed-in device. It returned reachable_emails=[], the native forwardingEmail, and null primary_email/server_account_name because those fields were absent. This verifies the actual dictionary-to-AKUserInformation parser and read path; it does not prove iCloud Mail forwarding or contact-email mutation.

Nine new host cases pass for sanitized field parsing, service normalization/input rejection, native fetch success/error/timeout, duplicate/late callbacks, changed phone identity and conflicting response identity. Existing module, SearchParty and recovery-helper suites also pass. Native Settings ServerUI signing and personal information loading returned HTTP200. The legacy AAAddEmailUIRequest instead loads an @icloud.com mailbox creation form and was not submitted. At this discovery stage, contact-email addition/verification and forwarding writes were unimplemented; subsequent actual execution is recorded below.

The correct server-advertised alternate-email addition form also loaded with HTTP200, exposing editable field `address` and a POST verification action. No address/code was submitted and no email setting was mutated.


## Contact addition and global private-relay forwarding (2026-10-07)

Formal email-actions v2 returned `requires_email_verification`, accepted a separately supplied fresh email code in the same process, then returned succeeded. An independent native AuthKit fetch showed the destination in reachable_emails. Earlier probes and v1 did not complete verification; v1 refused before OTP submission because asynchronous loader cleanup changed model.sourceURL. Fixed resolution uses the saved native origin, with a regression, and challenges are consumed only after preparing a valid request.

The separate native AKURLBag private-email page exposed both an existing App's private-email record and the global forwardemail action. Its single-page form used forwardToEmail, ak-button/read, and exact POST forwardemail/put. Formal v4 executed that save once, returned succeeded/already_configured=false, and fresh AuthKit forwarding_email matched the destination. Other App-specific forwarding switches were not submitted. No subscription or iCloud Mail action was invoked, and no App-message delivery test was performed.

Review corrected broad route matching and terminal completion handling. The production observer/result boundary now rejects missing completion even after HTTP200+model, preserves errors after a model, records alerts independently, and ignores late callbacks. New host coverage includes native postback preservation/content type, same-origin/method/path limits, exact forwarding field/button schema, mismatched/duplicate destinations, challenge mismatch/expiry/preparation failure, input normalization and unknown write fencing. Existing module and recovery suites pass. Final lifecycle/deadline changes have host coverage; the contact-add write was not repeated solely to obtain another OTP.

Final v5 built and signed with the terminal-result and authentication-lifetime fixes. On-device forwarding returned succeeded/already_configured=true without another POST; a separate query again confirmed the destination in reachable_emails and forwarding_email. Independent final review found no remaining important issues in the reviewed changes.


## User-confirmed relay delivery and Apple ID Settings name (2026-10-07)

After the earlier configuration verification, the user reported that actual email delivery worked. This is a user-performed delivery test; the module itself did not send a message or inspect the inbox.

Read-only native Settings discovery on iOS15.8.8 confirmed the three editable fields firstName/middleName/lastName and the native POST `/appleid/settings/account/manage/person/name/put`. The standalone formal `cazer-apple-name-settings-v1` query read the original names, then saved user-requested First Name `jack` and Last Name `ma` using the production adapter. It returned succeeded/already_configured=false, with a fresh native Settings profile confirming both names and the unchanged empty middleName. A separate process queried the server again and confirmed the same names. Repeating the same request returned already_configured=true without submitting another save. No UI automation or refresh validation was performed.

Host regression covers Unicode/nonblank/control-character/length validation, strict name fields and save route, middle-name preservation, sanitized profile/server identity, the production save and idempotent pipeline, fresh-profile mismatch/read failure producing unknown, facade normalization and the shared mutation fence. Existing account/email/SearchParty/recovery suites pass; the arm64 iOS15 tool builds and signs. Only this trusted signed-in iOS15.8.8 device was tested; newly required authentication and other OS versions remain unsupported/unverified.

Independent review found no confirmed P1/P2 issue and requested two boundary regressions. Added tests exercise POST-success followed by changed identity (unknown) and a live email challenge blocking both name read/write without discarding the session; the full host suite passes. Final name CLI v2 increases its outer wait to 300s to cover the native prepare plus individual transport deadlines, builds/signs, and independently queries the same saved names on-device. Production save logic is unchanged from the successful v1 mutation.


## queryState aggregate read (2026-10-07)

Standalone `cazer-apple-state-aggregate-v1` built/signed for arm64 iOS15 and ran once as mobile through device-ssh.sh without account/password inputs. The public aggregate returned collection_status=complete and collection_consistent=true. App Store was selected/authenticated, primary iCloud had enabled dataclasses, phone identity was selected, and Find My was false. Name section was available with jack/ma and unchanged empty middleName. Email section was available with the verified destination in reachable_emails and the same forwarding_email. Historical unselected media remained only in the original accounts list, not the current App Store summary. This was read-only; no sign-in/out or email/name save was submitted.

Thirteen new host aggregation scenarios cover success, signed-out/history-only, media-only, identity-only selection, independent media identity, name/email failures, unsupported name backend, wrong profile target, ambiguous identities, differing cloud/idms, identities changing between snapshots, and initial/final read failures. Existing module/auth/email/name/SearchParty/helper regressions also pass. The profile errors remain section-level and sanitized, and changed identities discard earlier profiles rather than presenting mixed data. Independent review found no confirmed P1/P2 issue. Neither per-section device failure nor a real device identity switch was induced; those failure branches are host-tested.


## Simplified aggregate JSON and iCloud Find My field

Per the user's schema requests, current public queryState moves Find My to icloud.find_my_enabled and removes collection_status/collection_consistent. Internal snapshots and mutation result states retain their existing top-level Find My field. Section-level failure reporting and internal identity checks remain intact.

The full host suite passes, including 14 aggregation scenarios (added native Find My true-value propagation), with assertions that the old top-level/collection keys are absent and both true/false values appear under iCloud. Final arm64 signed runner cazer-apple-state-aggregate-v3 ran on-device and confirmed icloud.status=signed_in/find_my_enabled=false, name/email available, jack/ma, and no collection markers. This is a read-only shape change; no cloud or Find My setting was changed.

## Sign in with Apple and reusable SCP wrapper (2026-10-07)

The formal signed arm64 `cazer-apple-siwa-v2` queried native Settings on-device and returned Vinted, bundle_id `lt.manodrabuziai.fr`, client_id `lt.manodrabuziai.fr.app`. Server-provided session query parameters are preserved internally; public results omit detail URLs and raw forms. Aggregate runner v4 independently returned the same list under apple_settings.sign_in_with_apple with status=available, iCloud signed_in/find_my_enabled=false and no collection markers.

Host tests cover list and confirmation schema validation, native XML confirmation capture, exact target and POST route binding, preservation of native postback/query data, successful/idempotent revoke pipelines, failed fresh verification and identity changes producing unknown, challenge conflicts, and the shared write fence. The full suite passes, including 15 aggregation scenarios. Both device tools build and sign. Independent review found no confirmed P1/P2 issue. A separate read-only on-device probe loaded Vinted's native confirmation and constructed the production revoke request with a native body (REVOKE_PREPARED=1/error=0); it did not submit the POST. An actual app authorization has not been revoked on-device; no test target was selected by the user.

`tests/device-scp.sh` uses the same fixed device connection settings as device-ssh.sh, with key authentication, BatchMode and strict host-key checking. Its upload and download paths were exercised with a real device binary; the downloaded file compared byte-for-byte equal to the original. Shell syntax validation passes. Directory transfer is supported by --recursive but was not separately exercised on-device.

## Vinted authorization removal and final-grant empty list

At the user's explicit request, formal SIWA v2 submitted the native Vinted removal once. The subsequent verification returned unknown because the actual empty-list page was not recognized. The user independently confirmed successful removal in Settings. A read-only native shape probe confirmed connectedAppView with one anonymous empty section, empty attributes and no rows; this is the server's final-grant removal response, rather than the previously tested identified empty section.

A regression reproducing that exact structure failed before the fix. The parser now accepts only this additional observed empty shape under the recognized table, while rejecting anonymous sections with rows, named unknown sections and multiple anonymous sections. Full module tests pass, including a native-empty post-removal pipeline, idempotent follow-up, and sanitized query. Arm64 SIWA v3 builds/signs; its independent on-device query returned apps=[]/bundle_ids=[]. Its follow-up stop returned outcome=succeeded/already_stopped=true without another POST. The initial unknown response was not blindly retried. No device account logout or forwarding-setting change was performed.

Final signed aggregate v5 independently returned apple_settings.sign_in_with_apple.status=available with empty apps/bundle_ids. App Store and iCloud remained signed_in. Temporary on-device shape instrumentation was removed after verification.

## New-account switch with formal trusted-device bootstrap

At the user's request, complete logout v11 removed all selected iCloud/identity/media accounts in one call and independently verified all domains signed out, with the known Accounts/17 dataclass warning retained and no SearchParty recovery needed. Formal login v5 then switched to a different account, issued a trusted_device challenge, accepted the externally supplied code in the same process and returned succeeded/two_factor_bootstrap=true with identity/media signed in. This validates the formal bootstrap path for a new account on this existing trusted jailbroken device; it does not cover every fresh-device or SMS flow.

Formal iCloud enablement v4 subsequently returned succeeded/already_enabled=false with all three domains signed in and Find My false, without another verification-code challenge. Independent aggregate v5 confirmed App Store, iCloud and identity all selected the new target account, with Find My disabled. No credentials, code or retrieval endpoint are retained in this record.

## iCloud companion device query and non-current removal

Read-only AuthKit and native Settings probes on iOS15.8.8 found the current iPhone and an iMac account-associated record. Native AKURLBag.trustedDevicesURL loaded the Settings RUI device list, and its native details explicitly marked the phone isCurrentDevice=true and the iMac false. SearchParty was not used for these queries or device removal. AppleAccount request/header and AuthKit header research was treated as discovery only; the implemented route and confirmation schema were verified at runtime.

Formal signed `cazer-apple-icloud-devices-v2` queried both devices with current_device markers, sanitized names/models and Find My state. Production v3 then ran removeOtherICloudDevices once, selected all non-current records without hardcoded device names/IDs, submitted the iMac's native Remove from Account confirmation, and returned succeeded/already_removed=false. Fresh verification showed only the same current iPhone remained. This tests one actual non-current target; batches of multiple real devices were not available on this account.

Full host tests pass, including batch deletion of two arbitrary non-current targets, current-device exclusion, exact target and route binding, native resource confirmation capture/postback retention, missing/ambiguous markers, unknown fresh reads or changed current identity stopping further POSTs, confirmed partial removals, idempotency and facade normalization/shared write fence. Aggregate cases cover devices failure/unsupported/wrong-account/identity change and no selected iCloud. Review identified a missing sourceURL on the test substitute, which was fixed before actual device removal; re-review found no remaining confirmed P1/P2. Production list/detail transport is exercised on this device, while broader OS/schema/authentication behaviors remain unverified.

Repeat formal removal returned succeeded/already_removed=true with removed_device_ids=[] and no further POST. Independent signed aggregate v6 returned icloud.devices.status=available with only current_device=true for the phone, Find My false, and iCloud/identity/media still signed in. Temporary discovery code and installed discovery tools were removed after verification.

## Name update and complete Sign in with Apple authorization cleanup

On the user's newly selected account, formal name-settings v2 saved First Name Alex and Last Name Morgan, returning succeeded; a separate native read confirmed both names and empty middleName. The current native SIWA list contained one Vinted grant. Formal SIWA v3 removed it and returned succeeded/already_stopped=false with apps=[]/bundle_ids=[] in the fresh verification. This validates the corrected final-grant empty-list parser after an actual successful POST, beyond the earlier idempotent-only v3 check. No app-specific cached session or full device sign-in was removed by this operation.

## AuthKit name synchronization after Settings save

The user reported that a Sign in with Apple popup still displayed the old name. A native read-only probe confirmed Settings server/primary iCloud given/family names were Alex/Morgan while the primary AuthKit identity retained old names. Native fetchUserInformationForAltDSID returned the new server names and refreshed the identity cache; a subsequent independent process read primary iCloud, primary AuthKit and cached getUserInformation as Alex/Morgan. A later updateUserInformation probe returned NO with nil error after names had already converged; it is not used by the production fix or counted as a successful synchronization method.

The name setter now performs a native fresh fetch and verifies both account identities and cached user information before success, including the same-name no-POST repair path. Formal signed name-settings v3 returned succeeded/already_configured=true for Alex/Morgan only after the new AuthKit checks passed. Host tests cover stale account/cache data, wrong server identity, malformed/failing fetch, timeout, duplicate/late callbacks, and both save/idempotent refresh failures mapping to unknown. Review found no confirmed P1/P2. This verifies native cache state, not the actual app popup rendering; user confirmation of a reopened app login remains a separate check.

Final name-settings v4 builds/signs and is installed with a shared-deadline guard; additional cached-get timeout, identity change during cached-get, and delayed convergence regressions pass with the full suite. Native cache discovery probes were removed after verification.

## Relay destination on the switched account

Formal email-actions v5 added the requested contact destination to the newly selected account, received a fresh externally supplied email verification code in the same process, and confirmed reachable_emails contained the destination. The subsequent global Sign in with Apple forwarding save returned succeeded/already_configured=false. An independent follow-up native AuthKit query confirmed forwarding_email matched the requested verified destination. The user subsequently confirmed receipt of the forwarded message after initially reporting no delivery. This is user-observed delivery, not an automated mailbox test; the cause of the delay was not established and no AuthKit forwarding-cache fix was needed. No code is retained.

2026-10-10 验证提交后的 RemoteUI 超时恢复：真机312的fresh queryEmail确认此前用户提供的Outlook目标已经在reachable_emails中；TrollVNC内queryName与独立原生个人信息读取均正常完成，未证明加载器普遍阻塞。旧verifyChallenge在load返回unknown后立即退出，跳过fresh服务端确认。313改为仅在已提交验证码POST返回模块OutcomeUnknown时继续独立TVAppleNativeEmailSettings读取，并验证session身份未变；目标确实在fresh reachable_emails且读取无错误才返回succeeded。缺失目标、读失败或身份变化保留unknown，不重放POST、不把HTTP200当成功。回归覆盖同一真实verifyChallenge调用链：HTTP200/no terminal/model + 服务端已绑定、未绑定、读失败、身份变化；首次旧代码复现失败，修复后通过。真机已验证当前绑定状态；新提交导致的超时分支尚未在真机重放。

同轮真机312经真实task31重新begin之前先fresh确认目标已在reachable_emails中，调用返回completed/error=null/outcome=succeeded/already_verified=true；没有发送新验证邮件，邮箱专属unknown恢复路径已实际返回成功。313的POST超时后fresh恢复分支为主机生产调用链回归，未在真机重新制造验证码POST超时。313本地源索引HTTP检查通过；独立审查无重要问题。


## 2026-10-10 / 3.2-314：撤销跨功能写栅栏

本节覆盖此前关于 shared Worker、unknown 写栅栏以及全局 busy 的设计约定。用户明确要求一次操作失败不阻止其它功能。

- Services 删除静态 uncertainMutation；每次结果只由该请求的返回/错误决定，unknown 不拒绝后续写入，也不要求重启模块。
- 原生工作队列可并发；name/email/authorizations/devices 使用各自 SettingsSession。task31按具体功能维护当前请求与验证码 provider；仅同一原生会话尚在执行时返回 busy，完成（含错误）释放。账户身份预检 queryAccountState 不查询网络 profile，不被登录挑战或邮箱操作占用。
- 新 signOutAppStore 只退出选中的 media 账户，保留 iCloud、identity、历史媒体记录。媒体退出不依赖 Find My；原有云账户身份、设备及数据策略检查继续有效。
- 真机捕获的 Native Invalid Email alert 仅在 parser succeeded、HTTP200、无普通 page 且确切 title/message 匹配时返回 InvalidRequest/code3。未知原生提示仍返回 unknown；不将 HTTP200 当绑定成功。当前用户指定目标被 Apple 返回 not available，与之前已绑定目标不同，不能用旧地址的查询说明当前目标已绑定。
- 本机使用314正式包已完成安装；原生并发与原始错误分支检查、RV面板隔离检查通过。账户写操作不会因为结果未知自动重放。

314安装后：正式task31的queryAccountState完成；并发queryName与queryEmail都获running，queryName最终completed/无error，queryEmail本次原生fresh查询超时code5。超时没有阻止账户/姓名读取。重复建立USB SSH通道的诊断曾出现banner/转发超时，切换固定SSH端口转发后协议健康检查正常；不要将其当作新增账户操作已成功。

随后314正式服务再次明确初始化当前绑定请求，返回requires_email_verification（无error），期间独立queryAccountState completed/无error；本次没有取码或提交验证码，不能报告已绑定成功。前述Invalid Email仅描述较早请求的原生响应，当前阶段已改变。


## 2026-10-10 / 3.2-315：接口成功直接完成

用户明确要求以 Apple 原生修改接口的成功响应决定结果，覆盖历史文档中成功后 fresh 复核、缓存同步及超时后查询恢复的完成判据。姓名、邮箱验证、转发邮箱、SIWA 撤销、设备移除，以及 Services 层 Store/iCloud 登录退出、Find My 关闭不再因成功后的查询失败或缓存陈旧返回 code 6。成功写入返回 outcome=succeeded；不输出伪造的查询 settings/state，不重发写入。原生响应必须完整、无错误及拒绝提示；HTTP 200 本身不代表原生操作成功，超时仍保留原始错误。身份、输入、服务器提供的请求路由和下一个设备写入前的预检继续保留。

RV 通过独立 queryAccountState 更新登录/退出菜单，Store 与 iCloud 分别判断，状态刷新不改写原操作结果。本次没有再次提交真机改名。

## 2026-10-10：原生 App Store Review / None 美国账单

真机 iOS15.8.8：AuthKit → Store Review → 原生预转换认证 → native FairPlay/SAP priming → 美国账单校验 HTTP200/status0/无字段错误 → 最终 createAccountSrv context=convert HTTP200/status0 → 后续 Store 认证成功且没有 Review。全过程未通过 UI 点击或显示页面完成。详细成功流程及引用见 [native-store-review.md](native-store-review.md)。当前为 private 接口和探针，未部署新正式包；整理后的失败处理回归与首次成功测试分别记载，不把它们等同于第二账号的完整真机回归。

### 2026-10-10 ZXTouch Store Review 登录分支

正式 NativeBackend/Services 登录现支持自动首次 Review；task31 signInAppStore 参数保持 apple_id/password。主机全模块回归通过，新增 StoreSignInTests 覆盖普通登录不取地址、六字段映射、失败停止、只提交一次、后续 Store 登录失败/未知保留 review_completed。StoreReviewAuthenticationTests 调用真实 production prepare 适配，确认 type4预转换 context 保留。ZXTouch适配器和真实TCP Python回归通过，arm64 socket探针编译链接签名通过。

iOS15.8.8 真机已运行只读取址探针 apple-store-billing.m：Foundation NSURLSession 直接 POST 地址工具成功，六个 Apple 账单字段齐全，电话拆分正确。没有使用主机Python获取该次地址。此测试不修改账户。先前 Review/None 保存与后续登录是真机原生探针成功；新ZXTouch自动Review组合分支尚未以第二个未开通账户做完整真机转换，未打包安装到运行中的daemon。后续安装后应通过同一operation_id验收，不重放已完成转换。

2026-10-10 后续已完成另一未开通账号的 ZXTouch 真机完整验收：signOutAppStore → signInAppStore/SMS submit_code → iOS自动取址 → native Review/None转换 → 后续 Store 登录 succeeded/review_completed=true。独立轻量账户查询确认新 media selected/authenticated=true，原 iCloud 保留、Find My=false。预转换 type3仅在原生code10/context/合法Review路由齐全时使用新的 response继续；不强制type4。selected media才阻碍 Store 切换。回归新增真实prepare type3保留context、完整编排continuation及不同云/身份账户保持的用例。服务为独立loopback ZXTouch探针，未替换正式daemon包；成功调用流程及引用见 native-store-review.md。不要记录凭据、原始响应或失败试验作为正确流程。

### 2026-10-10 后续三账号真机批次

使用同一源码构建的独立ZXTouch原生服务，按顺序切换三账号；各次轻量账户查询完成，原iCloud账户保留、Find My=false。实际结果：

| 测试账号 | 结果 | 已确认阶段 |
| --- | --- | --- |
| budsengeriqd@hotmail.com | 失败，AuthKit -7014 | code challenges=0，未产生验证码挑战，没有媒体登录 |
| murlbodegmb@hotmail.com | 成功 | SMS新码单独submit_code、iOS自动取址、Review/None保存、authenticated=true/review_completed=true；独立查询media selected/authenticated=true |
| hoytzemlakyye@hotmail.com | 失败，AuthKit -7014 | code challenges=0，未产生验证码挑战，没有媒体登录 |

失败发生在AuthKit认证而非Review最终提交；仅凭-7014尚不能判断账号限制、原生响应分支或网络根因。没有把未知原因写成已确认知识，没有重放账单转换。三账号批次为1成功/2认证异常，不宣称全部成功。最后失败后当前媒体域未登录。临时listener已关闭，正式daemon未替换。测试连接启动前等待READY，避免将USB转发TCP连接成功误当作手机listener已就绪。

2026-10-10 按用户要求追加第四账号 hectorrathkix@hotmail.com：ZXTouch请求已执行并完成，AuthKit返回-7014/code challenges=0，没有验证码provider挑战、没有进入Review；轻量查询确认媒体账户未登录，原iCloud保留、Find My=false。该批次累计四账号1成功/3认证异常；不能据此判断-7014的根因，未重放转换或替换正式daemon。

2026-10-10 网络对照：同一真机相邻测试 hectorrathkix 与已成功 murlbodegmb，仅原生AuthKit认证、不提交Store转换。hector约5.6秒返回AKAuthenticationError/-7014且无验证码挑战，murl完成SMS并约10.9秒认证成功。两次认证前后共12次gsa/idmsa无凭据GET探测均取得HTTP响应且无NSURL网络错误；401/403/404仅作为连通证据，不当作账号认证结果。既有失败时段日志显示ServerUI续接返回-7014，另有HTTP200响应。证据不支持当前DNS/TLS/连接/超时故障；具体账号后续交互分支仍未确认。诊断现在保留原生错误domain/code链，不记录native userInfo或认证材料。

2026-10-10 按用户要求追加第五账号 milodoyleimm@hotmail.com：同一ZXTouch原生登录分支完成SMS挑战与外部新码submit_code，iOS自动获取Sacramento/CA/95814账单地址，None付款方式，原生Review保存后Store认证成功；返回outcome=succeeded/authenticated=true/review_completed=true/error=null。独立queryAccountState确认该media selected/authenticated=true，原iCloud保留、Find My=false。该批次累计五账号2成功/3认证异常；本次成功不改变此前-7014根因尚未确认的结论。未替换正式daemon。
