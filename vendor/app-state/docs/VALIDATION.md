# TrollVNC port validation

2026-10-07. This records tests of this port, separately from the historical ProjectX evidence in INTEGRATION.md.

## Host verification

`rtk proxy bash vendor/app-state/build.sh test` passed:

- 169 core assertions: capture/restore integrity, traversal and symlink boundaries, store locking, baseline isolation, progress and late partial deletion.
- 245 native keychain assertions using mocked Security calls, including exact authority and synchronizable records.
- 49 session assertions: save-before-switch, durable restorePending, first-save metadata and preservation of omitted fields.
- Protocol tests: required backup IDs, opaque-ID conversion, strict types, metadata and JSON results.
- Lifecycle tests: uninstalled status, failed launch, main/extension status, protected bundles, graceful/forced stop, timeout and signal suppression after executable path change/PID reuse. Native launch/process/signal calls are substituted; this does not test real process signaling.
- Service tests: scoped worker/signature verification, progress, cleanup, unknown baseline/archive outcomes and blocked native lifecycle calls. A second service instance cannot start another lifecycle read or bypass the mutation fence. Assertion count varies with sampled progress callbacks.
- Root helper supervision: success, failed child exit, timeout, parent loss, reaping and recovery notification. These tests execute the production supervisor with fixture callbacks; they never signal the real lsd.

`rtk proxy bash tests/run_app_state_socket_tests.sh` passed adapter tests and a real TCP Python test. The native facade is substituted: framing, reconnect/result lookup, busy, progress, timeout continuity, strict switch parameters and failure fences are verified without changing a phone app.

Apple socket tests and the existing ZXTouch protocol/runtime/status/settings suites passed after adding the Python app_state client. Shell syntax and git diff whitespace checks passed.

## Build and deployment boundary

RootHide arm64 build command:

```sh
rtk proxy make -j1 THEOS=/opt/workspace/github/theos-roothide THEOS_PACKAGE_SCHEME=roothide trollvncserver.all.tool.variables app-state-worker.all.tool.variables app-state-idfv-worker.all.tool.variables
```

The daemon and both workers compiled, linked and signed successfully. Use serial make for this multi-goal invocation: parallel recursive make stalled in the local jobserver with no compiler child; serial execution completed. Existing daemon Vision deprecation and multiply_defined linker warnings are unrelated to this port. The workers use warnings as errors.

The root IDFV helper supervises its mutation child for at most 8 seconds; the mobile adapter bounds its sudo wait at 12 seconds. On failed execution, recovery targets only the notified lsd PID with matching start time, mobile UID and exact executable path. A surviving sudo monitor can delay parent-loss detection, so the absolute deadline is also required. An unknown operation fences socket mutations; restarting a service alone does not establish that filesystem/identity state is healthy.

This port has not yet been installed into the running TrollVNC on the phone. Native describe permissions, on-device scoped signing, package sudo-rule installation, real app stop/capture/switch, keychain restoration, lsd recovery and restored app login require device acceptance. Successful host tests and source-project history do not establish those results. No ProjectX backup/configuration store or live phone app was changed by these tests.

## Device acceptance: 3.2-308, 2026-10-07

The preceding paragraph describes the initial host-only checkpoint. The user subsequently installed 3.2-308 and authorized native testing. Tested over Mac -> Windows 10.17.12.17:6000 -> iPhone Wi-Fi 192.168.1.148:6000; SSH remains mobile@10.17.12.17:2222. Device is iPhone9,2/iOS15.8.8/RootHide; target Vinted lt.manodrabuziai.fr version26.39.0/build30256.

All ten methods passed: list, describe, status, launch, stop, save, createBaseline, switch, edit and delete. Launch/status reported the same main PID; stop/status reported an empty list. Initial catalog was empty. First save captured snapshot:20261007-01; edit and save without metadata preserved its name/note. Creating baseline:26.39.0 left the original environment unchanged. Switching to it saved current first, completed native verification and regenerated IDFV. Switching back saved the empty fixture as snapshot:20261007-02, restored snapshot01, and fresh describe confirmed the original IDFV. Both switches completed without restorePending. The temporary snapshot02 was deleted; deletion of current snapshot01 was refused with both partial flags false. Restored app launch and stop succeeded.

Final state: Vinted stopped, current snapshot01 retained, baseline retained, restore_pending=false. Worker operation directory contained only the zero-byte session.lock; scoped executable/request/signature/progress files were removed. Installed workers are numeric0:0/0755; SearchParty helper0:0/4755. No ProjectX backup/profile stores were changed.

This verifies the native capture/restore pipeline, including its container/keychain/preferences/IDFV readback. It does not independently verify a remote Vinted server still accepts restored login tokens or exercise fault-injected real lsd recovery. Device status exposed running/main_running as JSON0/1; the source now uses explicit boolean objects for those fields, to be verified on the next build.
