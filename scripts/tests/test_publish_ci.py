import gzip
import importlib.util
import io
import json
from pathlib import Path
import plistlib
import struct
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch
import zipfile

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
spec = importlib.util.spec_from_file_location('podhod_ci_publish', SCRIPTS / 'publish_ci.py')
ci = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ci)
import package_release as release

BASE = 'https://podhod.example/releases'
COMMIT = 'a' * 40


class CIPublishingTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.addCleanup(self.temporary.cleanup)
        self.repo = self.root / 'repo'
        self.repo.mkdir()
        (self.repo / 'Podhod.xcodeproj').mkdir()
        (self.repo / 'Podhod.xcodeproj/project.pbxproj').write_text('    MARKETING_VERSION = 1.2.0;\n')
        self.config = {'base_url': BASE, 'published_directory': str(self.root / 'public'),
                       'state_directory': str(self.root / 'state')}
        Path(self.config['state_directory']).mkdir()

    def artifacts(self, run=1, payload=b'code'):
        version, build = '1.2.' + str(run), str(1000 + run)
        info = {'CFBundleIdentifier': release.BUNDLE_ID, 'CFBundleExecutable': 'Podhod',
                'CFBundleShortVersionString': version, 'CFBundleVersion': build,
                'CFBundleSupportedPlatforms': ['iPhoneOS'], 'MinimumOSVersion': '17.0'}
        path = self.root / f'input-{run}-{len(payload)}.ipa'
        with zipfile.ZipFile(path, 'w', zipfile.ZIP_DEFLATED) as archive:
            archive.writestr('Payload/Podhod.app/Info.plist', plistlib.dumps(info))
            archive.writestr('Payload/Podhod.app/Podhod', b'\xcf\xfa\xed\xfe' + struct.pack('<I', 0x0100000C) + payload)
        directory = self.root / f'artifacts-{run}-{len(payload)}'
        release.package_release(path, BASE, directory)
        return directory

    def bundle(self, run=1, commit=COMMIT, payload=b'code'):
        artifacts = self.artifacts(run, payload)
        path = self.root / f'bundle-{run}-{len(payload)}.tar.gz'
        with patch.object(ci.subprocess, 'check_output', return_value=commit):
            identity = ci.bundle_release(self.repo, artifacts, path, run, commit)
        return path, identity

    def received(self, path, name):
        stage = self.root / name
        stage.mkdir()
        with path.open('rb') as stream:
            identity, manifest = ci.receive_archive(stream, stage)
        return stage, identity, manifest

    def test_identity_increments_patch_and_build_without_editing_project(self):
        source = (self.repo / 'Podhod.xcodeproj/project.pbxproj').read_bytes()
        with patch.object(ci.subprocess, 'check_output', return_value=COMMIT):
            value = ci.release_identity(self.repo, 7, COMMIT)
        self.assertEqual((value['version'], value['build']), ('1.2.7', '1007'))
        self.assertEqual((self.repo / 'Podhod.xcodeproj/project.pbxproj').read_bytes(), source)
        with patch.object(ci.subprocess, 'check_output', return_value='b' * 40):
            with self.assertRaisesRegex(ValueError, 'checkout HEAD'):
                ci.release_identity(self.repo, 7, COMMIT)

    def test_round_trip_publication_preserves_identity_and_artifacts(self):
        path, _ = self.bundle()
        stage, identity, manifest = self.received(path, 'stage')
        result = ci.publish_received(self.config, stage, identity, manifest)
        self.assertEqual(result['status'], 'published')
        self.assertEqual(ci.publication_status(self.config)['commit'], COMMIT)
        self.assertEqual((self.root / 'public' / manifest['ipa']).read_bytes(), (stage / manifest['ipa']).read_bytes())
        self.assertFalse((self.root / 'state/pending.json').exists())

    def test_same_commit_retry_preserves_published_bytes_even_after_rebuild(self):
        path, _ = self.bundle()
        stage, identity, manifest = self.received(path, 'stage')
        ci.publish_received(self.config, stage, identity, manifest)
        before = (self.root / 'public/source.json').read_bytes()
        rebuilt, _ = self.bundle(payload=b'changed build')
        stage2, identity2, manifest2 = self.received(rebuilt, 'stage2')
        result = ci.publish_received(self.config, stage2, identity2, manifest2)
        self.assertEqual(result['status'], 'already-published')
        self.assertEqual((self.root / 'public/source.json').read_bytes(), before)
        self.assertEqual((self.root / 'public' / manifest['ipa']).read_bytes(), (stage / manifest['ipa']).read_bytes())

    def test_stale_run_and_wrong_destination_leave_feed_unchanged(self):
        newer, _ = self.bundle(2, 'b' * 40)
        stage, identity, manifest = self.received(newer, 'newer')
        ci.publish_received(self.config, stage, identity, manifest)
        before = (self.root / 'public/source.json').read_bytes()
        old, _ = self.bundle()
        stage, identity, manifest = self.received(old, 'old')
        with self.assertRaisesRegex(ValueError, 'stale'):
            ci.publish_received(self.config, stage, identity, manifest)
        self.assertEqual((self.root / 'public/source.json').read_bytes(), before)
        manifest['baseURL'] = 'https://other.example/releases'
        with self.assertRaisesRegex(ValueError, 'destination'):
            ci.publish_received(self.config, stage, identity, manifest)
        self.assertEqual((self.root / 'public/source.json').read_bytes(), before)

    def test_reconciles_interruption_after_atomic_feed_update(self):
        path, _ = self.bundle()
        stage, identity, manifest = self.received(path, 'stage')
        promote = ci.promote_release

        def interrupted(stage, destination):
            promote(stage, destination)
            raise SystemExit('simulated SSH interruption')

        with patch.object(ci, 'promote_release', side_effect=interrupted):
            with self.assertRaises(SystemExit):
                ci.publish_received(self.config, stage, identity, manifest)
        self.assertTrue((self.root / 'state/pending.json').exists())
        self.assertEqual(ci.publication_status(self.config)['commit'], COMMIT)
        self.assertFalse((self.root / 'state/pending.json').exists())

    def test_failure_before_promotion_does_not_claim_publication(self):
        path, _ = self.bundle()
        stage, identity, manifest = self.received(path, 'stage')
        with patch.object(ci, 'promote_release', side_effect=ValueError('failed validation')):
            with self.assertRaises(ValueError):
                ci.publish_received(self.config, stage, identity, manifest)
        self.assertEqual(ci.publication_status(self.config)['run_number'], 0)
        self.assertFalse((self.root / 'public/source.json').exists())

    def test_compressed_and_decompressed_limits_include_tar_metadata(self):
        data = io.BytesIO()
        with tarfile.open(fileobj=data, mode='w:gz', format=tarfile.PAX_FORMAT) as archive:
            member = tarfile.TarInfo('ci.json')
            member.size = 2
            member.pax_headers = {'comment': 'x' * 100000}
            archive.addfile(member, io.BytesIO(b'{}'))
        stage = self.root / 'oversized'
        stage.mkdir()
        with patch.object(ci, 'MAX_EXPANDED', 4096), self.assertRaisesRegex(ValueError, 'Expanded'):
            ci.receive_archive(io.BytesIO(data.getvalue()), stage)
        stage2 = self.root / 'compressed'
        stage2.mkdir()
        with patch.object(ci, 'MAX_COMPRESSED', 20), self.assertRaisesRegex(ValueError, 'Compressed'):
            ci.receive_archive(io.BytesIO(b'x' * 21), stage2)

    def test_rejects_unsafe_duplicate_symlink_and_missing_entries(self):
        for kind in ('unsafe', 'duplicate', 'symlink', 'missing'):
            with self.subTest(kind=kind):
                data = io.BytesIO()
                with tarfile.open(fileobj=data, mode='w:gz') as archive:
                    member = tarfile.TarInfo('../escape' if kind == 'unsafe' else 'ci.json')
                    member.size = 2
                    if kind == 'symlink':
                        member.type = tarfile.SYMTYPE
                        member.linkname = '/etc/passwd'
                    archive.addfile(member, io.BytesIO(b'{}'))
                    if kind == 'duplicate':
                        archive.addfile(member, io.BytesIO(b'{}'))
                stage = self.root / kind
                stage.mkdir()
                with self.assertRaises((ValueError, KeyError)):
                    ci.receive_archive(io.BytesIO(data.getvalue()), stage)
        self.assertFalse((self.root / 'escape').exists())

    def test_rejects_corrupt_artifact_before_publication(self):
        path, _ = self.bundle()
        data = io.BytesIO()
        with tarfile.open(path, 'r:gz') as original, tarfile.open(fileobj=data, mode='w:gz') as changed:
            for member in original:
                content = original.extractfile(member).read()
                if member.name.endswith('-icon.png'):
                    content = b'corrupt upload'
                    member.size = len(content)
                changed.addfile(member, io.BytesIO(content))
        stage = self.root / 'corrupt'
        stage.mkdir()
        with self.assertRaisesRegex(ValueError, 'checksum'):
            ci.receive_archive(io.BytesIO(data.getvalue()), stage)
        self.assertFalse((self.root / 'public/source.json').exists())

    def test_rejects_arbitrary_ssh_command_before_reading_payload(self):
        config = self.root / 'publisher.json'
        config.write_text(json.dumps(self.config))
        config.chmod(0o600)
        with patch.object(ci, 'CONFIG', config), patch.object(ci.os, 'geteuid', return_value=0), \
                patch.object(Path, 'stat') as stat, patch.dict(ci.os.environ, {'SSH_ORIGINAL_COMMAND': 'sh -c whoami'}):
            stat.return_value.st_uid = 0
            stat.return_value.st_mode = 0o100600
            with self.assertRaisesRegex(ValueError, 'Only the read-only'):
                ci.receive_release(io.BytesIO(b''))


if __name__ == '__main__':
    unittest.main()
