from __future__ import annotations

import unittest
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))

from validate_macos_compatibility import deployment_versions, version_parts


class MacOSCompatibilityValidationTests(unittest.TestCase):
    def test_parses_modern_and_legacy_deployment_commands(self) -> None:
        output = """
Load command 9
      cmd LC_BUILD_VERSION
    minos 14.0
      sdk 26.2
Load command 10
      cmd LC_VERSION_MIN_MACOSX
  version 11.3
      sdk 15.5
"""
        self.assertEqual(deployment_versions(output), ["14.0", "11.3"])

    def test_versions_compare_numerically(self) -> None:
        self.assertLess(version_parts("14.10"), version_parts("15.0"))
        self.assertEqual(version_parts("14"), version_parts("14.0.0"))
        self.assertGreater(version_parts("26.0"), version_parts("15.3.1"))

    def test_rejects_invalid_versions(self) -> None:
        with self.assertRaisesRegex(ValueError, "invalid macOS version"):
            version_parts("14.beta")


if __name__ == "__main__":
    unittest.main()
