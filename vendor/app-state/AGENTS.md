## 2026-10-29: separate live access-token reader

The explicitly authorized authenticated `/api/apps/access-token` route is separate
from the retired backup/profile methods. `accessTokenForBundle` uses a disposable
exact-group worker's `accessToken` early branch, before backup-root/engine setup.
Only Vintedfr/token is read (including synchronizable items); refresh_token and
arbitrary keychain records are never returned. Bundle and Shadow's current IDFV
accompany the token; identity is sampled before/after. This read does not launch
Apps, refresh tokens, or touch backups. Existing retired public methods stay retired.

2026-10-30 device acceptance: installed formal4.0-15 on the authenticated
iPhone9,2/iOS15.8.8, verifying uploaded package SHA. The production HTTP2
access-token endpoint returned the actual current Shadow IDFV and live token.
After RV rotated credentials, wrote the selected backup and Shadow UI restored
it, the endpoint returned the exact RV-issued access token; Vinted opened and
showed the same signed-in shop profile. RV phone-source request/save also passed.
No refresh token is exposed by this endpoint. No repository publication or
Shadow code change; RV used its existing database for the roundtrip.

## 2026-10-27 / 4.0-14: obsolete public backup interfaces retired

The public executeBundle boundary only dispatches catalog/edit plus the independent App lifecycle methods. save/baseline/switch/delete/describe/profile/sessionSupplement return a known unsupported error before resolving targets, accessing the old store or launching workers. Historical private worker code/tests do not establish public support. Raw authenticated Shadow download/upload remain separate. RV's backup toolbar only refreshes the list; its App-environment registry exposes list/edit, not lifecycle or old backup operations. Metadata editing remains available; backup creation/restoration/deletion belong to Shadow. Host tests explicitly reject all seven retired public operations without launching a worker.

## 2026-10-27 / 4.0-13: Shadow metadata editing; RV switch removed

The existing authenticated task32 edit method now updates only the selected ShadowAppState2 manifest title/note under Shadow's app directory lock. Canonical Bundle/UUID, no-follow directory/file opens, ordinary single-link manifest, bounded reads, exclusive private staging, original owner/0600, fsync/atomic rename and cleanup are enforced. Unknown fields, dates and both archiveInfo dictionaries are preserved; no archive, Keychain, preferences or App operation is involved. It returns the refreshed Shadow catalog. Production HTTP2 metadata roundtrip passed on installed4.0-13, restored original title/note, and independently confirmed state/data hashes unchanged.

RV no longer registers app-switch or renders snapshot/baseline switch buttons. Native switch fails before resolving a target or launching the old worker. Backup rows use the existing Phone-to-RV takeover action, never a restore. The other legacy worker routes save/baseline/delete/profile/sessionSupplement still reference /var/mobile/Media/AppStateBackups and are NOT Shadow support; source audit identified them as remaining cleanup, not a compatible fallback. RV's current credential reader uses the raw Shadow download route instead of legacy profile.

## 2026-10-27 / 4.0-12: explicit RV → phone backup writeback

User explicitly authorized sequential state.tar.zst then manifest.plist writeback and readback verification, superseding the older read-only scope only for this selected backup action. Shadow source and restore logic remain untouched. Authenticated HTTP/2 POST /api/app-state/upload accepts canonical Bundle+IDFV, transfer UUID, bounded part/chunk/offset/total/SHA and expected data archive hash. Writes target only the selected existing snapshot. Each file is staged individually, published in state→manifest order by RV, and retains the original mobile UID/GID and0600. It never writes data.tar.zst, live Keychain/preferences, creates/restores backups or launches Apps. Client first checks the target data archiveInfo; native rechecks its SHA under the Shadow lock.

4.0-12 installed on iPhone9,2/iOS15.8.8. Production SessionHandle HTTP2 tested same-content204800-byte state→53627-byte manifest→both readbacks→phone ownership in an isolated RV database. All three phone backup files retained original bytes/size/501:501/0600, no staging files left. Real RV account execution mode was not switched. No token refresh, phone App restore/launch or device reboot.

## 2026-10-27 / 4.0-11: read-only Shadow state download

User subsequently authorized copying the complete selected state to RV, where Rust
unpacks/parses/stores it. This expands the catalog-only scope below to reading the
raw manifest.plist and state.tar.zst for the selected canonical Bundle+IDFV.
POST /api/app-state/download is authenticated HTTP/2, controlled part selection,
read-only opens under the real mobile ShadowBackups directory. It does not unpack,
restore, create backups, read live arbitrary Keychain or write phone state.

4.0-11 installed on USB iPhone9,2. Production RV SessionHandle HTTP control tested:
Shadow catalog to SQLite, complete204800-byte state download, Rust SHA validation,
unpacking/context extraction/encrypted storage, direct auth read and unchanged
export all passed. 4.0-10 rejected this route with HTTP400, explaining the previously
empty RV data. Only TrollVNC service restarted. No device reboot or respring.

## 2026-10-27: Shadow catalog query only

The user narrowed this integration to querying the backup list. Shadow owns backup
creation and restoration; do not implement those as part of this integration.
`list` reads only `/private/var/mobile/Library/ShadowBackups/<BundleID>/snapshots/<IDFV>/manifest.plist`
with format `ShadowAppState2`, mapping title/note/date/version/build/IDFV to RV.
It does not open or verify archives, read fingerprint preferences, run scoped
workers or invoke Shadow mutation commands. No old-format catalog fallback.
The existing opaque wire identifier is `snapshot:<IDFV>`; it is not a disk path.

