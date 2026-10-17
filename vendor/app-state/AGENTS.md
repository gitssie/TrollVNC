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
