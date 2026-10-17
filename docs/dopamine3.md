# Dopamine 3 development

This branch targets Dopamine 3 exclusively. Reference source:
`/opt/workspace/github/Dopamine`, commit `448ff1a` (`3.0.11`). Its libroot
implementation returns the real filesystem as the root prefix and queries the
bootstrap prefix through jbclient; DOBootstrapper maintains `/var/jb` as the
stable alias. Executable trust is handled by the systemhook spawn path.

## Build

Use standard `theos/theos`, not the RootHide fork:

```sh
export THEOS=/opt/workspace/github/theos
source devkit/rootless.sh
rtk proxy make -j1 clean package FINALPACKAGE=1
```

The device build rejects non-rootless schemes and standalone/bootstrap targets.
The first development package is `4.0-1`, architecture `iphoneos-arm64`.
Both arm64 and arm64e injection targets remain valid within that package format;
package architecture is independent of the CPU slice needed for SpringBoard.
CI builds only rootless. Simulator tooling remains for local development.

## Paths and permissions

- Install package files under `/var/jb`. Runtime App-state and SearchParty paths
  use the standard `rootless.h` helpers, with no RootHide library dependency.
- Real App Group containers, system groups and shared backups remain under real
  `/var`. Backups stay in `/var/mobile/Media/AppStateBackups`; no old-store migration.
- App-state temporary operations and associations remain package-owned. Scoped
  workers are still privately copied, signed per target, verified and cleaned;
  standard rootless rpaths replace the old `.jbroot` dependency symlink.
- Notification adapter/server share the short `/var/jb/var/mobile/.tvnc-run/n.sock`
  endpoint, keeping it within Unix socket length limits even with a long physical
  preboot root. Notification contents stay in memory.
- Maintainer scripts use the rootless shell, run the fixed App-state configuration
  script and manage only the fixed TrollVNC launchd service. Sudoers authorizes only
  the installed IDFV helper. Visudo failure preserves the previous rule.
- No RootHide path resolver or manual sudo-library trust insertion is required.
  The tested Procursus visudo needs its private `/var/jb/usr/libexec/sudo` library
  directory in a per-process DYLD_LIBRARY_PATH. SearchParty recovery retains
  root-only protected command ancestry.

## Host validation (2026-10-17)

- Standard Theos rootless build/package passed. A final clean rebuild found and
  corrected a Settings property accessor warning; packaging then completed.
- All 218 archive entries use numeric uid/gid 0. All 172 regular control/data
  files match staging bytes and modes; data payload is entirely under `/var/jb`.
  Recovery helper mode is 4755; other helpers are 0755. Launchd executable/log
  paths point into the rootless bootstrap.
- Both injection adapters contain arm64 and arm64e slices. Mach-O dependencies
  contain no RootHide library. The actual package renders and validates through
  the repository generator in a temporary directory, without publication.
- Nine installer/maintainer-script fixtures, seven repository-generator fixtures,
  App-state production host suite and socket adapter, Apple module host suite,
  Karing native helper tests, unsupported-build guards and shell/plist checks pass.
- Two independent reviews found no important remaining runtime/packaging blockers.

## Acceptance

Host tests and package builds do not prove device permissions or private API
compatibility. Before release, install manually on a Dopamine 3 device and verify
service start/restart, Settings, screen/input, notification delivery, Photos,
App-state save/switch/IDFV and Karing helper behavior. Apple account writes require
separate explicit device testing and must not be replayed automatically.

The initial source migration did not publish or install a package. The explicitly
authorized device installation below supersedes that earlier host-only boundary.

## Authorized device installation — 2026-10-17 / 4.0-2

Device: iPhone 7 Plus (iPhone9,2), iOS 15.8.8, Dopamine basebin 3.0.11,
standard rootless arm64. SSH used the previously pinned host key; credentials
were held in memory only. No Sileo repository was published or source added.

First install of 4.0-1 reproduced a real postinst failure: Procursus visudo
1.9.15p5 could not load `@rpath/libsudo_util.0.dylib`. The installed library was
at `/var/jb/usr/libexec/sudo/libsudo_util.0.dylib`; supplying that private lookup
directory made `visudo -V` succeed. Visudo is present and functional on this
phone. The installer now checks the library and scopes DYLD_LIBRARY_PATH to
visudo only, retaining sudoers validation and failure cleanup. No sudo package
binary was changed and no manual trustcache registration was needed.

A regression fixture first reproduced exit134 without the directory. The final
native executable fixture avoids macOS /bin/sh stripping DYLD variables under
SIP; all ten installer/maintainer fixtures pass. Independent review found no
important issue in the fix. Package4.0-2 builds with218 root-owned archive entries.

Installed ldid2.1.5-procursus7 and its libplist3 dependency, then installed4.0-2.
Dpkg reports `install ok installed`; sudoers validation parsed OK. One SpringBoard
reload activated the new adapters. Confirmed:

- Main launchd service running, one launch and no exit across the probes.
- VNC5901 handshake succeeds and reports348x620.
- HTTP/2 control6000 login, authorization, device-info, App list and disconnect
  succeed. Credentials/tokens and full device/App data were not logged.
- Screenshot returns HTTP200, image/jpeg,251916bytes with JPEG signature.
- App-state read-only Karing catalog completes successfully with zero backups,
  exercising actual temporary worker copy/sign/authority/execution/cleanup. Only
  the normal session.lock remains in the operation root. No save/switch/delete.
- Mobile sudo reaches the fixed IDFV helper; empty-input validation returns64.
  No IDFV mutation was requested.
- Notification socket is present, mobile-owned,0700parent/0600socket, at the shared
  short rootless path after SpringBoard reload. Actual notification delivery was
  not exercised.
- Native Karing config and status both return HTTP200 with data; no reload or VPN
  mutation was performed and full private responses were not logged.
- Main daemon log contains no new dyld/abort/exception/failure/error line during
  these checks. This is startup/probe evidence, not exhaustive runtime acceptance.

Touch/keyboard input, Photos writes, notification payload delivery, App-state
save/restore/IDFV mutation and Apple account writes remain separately unverified.
Uploaded installation files and temporary host probes were removed; connections
and control sessions were closed. The installed service remains running.
