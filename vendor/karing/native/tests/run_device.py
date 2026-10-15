#!/usr/bin/env python3
"""Real device test of the production client -> separately signed helper.

USB SSH 2222, existing SSH key, hidden sudo prompt. No reports or raw config logs.
Default reads only; --allow-reload reloads the existing config exactly once.
Temporary phone executables are always cleaned. Installed daemon is untouched.
"""
import argparse
import getpass
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile

PROJECT = Path(__file__).resolve().parents[4]
MODULE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PROJECT / "tests"))
from run_karing_ipc_probe import remote


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--allow-reload", action="store_true")
    args = parser.parse_args()
    password = (getpass.getpass("Device sudo password (not logged): ") if sys.stdin.isatty()
                else sys.stdin.readline().rstrip("\r\n")).encode() + b"\n"
    if password == b"\n":
        raise SystemExit("sudo password required")
    suffix = str(os.getpid())
    installed = []
    staged = []
    native_paths = []
    try:
        with tempfile.TemporaryDirectory(prefix="karing-native-device-") as temporary:
            helper = Path(temporary) / "helper"
            driver = Path(temporary) / "driver"
            subprocess.run(["bash", str(MODULE / "tests/build_helper.sh"), str(helper)], check=True)
            sdk = subprocess.check_output(["xcrun", "--sdk", "iphoneos", "--show-sdk-path"], text=True).strip()
            subprocess.run(["xcrun", "clang", "-target", "arm64-apple-ios15.0", "-isysroot", sdk,
                            "-fobjc-arc", "-DTVAS_ROOTHIDE=1", "-Wall", "-Wextra", "-Werror", "-framework", "Foundation",
                            "-I" + str(MODULE / "include"), str(MODULE / "tests/DeviceDriver.m"),
                            str(MODULE / "src/Client.m"), "-o", str(driver)], check=True)
            subprocess.run(["ldid", "-S" + str(PROJECT / "src/trollvncserver.entitlements"), str(driver)], check=True)
            for binary, name in [(helper, "helper"), (driver, "driver")]:
                stage = "/tmp/cazer-karing-native-stage-" + name + "-" + suffix
                target = "/usr/bin/cazer-karing-native-" + name + "-" + suffix
                staged.append(stage); installed.append(target)
                subprocess.run(["scp", "-P2222", "-oBatchMode=yes", "-oStrictHostKeyChecking=yes",
                                str(binary), "mobile@127.0.0.1:" + stage], check=True, timeout=35)
                remote("cp -f " + shlex.quote(stage) + " " + shlex.quote(target), password)
                remote("chmod 0755 " + shlex.quote(target), password)
                native = remote("jbroot " + shlex.quote(target)).stdout.decode().strip()
                native_paths.append(native)
                remote("/basebin/jbctl trustcache add " + shlex.quote(native), password)
            # Driver has the daemon's identity; helper has its own Karing identity.
            command = shlex.quote(installed[1]) + " " + shlex.quote(native_paths[0])
            if args.allow_reload:
                command += " --allow-reload"
            result = remote(command, password, check=False, timeout=90)
            print(result.stdout.decode(errors="replace"), end="", flush=True)
            if result.returncode:
                print("driver failed; exit=" + str(result.returncode), flush=True)
                diagnostic = remote(shlex.quote(installed[0]) + " status", password, check=False)
                print("helper direct exit=" + str(diagnostic.returncode), flush=True)
                if diagnostic.stderr:
                    print(diagnostic.stderr.decode(errors="replace")[:1500], flush=True)
                if os.environ.get("KARING_NATIVE_DIAGNOSTICS") == "1":
                    diagnostic = remote(shlex.quote(installed[0]) + " diagnostics", password, check=False)
                    print(diagnostic.stdout.decode(errors="replace")[:1500], flush=True)
            return result.returncode
    finally:
        failed = False
        for path, credential in [(p, None) for p in staged] + [(p, password) for p in installed]:
            try:
                failed |= remote("rm -f " + shlex.quote(path), credential, check=False).returncode != 0
            except (subprocess.SubprocessError, OSError):
                failed = True
        if failed:
            raise SystemExit("device test cleanup failed")


if __name__ == "__main__":
    sys.exit(main())
