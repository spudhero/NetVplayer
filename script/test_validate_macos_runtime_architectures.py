#!/usr/bin/env python3
"""Tests for production runtime architecture declarations."""

from __future__ import annotations

from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
from validate_macos_runtime_architectures import normalize_architectures, validate


class MacOSRuntimeArchitectureValidationTests(unittest.TestCase):
    def test_normalizes_universal2_and_rejects_ambiguous_declaration(self) -> None:
        self.assertEqual(normalize_architectures({"universal2"}), ({"arm64", "x86_64"}, []))
        _, errors = normalize_architectures({"universal2", "arm64"})
        self.assertTrue(any("cannot be combined" in error for error in errors))

    @patch("validate_macos_runtime_architectures.is_macho", return_value=True)
    @patch("validate_macos_runtime_architectures.macho_architectures")
    def test_rejects_false_dual_architecture_claim(self, architectures, _is_macho) -> None:
        architectures.return_value = ({"arm64"}, None)
        with tempfile.TemporaryDirectory(prefix="netvplayer-runtime-architecture-") as temporary:
            root = Path(temporary)
            executable = root / "bin/runtime"
            executable.parent.mkdir(parents=True)
            executable.write_bytes(b"runtime")
            errors = validate(root, executable, {"arm64", "x86_64"}, {"arm64", "x86_64"})
        self.assertTrue(any("missing declared architectures: x86_64" in error for error in errors))

    @patch("validate_macos_runtime_architectures.is_macho", return_value=True)
    @patch("validate_macos_runtime_architectures.macho_architectures")
    def test_accepts_runtime_with_both_declared_slices(self, architectures, _is_macho) -> None:
        architectures.return_value = ({"arm64", "x86_64"}, None)
        with tempfile.TemporaryDirectory(prefix="netvplayer-runtime-architecture-") as temporary:
            root = Path(temporary)
            executable = root / "bin/runtime"
            executable.parent.mkdir(parents=True)
            executable.write_bytes(b"runtime")
            self.assertEqual(
                validate(root, executable, {"universal2"}, {"arm64", "x86_64"}),
                [],
            )


if __name__ == "__main__":
    unittest.main()
