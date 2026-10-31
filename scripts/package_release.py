#!/usr/bin/env python3
"""Package and atomically publish Podhod's unsigned releases for Feather."""

import argparse
from datetime import datetime, timezone
import fcntl
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import struct
import sys
import tempfile
from urllib.parse import quote, unquote, urlsplit
import zipfile


BUNDLE_ID = "dev.podhod.training"
SOURCE_ID = "dev.podhod.releases"
VERSION_PATTERN = re.compile(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:\.(?:0|[1-9][0-9]*))?\Z")
BUILD_PATTERN = re.compile(r"[1-9][0-9]*\Z")
FILE_PATTERN = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*\Z")


def version_key(value):
    if not isinstance(value, str) or not VERSION_PATTERN.fullmatch(value):
        raise ValueError("Version must contain two or three numeric components, for example 1.2 or 1.2.1")
    parts = tuple(int(part) for part in value.split("."))
    return parts + (0,) * (3 - len(parts))


def validate_base_url(value):
    parsed = urlsplit(value)
    if (parsed.scheme != "https" or not parsed.netloc or parsed.username or parsed.password
            or parsed.query or parsed.fragment or ".." in PurePosixPath(unquote(parsed.path)).parts):
        raise ValueError("base_url must be an HTTPS directory URL without credentials, query or fragment")
    return value.rstrip("/")


def read_ipa(path):
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        if len(names) != len(set(names)):
            raise ValueError("IPA contains duplicate archive entries")
        for name in names:
            parts = PurePosixPath(name).parts
            if name.startswith("/") or "\\" in name or ".." in parts:
                raise ValueError("IPA contains an unsafe archive path")
            private_file = name.lower().endswith((".p12", ".pfx", ".mobileprovision"))
            secret_file = PurePosixPath(name).name in {".env", "access.json", "realm.json"}
            if private_file or secret_file or "secrets" in parts:
                raise ValueError("Unsigned IPA must not contain signing profiles or private deployment files")
        if archive.testzip() is not None:
            raise ValueError("IPA archive is damaged")
        manifests = [name for name in names if name.startswith("Payload/")
                     and name.count("/") == 2 and name.endswith(".app/Info.plist")]
        if len(manifests) != 1:
            raise ValueError("IPA must contain exactly one app")
        info = plistlib.loads(archive.read(manifests[0]))
        if info.get("CFBundleIdentifier") != BUNDLE_ID:
            raise ValueError(f"Bundle ID must remain {BUNDLE_ID}; refusing to publish a separate app")
        version = info.get("CFBundleShortVersionString")
        version_key(version)
        build = info.get("CFBundleVersion")
        if not isinstance(build, str) or not BUILD_PATTERN.fullmatch(build):
            raise ValueError("CFBundleVersion must be a positive integer")
        if info.get("CFBundleSupportedPlatforms") != ["iPhoneOS"]:
            raise ValueError("Expected a real-device iPhoneOS build, not a simulator build")
        version_key(info.get("MinimumOSVersion"))
        executable_name = info.get("CFBundleExecutable")
        if not isinstance(executable_name, str) or not FILE_PATTERN.fullmatch(executable_name):
            raise ValueError("IPA has an invalid app executable name")
        executable = manifests[0].removesuffix("Info.plist") + executable_name
        if executable not in names:
            raise ValueError("IPA has no app executable")
        with archive.open(executable) as binary:
            header = binary.read(8)
        if len(header) != 8 or header[:4] != b"\xcf\xfa\xed\xfe" or struct.unpack("<I", header[4:])[0] != 0x0100000C:
            raise ValueError("Expected an arm64 Mach-O device executable")
        return info


def json_bytes(value):
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2) + "\n").encode()


def atomic_release_file(path, data, immutable=False):
    path = Path(path)
    if path.is_symlink():
        raise ValueError(f"Refusing to replace a symbolic link: {path.name}")
    if immutable and path.exists():
        if path.read_bytes() != data:
            raise ValueError(f"Published artifact is immutable: {path.name}")
        return
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=path.parent, prefix=".release-", delete=False) as file:
            temporary = Path(file.name)
            file.write(data)
            file.flush()
            os.fsync(file.fileno())
        temporary.chmod(0o644)
        if immutable:
            try:
                os.link(temporary, path)
            except FileExistsError:
                if path.is_symlink() or path.read_bytes() != data:
                    raise ValueError(f"Published artifact is immutable: {path.name}")
        else:
            os.replace(temporary, path)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def read_source(directory):
    path = Path(directory) / "source.json"
    if not path.exists():
        return None
    value = json.loads(path.read_text())
    apps = value.get("apps")
    if value.get("identifier") != SOURCE_ID or not isinstance(apps, list) or len(apps) != 1:
        raise ValueError("Existing source.json does not belong to Podhod; it was not replaced")
    app = apps[0]
    if app.get("bundleIdentifier") != BUNDLE_ID or not isinstance(app.get("versions"), list) or not app["versions"]:
        raise ValueError("Existing Podhod source has invalid app metadata; it was not replaced")
    seen = set()
    for release in app["versions"]:
        key = version_key(release.get("version"))
        if key in seen:
            raise ValueError("Existing source has duplicate marketing versions")
        seen.add(key)
    return value


