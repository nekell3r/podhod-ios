#!/usr/bin/env python3
"""Bundle a tested IPA or publish it through a separately restricted SSH key."""

import argparse
import fcntl
import gzip
import hashlib
import io
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import zipfile
import zlib

from package_release import (atomic_release_file, json_bytes, promote_release, published_ipa,
                             read_source, validate_base_url, validate_staged_release, version_key)

CONFIG = Path('/etc/podhod-ipa-publish.json')
COMMIT = re.compile(r'[a-f0-9]{40}\Z')
MAX_COMPRESSED = 128 * 1024 * 1024
MAX_EXPANDED = 256 * 1024 * 1024
MAX_ZIP_EXPANDED = 256 * 1024 * 1024


def release_identity(repository, run_number, commit):
    if type(run_number) is not int or run_number < 1 or not COMMIT.fullmatch(commit):
        raise ValueError('Invalid workflow identity')
    actual = subprocess.check_output(['git', '-C', str(repository), 'rev-parse', 'HEAD'], text=True).strip()
    if actual != commit:
        raise ValueError('Workflow commit does not match checkout HEAD')
    versions = set(re.findall(r'^\s+MARKETING_VERSION\s*=\s*([0-9.]+);\s*$',
                              (repository / 'Podhod.xcodeproj/project.pbxproj').read_text(), re.MULTILINE))
    if len(versions) != 1:
        raise ValueError('Project targets must have one marketing version')
    major, minor, patch = version_key(versions.pop())
    return {'schema': 1, 'commit': commit, 'run_number': run_number,
            'version': f'{major}.{minor}.{patch + run_number}', 'build': str(1000 + run_number)}


def bundle_release(repository, artifacts, output, run_number, commit):
    identity = release_identity(repository, run_number, commit)
    manifest_path, manifest = validate_staged_release(artifacts)
    if any(manifest[key] != identity[key] for key in ('version', 'build')):
        raise ValueError('IPA identity differs from the workflow identity')
    output.parent.mkdir(parents=True, exist_ok=True)
    with tarfile.open(output, 'w:gz', format=tarfile.USTAR_FORMAT) as archive:
        data = json_bytes(identity)
        member = tarfile.TarInfo('ci.json')
        member.size = len(data)
        member.mode = 0o600
        archive.addfile(member, io.BytesIO(data))
        for name in [manifest_path.name, *manifest['files']]:
            path = artifacts / name
            if path.is_symlink():
                raise ValueError('Release inputs must be regular files')
            archive.add(path, arcname=name, recursive=False)
    return identity


def receive_archive(stream, directory):
    compressed = directory / 'incoming.tar.gz'
    with compressed.open('xb') as output:
        total = 0
        while data := stream.read(1024 * 1024):
            total += len(data)
            if total > MAX_COMPRESSED:
                raise ValueError('Compressed IPA release exceeds limit')
            output.write(data)
    plain = directory / 'incoming.tar'
    with gzip.open(compressed, 'rb') as source, plain.open('xb') as output:
        total = 0
        while data := source.read(1024 * 1024):
            total += len(data)
            if total > MAX_EXPANDED:
                raise ValueError('Expanded IPA release exceeds limit')
            output.write(data)
    received = set()
    with tarfile.open(plain, 'r:') as archive:
        for member in archive:
            if (not member.isfile() or member.name in received or member.size <= 0
                    or member.size > MAX_COMPRESSED
                    or not re.fullmatch(r'ci\.json|Podhod-[0-9.]+-[0-9]+(?:\.release\.json|\.ipa|-for-Files\.zip|-icon\.png|\.sha256)', member.name)):
                raise ValueError('Unexpected IPA release entry')
            if member.name.endswith('.json') and member.size > 65536:
                raise ValueError('IPA metadata exceeds limit')
            received.add(member.name)
            with archive.extractfile(member) as source, (directory / member.name).open('xb') as output:
                shutil.copyfileobj(source, output, length=1024 * 1024)
    identity = json.loads((directory / 'ci.json').read_text())
    if (set(identity) != {'schema', 'commit', 'run_number', 'version', 'build'} or identity['schema'] != 1
            or type(identity['run_number']) is not int or identity['run_number'] < 1
            or not COMMIT.fullmatch(identity['commit']) or identity['build'] != str(1000 + identity['run_number'])):
        raise ValueError('Invalid IPA workflow metadata')
    version_key(identity['version'])
    for path in directory.glob('*.ipa'):
        with zipfile.ZipFile(path) as archive:
            if sum(item.file_size for item in archive.infolist()) > MAX_ZIP_EXPANDED:
                raise ValueError('Expanded IPA contents exceed limit')
            if any(item.filename.endswith('/Info.plist') and item.file_size > 1024 * 1024 for item in archive.infolist()):
                raise ValueError('IPA property list exceeds limit')
    manifest_path, manifest = validate_staged_release(directory)
    expected = {'ci.json', manifest_path.name, *manifest['files']}
    if received != expected or any(manifest[key] != identity[key] for key in ('version', 'build')):
        raise ValueError('IPA artifacts differ from workflow metadata')
    return identity, manifest