Package4.0-10 was installed on the USB iPhone9,2 at the user's explicit request.
Authenticated HTTP/2 list/result and streamed list returned the one actual Shadow
snapshot, matching its manifest. Two polling queries took93/83ms including local
USB/SSH transport and polling. RV imported the actual result into an isolated
SQLite fixture; repeating the import created no duplicate App. Only the TrollVNC
background service restarted; no device reboot, respring or backup mutation.
Packaging now sets the final launchd plist to0644 after editing it:0664 was
rejected by launchctl during the initial4.0-9 installation.

## Dopamine 3 migration (2026-10-17)

This branch supersedes the historical RootHide-only integration requirements below.
Production uses standard Theos rootless packaging and `rootless.h` for package-owned
paths. Real system/container/backup paths stay on `/var`, with no rootfs wrapping.
Copied scoped workers use standard rootless rpaths; do not recreate `.jbroot`
anchors. Keep the same private operation directories and exact target authority.
Host tests model the bootstrap separately from real system data. Device behavior
must be verified on Dopamine 3; old RootHide results are historical evidence only.

# App state module instructions

The user explicitly authorized the authenticated `profile` route to export the selected snapshot's scoped access/refresh token pair to RV for host-side offline tasks. This narrowly overrides the token-export restriction below. Never log the reply or export arbitrary keychain records. `sessionSupplement` stores an exact Bundle+IDFV token pair in an independent checksum-protected plist for explicit restoration. No business HTTP requests or offline task execution belong on the phone.

Read include/TVAppStateServices.h and ../../docs/app-state-zxtouch.md before modifying the service. Source/license and port differences: SOURCE.md. Retain standalone Foundation core; no UIKit, socket, ProjectX profile or daemon dependencies inside this vendor. Socket adaptation belongs in TrollVNC/src/TVNCAppStateService.mm.

Use native exact-target container and keychain scopes. Resolve current install at each operation; archive container UUIDs are not live destinations. Never add wildcard/Apple/system groups to a resident daemon. Each worker is copied into a private0700 operation directory, signed with all validated declared groups, verified, then cleaned. Native keychain authority checks require exact equality. No source token or keychain record export to socket/logs. This uses target app keychain as backup payload; it does not change RV/VNC password or device passcode storage.

RootHide runtime paths use jbroot/rootfs semantic conversion; no random prefix, /var/jb fallback, environment configuration or request-provided helpers. IDFV helper is root-owned and accepts only the native target/vendor/current UUID plus verified system-group plist; sudo authorization is only for the package-owned helper. Current integration supports RootHide/iOS15+; native operations on other schemes fail closed.

Commands consume bundle_id and opaque backup_id, not physical paths. Session save merges optional display_name/note with current metadata; first save requires name, default note empty. Switch saves current first unless discard_current=true; failure never restores automatically or rolls back. Known partial restoration retains durable restorePending and permits an explicit retry; saving incomplete environments is refused. An unknown result belongs only to that operation and never permanently fences subsequent explicit requests. Only an actually active operation blocks concurrency. Explicit deletion accepts current snapshots, pending restore targets and listed version baselines: it removes archives only, detaches current/pending references, and retains restorePending for incomplete live data. Baseline creation does not capture live data; baseline restore clears target keychain (including synchronizable entries) and regenerates IDFV. Main-container SplashBoard is excluded; current source copies tmp contents. Format v2 and current source semantics are authoritative over historical documents.

Tests: build.sh test covers source core/native Security simulation/session plus command mapping and native worker service seams. tests/run_app_state_socket_tests.sh from TrollVNC covers actual TCP with native facade substituted. Rebuild main daemon and both workers with RootHide Theos; host tests do not prove device permissions or real login restoration. Temporary scoped workers/request/progress/signature files must be removed on all known outcomes. Preserve source ProjectX files; modify only this vendor port.

Validation evidence and remaining device acceptance: docs/VALIDATION.md. Root IDFV helper has an 8-second supervised child deadline and exact lsd recovery identity; mobile sudo wait is 12 seconds. Preserve known child error codes. Deletion attempted before failure and unknown baseline creation both report possible archive changes. Never turn unknown into success or automatically retry a mutation.

Basic lifecycle methods launch/stop/status live in src/TVASAppLifecycle.m and bypass scoped keychain workers. Parameters only bundle_id. Stop includes extensions and verifies exact PID/start time/UID/path, SIGTERM then SIGKILL, final fresh process query; never signal by name. launch verifies main process, not foreground UI. status includes installed/running/main_running/extension_process_count/pids and remains readable after an uncertain operation. Host native-seam tests are tests/LifecycleTests.m; device launch/stop acceptance remains pending.

The full lifecycle call is supervised at 6 seconds by the service facade. Its native call cannot be cancelled; pending state is process-wide and survives listener/facade recreation. It blocks concurrent native work only until the actual call returns, including a late completion; no permanent unknown latch is retained. Status cannot launch another native lifecycle call while one remains pending. Cross-instance blocking regression lives in ServiceTests.m.

The backup root is the phone App’s shared real-rootfs /var/mobile/Media/AppStateBackups, resolved with jbroot(rootfs(...)). Do not use the old TrollVNCAppStateBackups test store, migrate its records, or merge same-named snapshots. Keep worker/operation paths package-owned.
