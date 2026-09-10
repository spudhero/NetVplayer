#!/usr/bin/env python3
"""Tests for the signed Provider distribution index gate."""

from __future__ import annotations

import base64
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import build_provider_distribution_index as builder


ROOT = Path(__file__).resolve().parents[1]


def valid_index() -> dict[str, object]:
    return {
        "protocol": 2,
        "generated_at": 0,
        "releases": [{
            "provider_id": "fixture.python",
            "version": "1.0.0",
            "architectures": ["arm64"],
            "archive_url": "https://providers.example.test/fixture-python-1.0.0.zip",
            "archive_sha256": "a" * 64,
        }],
        "revoked": [],
    }


class ProviderDistributionIndexTests(unittest.TestCase):
    def test_valid_index_is_signed_as_shell_document(self) -> None:
        with tempfile.TemporaryDirectory(prefix="netvplayer-index-test-") as temporary:
            root = Path(temporary)
            private_key = root / "private.pem"
            public_key = root / "public.pem"
            source = root / "index.json"
            output = root / "signed-index.json"
            source.write_text(json.dumps(valid_index()), encoding="utf-8")
            subprocess.run(["openssl", "genpkey", "-algorithm", "ED25519", "-out", str(private_key)], check=True, capture_output=True)
            subprocess.run(["openssl", "pkey", "-in", str(private_key), "-pubout", "-out", str(public_key)], check=True, capture_output=True)

            result = subprocess.run([
                "python3",
                str(ROOT / "script/build_provider_distribution_index.py"),
                "--index", str(source),
                "--private-key", str(private_key),
                "--output", str(output),
            ], cwd=ROOT, text=True, capture_output=True, check=False)
            self.assertEqual(result.returncode, 0, result.stderr)
            document = json.loads(output.read_text(encoding="utf-8"))
            self.assertEqual(document["index"], valid_index())
            signature = base64.b64decode(document["signature"], validate=True)
            self.assertEqual(len(signature), 64)
            canonical = builder.canonical_json(document["index"])
            payload = root / "canonical-index.json"
            signature_file = root / "signature.ed25519"
            payload.write_bytes(canonical)
            signature_file.write_bytes(signature)
            verified = subprocess.run([
                "openssl", "pkeyutl", "-verify", "-rawin", "-pubin",
                "-inkey", str(public_key), "-in", str(payload), "-sigfile", str(signature_file),
            ], capture_output=True, text=True, check=False)
            self.assertEqual(verified.returncode, 0, verified.stderr)

    def test_accepts_disjoint_architecture_variants(self) -> None:
        index = valid_index()
        index["releases"].append(dict(
            index["releases"][0],
            architectures=["x86_64"],
            archive_url="https://providers.example.test/fixture-python-1.0.0-x86_64.zip",
        ))
        self.assertEqual(builder.validate_index(index), [])

    def test_rejects_non_https_overlapping_and_revoked_releases(self) -> None:
        index = valid_index()
        index["releases"] = [index["releases"][0], dict(index["releases"][0], archive_url="http://providers.example.test/other.zip")]
        index["revoked"] = [{"provider_id": "fixture.python", "version": "1.0.0"}]
        errors = builder.validate_index(index)
        self.assertTrue(any("HTTPS" in error for error in errors))
        self.assertTrue(any("duplicate release architecture" in error for error in errors))
        self.assertTrue(any("both published and revoked" in error for error in errors))

    def test_rejects_duplicate_and_non_string_architectures(self) -> None:
        duplicate = valid_index()
        duplicate["releases"][0]["architectures"] = ["arm64", "arm64"]
        self.assertTrue(any("duplicates" in error for error in builder.validate_index(duplicate)))

        malformed = valid_index()
        malformed["releases"][0]["architectures"] = ["arm64", {"unexpected": True}]
        self.assertTrue(any("architectures is invalid" in error for error in builder.validate_index(malformed)))


if __name__ == "__main__":
    unittest.main()
