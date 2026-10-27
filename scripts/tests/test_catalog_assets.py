import hashlib
import json
from pathlib import Path
import unittest


class CatalogAssetTests(unittest.TestCase):
    def test_phone_catalog_matches_pinned_backend_export(self):
        project = Path(__file__).resolve().parents[2]
        phone = (project / "Podhod/Resources/exercise-catalog.json").read_bytes()
        lock = json.loads((project / "catalog.lock.json").read_bytes())
        self.assertEqual(hashlib.sha256(phone).hexdigest(), lock["sha256"], "Run scripts/sync_catalog.py against the backend checkout")
        catalog = json.loads(phone)
        self.assertTrue(catalog["version"])
        self.assertEqual(58, len(catalog["exercises"]))
        self.assertEqual(57, sum(bool(entry["videos"]) for entry in catalog["exercises"]))
        entries = {entry["exercise"]["id"]: entry for entry in catalog["exercises"]}
        self.assertEqual(20, len(catalog["exerciseIDAliases"]))
        for alias in catalog["exerciseIDAliases"]:
            with self.subTest(alias=alias["id"]):
                entry = entries[alias["exerciseID"]]
                self.assertTrue(entry["primaryMuscles"])
                self.assertTrue(entry["instructions"])
                self.assertTrue(entry["videos"])


if __name__ == "__main__":
    unittest.main()
