from __future__ import annotations

import os
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from script.verify_packaged_app_startup import verify


class PackagedAppStartupTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.app = self.root / "extracted/NetVplayer.app"
        executable = self.app / "Contents/MacOS/NetVplayerApp"
        executable.parent.mkdir(parents=True)
        executable.touch()
        (self.app / "Contents/Resources/NetVplayer_NetVplayerApp.bundle").mkdir(parents=True)
        self.build = self.root / "release/NetVplayer_NetVplayerApp.bundle"
        self.build.mkdir(parents=True)
        (self.build / "original").write_bytes(b"preserve")
        self.output = self.root / "result"

    def launched(self, command, **kwargs):
        self.assertEqual(command[:4], ["/usr/bin/open", "-n", "-W", str(self.app)])
        self.assertFalse(self.build.exists())
        self.assertTrue((self.app / "Contents/Resources/NetVplayer_NetVplayerApp.bundle").is_dir())
        self.assertEqual(kwargs["timeout"], 90)
        return Path(command[command.index("--visual-regression-output") + 1])

    @patch.dict(os.environ, {"CI": "true"})
    def test_launches_extracted_app_without_build_fallback_and_restores_it(self):
        def launch(command, **kwargs):
            capture = self.launched(command, **kwargs)
            capture.write_bytes(b"\x89PNG\r\n\x1a\n" + struct.pack(">I", 13) + b"IHDR"
                                + struct.pack(">II", 1200, 675) + bytes(9))
        with patch("script.verify_packaged_app_startup.subprocess.run", side_effect=launch):
            receipt = verify(self.app, self.build, self.output)
        self.assertTrue(receipt["packaged_app_started"])
        self.assertEqual((self.build / "original").read_bytes(), b"preserve")
        self.assertTrue((self.output / "result.json").is_file())

    @patch.dict(os.environ, {"CI": "true"})
    def test_crash_timeout_or_missing_capture_fail_and_restore_original_resources(self):
        for failure in [subprocess.CalledProcessError(1, "open"),
                        subprocess.TimeoutExpired("open", 90), None]:
            with self.subTest(failure=type(failure).__name__):
                output = self.root / ("result-" + type(failure).__name__)
                def launch(command, **kwargs):
                    self.launched(command, **kwargs)
                    if failure:
                        raise failure
                with patch("script.verify_packaged_app_startup.subprocess.run", side_effect=launch):
                    with self.assertRaises((subprocess.CalledProcessError, subprocess.TimeoutExpired, FileNotFoundError)):
                        verify(self.app, self.build, output)
                self.assertEqual((self.build / "original").read_bytes(), b"preserve")
                self.assertFalse((output / "result.json").exists())

    @patch.dict(os.environ, {"CI": "false"})
    def test_refuses_to_move_a_developer_build_outside_isolated_ci(self):
        with patch("script.verify_packaged_app_startup.subprocess.run") as launch:
            with self.assertRaisesRegex(ValueError, "isolated CI"):
                verify(self.app, self.build, self.output)
            launch.assert_not_called()
        self.assertEqual((self.build / "original").read_bytes(), b"preserve")


if __name__ == "__main__":
    unittest.main()
