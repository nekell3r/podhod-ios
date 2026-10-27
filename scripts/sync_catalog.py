#!/usr/bin/env python3
"""Import the versioned exercise catalog from a local backend checkout."""

import argparse
import hashlib
import json
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("backend", type=Path, help="Local podhod-backend checkout")
    args = parser.parse_args()
    backend = args.backend.resolve()
    source = backend / "internal/service/exercise-catalog.json"
    relative = source.relative_to(backend)
    revision = subprocess.check_output(["git", "-C", str(backend), "rev-parse", "HEAD"], text=True).strip()
    committed = subprocess.check_output(["git", "-C", str(backend), "show", f"{revision}:{relative}"])
    data = source.read_bytes()
    if data != committed:
        parser.error("Commit backend catalog changes before importing them")
    catalog = json.loads(data)
    if not catalog.get("version") or not catalog.get("exercises"):
        parser.error("Backend catalog is empty or unversioned")
    project = Path(__file__).resolve().parents[1]
    (project / "Podhod/Resources/exercise-catalog.json").write_bytes(data)
    lock = {"repository": "https://github.com/nekell3r/podhod-backend", "revision": revision,
            "path": str(relative), "catalogVersion": catalog["version"],
            "sha256": hashlib.sha256(data).hexdigest()}
    (project / "catalog.lock.json").write_text(json.dumps(lock, indent=2) + "\n")
    print(f"Imported catalog {catalog['version']} from {revision}")


if __name__ == "__main__":
    main()
