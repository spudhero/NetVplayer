from __future__ import annotations

import json
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
EVIDENCE = ROOT / "docs/data/bili-quickjs-provider-verification-2026-08-25.json"
RUNTIME_LOCK = ROOT / "provider-runners/quickjs-runtime-lock-v1.json"


class BiliQuickJSVerificationEvidenceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.evidence = json.loads(EVIDENCE.read_text(encoding="utf-8"))
        cls.runtime_lock = json.loads(RUNTIME_LOCK.read_text(encoding="utf-8"))

    def test_runtime_package_runner_parser_and_network_layers_are_explicit(self) -> None:
        evidence = self.evidence
        self.assertEqual(evidence["provider_id"], "migration.bili.quickjs")
        self.assertEqual(evidence["runtime"]["name"], "quickjs")
        self.assertEqual(evidence["runtime"]["version"], self.runtime_lock["required_version"])
        self.assertEqual(evidence["runner"], {"handshake": "passed", "lifecycle": "passed"})
        self.assertEqual(evidence["network"]["status"], "usable")
        self.assertEqual(evidence["network"]["http_bridge"], "host_request")
        self.assertEqual(evidence["network"]["swift_http_host"], "passed")
        self.assertTrue(evidence["parser"]["passed"])
        self.assertEqual(
            evidence["parser"]["operations"],
            ["home", "category", "search", "detail", "player", "destroy"],
        )
        self.assertTrue(all(value == "passed" for value in evidence["package"].values()))

    def test_media_probe_and_credential_boundary_are_recorded_without_urls(self) -> None:
        evidence = self.evidence
        self.assertEqual(evidence["credential_mode"], "public-unauthenticated-only")
        self.assertEqual(evidence["media_probe"]["status"], "passed")
        self.assertEqual(evidence["media_probe"]["range"], "bytes=0-1023")
        self.assertGreaterEqual(evidence["media_probe"]["bytes_read_minimum"], 1)
        self.assertEqual(evidence["media_probe"]["accepted_http_statuses"], [200, 206])
        serialized = json.dumps(evidence, ensure_ascii=False)
        self.assertNotIn("http://", serialized)
        self.assertNotIn("https://", serialized)
        self.assertNotIn("Cookie", serialized)
        self.assertFalse(evidence["sensitive_values_persisted"])


if __name__ == "__main__":
    unittest.main()