def published_ipa(directory, record, base_url):
    url = record.get("downloadURL", "")
    filename = unquote(PurePosixPath(urlsplit(url).path).name)
    if not FILE_PATTERN.fullmatch(filename) or url != base_url + "/" + quote(filename):
        raise ValueError("Existing release points outside the configured release directory")
    path = Path(directory) / filename
    if path.is_symlink() or not path.is_file():
        raise ValueError(f"Existing release is missing its immutable IPA: {filename}")
    info = read_ipa(path)
    if info["CFBundleShortVersionString"] != record["version"]:
        raise ValueError("Existing IPA version does not match source.json")
    return path, info


def merged_source(directory, manifest):
    source = read_source(directory)
    record = manifest["release"]
    base_url = manifest["baseURL"]
    version = manifest["version"]
    if source is None:
        source = {"name": "Подход — обновления", "identifier": SOURCE_ID, "apps": [{
            "name": "Подход", "bundleIdentifier": BUNDLE_ID, "developerName": "Подход",
            "localizedDescription": "Программа по дням, запись подходов и прогресс в зале.",
            "subtitle": "Твой темп. Твой прогресс.", "tintColor": "C9F561", "appPermissions": {}, "versions": [],
        }], "news": []}
    app = source["apps"][0]
    versions = app["versions"]
    if versions:
        latest = max(versions, key=lambda item: version_key(item["version"]))
        if version_key(version) < version_key(latest["version"]):
            raise ValueError("Refusing to make an older marketing version current")
        previous_path, previous_info = published_ipa(directory, latest, base_url)
        if version_key(version) == version_key(latest["version"]):
            digest = hashlib.sha256(previous_path.read_bytes()).hexdigest()
            if digest != manifest["ipaSHA256"] or version != latest["version"]:
                raise ValueError("A different IPA is already published for this marketing version; bump the version")
            return source
        if int(manifest["build"]) <= int(previous_info["CFBundleVersion"]):
            raise ValueError("Build number must increase beyond the last published build")
    app["versions"] = sorted(versions + [record], key=lambda item: version_key(item["version"]), reverse=True)
    app.update({"version": version, "versionDate": record["date"], "size": record["size"],
                "downloadURL": record["downloadURL"], "iconURL": base_url + "/" + quote(manifest["icon"])})
    source["iconURL"] = app["iconURL"]
    return source


def package_release(ipa, base_url, output_directory):
    ipa = Path(ipa)
    base_url = validate_base_url(base_url)
    info = read_ipa(ipa)
    version = info["CFBundleShortVersionString"]
    build = info["CFBundleVersion"]
    output = Path(output_directory)
    output.mkdir(parents=True, exist_ok=True)
    stem = f"Podhod-{version}-{build}"
    manifest_name = stem + ".release.json"
    ipa_name = stem + ".ipa"
    ipa_data = ipa.read_bytes()
    digest = hashlib.sha256(ipa_data).hexdigest()
    date = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    with (output.parent / ".podhod-release.lock").open("a+b") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        existing_manifest = output / manifest_name
        if existing_manifest.exists():
            previous = json.loads(existing_manifest.read_text())
            if previous.get("ipaSHA256") != digest:
                raise ValueError("Release version/build already has a different IPA")
            date = previous["release"]["date"]
        icon_path = Path(__file__).resolve().parents[1] / "Podhod/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
        icon_name = stem + "-icon.png"
        zip_name = stem + "-for-Files.zip"
        zip_buffer = io.BytesIO()
        with zipfile.ZipFile(zip_buffer, "w") as archive:
            entry = zipfile.ZipInfo(ipa_name, date_time=(1980, 1, 1, 0, 0, 0))
            entry.compress_type = zipfile.ZIP_DEFLATED
            entry.external_attr = 0o100644 << 16
            archive.writestr(entry, ipa_data)
        files = {ipa_name: ipa_data, zip_name: zip_buffer.getvalue(), icon_name: icon_path.read_bytes()}
        checksums = "".join(f"{hashlib.sha256(data).hexdigest()}  {name}\n" for name, data in sorted(files.items()))
        files[stem + ".sha256"] = checksums.encode()
        record = {"version": version, "date": date, "size": len(ipa_data),
                  "downloadURL": base_url + "/" + quote(ipa_name), "minOSVersion": info["MinimumOSVersion"]}
        manifest = {"bundleIdentifier": BUNDLE_ID, "version": version, "build": build, "baseURL": base_url,
                    "ipa": ipa_name, "ipaSHA256": digest, "icon": icon_name, "release": record,
                    "files": {name: {"sha256": hashlib.sha256(data).hexdigest(), "size": len(data)}
                              for name, data in sorted(files.items())}}
        source = merged_source(output, manifest)
        for name, data in files.items():
            atomic_release_file(output / name, data, immutable=True)
        atomic_release_file(output / manifest_name, json_bytes(manifest), immutable=True)
        atomic_release_file(output / "source.json", json_bytes(source))
        return output / manifest_name


