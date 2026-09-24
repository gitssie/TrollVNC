#!/usr/bin/env python3
"""Build and verify TrollVNC's static GitHub Pages Sileo repository."""

from __future__ import annotations

import argparse
import gzip
import hashlib
import html
import io
import json
import lzma
import re
import shutil
import subprocess
import tarfile
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlsplit


ROOT = Path(__file__).resolve().parent.parent
SOURCE_URL = "https://gitssie.github.io/TrollVNC"
INDEXES = ("Packages", "Packages.gz", "Packages.xz")
HASHES = (("MD5Sum", "md5"), ("SHA1", "sha1"), ("SHA256", "sha256"))


class PublicationError(ValueError):
    pass


def digest(data: bytes, algorithm: str) -> str:
    return hashlib.new(algorithm, data).hexdigest()


def fields_from_control(data: bytes) -> dict[str, str]:
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError as error:
        raise PublicationError("package control is not UTF-8") from error
    fields: dict[str, str] = {}
    current = ""
    for line in text.splitlines():
        if not line:
            continue
        if line.startswith((" ", "\t")):
            if not current:
                raise PublicationError("orphan control continuation")
            fields[current] += "\n" + line
            continue
        if ":" not in line:
            raise PublicationError("invalid package control line")
        name, value = line.split(":", 1)
        if not re.fullmatch(r"[A-Za-z][A-Za-z0-9-]*", name) or name in fields:
            raise PublicationError("invalid or duplicate package control field")
        fields[name] = value.strip()
        current = name
    return fields


def deb_control(package: Path) -> dict[str, str]:
    if not package.is_file() or package.is_symlink():
        raise PublicationError("package is missing or is a symlink")
    members = subprocess.run(
        ("ar", "t", str(package)), capture_output=True, text=True, check=True
    ).stdout.splitlines()
    controls = [(name, name.rstrip("/")) for name in members if name.rstrip("/").startswith("control.tar.")]
    if len(controls) != 1 or controls[0][1] not in (
        "control.tar.gz", "control.tar.xz", "control.tar.bz2"
    ):
        raise PublicationError("deb must contain one supported control archive")
    archive = subprocess.run(
        ("ar", "p", str(package), controls[0][1]), capture_output=True, check=True
    ).stdout
    payloads = [name.rstrip("/") for name in members if name.rstrip("/").startswith("data.tar.")]
    if len(payloads) != 1 or payloads[0] not in (
        "data.tar.gz", "data.tar.xz", "data.tar.lzma", "data.tar.bz2"
    ):
        raise PublicationError("deb must contain one supported data archive")
    payload = subprocess.run(
        ("ar", "p", str(package), payloads[0]), capture_output=True, check=True
    ).stdout
    with tarfile.open(fileobj=io.BytesIO(payload), mode="r:*") as tar:
        files = {entry.name.removeprefix("./") for entry in tar.getmembers() if entry.isfile()}
        required = {
            "usr/bin/trollvncserver",
            "Library/LaunchDaemons/com.82flex.trollvnc.plist",
            "Library/PreferenceBundles/TrollVNCPrefs.bundle/TrollVNCPrefs",
        }
        if not required.issubset(files):
            raise PublicationError("deb data archive is missing TrollVNC payload files")
    with tarfile.open(fileobj=io.BytesIO(archive), mode="r:*") as tar:
        entries = [entry for entry in tar.getmembers() if entry.name in ("control", "./control")]
        if len(entries) != 1 or not entries[0].isfile():
            raise PublicationError("deb control entry is missing or unsafe")
        stream = tar.extractfile(entries[0])
        if stream is None:
            raise PublicationError("could not read deb control")
        return fields_from_control(stream.read())


def expected_version() -> str:
    makefile = (ROOT / "Makefile").read_text(encoding="utf-8")
    matches = re.findall(r"^export PACKAGE_VERSION := ([^\s]+)$", makefile, re.MULTILINE)
    if len(matches) != 1:
        raise PublicationError("Makefile must define one PACKAGE_VERSION")
    return matches[0]


