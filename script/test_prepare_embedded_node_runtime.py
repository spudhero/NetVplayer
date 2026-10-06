#!/usr/bin/env python3

from __future__ import annotations

import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
from prepare_embedded_node_runtime import node_spec, normalize_architecture, prepare


class EmbeddedNodeRuntimePreparationTests(unittest.TestCase):
    def test_checked_in_lock_selects_pinned_node_for_each_architecture(self) -> None:
        lock_path = Path("provider-runners/runtime-lock-v1.json")
        arm_record, arm_artifact = node_spec(lock_path, "arm64")
        intel_record, intel_artifact = node_spec(lock_path, "x86_64")

        self.assertEqual(arm_record["version"], "22.20.0")
        self.assertEqual(intel_record["version"], "22.20.0")
        self.assertIn("darwin-arm64", arm_artifact["filename"])
        self.assertIn("darwin-x64", intel_artifact["filename"])

    def test_architecture_aliases_are_normalized(self) -> None:
        self.assertEqual(normalize_architecture("aarch64"), "arm64")
        self.assertEqual(normalize_architecture("AMD64"), "x86_64")
        with self.assertRaisesRegex(RuntimeError, "unsupported"):
            normalize_architecture("powerpc")

    def test_prepare_writes_auditable_runtime_manifest(self) -> None:
        with tempfile.TemporaryDirectory(prefix="netvplayer-embedded-node-test-") as temporary:
            root = Path(temporary)
            lock = root / "runtime-lock.json"
            lock.write_text(Path("provider-runners/runtime-lock-v1.json").read_text(encoding="utf-8"), encoding="utf-8")
            output = root / "NodeRuntime"

            def fake_extract(_archive: Path, destination: Path) -> None:
                source = destination / "node-v22.20.0-darwin-arm64"
                (source / "bin").mkdir(parents=True)
                (source / "bin/node").write_bytes(b"node")
                (source / "LICENSE").write_text("MIT", encoding="utf-8")
                npm_cli = source / "lib/node_modules/npm/bin/npm-cli.js"
                npm_cli.parent.mkdir(parents=True)
                npm_cli.write_text("console.log('npm')", encoding="utf-8")

            def fake_build(source: Path, target: Path) -> Path:
                (target / "bin").mkdir(parents=True)
                executable = target / "bin/node"
                executable.write_bytes((source / "bin/node").read_bytes())
                executable.chmod(0o755)
                (target / "LICENSE").write_text("MIT", encoding="utf-8")
                return executable

            with patch("prepare_embedded_node_runtime.fetch_artifact", return_value=root / "node.tgz"), \
                 patch("prepare_embedded_node_runtime.safe_extract", side_effect=fake_extract), \
                 patch("prepare_embedded_node_runtime.build_node", side_effect=fake_build), \
                 patch("prepare_embedded_node_runtime.validate_runtime", return_value=[]):
                npm_output = root / "build-tools/npm"
                manifest = prepare(lock, root / "cache", output, "arm64", npm_output)

            stored = json.loads((output / "runtime-manifest.json").read_text(encoding="utf-8"))
            self.assertEqual(stored, manifest)
            self.assertEqual(stored["version"], "22.20.0")
            self.assertEqual(stored["architecture"], "arm64")
            self.assertEqual(stored["executable"], "bin/node")
            self.assertEqual(stored["validation"], "passed")
            self.assertTrue((output / "LICENSE").is_file())
            self.assertTrue((npm_output / "bin/npm-cli.js").is_file())
            self.assertFalse((output / "lib/node_modules/npm").exists())


if __name__ == "__main__":
    unittest.main()
