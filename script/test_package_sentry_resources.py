import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("package_sentry_resources", Path(__file__).with_name("package_sentry_resources.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class SentryPackagingTests(unittest.TestCase):
    def test_packaging_embeds_resources_and_overrides_dsn_without_touching_source(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            package = root / "package"
            source = package / "Sources/NetVplayerApp/Info.plist"
            source.parent.mkdir(parents=True)
            source.write_bytes(plistlib.dumps({"NetVplayerSentryDSN": ""}))
            sdk = package / ".build/artifacts/sentry-apple-binaries/Sentry-Static/Sentry.xcframework"
            resources = sdk / "macos/Sentry.framework/Resources"
            resources.mkdir(parents=True)
            (sdk / "Info.plist").write_bytes(plistlib.dumps({"AvailableLibraries": [{
                "SupportedPlatform": "macos", "LibraryIdentifier": "macos", "LibraryPath": "Sentry.framework"
            }]}))
            manifest = plistlib.dumps({"NSPrivacyTracking": False})
            (resources / "PrivacyInfo.xcprivacy").write_bytes(manifest)
            license_path = package / ".build/checkouts/sentry-apple-binaries/LICENSE.md"
            license_path.parent.mkdir(parents=True)
            license_path.write_text("The MIT License (MIT)")
            app = root / "NetVplayer.app"
            (app / "Contents").mkdir(parents=True)
            info_path = app / "Contents/Info.plist"
            info_path.write_bytes(plistlib.dumps({"CFBundleVersion": "10"}))
            dsn = "https://abc@o1.ingest.us.sentry.io/123"
            result = module.package_resources(package, app, dsn)
            self.assertTrue(result["sentry_configured"])
            self.assertEqual(plistlib.loads(info_path.read_bytes())["NetVplayerSentryDSN"], dsn)
            self.assertEqual(plistlib.loads(source.read_bytes())["NetVplayerSentryDSN"], "")
            self.assertEqual((app / "Contents/Resources/Sentry.bundle/Contents/Resources/PrivacyInfo.xcprivacy").read_bytes(), manifest)
            self.assertTrue((app / "Contents/Resources/ThirdPartyLicenses/Sentry.LICENSE").is_file())

    def test_invalid_dsn_is_rejected(self):
        for value in ["http://abc@o1.ingest.us.sentry.io/123", "https://abc:secret@o1.ingest.us.sentry.io/123", "https://abc@example.com/123"]:
            with self.assertRaises(ValueError):
                module.validate_dsn(value)
        self.assertEqual(module.validate_dsn(""), "")


if __name__ == "__main__":
    unittest.main()
