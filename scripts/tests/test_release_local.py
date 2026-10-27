import importlib.util
import contextlib
import io
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch


SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
spec = importlib.util.spec_from_file_location("podhod_local_release", SCRIPTS / "release_local.py")
local_release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(local_release)


class LocalReleaseTests(unittest.TestCase):
    def test_source_guard_detects_code_edits_without_reading_secrets_or_docs(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "App.swift"
            source.write_text("source version one")
            (root / "cert.p12").write_bytes(b"private fixture")
            (root / ".env").write_text("private fixture")
            (root / ".env.local").write_text("private fixture")
            (root / "Config").mkdir()
            (root / "Config/Local.xcconfig").write_text("private fixture")
            (root / "README.md").write_text("documentation")
            (root / "secrets").mkdir()
            (root / "secrets/credentials").write_text("private fixture")
            original_read = Path.read_bytes

            def checked_read(path):
                if path.name in {"cert.p12", ".env", ".env.local", "Local.xcconfig", "credentials", "README.md"}:
                    raise AssertionError("source guard read a private or excluded file")
                return original_read(path)

            with patch.object(local_release, "PROJECT", root), patch.object(Path, "read_bytes", checked_read):
                before = local_release.source_fingerprint()
                source.write_text("source version two")
                self.assertNotEqual(local_release.source_fingerprint(), before)

    def test_publishing_requires_explicit_operator_configuration_before_running_commands(self):
        with patch.dict(os.environ, {}, clear=True), patch.object(sys, "argv", ["release_local.py", "1.5", "6", "--publish"]), \
                patch.object(local_release.subprocess, "run") as command, contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit) as stopped:
                local_release.main()
            self.assertEqual(stopped.exception.code, 2)
            command.assert_not_called()
