#!/usr/bin/env python3
"""Build and Ed25519-sign a Provider ZIP from declared local assets."""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile
import zipfile

from build_provider_sandbox_launcher import RELEASE_PROFILES, build_bundle


ARCHITECTURES = {"arm64", "x86_64", "universal2"}
PROVIDER_LICENSE_PATH = "LICENSES/PROVIDER.txt"


def safe_path(root: Path, value: str) -> Path:
    relative = Path(value)
    if relative.is_absolute() or ".." in relative.parts or not relative.parts:
        raise ValueError(f"unsafe asset path: {value}")
    unresolved = root / relative
    if unresolved.is_symlink():
        raise ValueError(f"symlink assets are not allowed: {value}")
    candidate = unresolved.resolve(strict=True)
    candidate.relative_to(root.resolve(strict=True))
    return candidate


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def canonical_json(value: object) -> bytes:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")


def omit_nulls(value: object) -> object:
    if isinstance(value, dict):
        return {key: omit_nulls(item) for key, item in value.items() if item is not None}
    if isinstance(value, list):
        return [omit_nulls(item) for item in value]
    return value


def sign(data: bytes, private_key: Path, working: Path) -> bytes:
    payload = working / "manifest.canonical.json"
    signature = working / "signature.ed25519"
    payload.write_bytes(data)
    subprocess.run([
        "openssl", "pkeyutl", "-sign", "-rawin", "-inkey", str(private_key),
        "-in", str(payload), "-out", str(signature),
    ], check=True)
    return signature.read_bytes()


def zip_tree(root: Path, output: Path) -> None:
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for path in sorted(item for item in root.rglob("*") if item.is_file()):
            relative = path.relative_to(root).as_posix()
            info = zipfile.ZipInfo(relative, date_time=(2026, 1, 1, 0, 0, 0))
            mode = path.stat().st_mode & 0o777
            info.create_system = 3
            info.external_attr = (stat.S_IFREG | mode) << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(info, path.read_bytes())


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--license-file", type=Path, required=True)
    parser.add_argument("--private-key", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--sandbox-launcher", type=Path)
    parser.add_argument("--codesign-identity")
    parser.add_argument("--release-profile", choices=RELEASE_PROFILES)
    arguments = parser.parse_args()

    source = arguments.source.resolve(strict=True)
    if arguments.license_file.is_symlink():
        raise SystemExit("Provider license file must not be a symlink")
    license_file = arguments.license_file.resolve(strict=True)
    if not license_file.is_file() or not license_file.read_bytes().strip():
        raise SystemExit("Provider license file must be a non-empty regular file")
    manifest = omit_nulls(json.loads(arguments.manifest.read_text(encoding="utf-8")))
    # Swift's Codable manifest always encodes this non-optional default array.
    # Materialize it before signing so Python and the shell sign identical bytes.
    manifest.setdefault("host_capabilities", [])
    if not isinstance(manifest.get("license"), str) or not manifest["license"].strip():
        raise SystemExit("manifest license must be a non-empty string")
    if manifest.get("status") in {"blocked-license", "unsupported", "needs-port"}:
        raise SystemExit(f"refusing to distribute Provider with status {manifest.get('status')}")
    architectures = manifest.get("architectures")
    if (
        not isinstance(architectures, list)
        or not architectures
        or not all(isinstance(value, str) and value in ARCHITECTURES for value in architectures)
        or len(set(architectures)) != len(architectures)
        or ("universal2" in architectures and len(architectures) != 1)
    ):
        raise SystemExit("manifest architectures must be unique arm64/x86_64 values or universal2")
    assets = manifest.get("assets")
    if not isinstance(assets, list) or not assets:
        raise SystemExit("manifest assets must be a non-empty array")
    initially_declared = {item.get("path") for item in assets}
    if PROVIDER_LICENSE_PATH in initially_declared:
        raise SystemExit(f"{PROVIDER_LICENSE_PATH} is managed by --license-file")
    assets.append({"path": PROVIDER_LICENSE_PATH, "sha256": "", "executable": False})
    if arguments.sandbox_launcher and not arguments.codesign_identity:
        raise SystemExit("--sandbox-launcher requires --codesign-identity")
    if arguments.codesign_identity and not arguments.sandbox_launcher:
        raise SystemExit("--codesign-identity requires --sandbox-launcher")
    if arguments.sandbox_launcher and not arguments.release_profile:
        raise SystemExit("--sandbox-launcher requires --release-profile")
    if arguments.release_profile and not arguments.sandbox_launcher:
        raise SystemExit("--release-profile requires --sandbox-launcher")

    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="netvplayer-provider-package-") as value:
        working = Path(value)
        package = working / "package"
        package.mkdir()
        generated_assets: dict[str, Path] = {}
        if arguments.sandbox_launcher:
            sandbox_root = working / "generated" / "Sandbox" / "ProviderSandboxLauncher.app"
            manifest["sandbox"] = build_bundle(
                arguments.sandbox_launcher,
                sandbox_root,
                str(manifest.get("provider_id", "")),
                arguments.codesign_identity,
                arguments.release_profile,
            )
            generated_root = working / "generated"
            for path in sorted(item for item in sandbox_root.rglob("*") if item.is_file()):
                relative = path.relative_to(generated_root).as_posix()
                generated_assets[relative] = path
                assets.append({
                    "path": relative,
                    "sha256": "",
                    "executable": os.access(path, os.X_OK),
                })

        declared = {item.get("path") for item in assets}
        required = {manifest.get("entrypoint"), manifest.get("runner")}
        if manifest.get("runtime_executable"):
            required.add(manifest["runtime_executable"])
        sandbox = manifest.get("sandbox")
        if isinstance(sandbox, dict):
            required.add(sandbox.get("launcher"))
        if not required.issubset(declared):
            raise SystemExit("entrypoint, runner, runtime_executable, and sandbox launcher must be declared assets")

        sums: list[str] = []
        for asset in assets:
            relative = str(asset["path"])
            source_asset = generated_assets.get(relative)
            if source_asset is None:
                source_asset = license_file if relative == PROVIDER_LICENSE_PATH else safe_path(source, relative)
            if not source_asset.is_file():
                raise SystemExit(f"asset is not a file: {relative}")
            target = package / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source_asset, target)
            if asset.get("executable"):
                target.chmod(0o755)
            digest = sha256(target)
            asset["sha256"] = digest
            sums.append(f"{digest}  {relative}")

        signature = sign(canonical_json(manifest), arguments.private_key.resolve(strict=True), working)
        document = {"manifest": manifest, "signature": base64.b64encode(signature).decode("ascii")}
        (package / "manifest.json").write_bytes(canonical_json(manifest) + b"\n")
        (package / "signed-manifest.json").write_bytes(canonical_json(document) + b"\n")
        (package / "signature.ed25519").write_bytes(signature)
        (package / "SHA256SUMS").write_text("\n".join(sums) + "\n", encoding="utf-8")
        zip_tree(package, arguments.output)

    print(json.dumps({
        "archive": str(arguments.output.resolve()),
        "sha256": sha256(arguments.output),
        "provider_id": manifest.get("provider_id"),
        "version": manifest.get("version"),
        "sandbox": "app-sandbox-v2" if manifest.get("sandbox") else None,
        "release_profile": arguments.release_profile,
    }, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
