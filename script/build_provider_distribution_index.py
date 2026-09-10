#!/usr/bin/env python3
"""Validate and Ed25519-sign the public Provider distribution index."""

from __future__ import annotations

import argparse
import base64
import binascii
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile
from urllib.parse import urlparse


IDENTIFIER = re.compile(r"^[A-Za-z0-9._-]+$")
VERSION = re.compile(r"^[0-9]+(?:\.[0-9]+)*(?:-[A-Za-z0-9.-]+)?$")
HEX = set("0123456789abcdefABCDEF")


def canonical_json(value: object) -> bytes:
    return json.dumps(
        value,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")


def valid_reference(value: object) -> bool:
    return (
        isinstance(value, dict)
        and isinstance(value.get("provider_id"), str)
        and bool(IDENTIFIER.fullmatch(value["provider_id"]))
        and isinstance(value.get("version"), str)
        and bool(VERSION.fullmatch(value["version"]))
    )


def validate_index(index: object) -> list[str]:
    errors: list[str] = []
    if not isinstance(index, dict):
        return ["distribution index must contain an object"]
    if index.get("protocol") != 2:
        errors.append("distribution index protocol must be 2")
    generated = index.get("generated_at")
    if not isinstance(generated, int) or isinstance(generated, bool):
        errors.append("generated_at must be an integer Date value emitted by Swift JSONEncoder")

    releases = index.get("releases")
    if not isinstance(releases, list):
        errors.append("releases must be an array")
        releases = []
    architecture_claims: dict[tuple[str, str], set[str]] = {}
    for position, release in enumerate(releases):
        prefix = f"releases[{position}]"
        if not isinstance(release, dict):
            errors.append(f"{prefix} must be an object")
            continue
        provider_id = release.get("provider_id")
        version = release.get("version")
        if not isinstance(provider_id, str) or not IDENTIFIER.fullmatch(provider_id):
            errors.append(f"{prefix}.provider_id is invalid")
        if not isinstance(version, str) or not VERSION.fullmatch(version):
            errors.append(f"{prefix}.version is invalid")
        if isinstance(provider_id, str) and isinstance(version, str):
            identity = (provider_id, version)
            declared = release.get("architectures")
            valid_items = isinstance(declared, list) and all(isinstance(value, str) for value in declared)
            values = set(declared) if valid_items else set()
            if not values or values - {"arm64", "x86_64", "universal2"}:
                errors.append(f"{prefix}.architectures is invalid")
            elif len(values) != len(declared):
                errors.append(f"{prefix}.architectures contains duplicates")
            elif "universal2" in values and len(values) != 1:
                errors.append(f"{prefix}.architectures mixes universal2 with explicit architectures")
            effective = {"arm64", "x86_64"} if "universal2" in values else values
            previous = architecture_claims.get(identity, set())
            overlap = sorted(previous & effective)
            if overlap:
                errors.append(
                    f"duplicate release architecture: {provider_id}@{version}: {', '.join(overlap)}"
                )
            architecture_claims[identity] = previous | effective
        parsed = urlparse(release.get("archive_url", ""))
        if parsed.scheme.lower() != "https" or not parsed.netloc:
            errors.append(f"{prefix}.archive_url must be an HTTPS URL")
        digest = release.get("archive_sha256")
        if not isinstance(digest, str) or len(digest) != 64 or set(digest) - HEX:
            errors.append(f"{prefix}.archive_sha256 must be a 64-character hex digest")

    revoked = index.get("revoked", [])
    if not isinstance(revoked, list):
        errors.append("revoked must be an array")
        revoked = []
    revoked_ids: set[tuple[str, str]] = set()
    for position, reference in enumerate(revoked):
        if not valid_reference(reference):
            errors.append(f"revoked[{position}] is invalid")
            continue
        identity = (reference["provider_id"], reference["version"])
        if identity in revoked_ids:
            errors.append(f"duplicate revoked release: {identity[0]}@{identity[1]}")
        revoked_ids.add(identity)
        if identity in architecture_claims:
            errors.append(f"release is both published and revoked: {identity[0]}@{identity[1]}")
    return errors


def sign(data: bytes, private_key: Path) -> bytes:
    with tempfile.TemporaryDirectory(prefix="netvplayer-index-sign-") as temporary:
        root = Path(temporary)
        payload = root / "index.json"
        signature = root / "signature.ed25519"
        payload.write_bytes(data)
        subprocess.run(
            [
                "openssl",
                "pkeyutl",
                "-sign",
                "-rawin",
                "-inkey",
                str(private_key.resolve(strict=True)),
                "-in",
                str(payload),
                "-out",
                str(signature),
            ],
            check=True,
            capture_output=True,
        )
        return signature.read_bytes()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--index", type=Path, required=True)
    parser.add_argument("--private-key", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    arguments = parser.parse_args()

    index = json.loads(arguments.index.read_text(encoding="utf-8"))
    errors = validate_index(index)
    if errors:
        for error in errors:
            print(error)
        return 1
    signature = sign(canonical_json(index), arguments.private_key)
    if len(signature) != 64:
        raise SystemExit("Ed25519 signature must be 64 bytes")
    document = {
        "index": index,
        "signature": base64.b64encode(signature).decode("ascii"),
    }
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    arguments.output.write_bytes(canonical_json(document) + b"\n")
    print(json.dumps({
        "ok": True,
        "output": str(arguments.output.resolve()),
        "index_sha256": hashlib.sha256(canonical_json(index)).hexdigest(),
        "release_count": len(index["releases"]),
    }, sort_keys=True))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, json.JSONDecodeError, binascii.Error) as error:
        raise SystemExit(f"provider distribution index: {error}")
