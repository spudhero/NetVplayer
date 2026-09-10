from __future__ import annotations

from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
from audit_provider_public_boundary import (
    BoundaryAuditError,
    build_report,
    content_digest,
    is_private_provider_source,
    is_private_provider_staging_file,
    serialized,
    validate_report,
)


ROOT = Path(__file__).resolve().parents[1]


class ProviderPublicBoundaryAuditTests(unittest.TestCase):
    def test_checked_in_report_matches_repository_and_history(self) -> None:
        report = build_report(ROOT)
        expected = (ROOT / "docs/data/provider-public-boundary-v1.json").read_text(encoding="utf-8")

        self.assertEqual(validate_report(report), [])
        self.assertEqual(serialized(report), expected)
        self.assertEqual(report["summary"]["mixed_boundary_source_files"], 0)
        self.assertNotIn(
            "NetVplayer/Sources/SpiderEngine/NativeProviders.swift",
            report["groups"]["private_provider_sources"]["paths"],
        )
        self.assertEqual(report["summary"]["legacy_executable_loader_files"], 0)
        self.assertEqual(report["groups"]["legacy_executable_loaders"]["paths"], [])
        self.assertNotIn(
            "NetVplayer/Sources/SpiderEngine/SpiderReplacementRegistry.swift",
            report["groups"]["mixed_boundary_sources"]["paths"],
        )
        if report["summary"]["release_ready"]:
            blocker_counts = (
                "tracked_fongmi_files",
                "fongmi_history_commits",
                "android_binary_files",
                "private_provider_source_files",
                "private_provider_staging_files",
                "mixed_boundary_source_files",
                "legacy_executable_loader_files",
            )
            self.assertTrue(all(report["summary"][key] == 0 for key in blocker_counts))
            self.assertEqual(report["blocking_reasons"], [])
        else:
            self.assertEqual(report["summary"]["tracked_fongmi_files"], 0)
            self.assertGreater(report["summary"]["fongmi_history_commits"], 0)
            self.assertNotIn("tracked-fongmi-reference", report["blocking_reasons"])
            self.assertIn("fongmi-present-in-git-history", report["blocking_reasons"])
            self.assertGreater(report["summary"]["private_provider_source_files"], 0)
            self.assertGreater(report["summary"]["private_provider_staging_files"], 0)
            self.assertIn(
                "NetVplayer/Sources/SpiderEngine/LegacyNativeProviderRegistration.swift",
                report["groups"]["private_provider_sources"]["paths"],
            )
            self.assertIn(
                "NetVplayer/Sources/SpiderEngine/BiliNativeProvider.swift",
                report["groups"]["private_provider_sources"]["paths"],
            )
            self.assertIn(
                "private-providers/bili-java/src/main/java/com/netvplayer/privateprovider/bili/BiliProvider.java",
                report["groups"]["private_provider_staging"]["paths"],
            )

    def test_private_provider_detection_excludes_public_remote_adapter(self) -> None:
        self.assertTrue(is_private_provider_source("NetVplayer/Sources/SpiderEngine/ExampleNativeProvider.swift"))
        self.assertFalse(is_private_provider_source("NetVplayer/Sources/SpiderEngine/RemoteSiteContentProvider.swift"))
        self.assertFalse(is_private_provider_source("NetVplayer/Sources/ProviderRuntime/ProviderManager.swift"))

    def test_private_provider_staging_detection_is_prefix_scoped(self) -> None:
        self.assertTrue(is_private_provider_staging_file("private-providers/bili-java/BiliProvider.java"))
        self.assertFalse(is_private_provider_staging_file("provider-runners/java/ProviderRunner.java"))

    def test_release_ready_must_match_blockers(self) -> None:
        report = build_report(ROOT)
        report["summary"]["release_ready"] = not report["summary"]["release_ready"]

        errors = validate_report(report)

        self.assertTrue(any("release_ready" in error for error in errors))

    def test_content_digest_rejects_symlink(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            external = root.parent / "provider-boundary-external.swift"
            external.write_text("struct Example {}\n", encoding="utf-8")
            link = root / "ExampleNativeProvider.swift"
            link.symlink_to(external)
            try:
                with self.assertRaisesRegex(BoundaryAuditError, "cannot be a symlink"):
                    content_digest(root, [link.name])
            finally:
                external.unlink(missing_ok=True)


if __name__ == "__main__":
    unittest.main()
