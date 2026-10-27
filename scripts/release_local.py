#!/usr/bin/env python3
"""Test, build and publish one unsigned Podhod release using the existing Mac and VPS."""

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shlex
import shutil
import subprocess
import sys
import uuid

from package_release import BUNDLE_ID, BUILD_PATTERN, package_release, read_ipa, version_key


PROJECT = Path(__file__).resolve().parents[1]
WORKSPACE = PROJECT
BASE_URL = os.environ.get("PODHOD_RELEASE_BASE_URL", "https://api.example.com/releases")
REMOTE = os.environ.get("PODHOD_RELEASE_SSH_HOST")
PUBLIC_DIRECTORY = os.environ.get("PODHOD_RELEASE_DIRECTORY")


def source_fingerprint():
    digest = hashlib.sha256()
    for path in sorted(PROJECT.rglob("*")):
        relative = path.relative_to(PROJECT)
        if not path.is_file() or any(part in {
            ".git", ".build", "work", "__pycache__", "xcuserdata", "secrets", "backups", ".deploy"
        } for part in relative.parts):
            continue
        if (path.name in {".DS_Store", ".env", ".env.local", "Local.xcconfig", "access.json", "realm.json"}
                or path.suffix.lower() in {".md", ".p12", ".pfx", ".pem", ".key", ".mobileprovision"}):
            continue
        digest.update(str(relative).encode() + b"\0" + path.read_bytes() + b"\0")
    return digest.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("version", help="New marketing version, for example 1.2")
    parser.add_argument("build", help="Increasing positive integer build number, for example 3")
    parser.add_argument("--publish", action="store_true", help="Publish using explicit PODHOD_RELEASE_* environment settings")
    args = parser.parse_args()
    if args.publish:
        required = ["PODHOD_RELEASE_BASE_URL", "PODHOD_RELEASE_SSH_HOST", "PODHOD_RELEASE_DIRECTORY"]
        if any(not os.environ.get(name) for name in required):
            parser.error("--publish requires " + ", ".join(required))
        if REMOTE.startswith("-") or not PurePosixPath(PUBLIC_DIRECTORY).is_absolute():
            parser.error("Invalid SSH host or release directory")
    version_key(args.version)
    if not BUILD_PATTERN.fullmatch(args.build):
        parser.error("build must be a positive integer")
    release_id = f"{args.version}-{args.build}"
    scratch = WORKSPACE / ".build" / "local-release" / release_id
    output = WORKSPACE / ".build" / "releases" / release_id
    scratch.mkdir(parents=True, exist_ok=True)
    environment = os.environ.copy()
    environment.update({
        "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer",
        "CLANG_MODULE_CACHE_PATH": str(scratch / "swift-module-cache"),
    })
    before = source_fingerprint()
    steps = [
        ("Release packaging tests", PROJECT, [sys.executable, "-m", "unittest", "discover", "-s", "scripts/tests"]),
        ("Swift core tests", PROJECT, ["swift", "test", "--disable-sandbox", "--scratch-path", str(scratch / "swift-tests"),
                                      "--cache-path", str(scratch / "swift-cache")]),
        ("Unsigned iPhone device build", PROJECT, [
            "xcodebuild", "-project", "Podhod.xcodeproj", "-scheme", "Podhod", "-configuration", "Release",
            "-destination", "generic/platform=iOS", "-derivedDataPath", str(scratch / "DerivedData"),
            "CODE_SIGNING_ALLOWED=NO", "ENABLE_DEBUG_DYLIB=NO", f"MARKETING_VERSION={args.version}",
            f"CURRENT_PROJECT_VERSION={args.build}", "build",
        ]),
    ]
    for title, directory, command in steps:
        print(title, flush=True)
        subprocess.run(command, cwd=directory, env=environment, check=True)
    if source_fingerprint() != before:
        raise RuntimeError("Project sources changed during tests/build. Nothing was published; run again after edits finish.")
    app = scratch / "DerivedData/Build/Products/Release-iphoneos/Podhod.app"
    payload = scratch / "Payload"
    payload.mkdir(exist_ok=True)
    target = payload / "Podhod.app"
    if target.exists():
        shutil.rmtree(target)
    shutil.copytree(app, target)
    ipa = scratch / f"Podhod-{release_id}.ipa"
    subprocess.run(["ditto", "-c", "-k", "--norsrc", "--keepParent", str(payload), str(ipa)], check=True)
    info = read_ipa(ipa)
    if (info["CFBundleIdentifier"] != BUNDLE_ID or info["CFBundleShortVersionString"] != args.version
            or info["CFBundleVersion"] != args.build):
        raise RuntimeError("Built app identity/version does not match the requested release")
    manifest_path = package_release(ipa, BASE_URL, output)
    manifest = json.loads(manifest_path.read_text())
    if not args.publish:
        print(f"Built and packaged {manifest_path}. No remote upload requested.")
        return
    staging_parent = str(PurePosixPath(PUBLIC_DIRECTORY).parent / ".release-staging")
    remote_stage = staging_parent + "/" + str(uuid.uuid4())
    ssh = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15", REMOTE]
    subprocess.run(ssh + [shlex.join(["mkdir", "-p", remote_stage])], check=True)
    try:
        files = [output / name for name in manifest["files"]]
        files += [manifest_path, Path(__file__).with_name("package_release.py")]
        subprocess.run(["scp", "-o", "BatchMode=yes", *map(str, files), f"{REMOTE}:{remote_stage}/"], check=True)
        command = ["python3", remote_stage + "/package_release.py", "publish", remote_stage, PUBLIC_DIRECTORY]
        subprocess.run(ssh + [shlex.join(command)], check=True)
    finally:
        cleanup = "import pathlib,shutil,sys; p=pathlib.Path(sys.argv[1]); " \
                  "assert p.parent==pathlib.Path(sys.argv[2]); shutil.rmtree(p)"
        cleaned = subprocess.run(ssh + [shlex.join(["python3", "-c", cleanup, remote_stage, staging_parent])], check=False)
        if cleaned.returncode != 0:
            print("Warning: release staging cleanup failed; the published feed was not rolled back.", file=sys.stderr)
    print(f"Published {BASE_URL}/source.json")
    print("In Feather: refresh the source, sign with the same certificate and install over Podhod. Do not uninstall it.")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, RuntimeError, OSError, subprocess.CalledProcessError) as error:
        print(f"Release stopped: {error}", file=sys.stderr)
        sys.exit(1)
