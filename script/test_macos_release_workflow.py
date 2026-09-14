from __future__ import annotations

from pathlib import Path
import plistlib
import unittest


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/release-macos.yml"
INFO_PLIST = ROOT / "NetVplayer/Sources/NetVplayerApp/Info.plist"


class MacOSReleaseWorkflowTests(unittest.TestCase):
    def setUp(self) -> None:
        self.workflow = WORKFLOW.read_text(encoding="utf-8")

    def test_release_is_semver_tag_driven_and_can_publish(self) -> None:
        self.assertIn('tags:\n      - "[0-9]*.[0-9]*.[0-9]*"', self.workflow)
        self.assertIn("contents: write", self.workflow)
        self.assertIn('[[ ! "$release_version" =~ ^[0-9]+\\.[0-9]+\\.[0-9]+$ ]]', self.workflow)
        self.assertIn('git merge-base --is-ancestor "$GITHUB_SHA" origin/main', self.workflow)
        self.assertIn('[[ "$app_version" != "$release_version" ]]', self.workflow)
        self.assertIn("actions: read", self.workflow)
        self.assertIn("gh run list", self.workflow)
        self.assertIn("Provider public shell must pass", self.workflow)

    def test_release_builds_and_rechecks_the_extracted_public_app(self) -> None:
        required = (
            "build_and_run.sh --package-public",
            "/usr/bin/ditto -c -k --sequesterRsrc --keepParent",
            "unzip -t",
            "/usr/bin/ditto -x -k",
            "codesign --verify --deep --strict",
            "CFBundleShortVersionString",
            "/usr/bin/lipo -archs",
            "audit_source_free_app.py --repo . --app-bundle",
        )
        for fragment in required:
            self.assertIn(fragment, self.workflow)

    def test_release_publishes_the_complete_verified_asset_set(self) -> None:
        required = (
            "NetVplayer-${release_version}-macos-arm64.zip",
            "NetVplayer.build-artifacts.json",
            "NetVplayer.cdx.json",
            "NetVplayer.spdx.json",
            "SHA256SUMS.txt",
            "actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02",
            "gh release create",
            "gh release download",
            'cmp SHA256SUMS.txt "$existing_assets/SHA256SUMS.txt"',
            "--verify-tag",
            "--latest",
        )
        for fragment in required:
            self.assertIn(fragment, self.workflow)
        self.assertNotIn("--clobber", self.workflow)

    def test_application_version_matches_the_release_documentation(self) -> None:
        with INFO_PLIST.open("rb") as handle:
            info = plistlib.load(handle)
        readme = (ROOT / "README.md").read_text(encoding="utf-8")

        self.assertEqual(info["CFBundleShortVersionString"], "1.0.1")
        self.assertEqual(info["CFBundleVersion"], "2")
        self.assertIn("NetVplayer 1.0.1", readme)
        self.assertIn("current 1.0.1 release", readme)


if __name__ == "__main__":
    unittest.main()
