from pathlib import Path
import plistlib
import tempfile
import unittest

from prune_torrent_prebuilds import prune


class TorrentPrebuildPackagingTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.app = Path(self.tmp.name) / "Staged.app"
        contents = self.app / "Contents"
        contents.mkdir(parents=True)
        with (contents / "Info.plist").open("wb") as stream:
            plistlib.dump({"CFBundleIdentifier": "com.netvplayer.app"}, stream)
        self.root = contents / "Resources/TorrentBridge/node_modules"
        self.root.mkdir(parents=True)

    def tearDown(self):
        self.tmp.cleanup()

    def package(self, name, targets):
        parent = self.root / name / "prebuilds"
        for target in targets:
            directory = parent / target
            directory.mkdir(parents=True)
            (directory / "native.node").write_bytes(target.encode())
        return parent

    def test_retains_target_bytes_and_licenses_only_prunes_other_platforms(self):
        parent = self.package("module", ["darwin-arm64", "darwin-x64", "ios-arm64", "linux-x64"])
        license_file = parent.parent / "LICENSE"
        license_file.write_text("fixture license")
        result = prune(self.app, "arm64")
        self.assertEqual((parent / "darwin-arm64/native.node").read_bytes(), b"darwin-arm64")
        self.assertEqual(license_file.read_text(), "fixture license")
        self.assertEqual(len(result["removed"]), 3)
        self.assertEqual([p.name for p in parent.iterdir()], ["darwin-arm64"])

    def test_missing_target_refuses_entire_plan_before_any_deletion(self):
        first = self.package("a-valid", ["darwin-arm64", "darwin-x64"])
        self.package("z-missing", ["linux-x64"])
        with self.assertRaisesRegex(ValueError, "Missing target"):
            prune(self.app, "arm64")
        self.assertTrue((first / "darwin-x64/native.node").exists())

    def test_linked_prebuild_cannot_delete_external_or_source_bytes(self):
        external = Path(self.tmp.name) / "npm-source"
        external.mkdir()
        (external / "marker").write_text("keep")
        package = self.root / "module"
        package.mkdir()
        (package / "prebuilds").symlink_to(external)
        with self.assertRaisesRegex(ValueError, "escapes"):
            prune(self.app, "arm64")
        self.assertEqual((external / "marker").read_text(), "keep")


if __name__ == "__main__":
    unittest.main()
