#!/usr/bin/env python3
from __future__ import annotations

import json
from pathlib import Path
import plistlib
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))

from build_provider_sandbox_launcher import (
    COMMUNITY_ADHOC_RELEASE_PROFILE,
    DEVELOPER_ID_RELEASE_PROFILE,
    build_bundle,
    signature_scope_errors,
)
from validate_provider_sandbox import validate


class ProviderSandboxValidationTests(unittest.TestCase):
    def build_fixture(self, root: Path, provider_id: str = "fixture.sandbox") -> dict[str, object]:
        launcher = root / "launcher"
        shutil.copyfile("/usr/bin/true", launcher)
        launcher.chmod(0o755)
        bundle = root / "Sandbox" / "ProviderSandboxLauncher.app"
        sandbox = build_bundle(
            launcher,
            bundle,
            provider_id,
            "-",
            COMMUNITY_ADHOC_RELEASE_PROFILE,
        )
        return {"provider_id": provider_id, "sandbox": sandbox}

    def test_accepts_community_adhoc_entitlements_but_not_developer_id_profile(self) -> None:
        with tempfile.TemporaryDirectory(prefix="netvplayer-sandbox-validation-") as temporary:
            root = Path(temporary)
            manifest = self.build_fixture(root)
            self.assertEqual(validate(root, manifest, COMMUNITY_ADHOC_RELEASE_PROFILE), [])
            errors = validate(root, manifest, DEVELOPER_ID_RELEASE_PROFILE)
            self.assertTrue(any("release_profile mismatch" in error for error in errors))
            manifest["sandbox"]["profile_version"] = 1
            errors = validate(root, manifest, COMMUNITY_ADHOC_RELEASE_PROFILE)
            self.assertTrue(any("profile_version must be 2" in error for error in errors))

    def test_builder_rejects_identity_that_does_not_match_release_profile(self) -> None:
        with tempfile.TemporaryDirectory(prefix="netvplayer-sandbox-profile-") as temporary:
            root = Path(temporary)
            launcher = root / "launcher"
            shutil.copyfile("/usr/bin/true", launcher)
            with self.assertRaisesRegex(ValueError, "developer-id requires"):
                build_bundle(
                    launcher,
                    root / "developer.app",
                    "fixture.sandbox",
                    "-",
                    DEVELOPER_ID_RELEASE_PROFILE,
                )
            with self.assertRaisesRegex(ValueError, "community-adhoc requires"):
                build_bundle(
                    launcher,
                    root / "community.app",
                    "fixture.sandbox",
                    "Developer ID Application: Example Team",
                    COMMUNITY_ADHOC_RELEASE_PROFILE,
                )
            self.assertEqual(
                signature_scope_errors(
                    "Signature=Developer ID\n"
                    "Authority=Developer ID Application: Example Team\n"
                    "TeamIdentifier=EXAMPLETEAM",
                    DEVELOPER_ID_RELEASE_PROFILE,
                ),
                [],
            )
            self.assertTrue(signature_scope_errors(
                "Signature=Apple Development\n"
                "Authority=Apple Development: Example\n"
                "TeamIdentifier=EXAMPLETEAM",
                DEVELOPER_ID_RELEASE_PROFILE,
            ))

    def test_rejects_bundle_identifier_mismatch(self) -> None:
        with tempfile.TemporaryDirectory(prefix="netvplayer-sandbox-identifier-") as temporary:
            root = Path(temporary)
            manifest = self.build_fixture(root)
            manifest["sandbox"]["bundle_id"] = "com.netvplayer.provider.wrong"
            errors = validate(root, manifest)
            self.assertTrue(any("bundle_id" in error for error in errors))

    def test_rejects_resigned_broad_file_entitlement(self) -> None:
        with tempfile.TemporaryDirectory(prefix="netvplayer-sandbox-entitlement-") as temporary:
            root = Path(temporary)
            manifest = self.build_fixture(root)
            bundle = root / "Sandbox" / "ProviderSandboxLauncher.app"
            entitlement_file = root / "broad.plist"
            with entitlement_file.open("wb") as handle:
                plistlib.dump({
                    "com.apple.security.app-sandbox": True,
                    "com.apple.security.network.client": True,
                    "com.apple.security.files.user-selected.read-write": True,
                }, handle)
            import subprocess

            subprocess.run(
                [
                    "/usr/bin/codesign", "--force", "--sign", "-",
                    "--entitlements", str(entitlement_file), str(bundle),
                ],
                check=True,
                capture_output=True,
            )
            errors = validate(root, manifest)
            self.assertTrue(any("unexpected entitlements" in error for error in errors))

    def test_rejects_launcher_path_escape(self) -> None:
        with tempfile.TemporaryDirectory(prefix="netvplayer-sandbox-path-") as temporary:
            parent = Path(temporary)
            root = parent / "package"
            root.mkdir()
            outside = parent / "outside"
            outside.mkdir()
            manifest = self.build_fixture(outside)
            manifest["sandbox"]["launcher"] = (
                "../../outside/Sandbox/ProviderSandboxLauncher.app/Contents/MacOS/"
                "ProviderSandboxLauncher"
            )
            errors = validate(root, manifest)
            self.assertTrue(any("Contents/MacOS" in error for error in errors))


if __name__ == "__main__":
    unittest.main()
