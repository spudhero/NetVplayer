from __future__ import annotations

import subprocess
import tempfile
import unittest
from unittest.mock import patch
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))

from validate_macos_compatibility import deployment_target, deployment_versions, inspect_slices, is_macho, validate, version_parts


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

    def test_rejects_ios_and_catalyst_even_with_low_deployment_version(self) -> None:
        for platform in ["IOS", "IOSSIMULATOR", "MACCATALYST", "6", ""]:
            with self.subTest(platform=platform), self.assertRaisesRegex(ValueError, "not macOS"):
                deployment_target("Load command 1\n cmd LC_BUILD_VERSION\n platform " + platform + "\n minos 13.0\n")

    def test_requires_one_complete_target_in_each_slice(self) -> None:
        valid = "Load command 1\n cmd LC_BUILD_VERSION\n platform MACOS\n minos 14.0\n"
        self.assertEqual(deployment_target(valid), "14.0")
        self.assertEqual(deployment_target(valid.replace("MACOS", "1")), "14.0")
        self.assertEqual(deployment_target("Load command 1\n cmd LC_VERSION_MIN_MACOSX\n version 10.13\n"), "10.13")
        for output in ["", valid.replace(" minos 14.0\n", ""), valid + valid]:
            with self.subTest(output=output), self.assertRaises(ValueError):
                deployment_target(output)

    @patch("validate_macos_compatibility.subprocess.run")
    def test_probes_both_slices_and_rejects_unparseable_second_slice(self, run) -> None:
        run.side_effect = [subprocess.CompletedProcess([], 0, "arm64 x86_64\n", ""),
                           subprocess.CompletedProcess([], 0, "Load command 1\n cmd LC_BUILD_VERSION\n platform MACOS\n minos 14.0\n", ""),
                           subprocess.CompletedProcess([], 0, "", "")]
        with self.assertRaisesRegex(ValueError, "exactly one"):
            inspect_slices(Path("universal"))
        self.assertIn("x86_64", run.call_args_list[-1].args[0])

    @patch("validate_macos_compatibility.inspect_slices")
    def test_mixed_architecture_minimum_and_missing_architecture_fail(self, inspect) -> None:
        inspect.return_value = [{"architecture": "arm64", "platform": "macOS", "minimum_version": "14.0"},
                                {"architecture": "x86_64", "platform": "macOS", "minimum_version": "15.0"}]
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "binary").write_bytes(bytes.fromhex("cffaedfe"))
            report = validate(root, "14.0", {"arm64"})
            self.assertIn("exceeds", report["failures"][0]["errors"][0])
            inspect.return_value = inspect.return_value[:1]
            self.assertIn("x86_64", validate(root, "14.0", {"x86_64"})["failures"][0]["errors"][0])
            self.assertEqual(validate(root, "14.0", {"arm64"})["failures"], [])

    @patch("validate_macos_compatibility.inspect_slices", side_effect=ValueError("invalid platform"))
    def test_inspection_error_is_an_explicit_failed_record(self, inspect) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "binary").write_bytes(bytes.fromhex("cffaedfe"))
            report = validate(root, "14.0")
        self.assertEqual(report["macho_count"], 1)
        self.assertEqual(report["failures"][0]["errors"], ["invalid platform"])

    def test_java_class_magic_is_not_a_fat_macho(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "Fixture.class"
            path.write_bytes(bytes.fromhex("cafebabe0000003400010000"))
            self.assertFalse(is_macho(path))

    def test_versions_compare_numerically(self) -> None:
        self.assertLess(version_parts("14.10"), version_parts("15.0"))
        self.assertEqual(version_parts("14"), version_parts("14.0.0"))
        self.assertGreater(version_parts("26.0"), version_parts("15.3.1"))

    def test_rejects_invalid_versions(self) -> None:
        with self.assertRaisesRegex(ValueError, "invalid macOS version"):
            version_parts("14.beta")


if __name__ == "__main__":
    unittest.main()