def validate_package(package: Path) -> dict[str, str]:
    source = fields_from_control((ROOT / "layout/DEBIAN/control").read_bytes())
    fields = deb_control(package)
    expected = {
        "Package": source.get("Package", ""),
        "Name": "TrollVNC",
        "Version": expected_version(),
        "Architecture": "iphoneos-arm64e",
        "Author": "XenSpace",
        "Maintainer": "XenSpace",
    }
    if source.get("Architecture") != "iphoneos-arm":
        raise PublicationError("source control Architecture must be iphoneos-arm")
    for name, value in expected.items():
        if fields.get(name) != value:
            raise PublicationError(f"deb {name} does not match source publication metadata")
    filename = f"{fields['Package']}_{fields['Version']}_{fields['Architecture']}.deb"
    if package.name != filename:
        raise PublicationError("deb filename does not match package identity")
    if not re.fullmatch(r"[A-Za-z0-9.+:~_-]+", filename):
        raise PublicationError("deb filename is unsafe")
    return fields


def control_stanza(fields: dict[str, str], package: Path) -> bytes:
    blocked = {"Filename", "Size", "MD5sum", "SHA1", "SHA256", "Homepage", "Depiction", "SileoDepiction"}
    if blocked.intersection(fields):
        raise PublicationError("deb control contains repository-only fields")
    data = package.read_bytes()
    lines: list[str] = []
    for name, value in fields.items():
        lines.append(f"{name}: {value}")
    lines.extend(
        (
            f"Homepage: {SOURCE_URL}/",
            f"Depiction: {SOURCE_URL}/",
            f"SileoDepiction: {SOURCE_URL}/depiction.json",
            f"Filename: pool/{package.name}",
            f"Size: {len(data)}",
            f"MD5sum: {digest(data, 'md5')}",
            f"SHA1: {digest(data, 'sha1')}",
            f"SHA256: {digest(data, 'sha256')}",
            "",
            "",
        )
    )
    return "\n".join(lines).encode("utf-8")


def release_file(output: Path) -> bytes:
    date = datetime.now(timezone.utc).strftime("%a, %d %b %Y %H:%M:%S GMT")
    lines = [
        "Origin: XenSpace",
        "Label: TrollVNC",
        "Suite: stable",
        "Codename: trollvnc",
        "Architectures: iphoneos-arm64e",
        "Components: main",
        "Description: TrollVNC for Dopamine RootHide",
        f"Date: {date}",
        "Acquire-By-Hash: no",
    ]
    for section, algorithm in HASHES:
        lines.append(section + ":")
        for name in INDEXES:
            data = (output / name).read_bytes()
            lines.append(f" {digest(data, algorithm)} {len(data):16d} {name}")
    return ("\n".join(lines) + "\n").encode("utf-8")


def replace_tokens(template: str, tokens: dict[str, str], *, escape: bool) -> str:
    for token, value in tokens.items():
        template = template.replace("{{" + token + "}}", html.escape(value, quote=True) if escape else value)
    if re.search(r"\{\{[A-Z0-9_]+\}\}", template):
        raise PublicationError("site template contains unresolved tokens")
    return template


