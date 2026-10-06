#!/usr/bin/env python3
"""Validate an assembled Provider package before signing or publication.

The Swift shell performs the authoritative signature and compatibility checks at
install time. This tool is the CI-side structural gate: it checks that the
signed package contains exactly the declared payload, that every digest and
metadata file agrees, and that no runtime-specific escape hatch was introduced.
"""

from __future__ import annotations

import argparse
import base64
import binascii
import hashlib
import json
from pathlib import Path
import stat
import tempfile
import zipfile

from validate_provider_sandbox import validate as validate_provider_sandbox


RESERVED = {"manifest.json", "signed-manifest.json", "signature.ed25519", "SHA256SUMS"}
RUNTIMES = {"java", "js", "quickjs", "python", "android-dex"}
ARCHITECTURES = {"arm64", "x86_64", "universal2"}
BLOCKED_STATUSES = {"blocked-license", "unsupported", "needs-port"}
HEX64 = set("0123456789abcdefABCDEF")
PROVIDER_LICENSE_PATH = "LICENSES/PROVIDER.txt"


def digest(path: Path) -> str:
    hasher = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            hasher.update(chunk)
    return hasher.hexdigest()


def safe_relative(value: object) -> str | None:
    if not isinstance(value, str) or not value or value.startswith(("/", "~")):
        return None
    path = Path(value)
    if path.is_absolute() or ".." in path.parts or "\\" in value or "\x00" in value:
        return None
    return path.as_posix()


def package_files(root: Path) -> set[str]:
    files: set[str] = set()
    for path in root.rglob("*"):
        if path.is_symlink():
            raise ValueError(f"symlink is not allowed: {path.relative_to(root)}")
        if path.is_file():
            files.add(path.relative_to(root).as_posix())
    return files


