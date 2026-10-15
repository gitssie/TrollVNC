#!/usr/bin/env python3
"""USB integration probe; temporary device files are removed, no report files.

Uses an existing SSH key. Sudo credentials arrive on stdin / a hidden TTY prompt.
Default runs only public NetworkExtension discovery, as mobile and root.

Build: bash tests/build_karing_ipc_probe.sh /tmp/karing-ipc-probe
Read:  python3 tests/run_karing_ipc_probe.py /tmp/karing-ipc-probe \
           --sudo-password-stdin --karing-identity --ipc-read
Reload: replace --ipc-read with --restart-current (one restart, no retry).
Identity mode affects only a temporary helper, never the production daemon.
Exit 0: verified; 1: failed; 3: restart accepted but not verified.
Configuration writing / subscription refresh are outside this probe's scope.
"""
import argparse
import getpass
import json
import plistlib
import tempfile
import time
import os
from pathlib import Path
import shlex
import subprocess
import sys

SSH = ["ssh", "-T", "-p2222", "-oBatchMode=yes", "-oStrictHostKeyChecking=yes", "-oConnectTimeout=5", "mobile@127.0.0.1"]


def remote(command, password=None, check=True, timeout=35):
    if password is not None:
        command = "sudo -S -p '' " + command
    return subprocess.run(SSH + [command], input=password, capture_output=True, check=check, timeout=timeout)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("binary", type=Path)
    parser.add_argument("--sudo-password-stdin", action="store_true", required=True)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--inspect", action="store_true")
    mode.add_argument("--private", action="store_true")
    mode.add_argument("--ipc-read", action="store_true")
    mode.add_argument("--restart-current", action="store_true", help="Restart once with the existing on-disk config; may briefly interrupt VPN")
    parser.add_argument("--karing-identity", action="store_true", help="Sign a temporary helper copy with installed Karing identity; production daemon is unchanged")
    args = parser.parse_args()
    password = (getpass.getpass("Device sudo password (not logged): ") if sys.stdin.isatty()
                else sys.stdin.readline().rstrip("\r\n")).encode() + b"\n"
    if password == b"\n":
        raise SystemExit("sudo password is required")
    suffix = str(os.getpid())
    staged = "/tmp/cazer-karing-ipc-stage-" + suffix
    installed = "/usr/bin/cazer-karing-ipc-probe-" + suffix
    exit_code = 0
    temporary = tempfile.TemporaryDirectory(prefix="cazer-karing-probe-")
    binary = args.binary
    try:
        if args.karing_identity:
            # Identity-only entitlements: no profile, config or credential contents.
            result = remote("for p in /private/var/containers/Bundle/Application/*/Karing.app/Karing; do if [ -f \"$p\" ]; then ldid -e \"$p\"; break; fi; done")
            identity = plistlib.loads(result.stdout)
            original = subprocess.run(["ldid", "-e", str(binary)], capture_output=True, check=True, timeout=15)
            entitlements = plistlib.loads(original.stdout)
            for key in ["application-identifier", "com.apple.developer.team-identifier", "com.apple.security.application-groups", "com.apple.developer.networking.networkextension"]:
                entitlements[key] = identity[key]
            signed = Path(temporary.name) / "probe"
            signed.write_bytes(binary.read_bytes())
            signed.chmod(0o700)
            entitlement_file = Path(temporary.name) / "identity.plist"
            entitlement_file.write_bytes(plistlib.dumps(entitlements))
            subprocess.run(["ldid", "-S" + str(entitlement_file), str(signed)], check=True, timeout=15)
            binary = signed
        subprocess.run(["scp", "-P2222", "-oBatchMode=yes", "-oStrictHostKeyChecking=yes",
                        str(binary), "mobile@127.0.0.1:" + staged], check=True,
                       stdout=subprocess.DEVNULL, timeout=35)
        remote("cp -f " + shlex.quote(staged) + " " + shlex.quote(installed), password)
        remote("chmod 0755 " + shlex.quote(installed), password)
        native = remote("jbroot " + shlex.quote(installed)).stdout.decode().strip()
        remote("/basebin/jbctl trustcache add " + shlex.quote(native), password)
        baseline = None
        if args.restart_current:
            before = remote(shlex.quote(installed) + " --ipc-read", password, check=False)
            if before.returncode:
                print("Read preflight failed; restart skipped.", flush=True)
                return before.returncode
            baseline = json.loads(before.stdout).get("providerStartTime")
            if baseline is None:
                print("Missing core startTime; restart skipped.", flush=True)
                return 1
        for identity in (["root"] if args.restart_current else ["mobile", "root"]):
            command = shlex.quote(installed) + (" --inspect" if args.inspect else " --private" if args.private else " --ipc-read" if args.ipc_read else " --restart-current" if args.restart_current else "")
            result = remote(command, password if identity == "root" else None, check=False)
            print(identity + ": " + result.stdout.decode().strip(), flush=True)
            print("exit=" + str(result.returncode), flush=True)
            if result.returncode:
                exit_code = result.returncode
            if result.stderr:
                print("native stderr: " + result.stderr.decode(errors="replace")[:1000], flush=True)
        if args.restart_current and exit_code == 3:
            verified = False
            for _ in range(5):
                time.sleep(1)
                after = remote(shlex.quote(installed) + " --ipc-read", password, check=False)
                if after.returncode == 0:
                    changed = json.loads(after.stdout).get("providerStartTime")
                    if changed is not None and changed != baseline:
                        verified = True
                        break
            print("reloadVerified=" + str(verified).lower(), flush=True)
            exit_code = 0 if verified else 3
    finally:
        cleanup_failed = False
        for path, credential in [(staged, None), (installed, password)]:
            try:
                result = remote("rm -f " + shlex.quote(path), credential, check=False)
                cleanup_failed |= result.returncode != 0
            except (subprocess.SubprocessError, OSError):
                cleanup_failed = True
        temporary.cleanup()
        if cleanup_failed:
            raise SystemExit("device probe cleanup failed")

    return exit_code


if __name__ == "__main__":
    sys.exit(main())
