#!/usr/bin/env python3
"""Exercise the production installer with isolated paths and RootHide tools.

The fixture models dyld rejecting an unregistered library. It checks installer
ordering and failure handling, not physical-device signature acceptance.
"""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="tvnc-installer-")
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.env = dict(os.environ, PATH=f"{self.base}/bin:{os.environ['PATH']}")
        self.env["FIXTURE_ROOT"] = str(self.base)
        self.write_executable("bin/chown", "exit 0")
        self.write_executable("usr/bin/jbroot", 'printf "%s\\n" "$1"')
        self.write_executable("usr/libexec/trollvnc/app-state-idfv-worker", "exit 0")
        self.write_executable("basebin/jbctl", '''
[ "$1" = trustcache ] && [ "$2" = add ] || exit 64
[ "$3" = "$FIXTURE_ROOT/usr/libexec/sudo/libsudo_util.0.dylib" ] || exit 65
[ "${FAIL_TRUST:-0}" = 0 ] || exit 9
printf '%s\\n' "$3" > "$FIXTURE_ROOT/trusted"
''')
        self.write_executable("usr/sbin/visudo", '''
[ -f "$FIXTURE_ROOT/trusted" ] || exit 134
touch "$FIXTURE_ROOT/visudo-called"
[ "${FAIL_VALIDATION:-0}" = 0 ] || exit 7
printf 'fixture: parsed OK\\n'
''')
        self.library = self.base / "usr/libexec/sudo/libsudo_util.0.dylib"
        self.library.parent.mkdir(parents=True)
        self.library.write_bytes(b"fixture library")
        self.rule = self.base / "etc/sudoers.d/trollvnc-app-state"
        self.script = self.base / "configure.sh"
        source = (ROOT / "layout/usr/libexec/trollvnc/configure-app-state.sh").read_text()
        for prefix in ("/usr/libexec", "/usr/bin/jbroot", "/usr/sbin/visudo", "/etc/sudoers.d", "/basebin/jbctl"):
            source = source.replace(prefix, str(self.base) + prefix)
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

    def test_library_is_trusted_before_validation(self):
        for _ in range(2):
            result = self.run_installer()
            self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.base / "trusted").read_text().strip(), str(self.library))
        helper = self.base / "usr/libexec/trollvnc/app-state-idfv-worker"
        self.assertEqual(self.rule.read_text(), f"mobile ALL=(root) NOPASSWD: {helper}\n")
        self.assertEqual(self.rule.stat().st_mode & 0o777, 0o440)
        self.assert_no_temp()
        self.assertEqual(self.run_installer("remove").returncode, 0)
        self.assertFalse(self.rule.exists())

    def test_old_order_reproduces_dyld_exit(self):
        source = self.script.read_text()
        call = f'{self.base}/basebin/jbctl trustcache add "$sudo_library"'
        self.assertIn(call, source)
        self.script.write_text(source.replace(call, ":"))
        result = self.run_installer()
        self.assertEqual(result.returncode, 134, result.stderr)
        self.assertIn("validate the sudoers rule", result.stderr)
        self.assertFalse(self.rule.exists())
        self.assert_no_temp()

    def test_trust_failure_keeps_previous_rule_and_skips_visudo(self):
        self.rule.parent.mkdir(parents=True)
        self.rule.write_text("previous rule\n")
        self.env["FAIL_TRUST"] = "1"
        result = self.run_installer()
        self.assertEqual(result.returncode, 9)
        self.assertIn("prepare RootHide trust", result.stderr)
        self.assertEqual(self.rule.read_text(), "previous rule\n")
        self.assertFalse((self.base / "visudo-called").exists())
        self.assert_no_temp()

    def test_validation_failure_cleans_temp(self):
        self.env["FAIL_VALIDATION"] = "1"
        result = self.run_installer()
        self.assertEqual(result.returncode, 7)
        self.assertIn("validate the sudoers rule", result.stderr)
        self.assertFalse(self.rule.exists())
        self.assert_no_temp()

    def test_missing_library_reports_error(self):
        self.library.unlink()
        result = self.run_installer()
        self.assertEqual(result.returncode, 1)
        self.assertIn("reinstall the sudo package", result.stderr)
        self.assertFalse((self.base / "visudo-called").exists())
        self.assert_no_temp()


if __name__ == "__main__":
    unittest.main()