def validate_site(output: Path, package: Path) -> None:
    packages = (output / "Packages").read_bytes()
    fields = fields_from_control(packages)
    for name, value in {
        "Author": "XenSpace",
        "Maintainer": "XenSpace",
        "Homepage": SOURCE_URL + "/",
        "Depiction": SOURCE_URL + "/",
        "SileoDepiction": SOURCE_URL + "/depiction.json",
    }.items():
        if fields.get(name) != value:
            raise PublicationError(f"Packages {name} is incorrect")
    if fields.get("Filename") != f"pool/{package.name}":
        raise PublicationError("Packages Filename does not match the deb")
    if len(list((output / "pool").iterdir())) != 1:
        raise PublicationError("pool must contain exactly one package")
    copied = (output / fields["Filename"]).read_bytes()
    if copied != package.read_bytes() or fields.get("Size") != str(len(copied)):
        raise PublicationError("published package differs from the selected deb")
    for field, algorithm in (("MD5sum", "md5"), ("SHA1", "sha1"), ("SHA256", "sha256")):
        if fields.get(field) != digest(copied, algorithm):
            raise PublicationError(f"Packages {field} does not match the deb")
    if gzip.decompress((output / "Packages.gz").read_bytes()) != packages:
        raise PublicationError("Packages.gz does not match Packages")
    if lzma.decompress((output / "Packages.xz").read_bytes()) != packages:
        raise PublicationError("Packages.xz does not match Packages")
    release = (output / "Release").read_text(encoding="utf-8")
    for section, algorithm in HASHES:
        if section + ":" not in release:
            raise PublicationError(f"Release is missing {section}")
        for name in INDEXES:
            data = (output / name).read_bytes()
            entry = f" {digest(data, algorithm)} {len(data):16d} {name}"
            if entry not in release:
                raise PublicationError(f"Release {section} does not match {name}")
    if "Origin: XenSpace\n" not in release:
        raise PublicationError("Release has the wrong origin")
    page = (output / "index.html").read_text(encoding="utf-8")
    depiction = json.loads((output / "depiction.json").read_text(encoding="utf-8"))
    if SOURCE_URL not in page or f"sileo://source/{SOURCE_URL}" not in page:
        raise PublicationError("website has incorrect source links")
    if depiction.get("class") != "DepictionTabView" or SOURCE_URL not in json.dumps(depiction):
        raise PublicationError("Sileo depiction is invalid")
    if not (output / "icon.png").is_file() or not (output / ".nojekyll").is_file():
        raise PublicationError("site assets are missing")


def render(package: Path, output: Path) -> dict[str, str]:
    parsed = urlsplit(SOURCE_URL)
    if parsed.scheme != "https" or not parsed.netloc or parsed.query or parsed.fragment:
        raise PublicationError("source URL is invalid")
    package = package.resolve(strict=True)
    output = output.resolve()
    if output.exists() and any(output.iterdir()):
        raise PublicationError("output directory must be empty")
    fields = validate_package(package)
    output.mkdir(parents=True, exist_ok=True)
    (output / "pool").mkdir()
    shutil.copy2(package, output / "pool" / package.name)
    packages = control_stanza(fields, package)
    (output / "Packages").write_bytes(packages)
    (output / "Packages.gz").write_bytes(gzip.compress(packages, compresslevel=9, mtime=0))
    (output / "Packages.xz").write_bytes(lzma.compress(packages, preset=9))
    (output / "Release").write_bytes(release_file(output))
    shutil.copy2(ROOT / "Artworks/AppIcon.png", output / "icon.png")
    shutil.copy2(ROOT / "Artworks/AppIcon.png", output / "CydiaIcon.png")
    (output / ".nojekyll").write_bytes(b"")

    package_data = package.read_bytes()
    tokens = {
        "SOURCE_URL": SOURCE_URL,
        "SILEO_URL": "sileo://source/" + SOURCE_URL,
        "PACKAGE_URL": SOURCE_URL + "/pool/" + package.name,
        "VERSION": fields["Version"],
        "ARCHITECTURE": fields["Architecture"],
        "PACKAGE_SIZE": f"{len(package_data) / 1024 / 1024:.2f} MB",
        "SHA256": digest(package_data, "sha256"),
    }
    page = (ROOT / "pages/index.html").read_text(encoding="utf-8")
    (output / "index.html").write_text(replace_tokens(page, tokens, escape=True), encoding="utf-8")
    depiction_text = (ROOT / "pages/depiction.json").read_text(encoding="utf-8")
    depiction = json.loads(replace_tokens(depiction_text, tokens, escape=False))
    (output / "depiction.json").write_text(
        json.dumps(depiction, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    validate_site(output, package)
    return {"version": fields["Version"], "sha256": tokens["SHA256"], "source_url": SOURCE_URL}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--package", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    try:
        result = render(args.package, args.output)
    except (OSError, PublicationError, subprocess.CalledProcessError, tarfile.TarError, json.JSONDecodeError) as error:
        parser.error(str(error))
    for name, value in result.items():
        print(f"{name}={value}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
