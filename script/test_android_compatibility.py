from pathlib import Path
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
from android_compatibility import ARTIFACT_NAME, RESOURCE_PATH, validate


class AndroidCompatibilityResourceTests(unittest.TestCase):
    def test_pinned_resource_rejects_modified_missing_and_linked_bytes(self):
        source = Path(__file__).resolve().parents[1] / RESOURCE_PATH
        self.assertEqual(validate(source), [])
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "resources"
            shutil.copytree(source, target)
            artifact = target / ARTIFACT_NAME
            artifact.write_bytes(b"changed artifact")
            self.assertEqual(validate(target), ["compatibility-artifact-digest-mismatch"])
            artifact.unlink()
            self.assertEqual(validate(target), ["compatibility-resource-missing-or-invalid"])
            artifact.symlink_to(source / ARTIFACT_NAME)
            self.assertEqual(validate(target), ["compatibility-resource-symlink"])
