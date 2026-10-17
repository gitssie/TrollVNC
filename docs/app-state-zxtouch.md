# App state commands over ZXTouch

Task32 uses one Base64 UTF-8 JSON payload and response `0;;<Base64 JSON>\r\n`, matching the Apple task31 convention. Base64 is framing, not encryption. It inherits ZXTouch's controlled-network trust model and lack of an authentication handshake.

```python
op = device.app_state.invoke("list", {"bundle_id": "com.example.app"})
listing = device.app_state.wait(op["operation_id"])["result"]

op = device.app_state.invoke("save", {
    "bundle_id": "com.example.app", "display_name": "Account A", "note": ""
})
state = device.app_state.wait(op["operation_id"])

op = device.app_state.invoke("switch", {
    "bundle_id": "com.example.app",
    "backup_id": listing["backups"][0]["backup_id"],
    "discard_current": False
})
state = device.app_state.wait(op["operation_id"])
```

Check final error as well as status: completed means the operation ended, not that it succeeded. wait timeout does not cancel/replay the operation. Preserve operation_id and use result after reconnect. One operation at a time returns busy for overlaps; completed results live in memory600s, max64. IDs do not survive daemon restart.

| Method | Required | Optional |
| --- | --- | --- |
| list | bundle_id | none |
| describe | bundle_id | none |
| launch | bundle_id | none |
| stop | bundle_id | none |
| status | bundle_id | none |
| save | bundle_id | display_name, note |
| createBaseline | bundle_id | none |
| switch | bundle_id, backup_id | discard_current=false, display_name, note |
| edit | bundle_id, backup_id, display_name, note | none |
| delete | bundle_id, backup_id | none |

First save requires display_name; note defaults empty. Existing current backup is fully refreshed, with omitted metadata retained. Optional switch metadata describes the current environment being saved, not the destination backup. An unassigned current environment requires display_name or explicit discard_current=true before switching. discard_current must be a JSON boolean; true cannot be combined with save metadata. Backup IDs (snapshot:YYYYMMDD-NN or baseline:version) come from list and are opaque to callers; no filesystem roots, raw references, scopes or commands are accepted. edit operates on snapshots only. delete accepts snapshots and version baselines; the current snapshot and the archive targeted by a pending restore cannot be deleted.

`launch`, `stop`, `status` take only `bundle_id` and do not access backup/keychain data. `launch` requests native LaunchServices opening and verifies the main process appears within 4 seconds; it can bring an existing app forward but does not promise foreground/unlocked-screen verification. `stop` includes processes executing within the installed app bundle, including extensions: SIGTERM, then SIGKILL after 0.5 seconds for surviving original identities, with a 4-second final verification deadline. Relaunched/new processes are reported as failure, not repeatedly killed. Apple system bundles and TrollVNC itself cannot be launched/stopped through this interface. Process identity is checked by UID, PID/start time and canonical executable path before signaling.

`status` returns `bundle_id`, `installed`, `running`, `main_running`, `extension_process_count`, `pids`. `running` includes extensions; `main_running` describes the main executable. An uninstalled app returns installed/running=false and an empty PID list. Unknown process visibility returns an error, not a false stopped result. All commands use the same invoke/result/wait and busy rules; status remains allowed behind the unknown-operation write fence. Known lifecycle errors can include state_may_be_partial; no backup association is altered.

The service bounds the whole native lifecycle invocation at 6 seconds, including synchronous LaunchServices calls. A timeout does not cancel that native call: launch/stop returns unknown because it may finish later. At most one native lifecycle call can remain outstanding across service instances; status requests fail until it returns. A timed-out or exceptional mutation fences process-wide mutations, including save/switch. Restarting the socket listener or receiving a late completion cannot clear that fence or overwrite the recorded result. Restart the daemon only after resolving any outstanding work and checking the resulting state.

```python
op = device.app_state.invoke("launch", {"bundle_id": "com.example.app"})
started = device.app_state.wait(op["operation_id"])
op = device.app_state.invoke("status", {"bundle_id": "com.example.app"})
current = device.app_state.wait(op["operation_id"])["result"]
op = device.app_state.invoke("stop", {"bundle_id": "com.example.app"})
stopped = device.app_state.wait(op["operation_id"])
```

list returns bundle_id, backups[], current_backup_id (null if unassigned), restore_pending and optional pending_backup_id / duplicate_identity_backup_ids. Each backup has backup_id, kind, display_name, note, date, version, build and idfv. describe returns version/build/current IDFV, container IDs and validated keychain group scope, without credentials or signed raw entitlements. Progress reports phase/stage plus copied bytes/files and savedCurrent where available; no file names or keychain records.

save and switch stop the target app/extensions and leave them stopped. switch saves current before a durable pending marker and target restore; failure leaves pending state, never falsely activates the destination. An explicitly requested retry is permitted after a known completed partial restore; save of a pending environment is blocked. Unknown worker completion/cleanup fences writes until the service is re-established with no outstanding work; list/describe remain available. Errors retain state_may_be_partial/archive_may_be_partial; publication failure may include pending_capture_id for diagnostics, not a switchable backup.

Baseline creation produces an empty template for the current installed version without capturing/changing live app data. Baseline switch clears all target keychain entries, including synchronizable ones, and generates a new IDFV. Snapshot switch restores container/keychain/identity and refreshes preference caches with native readback. Backup format is data-only v2; main-container SplashBoard is excluded and tmp contents follow the source module's current complete-copy behavior. Core validation cannot guarantee a remote app server still accepts historical login tokens.

Native integration requires Dopamine 3/iOS15+ and packaged app-state-worker/app-state-idfv-worker under /var/jb/usr/libexec/trollvnc. The daemon never receives target keychain groups. A copied worker gets exact installed-target scope through on-device ldid, signature readback and effective-authority verification. A package-specific sudo rule authorizes only the root-owned IDFV helper, removed during package removal. Bootstrap paths use standard rootless resolution; system data paths remain on the real data volume. Backups use the phone App’s shared /var/mobile/Media/AppStateBackups directory; explicit backup commands operate on those same records. Worker/operation state remains package-owned under TrollVNC; ProjectX configuration is not used. TrollStore standalone and other packaging schemes are unsupported.

Run `rtk proxy sh vendor/app-state/build.sh test` and `rtk proxy bash tests/run_app_state_socket_tests.sh`. Source/native tests and actual TCP tests have separate boundaries; on-device mutation acceptance must be recorded in vendor/app-state/docs/VALIDATION.md.
