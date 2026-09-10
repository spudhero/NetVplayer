#!/usr/bin/env python3
"""Tests for the private Provider release input gate."""

from __future__ import annotations

import base64
from copy import deepcopy
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
from validate_provider_release import canonical_json, runtime_errors, validate_catalog_record, verify_signature


class ProviderReleaseValidationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.catalog = [{
            "provider_id": "release.fixture",
            "runtime": "python",
            "compatibility": "compatible",
            "runner_verified": True,
            "parser_verified": True,
            "runtime_packaging": "poc-only",
            "network": "untested",
            "playback_verified": False,
            "distribution_ready": False,
            "source": "fixture",
            "license": "fixture-only",
            "reason": "fixture is not approved for distribution",
        }]

    def test_poc_catalog_record_is_rejected(self) -> None:
        errors = validate_catalog_record(self.catalog[0])
        self.assertTrue(any("distribution_ready" in error for error in errors))
        self.assertTrue(any("network" in error for error in errors))
        self.assertTrue(any("playback" in error for error in errors))

    def test_ready_catalog_record_passes(self) -> None:
        record = deepcopy(self.catalog[0])
        record.update({
            "runtime_packaging": "passed",
            "network": "usable",
            "playback_verified": True,
            "distribution_ready": True,
            "reason": "authorized release evidence",
        })
        self.assertEqual(validate_catalog_record(record), [])

    def test_user_configured_adapter_does_not_claim_a_site_or_playback(self) -> None:
        record = deepcopy(self.catalog[0])
        record.update({
            "compatibility": "compatible",
            "runtime_packaging": "passed",
            "network": "configuration",
            "source_policy": "user-configured-only",
            "distribution_ready": True,
            "reason": "address-free adapter release",
        })
        self.assertEqual(validate_catalog_record(record), [])

    def test_quickjs_runtime_probe_uses_polyglot_shell_invocation(self) -> None:
        with tempfile.TemporaryDirectory(prefix="netvplayer-quickjs-release-probe-") as temporary:
            root = Path(temporary) / "runtimes" / "quickjs"
            executable = root / "bin/qjs"
            executable.parent.mkdir(parents=True)
            executable.write_text(
                "#!/bin/sh\nprintf '%s\\n' '{\"engine\":\"QuickJS\",\"bigint\":true}'\n",
                encoding="utf-8",
            )
            executable.chmod(0o755)
            manifest = {
                "runtime": "quickjs",
                "runtime_executable": "runtimes/quickjs/bin/qjs",
            }
            self.assertEqual(
                runtime_errors(manifest, Path(temporary), {}, {"arm64"}),
                [],
            )

    def test_signature_verification_rejects_tampering(self) -> None:
        with tempfile.TemporaryDirectory(prefix="netvplayer-provider-release-") as temporary:
            root = Path(temporary)
            private_key = root / "private.pem"
            public_key = root / "public.pem"
            subprocess.run(["openssl", "genpkey", "-algorithm", "Ed25519", "-out", str(private_key)], check=True)
            subprocess.run(["openssl", "pkey", "-in", str(private_key), "-pubout", "-out", str(public_key)], check=True)
            manifest = {"provider_id": "release.fixture", "version": "1.0.0", "runtime": "java"}
            payload = root / "manifest.canonical.json"
            payload.write_bytes(canonical_json(manifest))
            signature = root / "signature.ed25519"
            subprocess.run(["openssl", "pkeyutl", "-sign", "-rawin", "-inkey", str(private_key), "-in", str(payload), "-out", str(signature)], check=True)
            (root / "manifest.json").write_bytes(canonical_json(manifest) + b"\n")
            (root / "signed-manifest.json").write_bytes(canonical_json({"manifest": manifest, "signature": base64.b64encode(signature.read_bytes()).decode("ascii")}) + b"\n")
            signature.write_bytes(signature.read_bytes()[:-1] + bytes([signature.read_bytes()[-1] ^ 1]))
            errors = verify_signature(root, public_key)
            self.assertTrue(any("does not match" in error for error in errors))


if __name__ == "__main__":
    unittest.main()