def validate_directory(root: Path) -> list[str]:
    errors: list[str] = []
    root = root.resolve(strict=True)
    try:
        manifest = json.loads((root / "manifest.json").read_text(encoding="utf-8"))
        signed = json.loads((root / "signed-manifest.json").read_text(encoding="utf-8"))
    except FileNotFoundError as error:
        return [f"missing metadata file: {error.filename}"]
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        return [f"invalid package metadata: {error}"]

    if not isinstance(manifest, dict):
        errors.append("manifest.json must contain an object")
        manifest = {}
    if not isinstance(signed, dict):
        errors.append("signed-manifest.json must contain an object")
        signed = {}
    if signed.get("manifest") != manifest:
        errors.append("signed-manifest.json manifest does not match manifest.json")
    if not isinstance(signed.get("signature"), str) or not signed.get("signature"):
        errors.append("signed-manifest.json must contain a Base64 signature")

    try:
        signature = base64.b64decode(signed.get("signature", ""), validate=True)
        if len(signature) != 64:
            errors.append("Ed25519 signature must decode to 64 bytes")
    except (binascii.Error, ValueError):
        errors.append("signed-manifest.json signature is not valid Base64")

    if (root / "signature.ed25519").exists() and signature:
        if (root / "signature.ed25519").read_bytes() != signature:
            errors.append("signature.ed25519 does not match signed-manifest.json")
    else:
        errors.append("signature.ed25519 is missing")

    runtime = manifest.get("runtime")
    if runtime not in RUNTIMES:
        errors.append(f"invalid runtime: {runtime}")
    if not isinstance(manifest.get("license"), str) or not manifest.get("license", "").strip():
        errors.append("manifest license must be a non-empty string")
    if manifest.get("status") in BLOCKED_STATUSES:
        errors.append(f"Provider status is not distributable: {manifest.get('status')}")
    if runtime == "android-dex" and manifest.get("status") == "compatible":
        errors.append("android-dex cannot be distributed as compatible")
    if runtime in {"java", "js", "quickjs", "python"} and not manifest.get("runtime_executable"):
        errors.append(f"{runtime} package must declare runtime_executable")
    architectures = manifest.get("architectures")
    if (
        not isinstance(architectures, list)
        or not architectures
        or not all(isinstance(value, str) and value in ARCHITECTURES for value in architectures)
        or len(set(architectures)) != len(architectures)
        or ("universal2" in architectures and len(architectures) != 1)
    ):
        errors.append("manifest architectures must be unique arm64/x86_64 values or universal2")

    assets = manifest.get("assets")
    if not isinstance(assets, list) or not assets:
        errors.append("manifest assets must be a non-empty array")
        assets = []
    paths: list[str] = []
    for index, asset in enumerate(assets):
        if not isinstance(asset, dict):
            errors.append(f"assets[{index}] must be an object")
            continue
        path = safe_relative(asset.get("path"))
        if path is None:
            errors.append(f"assets[{index}] has an unsafe path")
            continue
        if path in RESERVED:
            errors.append(f"asset path is reserved metadata: {path}")
        if path in paths:
            errors.append(f"duplicate asset path: {path}")
        paths.append(path)
        value = asset.get("sha256")
        if not isinstance(value, str) or len(value) != 64 or set(value) - HEX64:
            errors.append(f"{path}: sha256 must be a 64-character hex digest")
        if not isinstance(asset.get("executable", False), bool):
            errors.append(f"{path}: executable must be boolean")
        target = root / path
        if not target.is_file():
            errors.append(f"missing declared asset: {path}")
        elif isinstance(value, str) and len(value) == 64 and set(value) <= HEX64 and digest(target).lower() != value.lower():
            errors.append(f"hash mismatch: {path}")
        elif asset.get("executable") and not target.stat().st_mode & (stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH):
            errors.append(f"executable bit is missing: {path}")

    required = {manifest.get("entrypoint"), manifest.get("runner")}
    if manifest.get("runtime_executable"):
        required.add(manifest["runtime_executable"])
    required.add(PROVIDER_LICENSE_PATH)
    sandbox = manifest.get("sandbox")
    if sandbox is not None:
        if not isinstance(sandbox, dict):
            errors.append("manifest sandbox must be an object")
        else:
            required.add(sandbox.get("launcher"))
    for required_path in required:
        if not isinstance(required_path, str) or required_path not in paths:
            errors.append(f"required path is not declared as an asset: {required_path}")

    provider_license = root / PROVIDER_LICENSE_PATH
    if provider_license.is_file():
        try:
            if not provider_license.read_text(encoding="utf-8").strip():
                errors.append(f"{PROVIDER_LICENSE_PATH} must be non-empty UTF-8 text")
        except UnicodeDecodeError:
            errors.append(f"{PROVIDER_LICENSE_PATH} must be non-empty UTF-8 text")

    try:
        actual = package_files(root)
    except ValueError as error:
        actual = set()
        errors.append(str(error))
    undeclared = sorted(actual - RESERVED - set(paths))
    if undeclared:
        errors.append(f"undeclared package files: {', '.join(undeclared)}")
    missing_reserved = sorted(RESERVED - actual)
    errors.extend(f"missing metadata file: {path}" for path in missing_reserved)

    sums_path = root / "SHA256SUMS"
    if sums_path.is_file():
        parsed: dict[str, str] = {}
        for line_number, line in enumerate(sums_path.read_text(encoding="utf-8").splitlines(), 1):
            parts = line.split("  ", 1)
            if len(parts) != 2:
                errors.append(f"SHA256SUMS line {line_number} is malformed")
                continue
            value, path = parts
            if path in parsed:
                errors.append(f"SHA256SUMS has duplicate path: {path}")
            parsed[path] = value
        expected = {asset.get("path"): asset.get("sha256") for asset in assets if isinstance(asset, dict)}
        if parsed != expected:
            errors.append("SHA256SUMS does not exactly match manifest assets")

    if isinstance(sandbox, dict):
        errors.extend(validate_provider_sandbox(root, manifest))

    return errors


def extract_archive(archive: Path, destination: Path) -> None:
    with zipfile.ZipFile(archive) as handle:
        for info in handle.infolist():
            name = safe_relative(info.filename)
            if name is None or info.is_dir():
                if name is None:
                    raise ValueError(f"unsafe archive path: {info.filename}")
                continue
            mode = (info.external_attr >> 16) & 0o170000
            if mode == stat.S_IFLNK:
                raise ValueError(f"symlink is not allowed: {info.filename}")
            target = destination / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(handle.read(info))
            permissions = (info.external_attr >> 16) & 0o777
            if permissions:
                target.chmod(permissions)


def validate_package(path: Path) -> list[str]:
    if path.is_dir():
        return validate_directory(path)
    if path.suffix.lower() != ".zip":
        return ["package must be a directory or .zip archive"]
    with tempfile.TemporaryDirectory(prefix="netvplayer-package-validate-") as temporary:
        destination = Path(temporary)
        try:
            extract_archive(path.resolve(strict=True), destination)
        except (OSError, ValueError, zipfile.BadZipFile) as error:
            return [f"invalid package archive: {error}"]
        return validate_directory(destination)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("package", type=Path)
    arguments = parser.parse_args()
    errors = validate_package(arguments.package)
    if errors:
        for error in errors:
            print(error)
        return 1
    print(json.dumps({"ok": True, "package": str(arguments.package.resolve())}, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
