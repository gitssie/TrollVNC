#!/usr/bin/env python3
"""Exercise the Dopamine 3 rootless installer in an isolated bootstrap."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class InstallerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build_tmp = tempfile.TemporaryDirectory(prefix="tvnc-visudo-fixture-")
        cls.addClassCleanup(cls.build_tmp.cleanup)
        cls.visudo = Path(cls.build_tmp.name) / "visudo"
        # A shell fixture uses Apple's SIP-protected /bin/sh, which strips DYLD
        # variables. Use an ordinary executable to model the on-device loader.
        source = r'''#include <stdio.h>
#include <stdlib.h>
#include <string.h>
int main(void) {
    const char *root=getenv("FIXTURE_ROOT"), *libraries=getenv("DYLD_LIBRARY_PATH");
    char path[4096];
    if (!root || !libraries) return 134;
    snprintf(path,sizeof(path),"%s/usr/libexec/sudo",root);
    if (strcmp(path,libraries)) return 134;
    snprintf(path,sizeof(path),"%s/visudo-called",root);
    FILE *file=fopen(path,"w"); if (!file) return 1; fclose(file);
    const char *fail=getenv("FAIL_VALIDATION");
    if (fail && strcmp(fail,"0")) return 7;
    puts("fixture: parsed OK"); return 0;
}
'''
        subprocess.run(["xcrun", "clang", "-x", "c", "-", "-o", str(cls.visudo)],
                       input=source, text=True, check=True)

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="tvnc-installer-")
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.env = dict(os.environ, PATH=f"{self.base}/bin:{os.environ['PATH']}")
        self.env["FIXTURE_ROOT"] = str(self.base)
        self.write_executable("bin/chown", "exit 0")
        self.write_executable("usr/libexec/trollvnc/app-state-idfv-worker", "exit 0")
        visudo = self.base / "usr/sbin/visudo"
        visudo.parent.mkdir(parents=True)
        visudo.write_bytes(self.visudo.read_bytes())
        visudo.chmod(0o755)
        self.library = self.base / "usr/libexec/sudo/libsudo_util.0.dylib"
        self.library.parent.mkdir(parents=True, exist_ok=True)
        self.library.write_bytes(b"fixture")
        self.rule = self.base / "etc/sudoers.d/trollvnc-app-state"
        self.script = self.base / "configure.sh"
        source = (ROOT / "layout/usr/libexec/trollvnc/configure-app-state.sh").read_text()
        source = source.replace("/var/jb", str(self.base))
        self.script.write_text(source)

    def write_executable(self, name, body):
        path = self.base / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("#!/bin/sh\n" + body + "\n")
        path.chmod(0o755)

    def run_installer(self, action="install"):
        return subprocess.run(["/bin/sh", str(self.script), action], env=self.env,
                              text=True, capture_output=True)

    def assert_no_temp(self):
        self.assertEqual(list(self.rule.parent.glob(".trollvnc-app-state.*")), [])

    def test_rootless_rule_install_is_idempotent(self):
        for _ in range(2):
            result = self.run_installer()
            self.assertEqual(result.returncode, 0, result.stderr)
        helper = self.base / "usr/libexec/trollvnc/app-state-idfv-worker"
        self.assertEqual(self.rule.read_text(), f"mobile ALL=(root) NOPASSWD: {helper}\n")
        self.assertEqual(self.rule.stat().st_mode & 0o777, 0o440)
        self.assert_no_temp()
        self.assertEqual(self.run_installer("remove").returncode, 0)
        self.assertFalse(self.rule.exists())

    def test_validation_failure_retains_previous_rule(self):
        self.rule.parent.mkdir(parents=True)
        self.rule.write_text("previous rule\n")
        self.env["FAIL_VALIDATION"] = "1"
        result = self.run_installer()
        self.assertEqual(result.returncode, 7, result.stderr)
        self.assertEqual(self.rule.read_text(), "previous rule\n")
        self.assert_no_temp()

    def test_remove_does_not_require_helper_or_visudo(self):
        self.assertEqual(self.run_installer().returncode, 0)
        (self.base / "usr/libexec/trollvnc/app-state-idfv-worker").unlink()
        (self.base / "usr/sbin/visudo").unlink()
        self.assertEqual(self.run_installer("remove").returncode, 0)
        self.assertFalse(self.rule.exists())

    def test_validation_failure_cleans_temp(self):
        self.env["FAIL_VALIDATION"] = "1"
        result = self.run_installer()
        self.assertEqual(result.returncode, 7)
        self.assertIn("validate the sudoers rule", result.stderr)
        self.assertFalse(self.rule.exists())
        self.assert_no_temp()

    def test_missing_sudo_library_reports_error_before_validation(self):
        self.library.unlink()
        result = self.run_installer()
        self.assertEqual(result.returncode, 1)
        self.assertIn("sudo utility library", result.stderr)
        self.assertFalse((self.base / "visudo-called").exists())
        self.assert_no_temp()

    def test_missing_visudo_reports_error(self):
        (self.base / "usr/sbin/visudo").unlink()
        result = self.run_installer()
        self.assertEqual(result.returncode, 1)
        self.assertIn("install the sudo package", result.stderr)
        self.assertFalse(self.rule.exists())

    def test_missing_helper_reports_error(self):
        (self.base / "usr/libexec/trollvnc/app-state-idfv-worker").unlink()
        result = self.run_installer()
        self.assertEqual(result.returncode, 1)
        self.assertIn("missing executable helper", result.stderr)
        self.assertFalse(self.rule.exists())


class MaintainerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="tvnc-maintainer-")
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.env = dict(os.environ, FIXTURE_ROOT=str(self.base),
                        DPKG_MAINTSCRIPT_ARCH="iphoneos-arm64")
        (self.base / "bin").mkdir()
        (self.base / "bin/sh").symlink_to("/bin/sh")
        scripts = {
            "usr/libexec/trollvnc/configure-app-state.sh":
                'printf "%s\\n" "$1" >> "$FIXTURE_ROOT/helper-calls"; exit "${HELPER_STATUS:-0}"',
            "usr/bin/launchctl":
                'printf "%s\\n" "$*" >> "$FIXTURE_ROOT/launchctl-calls"',
            "usr/bin/sleep": "exit 0",
            "usr/bin/killall": "exit 0",
        }
        for name, body in scripts.items():
            path = self.base / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("#!/bin/sh\n" + body + "\n")
            path.chmod(0o755)
        plist = self.base / "Library/LaunchDaemons/com.82flex.trollvnc.plist"
        plist.parent.mkdir(parents=True)
        plist.write_text("fixture")

    def run_hook(self, name):
        source = (ROOT / "layout/DEBIAN" / name).read_text()
        script = self.base / name
        script.write_text(source.replace("/var/jb", str(self.base)))
        return subprocess.run(["/bin/sh", str(script)], env=self.env,
                              text=True, capture_output=True)

    def test_install_and_remove_configure_rootless_helper_and_service(self):
        for name in ("postinst", "prerm"):
            result = self.run_hook(name)
            self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.base / "helper-calls").read_text().splitlines(),
                         ["install", "remove"])
        calls = (self.base / "launchctl-calls").read_text()
        self.assertIn(str(self.base / "Library/LaunchDaemons/com.82flex.trollvnc.plist"), calls)

    def test_unsupported_architecture_is_rejected_before_configuration(self):
        self.env["DPKG_MAINTSCRIPT_ARCH"] = "iphoneos-arm64e"
        for name in ("postinst", "prerm"):
            result = self.run_hook(name)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("only Dopamine 3", result.stderr)
        self.assertFalse((self.base / "helper-calls").exists())
        self.assertFalse((self.base / "launchctl-calls").exists())

    def test_configuration_failure_prevents_service_start(self):
        self.env["HELPER_STATUS"] = "7"
        result = self.run_hook("postinst")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("configuration failed", result.stderr)
        self.assertFalse((self.base / "launchctl-calls").exists())


if __name__ == "__main__":
    unittest.main()
