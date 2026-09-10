#!/usr/bin/env python3
"""Tests for the pinned dual-architecture runtime builder."""

from __future__ import annotations

from copy import deepcopy
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
from prepare_provider_runtimes import fetch_artifact, materialize_runtime_symlinks, prepare, validate_lock
from build_provider_sandbox_launcher import COMMUNITY_ADHOC_RELEASE_PROFILE, DEVELOPER_ID_RELEASE_PROFILE


class ProviderRuntimePreparationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.lock = json.loads(Path("provider-runners/runtime-lock-v1.json").read_text(encoding="utf-8"))

    def test_checked_in_lock_covers_both_architectures_with_pinned_hashes(self) -> None:
        self.assertEqual(validate_lock(self.lock), [])

    def test_rejects_incomplete_architecture_lock(self) -> None:
        lock = deepcopy(self.lock)
        del lock["runtimes"]["python"]["artifacts"]["x86_64"]
        self.assertTrue(any("python" in error for error in validate_lock(lock)))

    def test_release_runtime_build_requires_explicit_code_signing_identity(self) -> None:
        with tempfile.TemporaryDirectory(prefix="netvplayer-runtime-signing-") as temporary:
            root = Path(temporary)
            with self.assertRaisesRegex(RuntimeError, "code-signing identity is required"):
                prepare(
                    Path("provider-runners/runtime-lock-v1.json"),
                    root / "cache",
                    root / "output",
                    None,
                    COMMUNITY_ADHOC_RELEASE_PROFILE,
                )
            with self.assertRaisesRegex(RuntimeError, "developer-id requires"):
                prepare(
                    Path("provider-runners/runtime-lock-v1.json"),
                    root / "cache",
                    root / "output",
                    "-",
                    DEVELOPER_ID_RELEASE_PROFILE,
                )

    def test_cached_artifact_hash_mismatch_is_not_replaced(self) -> None:
        with tempfile.TemporaryDirectory(prefix="netvplayer-runtime-cache-") as temporary:
            cache = Path(temporary)
            artifact = deepcopy(self.lock["runtimes"]["js"]["artifacts"]["arm64"])
            target = cache / artifact["filename"]
            target.write_bytes(b"tampered")
            with self.assertRaisesRegex(RuntimeError, "hash mismatch"):
                fetch_artifact(artifact, cache)
            self.assertEqual(target.read_bytes(), b"tampered")

    def test_materialize_symlinks_rejects_escape(self) -> None:
        with tempfile.TemporaryDirectory(prefix="netvplayer-runtime-links-") as temporary:
            root = Path(temporary) / "runtime"
            root.mkdir()
            (root / "escape").symlink_to(Path(temporary).parent / "outside")
            with self.assertRaisesRegex(RuntimeError, "escapes package"):
                materialize_runtime_symlinks(root)


if __name__ == "__main__":
    unittest.main()
