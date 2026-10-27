import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import struct
import tempfile
import unittest
import zipfile


SCRIPT = Path(__file__).resolve().parents[1] / "package_release.py"
spec = importlib.util.spec_from_file_location("podhod_release", SCRIPT)
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)
BASE = "https://podhod.example/releases"


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.addCleanup(self.temporary.cleanup)

    def make_ipa(self, name, version="1.2", build="3", payload=b"app", changes=None, extra=None):
        info = {
            "CFBundleIdentifier": "dev.podhod.training", "CFBundleExecutable": "Podhod",
            "CFBundleShortVersionString": version, "CFBundleVersion": build,
            "CFBundleSupportedPlatforms": ["iPhoneOS"], "MinimumOSVersion": "17.0",
        }
        info.update(changes or {})
        path = self.root / name
        with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as archive:
            archive.writestr("Payload/Podhod.app/Info.plist", plistlib.dumps(info))
            archive.writestr("Payload/Podhod.app/Podhod", b"\xcf\xfa\xed\xfe" + struct.pack("<I", 0x0100000C) + payload)
            for key, value in (extra or {}).items():
                archive.writestr(key, value)
        return path

    def package(self, ipa, directory):
        path = release.package_release(ipa, BASE, self.root / directory)
        return path.parent, path, json.loads(path.read_text())

    def first_publication(self):
        stage, _, _ = self.package(self.make_ipa("old.ipa", "1.1", "2"), "old-stage")
        public = self.root / "public"
        release.promote_release(stage, public)
        return public

    def test_retains_old_versions_and_publishes_checksums(self):
        public = self.first_publication()
        old_data = (public / "Podhod-1.1-2.ipa").read_bytes()
        stage, _, manifest = self.package(self.make_ipa("new.ipa"), "new-stage")
        source = release.promote_release(stage, public)
        self.assertEqual([item["version"] for item in source["apps"][0]["versions"]], ["1.2", "1.1"])
        self.assertEqual((public / "Podhod-1.1-2.ipa").read_bytes(), old_data)
        for name, expected in manifest["files"].items():
            data = (public / name).read_bytes()
            self.assertEqual(hashlib.sha256(data).hexdigest(), expected["sha256"])
            self.assertEqual(len(data), expected["size"])
        with zipfile.ZipFile(public / "Podhod-1.2-3-for-Files.zip") as archive:
            self.assertEqual(archive.namelist(), ["Podhod-1.2-3.ipa"])
            self.assertEqual(archive.read("Podhod-1.2-3.ipa"), (public / "Podhod-1.2-3.ipa").read_bytes())

    def test_same_marketing_version_cannot_publish_different_ipa_even_with_new_build(self):
        public = self.first_publication()
        before = (public / "source.json").read_bytes()
        stage, _, _ = self.package(self.make_ipa("changed.ipa", "1.1", "3", b"changed"), "changed-stage")
        with self.assertRaisesRegex(ValueError, "marketing version"):
            release.promote_release(stage, public)
        self.assertEqual((public / "source.json").read_bytes(), before)
        self.assertFalse((public / "Podhod-1.1-3.ipa").exists())

    def test_fresh_staging_retry_preserves_published_manifest_and_date(self):
        ipa = self.make_ipa("app.ipa")
        first, _, _ = self.package(ipa, "first")
        public = self.root / "public"
        release.promote_release(first, public)
        original_source = (public / "source.json").read_bytes()
        original_manifest = (public / "Podhod-1.2-3.release.json").read_bytes()
        retry, path, manifest = self.package(ipa, "retry")
        manifest["release"]["date"] = "2099-01-01T00:00:00Z"
        path.write_text(json.dumps(manifest))
        release.promote_release(retry, public)
        self.assertEqual((public / "source.json").read_bytes(), original_source)
        self.assertEqual((public / "Podhod-1.2-3.release.json").read_bytes(), original_manifest)

    def test_local_artifact_version_and_build_are_immutable(self):
        _, path, _ = self.package(self.make_ipa("first.ipa"), "same-output")
        original = path.read_bytes()
        with self.assertRaisesRegex(ValueError, "different IPA"):
            self.package(self.make_ipa("different.ipa", payload=b"different"), "same-output")
        self.assertEqual(path.read_bytes(), original)

    def test_corrupt_upload_does_not_change_visible_feed(self):
        public = self.first_publication()
        before = (public / "source.json").read_bytes()
        stage, _, manifest = self.package(self.make_ipa("next.ipa"), "next-stage")
        (stage / manifest["ipa"]).write_bytes(b"incomplete upload")
        with self.assertRaisesRegex(ValueError, "checksum"):
            release.promote_release(stage, public)
        self.assertEqual((public / "source.json").read_bytes(), before)
        self.assertFalse((public / "Podhod-1.2-3.ipa").exists())

    def test_rejects_downgrade_and_nonincreasing_build(self):
        public = self.first_publication()
        for name, version, build in [("downgrade", "1.0", "9"), ("low-build", "1.2", "1")]:
            with self.subTest(name=name):
                stage, _, _ = self.package(self.make_ipa(name + ".ipa", version, build), name)
                with self.assertRaises(ValueError):
                    release.promote_release(stage, public)
        self.assertEqual(json.loads((public / "source.json").read_text())["apps"][0]["version"], "1.1")

    def test_rejects_wrong_identity_simulator_private_files_and_invalid_version(self):
        cases = [
            ("identity", {"CFBundleIdentifier": "dev.other.app"}, None),
            ("simulator", {"CFBundleSupportedPlatforms": ["iPhoneSimulator"]}, None),
            ("version", {"CFBundleShortVersionString": "1..2"}, None),
            ("build", {"CFBundleVersion": "0"}, None),
            ("profile", None, {"Payload/Podhod.app/embedded.mobileprovision": b"not allowed"}),
            ("private-key", None, {"Payload/Podhod.app/cert.p12": b"not allowed"}),
            ("credentials", None, {"Payload/Podhod.app/access.json": b"not allowed"}),
            ("traversal", None, {"../escape": b"not allowed"}),
        ]
        for name, changes, extra in cases:
            with self.subTest(name=name):
                ipa = self.make_ipa(name + ".ipa", changes=changes, extra=extra)
                with self.assertRaises(ValueError):
                    release.package_release(ipa, BASE, self.root / name)

    def test_existing_broken_feed_is_not_silently_reset(self):
        public = self.first_publication()
        (public / "source.json").write_text('{"identifier":"wrong","apps":[]}')
        before = (public / "source.json").read_bytes()
        stage, _, _ = self.package(self.make_ipa("next.ipa"), "next-stage")
        with self.assertRaisesRegex(ValueError, "does not belong"):
            release.promote_release(stage, public)
        self.assertEqual((public / "source.json").read_bytes(), before)


if __name__ == "__main__":
    unittest.main()