def validate_staged_release(staging_directory):
    stage = Path(staging_directory)
    manifests = list(stage.glob("Podhod-*.release.json"))
    if len(manifests) != 1:
        raise ValueError("Staging must contain exactly one Podhod release manifest")
    manifest_path = manifests[0]
    manifest = json.loads(manifest_path.read_text())
    if manifest.get("bundleIdentifier") != BUNDLE_ID:
        raise ValueError("Staged Bundle ID does not match the installed app")
    version_key(manifest.get("version"))
    if not BUILD_PATTERN.fullmatch(str(manifest.get("build", ""))):
        raise ValueError("Staged build number is invalid")
    validate_base_url(manifest["baseURL"])
    files = manifest.get("files")
    stem = f"Podhod-{manifest['version']}-{manifest['build']}"
    expected_names = {stem + ".ipa", stem + "-for-Files.zip", stem + "-icon.png", stem + ".sha256"}
    if (not isinstance(files, dict) or set(files) != expected_names
            or manifest.get("ipa") != stem + ".ipa" or manifest.get("icon") != stem + "-icon.png"
            or manifest_path.name != stem + ".release.json"):
        raise ValueError("Staged release must contain only the expected Podhod artifacts")
    for name, expected in files.items():
        if not FILE_PATTERN.fullmatch(name):
            raise ValueError("Staged artifact filename is unsafe")
        path = stage / name
        if path.is_symlink() or not path.is_file():
            raise ValueError("Staged artifact is missing or is a symbolic link")
        data = path.read_bytes()
        if len(data) != expected["size"] or hashlib.sha256(data).hexdigest() != expected["sha256"]:
            raise ValueError(f"Staged artifact checksum mismatch: {name}")
    info = read_ipa(stage / manifest["ipa"])
    if info["CFBundleShortVersionString"] != manifest["version"] or info["CFBundleVersion"] != manifest["build"]:
        raise ValueError("Staged IPA version/build differs from release metadata")
    if hashlib.sha256((stage / manifest["ipa"]).read_bytes()).hexdigest() != manifest["ipaSHA256"]:
        raise ValueError("Staged IPA digest differs from release metadata")
    record = manifest["release"]
    if record["downloadURL"] != manifest["baseURL"] + "/" + quote(manifest["ipa"]):
        raise ValueError("Staged download URL does not point at the verified IPA")
    if (record["version"] != manifest["version"] or record["size"] != files[manifest["ipa"]]["size"]
            or record["minOSVersion"] != info["MinimumOSVersion"]):
        raise ValueError("Staged feed metadata differs from the verified IPA")
    return manifest_path, manifest


def promote_release(staging_directory, published_directory):
    stage = Path(staging_directory)
    published = Path(published_directory)
    manifest_path, manifest = validate_staged_release(stage)
    files = manifest["files"]
    published.mkdir(parents=True, exist_ok=True)
    with (published.parent / ".podhod-release.lock").open("a+b") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        source = merged_source(published, manifest)
        for name in files:
            atomic_release_file(published / name, (stage / name).read_bytes(), immutable=True)
        target_manifest = published / manifest_path.name
        if target_manifest.exists():
            previous = json.loads(target_manifest.read_text())
            keys = ["bundleIdentifier", "version", "build", "baseURL", "ipa", "ipaSHA256", "icon", "files"]
            if any(previous.get(key) != manifest.get(key) for key in keys):
                raise ValueError("Published release metadata differs from the staged artifacts")
        else:
            atomic_release_file(target_manifest, manifest_path.read_bytes(), immutable=True)
        atomic_release_file(published / "source.json", json_bytes(source))
    return source


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    publishing = len(sys.argv) > 1 and sys.argv[1] == "publish"
    if publishing:
        parser.add_argument("action", choices=["publish"])
        parser.add_argument("staging_directory", type=Path)
        parser.add_argument("published_directory", type=Path)
    else:
        parser.add_argument("ipa", type=Path)
        parser.add_argument("base_url", help="Public HTTPS URL of the release directory")
        parser.add_argument("output_directory", type=Path)
    args = parser.parse_args()
    try:
        if publishing:
            source = promote_release(args.staging_directory, args.published_directory)
            print("Published unsigned Podhod " + source["apps"][0]["version"])
        else:
            manifest = package_release(args.ipa, args.base_url, args.output_directory)
            print(f"Packaged unsigned Podhod release: {manifest}")
    except (ValueError, OSError, KeyError, TypeError, zipfile.BadZipFile, plistlib.InvalidFileException) as error:
        parser.error(str(error))


if __name__ == "__main__":
    main()
