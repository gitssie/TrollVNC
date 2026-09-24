#!/usr/bin/env python3

import importlib.util
import io
import json
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "trollvnc_pages", ROOT / "scripts/render_github_pages.py"
)
assert SPEC and SPEC.loader
pages = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = pages
SPEC.loader.exec_module(pages)


class GitHubPagesPublicationTests(unittest.TestCase):
    def make_deb(self, root: Path, author: str = "XenSpace") -> Path:
        source = pages.fields_from_control((ROOT / "layout/DEBIAN/control").read_bytes())
        version = pages.expected_version()
        control = dict(source)
        control["Author"] = author
        control["Architecture"] = "iphoneos-arm64e"
        control["Version"] = version
        control_data = "".join(f"{name}: {value}\n" for name, value in control.items()).encode()
        archive = io.BytesIO()
        with tarfile.open(fileobj=archive, mode="w:gz") as tar:
            info = tarfile.TarInfo("./control")
            info.size = len(control_data)
            tar.addfile(info, io.BytesIO(control_data))
        (root / "debian-binary").write_bytes(b"2.0\n")
        (root / "control.tar.gz").write_bytes(archive.getvalue())
        data_archive = io.BytesIO()
        with tarfile.open(fileobj=data_archive, mode="w:gz") as tar:
            for name in (
                "./usr/bin/trollvncserver",
                "./Library/LaunchDaemons/com.82flex.trollvnc.plist",
                "./Library/PreferenceBundles/TrollVNCPrefs.bundle/TrollVNCPrefs",
            ):
                payload = b"fixture"
                info = tarfile.TarInfo(name)
                info.size = len(payload)
                tar.addfile(info, io.BytesIO(payload))
        (root / "data.tar.gz").write_bytes(data_archive.getvalue())
        package = root / f"{source['Package']}_{version}_iphoneos-arm64e.deb"
        with package.open("wb") as stream:
            stream.write(b"!<arch>\n")
            for name in ("debian-binary", "control.tar.gz", "data.tar.gz"):
                data = (root / name).read_bytes()
                header = (
                    f"{name:16}{0:<12}{0:<6}{0:<6}{'100644':<8}{len(data):<10}`\n"
                ).encode("ascii")
                stream.write(header)
                stream.write(data)
                if len(data) % 2:
                    stream.write(b"\n")
        return package

    def test_rendered_source_has_matching_indexes_and_developer(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            package = self.make_deb(root)
            output = root / "site"
            result = pages.render(package, output)

            self.assertEqual(result["source_url"], pages.SOURCE_URL)
            pages.validate_site(output, package)
            fields = pages.fields_from_control((output / "Packages").read_bytes())
            self.assertEqual(fields["Author"], "XenSpace")
            self.assertEqual(fields["Maintainer"], "XenSpace")
            self.assertEqual(fields["SileoDepiction"], pages.SOURCE_URL + "/depiction.json")
            self.assertIn("Origin: XenSpace\n", (output / "Release").read_text())
            self.assertIn("sileo://source/" + pages.SOURCE_URL, (output / "index.html").read_text())
            depiction = json.loads((output / "depiction.json").read_text())
            self.assertEqual(depiction["class"], "DepictionTabView")
            self.assertIn("82Flex", json.dumps(depiction))

    def test_rejects_deb_with_old_developer(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            package = self.make_deb(root, "82Flex <82flex@gmail.com>")
            with self.assertRaisesRegex(pages.PublicationError, "deb Author"):
                pages.render(package, root / "site")

    def test_detects_tampered_published_package(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            package = self.make_deb(root)
            output = root / "site"
            pages.render(package, output)
            published = output / "pool" / package.name
            published.write_bytes(published.read_bytes() + b"tampered")
            with self.assertRaisesRegex(pages.PublicationError, "differs"):
                pages.validate_site(output, package)


if __name__ == "__main__":
    unittest.main()
