from __future__ import annotations

import json
from pathlib import Path
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
from android_presentation import ARCHIVE_NAME, RESOURCE_PATH, SOURCE_DIRECTORY, SOURCE_NAMES, validate_presentation
from audit_provider_public_release import build_release_report
from audit_source_free_app import audit_bundle
from test_audit_provider_public_release import git, public_fixture
import test_audit_source_free_app as app_fixture

ROOT = Path(__file__).resolve().parents[1]


def copy_presentation(repo: Path) -> Path:
    destination = repo / RESOURCE_PATH
    shutil.copytree(ROOT / RESOURCE_PATH, destination)
    for name in SOURCE_NAMES:
        source = repo / SOURCE_DIRECTORY / name
        source.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / SOURCE_DIRECTORY / name, source)
    return destination


class PresentationAuditTests(unittest.TestCase):
    def test_source_audit_accepts_only_the_reviewed_archive_and_public_sources(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            repo = public_fixture(Path(temporary))
            presentation = copy_presentation(repo)
            git(repo, "add", "--", ".")
            self.assertTrue(build_release_report(repo)["release_ready"])
            (presentation / "provider.jar").write_bytes(b"untrusted provider")
            git(repo, "add", "--", ".")
            report = build_release_report(repo)
            self.assertFalse(report["release_ready"])
            self.assertEqual(report["forbidden_binary_files"], [f"{RESOURCE_PATH}/provider.jar"])

    def test_changed_archive_and_updated_receipt_cannot_replace_the_pin(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            repo = Path(temporary)
            presentation = copy_presentation(repo)
            (presentation / ARCHIVE_NAME).write_bytes(b"different archive")
            import hashlib
            receipt = json.loads((presentation / "provenance.json").read_text())
            receipt["archiveSHA256"] = hashlib.sha256(b"different archive").hexdigest()
            (presentation / "provenance.json").write_text(json.dumps(receipt))
            self.assertEqual(validate_presentation(presentation, repo=repo), ["presentation-archive-digest"])

    def test_source_drift_missing_receipt_and_symlinks_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            repo = Path(temporary)
            presentation = copy_presentation(repo)
            source = repo / SOURCE_DIRECTORY / SOURCE_NAMES[0]
            original = source.read_bytes()
            source.write_bytes(original + b"\n// unreviewed source\n")
            self.assertEqual(validate_presentation(presentation, repo=repo), ["presentation-source-digest"])
            source.write_bytes(original)
            (presentation / "provenance.json").unlink()
            self.assertTrue(validate_presentation(presentation, repo=repo))
            (presentation / "provenance.json").symlink_to(ROOT / RESOURCE_PATH / "provenance.json")
            self.assertEqual(validate_presentation(presentation, repo=repo), ["presentation-symlink"])

    def test_bundle_audit_checks_real_swiftpm_layout_and_rejects_extra_or_relocated_jar(self) -> None:
        for prefix in ("Resources", "Resources/NetVplayer_NetVplayerApp.bundle/Contents/Resources"):
            with self.subTest(prefix=prefix), tempfile.TemporaryDirectory() as temporary:
                # Reuse the app fixture without collecting its unrelated test cases.
                fixture = app_fixture.SourceFreeAppAuditTests()
                fixture.setUp()
                try:
                    destination = fixture.contents / prefix / "AndroidPresentation"
                    shutil.copytree(ROOT / RESOURCE_PATH, destination)
                    self.assertEqual(audit_bundle(fixture.app), [])
                    (destination / "payload.jar").write_bytes(b"provider")
                    self.assertTrue(any("bundled-source-data" in e for e in audit_bundle(fixture.app)))
                    (destination / "payload.jar").unlink()
                    (destination / ARCHIVE_NAME).write_bytes(b"tampered")
                    self.assertIn("presentation-archive-digest", audit_bundle(fixture.app))
                    (destination / ARCHIVE_NAME).unlink()
                    relocated = fixture.contents / "Resources/other/AndroidPresentation"
                    shutil.copytree(ROOT / RESOURCE_PATH, relocated)
                    self.assertTrue(any("bundled-source-data" in e for e in audit_bundle(fixture.app)))
                finally:
                    fixture.doCleanups()


if __name__ == "__main__":
    unittest.main()
