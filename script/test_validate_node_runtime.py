#!/usr/bin/env python3
"""Tests for package-local Node runtime dependency validation."""

from __future__ import annotations

from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
from validate_node_runtime import dependency_error, parse_otool_dependencies, parse_otool_rpaths


class NodeRuntimeValidationTests(unittest.TestCase):
    def test_parses_dependencies_and_rpaths(self) -> None:
        dependencies = "/tmp/node:\n\t@rpath/libnode.dylib (compatibility version 0.0.0, current version 0.0.0)\n\t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1.0.0)\n"
        commands = "cmd LC_RPATH\ncmdsize 32\npath @loader_path/../lib (offset 12)\n"
        self.assertEqual(parse_otool_dependencies(dependencies), ["@rpath/libnode.dylib", "/usr/lib/libSystem.B.dylib"])
        self.assertEqual(parse_otool_rpaths(commands), ["@loader_path/../lib"])

    def test_allows_system_and_resolved_package_relative_dependencies(self) -> None:
        with tempfile.TemporaryDirectory(prefix="netvplayer-node-runtime-") as temporary:
            root = Path(temporary)
            executable = root / "bin/node"
            library = root / "lib/libnode.dylib"
            executable.parent.mkdir(parents=True)
            library.parent.mkdir(parents=True)
            executable.write_bytes(b"node")
            library.write_bytes(b"library")
            self.assertIsNone(dependency_error("/usr/lib/libSystem.B.dylib", executable, executable, root))
            self.assertIsNone(dependency_error(
                "@rpath/libnode.dylib",
                executable,
                executable,
                root,
                ["@loader_path/../lib"],
            ))

    def test_rejects_host_absolute_and_missing_relative_dependencies(self) -> None:
        with tempfile.TemporaryDirectory(prefix="netvplayer-node-runtime-") as temporary:
            root = Path(temporary)
            executable = root / "bin/node"
            executable.parent.mkdir(parents=True)
            executable.write_bytes(b"node")
            self.assertIn("host-only", dependency_error("/opt/homebrew/opt/libuv/lib/libuv.dylib", executable, executable, root) or "")
            self.assertIn("unresolved", dependency_error("@rpath/libnode.dylib", executable, executable, root) or "")

    def test_resolves_inherited_loader_chain_rpath_inside_runtime(self) -> None:
        with tempfile.TemporaryDirectory(prefix="netvplayer-node-runtime-") as temporary:
            root = Path(temporary)
            executable = root / "bin/node"
            binary = root / "lib/libjava.dylib"
            library = root / "lib/server/libjvm.dylib"
            executable.parent.mkdir(parents=True)
            binary.parent.mkdir(parents=True)
            library.parent.mkdir(parents=True)
            executable.write_bytes(b"node")
            binary.write_bytes(b"library")
            library.write_bytes(b"jvm")
            self.assertIsNone(dependency_error(
                "@rpath/libjvm.dylib",
                binary,
                executable,
                root,
                ["@loader_path/."],
                [library.parent],
            ))


if __name__ == "__main__":
    unittest.main()
