from __future__ import annotations

import base64
from pathlib import Path
import tempfile
import unittest

from script.validate_app_update_feed import validate
from script.validate_macos_release_version import version_tuple


class AppUpdateReleaseTests(unittest.TestCase):
    def test_feed_must_name_the_exact_signed_archive(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive = root / "NetVplayer-1.0.9-macos-arm64.zip"
            archive.write_bytes(b"archive")
            feed = root / "appcast.xml"
            signature = base64.b64encode(b"x" * 64).decode("ascii")
            feed.write_text(
                '<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">'
                '<channel><item><sparkle:version>10</sparkle:version>'
                '<sparkle:shortVersionString>1.0.9</sparkle:shortVersionString>'
                '<sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>'
                '<enclosure url="https://github.com/spudhero/NetVplayer/releases/download/'
                '1.0.9/NetVplayer-1.0.9-macos-arm64.zip" length="7" '
                f'sparkle:edSignature="{signature}" /></item></channel></rss>',
                encoding="utf-8",
            )
            self.assertEqual(validate(feed, archive, "1.0.9", "spudhero/NetVplayer"), signature)

            feed.write_text(feed.read_text().replace('length="7"', 'length="8"'))
            with self.assertRaisesRegex(ValueError, "length"):
                validate(feed, archive, "1.0.9", "spudhero/NetVplayer")

    def test_release_version_comparison_is_numeric(self) -> None:
        self.assertGreater(version_tuple("1.0.10"), version_tuple("1.0.9"))
        with self.assertRaisesRegex(ValueError, "invalid"):
            version_tuple("1.0.9-beta")


if __name__ == "__main__":
    unittest.main()
