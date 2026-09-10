#!/usr/bin/env python3

from __future__ import annotations

import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
from prepare_embedded_quickjs_runtime import normalize_architecture, prepare, quickjs_spec, validate_lock


class EmbeddedQuickJSRuntimePreparationTests(unittest.TestCase):
    def test_checked_in_lock_is_architecture_complete(self) -> None:
        lock_path = Path("provider-runners/quickjs-runtime-lock-v1.json")
        document = json.loads(lock_path.read_text(encoding="utf-8"))
        self.assertEqual(validate_lock(document), [])
        _, arm = quickjs_spec(lock_path, "arm64")
        _, intel = quickjs_spec(lock_path, "AMD64")
        self.assertEqual(arm["sha256"], intel["sha256"])
        self.assertEqual(normalize_architecture("aarch64"), "arm64")

    def test_rejects_unsupported_architecture(self) -> None:
        with self.assertRaisesRegex(RuntimeError, "unsupported"):
            normalize_architecture("powerpc")

    def test_prepare_copies_qjs_and_records_shell_launcher(self) -> None:
        with tempfile.TemporaryDirectory(prefix="netvplayer-embedded-quickjs-test-") as temporary:
            root = Path(temporary)
            lock = root / "lock.json"
            lock.write_text(Path("provider-runners/quickjs-runtime-lock-v1.json").read_text(encoding="utf-8"), encoding="utf-8")
            output = root / "QuickJSRuntime"

            def fake_extract(_archive: Path, destination: Path) -> None:
                destination.mkdir(parents=True)
                (destination / "qjs").write_bytes(b"MZqFpD='\n")

            with patch("prepare_embedded_quickjs_runtime.fetch_artifact", return_value=root / "qjs.zip"), \
                 patch("prepare_embedded_quickjs_runtime.safe_extract", side_effect=fake_extract), \
                 patch("prepare_embedded_quickjs_runtime.subprocess.run") as run:
                run.return_value.returncode = 0
                run.return_value.stdout = '{"engine":"QuickJS","version":"2026-06-04","es2025":true}\n'
                run.return_value.stderr = ""
                manifest = prepare(lock, root / "cache", output, "arm64")

            self.assertEqual(manifest["launcher"], "/bin/sh")
            self.assertEqual(manifest["polyglot"], "bin/qjs-cosmo")
            self.assertEqual(manifest["validation"], "passed")
            self.assertTrue((output / "bin/qjs").is_file())
            self.assertTrue((output / "bin/qjs-cosmo").is_file())
            self.assertTrue((output / "LICENSE").is_file())
            self.assertTrue((output / "runtime-manifest.json").is_file())
            self.assertEqual(run.call_args.args[0][:2], ["/bin/sh", str(output / "bin/qjs")])


if __name__ == "__main__":
    unittest.main()
