#!/usr/bin/env python3
"""Tests for relocatable package-local CPython validation."""

from __future__ import annotations

import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
from validate_cpython_runtime import inside, validate


def write_probe(executable: Path, payload: dict[str, object]) -> None:
    executable.parent.mkdir(parents=True)
    executable.write_text(
        "#!/bin/sh\n" + "printf '%s\\n' " + repr(json.dumps(payload)) + "\n",
        encoding="utf-8",
    )
    executable.chmod(0o755)


class CPythonRuntimeValidationTests(unittest.TestCase):
    def test_inside_requires_existing_path_below_runtime(self) -> None:
        with tempfile.TemporaryDirectory(prefix="netvplayer-python-runtime-") as temporary:
            root = Path(temporary)
            child = root / "lib/python"
            child.mkdir(parents=True)
            self.assertTrue(inside(child, root))
            self.assertFalse(inside(root.parent, root))

    def test_accepts_package_local_prefixes_and_sys_path(self) -> None:
        with tempfile.TemporaryDirectory(prefix="netvplayer-python-runtime-") as temporary:
            root = Path(temporary)
            executable = root / "bin/python3"
            library = root / "lib/python3.12"
            library.mkdir(parents=True)
            write_probe(executable, {
                "executable": str(executable),
                "prefix": str(root),
                "base_prefix": str(root),
                "path": [str(library)],
            })
            self.assertEqual(validate(root, executable), [])

    def test_accepts_missing_package_local_zip_path(self) -> None:
        with tempfile.TemporaryDirectory(prefix="netvplayer-python-runtime-") as temporary:
            root = Path(temporary)
            executable = root / "bin/python3"
            write_probe(executable, {
                "executable": str(executable),
                "prefix": str(root),
                "base_prefix": str(root),
                "path": [str(root / "lib/python312.zip")],
            })
            self.assertEqual(validate(root, executable), [])

    def test_rejects_prefix_and_sys_path_outside_runtime(self) -> None:
        with tempfile.TemporaryDirectory(prefix="netvplayer-python-runtime-") as temporary:
            root = Path(temporary)
            executable = root / "bin/python3"
            write_probe(executable, {
                "executable": str(executable),
                "prefix": "/opt/homebrew/python",
                "base_prefix": "/opt/homebrew/python",
                "path": ["/opt/homebrew/python/lib"],
            })
            errors = validate(root, executable)
            self.assertTrue(any("prefix escapes" in error for error in errors))
            self.assertTrue(any("sys.path escapes" in error for error in errors))


if __name__ == "__main__":
    unittest.main()
