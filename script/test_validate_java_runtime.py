#!/usr/bin/env python3
"""Tests for package-local Java runtime validation."""

from __future__ import annotations

from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
from validate_java_runtime import parse_java_properties, validate


class JavaRuntimeValidationTests(unittest.TestCase):
    def test_parses_java_properties(self) -> None:
        values = parse_java_properties("Property settings:\n    java.home = /runtime\n    java.version = 21.0.8\n")
        self.assertEqual(values["java.home"], "/runtime")
        self.assertEqual(values["java.version"], "21.0.8")

    def test_accepts_package_local_probe_and_rejects_wrong_major(self) -> None:
        with tempfile.TemporaryDirectory(prefix="netvplayer-java-runtime-") as temporary:
            root = Path(temporary)
            executable = root / "bin/java"
            executable.parent.mkdir(parents=True)
            executable.write_text(
                "#!/bin/sh\n"
                f"echo '    java.home = {root}' >&2\n"
                "echo '    java.version = 21.0.8' >&2\n",
                encoding="utf-8",
            )
            executable.chmod(0o755)
            self.assertEqual(validate(root, executable, "21"), [])
            self.assertTrue(any("version mismatch" in error for error in validate(root, executable, "17")))

    def test_rejects_java_home_outside_runtime(self) -> None:
        with tempfile.TemporaryDirectory(prefix="netvplayer-java-runtime-") as temporary:
            root = Path(temporary)
            executable = root / "bin/java"
            executable.parent.mkdir(parents=True)
            executable.write_text(
                "#!/bin/sh\n"
                "echo '    java.home = /Library/Java/HostJDK' >&2\n"
                "echo '    java.version = 21.0.8' >&2\n",
                encoding="utf-8",
            )
            executable.chmod(0o755)
            self.assertTrue(any("java.home escapes" in error for error in validate(root, executable, "21")))


if __name__ == "__main__":
    unittest.main()
