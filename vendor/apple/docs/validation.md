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
