#!/usr/bin/env python3
"""A successful encoder exit must not promote an incorrectly tagged fixture."""
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("performance_fixtures", Path(__file__).with_name("generate_playback_performance_fixtures.py"))
fixtures = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixtures)


class PerformanceFixtureReuseTests(unittest.TestCase):
    def test_failed_or_missing_stream_validation_preserves_files_and_rejects_reuse(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            media = root / "pq-hevc-10bit-3840x2160-60-1920s.mp4"
            media.write_bytes(b"task fixture bytes")
            report = media.with_suffix(".mp4.json")
            for validation in [False, None]:
                data = {"exitCode": 0, "sha256": hashlib.sha256(media.read_bytes()).hexdigest()}
                if validation is not None: data["streamValidationPassed"] = validation
                report.write_text(json.dumps(data))
                original = report.read_bytes()
                with self.assertRaisesRegex(RuntimeError, "Prior failed/changed fixture preserved"):
                    fixtures.generate(root, "hevc", 10, "60", 1920, "3840x2160", "mp4", "pq")
                self.assertEqual(report.read_bytes(), original)
                self.assertEqual(media.read_bytes(), b"task fixture bytes")


if __name__ == "__main__":
    unittest.main()
