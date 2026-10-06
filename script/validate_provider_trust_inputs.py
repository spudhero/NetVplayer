#!/usr/bin/env python3
"""Validate code-signing-time Provider trust inputs without exposing secrets."""

from __future__ import annotations

import argparse
import base64
import binascii
import json
from urllib.parse import urlsplit


class TrustInputError(ValueError):
    pass


def decode_public_key(value: str, label: str) -> bytes:
    try:
        decoded = base64.b64decode(value, validate=True)
    except (binascii.Error, ValueError) as error:
        raise TrustInputError(f"{label} must be valid Base64") from error
    if len(decoded) != 32:
        raise TrustInputError(f"{label} must decode to 32 bytes")
    return decoded


def validate(manifest_key: str, distribution_key: str, index_url: str) -> dict[str, object]:
    values = {
        "manifest public key": manifest_key.strip(),
        "distribution public key": distribution_key.strip(),
        "distribution index URL": index_url.strip(),
    }
    configured = [label for label, value in values.items() if value]
    if not configured:
        return {"configured": False}
    missing = [label for label, value in values.items() if not value]
    if missing:
        raise TrustInputError("Provider trust inputs must be configured together; missing " + ", ".join(missing))
    decode_public_key(values["manifest public key"], "manifest public key")
    decode_public_key(values["distribution public key"], "distribution public key")
    parsed = urlsplit(values["distribution index URL"])
    if parsed.scheme != "https" or not parsed.hostname:
        raise TrustInputError("distribution index URL must be an absolute HTTPS URL")
    if parsed.username or parsed.password:
        raise TrustInputError("distribution index URL must not contain userinfo")
    if parsed.fragment:
        raise TrustInputError("distribution index URL must not contain a fragment")
    return {
        "configured": True,
        "manifest_key_bytes": 32,
        "distribution_key_bytes": 32,
        "index_scheme": "https",
        "index_host": parsed.hostname,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest-public-key", default="")
    parser.add_argument("--distribution-public-key", default="")
    parser.add_argument("--index-url", default="")
    arguments = parser.parse_args()
    print(json.dumps(validate(
        arguments.manifest_public_key,
        arguments.distribution_public_key,
        arguments.index_url,
    ), sort_keys=True))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except TrustInputError as error:
        print(f"Provider trust inputs: {error}", file=__import__("sys").stderr)
        raise SystemExit(1)
