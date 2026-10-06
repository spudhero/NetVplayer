from __future__ import annotations

import json
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
from audit_source_free_app import audit_build_inputs, audit_bundle, audit_output_directory


class SourceFreeAppAuditTests(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.app = Path(self.directory.name) / "NetVplayer.app"
        self.contents = self.app / "Contents"
        (self.contents / "MacOS").mkdir(parents=True)
        (self.contents / "Resources").mkdir()
        (self.contents / "MacOS/NetVplayerApp").write_bytes(b"public application binary")
        (self.contents / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleExecutable": "NetVplayerApp",
            "NetVplayerSourcePolicy": "user-configured-only",
        }))

    def test_accepts_empty_shell_resources(self) -> None:
        self.assertEqual(audit_bundle(self.app), [])

    def test_rejects_default_source_and_legacy_provider_in_binary(self) -> None:
        for payload in (b"http://fty.xxooo.cf/tv", b"https://cj.ffzyapi.com/api.php/provide/vod/", b"HmysNativeProvider"):
            with self.subTest(payload=payload):
                (self.contents / "MacOS/NetVplayerApp").write_bytes(payload)
                self.assertTrue(any("forbidden-binary-marker" in value for value in audit_bundle(self.app)))

    def test_rejects_bundled_source_lists_and_user_database(self) -> None:
        for name in ("channels.m3u", "configs.json", "history.json", "sources.sqlite"):
            with self.subTest(name=name):
                path = self.contents / "Resources" / name
                path.write_text("fixture")
                self.assertTrue(any("bundled-source-data" in value for value in audit_bundle(self.app)))
                path.unlink()

    def test_rejects_disguised_configuration_and_provider_payload(self) -> None:
        (self.contents / "Resources/theme.json").write_text(json.dumps({
            "sites": [{"api": "https://source.example.test"}],
        }))
        provider = self.contents / "Resources/Providers/example"
        provider.mkdir(parents=True)
        (provider / "provider.py").write_text("fixture")
        errors = audit_bundle(self.app)
        self.assertTrue(any("bundled-source-configuration" in value for value in errors))
        self.assertTrue(any("bundled-provider-payload" in value for value in errors))

    def test_rejects_bundle_without_public_build_policy(self) -> None:
        (self.contents / "Info.plist").write_bytes(plistlib.dumps({"CFBundleExecutable": "NetVplayerApp"}))
        self.assertIn("missing-source-free-build-policy", audit_bundle(self.app))

    def test_output_rejects_application_descendants_and_aliases(self) -> None:
        alias = Path(self.directory.name) / "alias"
        alias.symlink_to("/Applications", target_is_directory=True)
        for path in (
            Path("/Applications/NetVplayer.app/Contents/Resources"),
            Path("/Applications/../Applications/packages"),
            alias / "packages",
            Path(self.directory.name) / "Installed.app/Contents/Resources",
        ):
            with self.subTest(path=path):
                self.assertTrue(audit_output_directory(path))
        self.assertEqual(audit_output_directory(Path(self.directory.name) / "packages"), [])

    def test_build_rejects_dirty_untracked_and_ignored_source_inputs(self) -> None:
        repo = Path(self.directory.name) / "repo"
        sources = repo / "NetVplayer/Sources/App"
        sources.mkdir(parents=True)
        source = sources / "App.swift"
        source.write_text("// tracked source\n")
        (repo / ".gitignore").write_text("ignored.swift\n")

        def git(*args: str) -> None:
            subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True)

        git("init")
        git("add", "--", ".gitignore", "NetVplayer/Sources/App/App.swift")
        git("-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "fixture")
        self.assertEqual(audit_build_inputs(repo), [])
        for name in ("Extra.swift", "ignored.swift"):
            path = sources / name
            path.write_text("// unreviewed source\n")
            self.assertTrue(any("untracked-build-input" in value for value in audit_build_inputs(repo)))
            path.unlink()
        source.write_text("// changed tracked source\n")
        self.assertIn("public-build-requires-clean-tracked-files", audit_build_inputs(repo))


if __name__ == "__main__":
    unittest.main()
