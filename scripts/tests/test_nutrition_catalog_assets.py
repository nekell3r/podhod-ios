import hashlib
import json
from pathlib import Path
import unittest


class NutritionCatalogAssetsTests(unittest.TestCase):
    def test_lock_matches_bundled_data_and_resource_is_in_both_builds(self):
        project = Path(__file__).resolve().parents[2]
        data = (project / 'Podhod/Resources/nutrition-catalog.json').read_bytes()
        lock = json.loads((project / 'nutrition-catalog.lock.json').read_text())
        catalog = json.loads(data)
        self.assertEqual(lock['sha256'], hashlib.sha256(data).hexdigest())
        self.assertEqual(lock['catalogVersion'], catalog['version'])
        self.assertEqual(lock['formatVersion'], catalog['formatVersion'])
        self.assertEqual(len(lock['revision']), 40)
        self.assertEqual(lock['path'], 'internal/service/nutrition-catalog.json')
        self.assertIn('Resources/nutrition-catalog.json', (project / 'Podhod.xcodeproj/project.pbxproj').read_text())
        self.assertIn('.process("Resources")', (project / 'Package.swift').read_text())
        self.assertEqual(len({food['id'] for food in catalog['foods']}), len(catalog['foods']))
        self.assertEqual(len({recipe['id'] for recipe in catalog['recipes']}), len(catalog['recipes']))
