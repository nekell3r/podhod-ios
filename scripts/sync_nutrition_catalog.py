#!/usr/bin/env python3
"""Import the pinned nutrition catalog from a committed local backend checkout."""

import argparse
import hashlib
import json
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('backend', type=Path)
    args = parser.parse_args()
    backend = args.backend.resolve()
    relative = Path('internal/service/nutrition-catalog.json')
    revision = subprocess.check_output(['git', '-C', str(backend), 'rev-parse', 'HEAD'], text=True).strip()
    committed = subprocess.check_output(['git', '-C', str(backend), 'show', f'{revision}:{relative}'])
    data = (backend / relative).read_bytes()
    if data != committed:
        parser.error('Commit backend nutrition catalog changes before importing them')
    catalog = json.loads(data)
    if catalog.get('formatVersion') != 1 or not catalog.get('version') or not catalog.get('foods') or not catalog.get('recipes'):
        parser.error('Unsupported, empty or unversioned nutrition catalog')
    project = Path(__file__).resolve().parents[1]
    (project / 'Podhod/Resources/nutrition-catalog.json').write_bytes(data)
    lock = {'repository': 'https://github.com/nekell3r/podhod-backend', 'revision': revision,
            'path': str(relative), 'catalogVersion': catalog['version'], 'formatVersion': catalog['formatVersion'],
            'sha256': hashlib.sha256(data).hexdigest()}
    (project / 'nutrition-catalog.lock.json').write_text(json.dumps(lock, indent=2) + '\n')
    print(f"Imported nutrition catalog {catalog['version']} from {revision}")


if __name__ == '__main__':
    main()