def publication_status(configuration):
    public = Path(configuration['published_directory'])
    state = Path(configuration['state_directory'])
    current = state / 'current.json'
    pending = state / 'pending.json'
    if pending.exists():
        candidate = json.loads(pending.read_text())
        source = read_source(public)
        latest = max(source['apps'][0]['versions'], key=lambda item: version_key(item['version'])) if source else None
        if latest and latest['version'] == candidate['version']:
            path, info = published_ipa(public, latest, configuration['base_url'])
            if info['CFBundleVersion'] == candidate['build'] and hashlib.sha256(path.read_bytes()).hexdigest() == candidate['ipa_sha256']:
                atomic_release_file(current, json_bytes(candidate))
                current.chmod(0o600)
                pending.unlink()
    if current.exists():
        value = json.loads(current.read_text())
        return {key: value[key] for key in ('commit', 'run_number', 'version', 'build')}
    return {'commit': None, 'run_number': 0, 'version': None, 'build': None}


def publish_received(configuration, stage, identity, manifest):
    if manifest['baseURL'] != configuration['base_url']:
        raise ValueError('IPA destination does not match the configured destination')
    previous = publication_status(configuration)
    if previous['commit'] == identity['commit']:
        return {'status': 'already-published', **previous}
    if identity['run_number'] <= previous['run_number']:
        raise ValueError('Newer workflow run is already published; stale IPA refused')
    state = Path(configuration['state_directory'])
    candidate = {**identity, 'ipa_sha256': manifest['ipaSHA256']}
    atomic_release_file(state / 'pending.json', json_bytes(candidate))
    (state / 'pending.json').chmod(0o600)
    promote_release(stage, Path(configuration['published_directory']))
    current = publication_status(configuration)
    if current['commit'] != identity['commit']:
        raise ValueError('Publication could not be verified')
    return {'status': 'published', **current}


def receive_release(stream):
    if os.geteuid() != 0 or CONFIG.stat().st_uid != 0 or CONFIG.stat().st_mode & 0o077:
        raise ValueError('IPA publisher requires root and root-owned private configuration')
    command = os.environ.get('SSH_ORIGINAL_COMMAND', '')
    if command not in ('', 'status'):
        raise ValueError('Only the read-only status command or an IPA stream is accepted')
    configuration = json.loads(CONFIG.read_text())
    configuration['base_url'] = validate_base_url(configuration['base_url'])
    for name in ('published_directory', 'state_directory'):
        if not Path(configuration[name]).is_absolute():
            raise ValueError('IPA publisher directories must be absolute')
    state = Path(configuration['state_directory'])
    state.mkdir(mode=0o700, parents=True, exist_ok=True)
    with (state / 'lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if command == 'status':
            print(json.dumps(publication_status(configuration)))
            return
        with tempfile.TemporaryDirectory(prefix='incoming-', dir=state) as temporary:
            stage = Path(temporary)
            identity, manifest = receive_archive(stream, stage)
            print(json.dumps(publish_received(configuration, stage, identity, manifest)))


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='action', required=True)
    identity = commands.add_parser('identity')
    bundle = commands.add_parser('bundle')
    for command in (identity, bundle):
        command.add_argument('--repository', type=Path, required=True)
        command.add_argument('--commit', required=True)
        command.add_argument('--run-number', type=int, required=True)
    bundle.add_argument('--artifacts', type=Path, required=True)
    bundle.add_argument('--output', type=Path, required=True)
    commands.add_parser('receive')
    args = parser.parse_args()
    if args.action == 'identity':
        print(json.dumps(release_identity(args.repository, args.run_number, args.commit)))
    elif args.action == 'bundle':
        print(json.dumps(bundle_release(args.repository, args.artifacts, args.output, args.run_number, args.commit)))
    else:
        receive_release(sys.stdin.buffer)


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, KeyError, TypeError, AttributeError, tarfile.TarError, EOFError, zipfile.BadZipFile, zlib.error):
        print('Podhod IPA publication stopped: invalid release, configuration or local operation', file=sys.stderr)
        sys.exit(1)
