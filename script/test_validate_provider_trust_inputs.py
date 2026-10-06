from __future__ import annotations

import base64
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
from validate_provider_trust_inputs import TrustInputError, validate


KEY_A = base64.b64encode(bytes(range(32))).decode("ascii")
KEY_B = base64.b64encode(bytes(reversed(range(32)))).decode("ascii")


class ProviderTrustInputTests(unittest.TestCase):
    def test_unconfigured_build_remains_fail_closed(self) -> None:
        self.assertEqual(validate("", "", ""), {"configured": False})

    def test_complete_https_configuration_passes(self) -> None:
        result = validate(KEY_A, KEY_B, "https://providers.example.invalid/index.json")
        self.assertTrue(result["configured"])
        self.assertEqual(result["manifest_key_bytes"], 32)
        self.assertEqual(result["distribution_key_bytes"], 32)

    def test_partial_configuration_is_rejected(self) -> None:
        with self.assertRaisesRegex(TrustInputError, "configured together"):
            validate(KEY_A, "", "https://providers.example.invalid/index.json")

    def test_malformed_or_wrong_length_keys_are_rejected(self) -> None:
        with self.assertRaisesRegex(TrustInputError, "valid Base64"):
            validate("not-base64", KEY_B, "https://providers.example.invalid/index.json")
        short = base64.b64encode(b"short").decode("ascii")
        with self.assertRaisesRegex(TrustInputError, "32 bytes"):
            validate(short, KEY_B, "https://providers.example.invalid/index.json")

    def test_insecure_credentialed_or_fragmented_index_is_rejected(self) -> None:
        for url in (
            "http://providers.example.invalid/index.json",
            "https://user:pass@providers.example.invalid/index.json",
            "https://providers.example.invalid/index.json#latest",
        ):
            with self.subTest(url=url), self.assertRaises(TrustInputError):
                validate(KEY_A, KEY_B, url)


if __name__ == "__main__":
    unittest.main()
