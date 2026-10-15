from __future__ import annotations

from pathlib import Path
import plistlib
import unittest


ROOT = Path(__file__).resolve().parents[1]
RELEASE_TEMPLATE = ROOT / "script/templates/release-macos.yml"
WORKFLOW = RELEASE_TEMPLATE if RELEASE_TEMPLATE.is_file() else ROOT / ".github/workflows/release-macos.yml"
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

    def test_release_pins_xcode_with_icon_composer_support(self) -> None:
        self.assertIn("runs-on: macos-26", self.workflow)
        self.assertIn(
            "DEVELOPER_DIR: /Applications/Xcode_26.3.app/Contents/Developer",
            self.workflow,
        )

    def test_release_verifies_pinned_libmpv_on_the_oldest_supported_macos(self) -> None:
        required = (
            "libmpv-runtime:",
            "runs-on: macos-14",
            "gh release download 1.1.2 --repo spudhero/NetVplayer",
            "e03ebba79d6b396f837eca1f93462be69f99f0a3ef58d1f2d0b5ea1592d669fb",
            "shasum -a 256 --check",
            '"$runtime_only" "$RUNNER_TEMP/libmpv-runtime-macos14-arm64.zip"',
            "libmpv-runtime-macos14-arm64",
            "actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c",
            "NETVPLAYER_LIBMPV_RUNTIME_BUNDLE",
            "validate_macos_compatibility.py",
            "--maximum-version 14.0",
        )
        for fragment in required:
            self.assertIn(fragment, self.workflow)
        self.assertIn("needs: libmpv-runtime", self.workflow)
        self.assertNotIn("runs-on: macos-14-arm64", self.workflow)
        self.assertEqual(self.workflow.count("run: brew install mpv"), 1)
        self.assertNotIn("script/vendor_libmpv.sh", self.workflow)

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

    def test_tmdb_credential_is_verified_online_and_in_the_extracted_app(self) -> None:
        preflight = self.workflow.split(
            '- name: Validate TMDB application credential and online metadata', 1
        )[1].split('\n      - name:', 1)[0]
        package = self.workflow.split('- name: Build and verify release assets', 1)[1].split(
            '\n      - name:', 1
        )[0]
        for step in (preflight, package):
            for name in ('NETVPLAYER_TMDB_READ_ACCESS_TOKEN', 'NETVPLAYER_TMDB_API_KEY'):
                self.assertIn(name + ': ${{ secrets.' + name + ' }}', step)
        self.assertIn('--validate-only --require --verify-online', preflight)
        self.assertLess(self.workflow.index('TMDB application credential and online metadata'),
                        self.workflow.index('build_and_run.sh --package-public'))
        self.assertIn('--app-bundle "$extracted_app" --audit-only --require', package)
        self.assertLess(package.index('--audit-only --require'),
                        package.index('audit_source_free_app.py'))

    def test_debug_symbols_are_matched_and_uploaded_only_to_sentry(self) -> None:
        for fragment in [
            'xcrun dsymutil "$binary" -o "$symbols"',
            '"$binary_uuid" == "$symbols_uuid"',
            "secrets.SENTRY_AUTH_TOKEN",
            "debug-files upload --org spudhero --project apple-macos-e7",
            "2c26914636c47ab9bf9e710484ad7b44d371cbec8bd29cafb36b3cf877bf4285",
        ]:
            self.assertIn(fragment, self.workflow)
        release_assets = self.workflow.split("release_assets=(", 1)[1].split(")", 1)[0]
        self.assertNotIn("dSYM", release_assets)
        self.assertNotIn("--include-sources", self.workflow)
        self.assertNotIn("-debug-symbols", self.workflow)
        self.assertIn("--no-sources --wait", self.workflow)

    def test_release_publishes_the_complete_verified_asset_set(self) -> None:
        required = (
            "NetVplayer-${release_version}-macos-arm64.zip",
            "NetVplayer.build-artifacts.json",
            "NetVplayer.cdx.json",
            "NetVplayer.spdx.json",
            "SHA256SUMS.txt",
            "actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a",
            "gh release create",
            "gh release upload",
            '[[ "$release_state" == "empty-draft" ]]',
            '[[ "$draft_author" != "$GITHUB_REPOSITORY_OWNER" ]]',
            '--json author --jq \'.author.login\'',
            "gh release download",
            'cmp SHA256SUMS.txt "$existing_assets/SHA256SUMS.txt"',
            "--verify-tag",
            "--draft",
            '--notes-file "$GITHUB_WORKSPACE/RELEASE_NOTES_${release_version}.md"',
            "appcast.xml",
            "SPARKLE_ED25519_PRIVATE_KEY",
            "generate_appcast",
            "sign_update",
            "validate_app_update_feed.py",
            "validate_macos_release_version.py",
            "validate_app_update_key.swift",
        )
        for fragment in required:
            self.assertIn(fragment, self.workflow)
        self.assertNotIn("--clobber", self.workflow)
        self.assertNotIn("gh release edit", self.workflow)
        self.assertNotIn('releases/tags/$release_version', self.workflow)

    def test_application_version_matches_the_release_documentation(self) -> None:
        with INFO_PLIST.open("rb") as handle:
            info = plistlib.load(handle)
        readme = (ROOT / "README.md").read_text(encoding="utf-8")

        self.assertEqual(info["CFBundleShortVersionString"], "1.1.4")
        self.assertEqual(info["CFBundleVersion"], "18")
        self.assertIn("NetVplayer 1.1.4", readme)
        self.assertIn("**NetVplayer 1.1.4 (build 18)**", readme)
        self.assertIn("| Stable application | 1.1.4 |", readme)


if __name__ == "__main__":
    unittest.main()
