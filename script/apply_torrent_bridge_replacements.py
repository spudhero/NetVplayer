#!/usr/bin/env python3
"""Apply reviewed local replacements to a freshly locked WebTorrent install."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import tempfile
from typing import Any


class TorrentReplacementError(RuntimeError):
    pass


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise TorrentReplacementError(f"invalid JSON document: {path}") from error
    if not isinstance(value, dict):
        raise TorrentReplacementError(f"JSON document must be an object: {path}")
    return value


def required_string(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise TorrentReplacementError(f"{label} must be a non-empty string")
    return value.strip()


def replacement_files(provenance: dict[str, Any]) -> dict[str, str]:
    replacement = provenance.get("replacement")
    if not isinstance(replacement, dict):
        raise TorrentReplacementError("replacement provenance is missing replacement")
    files = replacement.get("files")
    if not isinstance(files, dict) or not files:
        raise TorrentReplacementError("replacement provenance has no file hashes")
    checked: dict[str, str] = {}
    for raw_path, raw_digest in files.items():
        path = required_string(raw_path, "replacement file path")
        digest = required_string(raw_digest, f"replacement digest for {path}")
        relative = Path(path)
        if relative.is_absolute() or len(relative.parts) != 1 or path == "PROVENANCE.json":
            raise TorrentReplacementError(f"unsafe replacement file path: {path}")
        if len(digest) != 64 or any(character not in "0123456789abcdef" for character in digest):
            raise TorrentReplacementError(f"invalid replacement digest for {path}")
        checked[path] = digest
    return checked


def verify_payload(root: Path, provenance: dict[str, Any]) -> None:
    if root.is_symlink() or not root.is_dir():
        raise TorrentReplacementError(f"replacement payload is not a directory: {root}")
    files = replacement_files(provenance)
    expected = set(files) | {"PROVENANCE.json"}
    actual = {path.name for path in root.iterdir()}
    if actual != expected:
        raise TorrentReplacementError(
            f"replacement payload file set differs: expected {sorted(expected)}, got {sorted(actual)}"
        )
    for name, digest in files.items():
        path = root / name
        if path.is_symlink() or not path.is_file() or sha256(path) != digest:
            raise TorrentReplacementError(f"replacement payload hash mismatch: {name}")


def verify_lock(root: Path, provenance: dict[str, Any]) -> tuple[Path, dict[str, Any]]:
    if provenance.get("schema_version") != 1:
        raise TorrentReplacementError("unsupported replacement provenance schema")
    installed_path = required_string(provenance.get("installed_path"), "installed_path")
    relative = Path(installed_path)
    if relative.is_absolute() or len(relative.parts) != 2 or relative.parts[0] != "node_modules":
        raise TorrentReplacementError(f"unsafe replacement install path: {installed_path}")
    original = provenance.get("original")
    if not isinstance(original, dict):
        raise TorrentReplacementError("replacement provenance is missing original")
    lock = load_json(root / "package-lock.json")
    packages = lock.get("packages")
    locked = packages.get(installed_path) if isinstance(packages, dict) else None
    if not isinstance(locked, dict):
        raise TorrentReplacementError(f"lockfile does not contain {installed_path}")
    for key in ("version", "license", "integrity"):
        if locked.get(key) != original.get(key):
            raise TorrentReplacementError(f"locked {key} does not match replacement provenance")
    return root / relative, original


def package_identity(package: dict[str, Any]) -> tuple[str, str, str]:
    return (
        required_string(package.get("name"), "package name"),
        required_string(package.get("version"), "package version"),
        required_string(package.get("license"), "package license"),
    )


def apply_replacement(root: Path, replacement_root: Path) -> str:
    root = root.resolve(strict=True)
    replacement_root = replacement_root.resolve(strict=True)
    provenance = load_json(replacement_root / "PROVENANCE.json")
    verify_payload(replacement_root, provenance)
    package_root, original = verify_lock(root, provenance)
    replacement = provenance["replacement"]
    if package_root.is_symlink() or not package_root.is_dir():
        raise TorrentReplacementError(f"installed package is not a directory: {package_root}")
    package_json = package_root / "package.json"
    installed = load_json(package_json)
    identity = package_identity(installed)
    replacement_identity = package_identity(replacement)
    original_identity = package_identity(original)

    if identity == replacement_identity:
        verify_payload(package_root, provenance)
        if (package_root / "PROVENANCE.json").read_bytes() != (
            replacement_root / "PROVENANCE.json"
        ).read_bytes():
            raise TorrentReplacementError("installed replacement provenance drifted")
        return "already-applied"
    if identity != original_identity:
        raise TorrentReplacementError(f"unexpected installed package identity: {identity}")
    if sha256(package_json) != required_string(
        original.get("package_json_sha256"), "original package_json_sha256"
    ):
        raise TorrentReplacementError("original installed package metadata hash mismatch")

    modules_root = package_root.parent
    staging = Path(tempfile.mkdtemp(prefix=".netvplayer-replacement-", dir=modules_root))
    backup = modules_root / f".netvplayer-original-{package_root.name}"
    if backup.exists():
        shutil.rmtree(staging)
        raise TorrentReplacementError(f"stale replacement backup exists: {backup}")
    try:
        for source in replacement_root.iterdir():
            shutil.copy2(source, staging / source.name)
        verify_payload(staging, provenance)
        package_root.rename(backup)
        try:
            staging.rename(package_root)
        except Exception:
            backup.rename(package_root)
            raise
        shutil.rmtree(backup)
    except Exception:
        if staging.exists():
            shutil.rmtree(staging)
        raise
    return "applied"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--root",
        type=Path,
        default=Path("NetVplayer/Resources/TorrentBridge"),
    )
    parser.add_argument(
        "--replacement",
        type=Path,
        default=None,
    )
    arguments = parser.parse_args()
    replacement = arguments.replacement or (
        arguments.root / "replacements/compact-peer-address"
    )
    status = apply_replacement(arguments.root, replacement)
    print(json.dumps({"replacement": "compact2string", "status": status}, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
