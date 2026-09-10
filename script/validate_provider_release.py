#!/usr/bin/env python3
"""Validate production Provider release inputs in private CI.

This gate is intentionally stricter than the public POC matrix. It refuses
catalog records without real network/player evidence, verifies package
signatures against the supplied release public key, checks the requested
architecture declaration, and probes the runtime selected by each package.
It does not create or publish a release.
"""

from __future__ import annotations

import argparse
import base64
import binascii
from contextlib import contextmanager
import json
from pathlib import Path
import subprocess
import tempfile
from typing import Iterator

import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from build_provider_sandbox_launcher import RELEASE_PROFILES
from validate_cpython_runtime import validate as validate_cpython_runtime
from validate_java_runtime import validate as validate_java_runtime
from validate_java_runtime import parse_java_properties
from validate_macos_runtime_architectures import normalize_architectures
from validate_macos_runtime_architectures import validate as validate_runtime_architectures
from validate_node_runtime import validate as validate_node_runtime
from validate_provider_package import extract_archive, validate_package
from validate_provider_sandbox import validate as validate_provider_sandbox


RUNTIMES = {"java", "js", "quickjs", "python"}


def canonical_json(value: object) -> bytes:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")


def validate_catalog_record(record: object) -> list[str]:
    if not isinstance(record, dict):
        return ["catalog record must be an object"]
    provider_id = record.get("provider_id", "<unknown>")
    errors: list[str] = []
    if record.get("runtime") not in RUNTIMES:
        errors.append(f"{provider_id}: runtime is not releasable")
    if record.get("compatibility") != "compatible":
        errors.append(f"{provider_id}: compatibility is not compatible")
    if not record.get("runner_verified"):
        errors.append(f"{provider_id}: runner evidence is missing")
    if not record.get("parser_verified"):
        errors.append(f"{provider_id}: parser evidence is missing")
    if record.get("runtime_packaging") != "passed":
        errors.append(f"{provider_id}: runtime packaging is not passed")
    if record.get("source_policy") in {"user-configured-only", "user-configured-catalog"}:
        if record.get("network") != "configuration":
            errors.append(f"{provider_id}: user-configured-only network status is not configuration")
    else:
        if record.get("network") != "usable":
            errors.append(f"{provider_id}: network evidence is not usable")
        if record.get("playback_verified") is not True:
            errors.append(f"{provider_id}: playback evidence is missing")
    if record.get("distribution_ready") is not True:
        errors.append(f"{provider_id}: distribution_ready is false")
    for field in ("source", "license", "reason"):
        if not isinstance(record.get(field), str) or not record[field].strip():
            errors.append(f"{provider_id}: {field} is missing")
    return errors


def verify_signature(package_root: Path, public_key: Path) -> list[str]:
    errors: list[str] = []
    try:
        manifest = json.loads((package_root / "manifest.json").read_text(encoding="utf-8"))
        signed = json.loads((package_root / "signed-manifest.json").read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        return [f"invalid signed manifest: {error}"]
    signature_path = package_root / "signature.ed25519"
    try:
        signature = signature_path.read_bytes()
    except OSError as error:
        return [f"signature.ed25519 is missing: {error}"]
    encoded = signed.get("signature") if isinstance(signed, dict) else None
    try:
        if not isinstance(encoded, str) or base64.b64decode(encoded, validate=True) != signature:
            errors.append("signed-manifest signature does not match signature.ed25519")
    except (ValueError, binascii.Error):
        errors.append("signed-manifest signature is invalid Base64")
    if not isinstance(signed, dict) or signed.get("manifest") != manifest:
        errors.append("signed-manifest manifest does not match manifest.json")
    if errors:
        return errors
    with tempfile.TemporaryDirectory(prefix="netvplayer-provider-signature-") as temporary:
        payload = Path(temporary) / "manifest.canonical.json"
        payload.write_bytes(canonical_json(manifest))
        result = subprocess.run(
            [
                "openssl", "pkeyutl", "-verify", "-rawin", "-pubin",
                "-inkey", str(public_key.resolve(strict=True)),
                "-in", str(payload), "-sigfile", str(signature_path),
            ],
            check=False,
            capture_output=True,
            text=True,
        )
    if result.returncode != 0:
        errors.append(f"Provider signature verification failed: {result.stderr.strip() or result.stdout.strip()}")
    return errors


@contextmanager
def package_root(path: Path) -> Iterator[Path]:
    resolved = path.resolve(strict=True)
    if resolved.is_dir():
        yield resolved
        return
    with tempfile.TemporaryDirectory(prefix="netvplayer-provider-release-") as temporary:
        destination = Path(temporary)
        extract_archive(resolved, destination)
        yield destination


def architecture_command(executable: Path, architecture: str, *arguments: str) -> list[str]:
    return ["/usr/bin/arch", f"-{architecture}", str(executable), *arguments]


def runtime_architecture_probe_errors(
    runtime: str,
    executable: Path,
    root: Path,
    architectures: set[str],
    versions: dict[str, str],
) -> list[str]:
    normalized, errors = normalize_architectures(architectures)
    for architecture in sorted(normalized):
        if runtime == "java":
            arguments = ("-XshowSettings:properties", "-version")
        elif runtime == "js":
            arguments = ("-p", "process.versions.node")
        elif runtime == "quickjs":
            arguments = ("-e", "console.log(JSON.stringify({engine:'QuickJS',bigint:typeof BigInt==='function'}))")
        else:
            arguments = ("-I", "-S", "-c", "import sys; print(f'{sys.version_info[0]}.{sys.version_info[1]}')")
        try:
            command = architecture_command(executable, architecture, *arguments)
            if runtime == "quickjs":
                command = ["/usr/bin/arch", f"-{architecture}", "/bin/sh", str(executable), *arguments]
            probe = subprocess.run(
                command,
                check=False,
                capture_output=True,
                text=True,
                env={"PATH": str(executable.parent)},
                timeout=60,
            )
        except (OSError, subprocess.TimeoutExpired) as error:
            errors.append(f"{runtime} {architecture} runtime probe could not execute: {error}")
            continue
        if probe.returncode != 0:
            errors.append(
                f"{runtime} {architecture} runtime probe failed: "
                f"{probe.stderr.strip() or probe.stdout.strip() or probe.returncode}"
            )
            continue
        if runtime == "java":
            properties = parse_java_properties(probe.stderr)
            java_home = properties.get("java.home")
            try:
                home_is_local = bool(java_home) and Path(java_home).resolve(strict=True).is_relative_to(root.resolve(strict=True))
            except (FileNotFoundError, ValueError):
                home_is_local = False
            if not home_is_local:
                errors.append(f"Java {architecture} java.home escapes runtime root: {java_home}")
            actual = properties.get("java.version", "")
            if actual.split(".", 1)[0] != versions["java"]:
                errors.append(f"Java {architecture} version mismatch: expected {versions['java']}, got {actual or 'unknown'}")
        elif runtime == "js":
            actual = probe.stdout.strip()
            if actual.split(".", 1)[0] != versions["js"].split(".", 1)[0]:
                errors.append(f"Node {architecture} version mismatch: expected major {versions['js'].split('.', 1)[0]}, got {actual}")
        elif runtime == "quickjs":
            try:
                payload = json.loads(probe.stdout.strip())
            except json.JSONDecodeError:
                payload = None
            if payload != {"engine": "QuickJS", "bigint": True}:
                errors.append(f"QuickJS {architecture} probe mismatch: {probe.stdout.strip() or probe.stderr.strip()}")
        else:
            actual = probe.stdout.strip()
            if actual != versions["python"]:
                errors.append(f"CPython {architecture} version mismatch: expected {versions['python']}, got {actual}")
    return errors


def runtime_errors(
    manifest: dict[str, object],
    root: Path,
    versions: dict[str, str],
    architectures: set[str],
) -> list[str]:
    runtime = manifest.get("runtime")
    executable_value = manifest.get("runtime_executable")
    if runtime not in RUNTIMES or not isinstance(executable_value, str):
        return ["manifest runtime and runtime_executable are required"]
    executable = root / executable_value
    runtime_root = executable.parent.parent
    if runtime == "java":
        errors = validate_java_runtime(runtime_root, executable, versions["java"])
        errors.extend(runtime_architecture_probe_errors(runtime, executable, runtime_root, architectures, versions))
        return errors
    if runtime == "js":
        errors = validate_node_runtime(runtime_root, executable)
        if not errors:
            probe = subprocess.run(
                [str(executable), "-p", "process.versions.node"],
                check=False,
                capture_output=True,
                text=True,
                env={"PATH": str(executable.parent)},
                timeout=60,
            )
            actual = probe.stdout.strip()
            expected_major = versions["js"].split(".", 1)[0]
            if probe.returncode != 0 or actual.split(".", 1)[0] != expected_major:
                errors.append(f"Node version mismatch: expected major {expected_major}, got {actual or probe.stderr.strip()}")
        errors.extend(runtime_architecture_probe_errors(runtime, executable, runtime_root, architectures, versions))
        return errors
    if runtime == "quickjs":
        probe = subprocess.run(
            ["/bin/sh", str(executable), "-e", "console.log(JSON.stringify({engine:'QuickJS',bigint:typeof BigInt==='function'}))"],
            check=False,
            capture_output=True,
            text=True,
            env={"PATH": str(executable.parent)},
            timeout=60,
        )
        try:
            payload = json.loads(probe.stdout.strip())
        except json.JSONDecodeError:
            payload = None
        if probe.returncode != 0 or payload != {"engine": "QuickJS", "bigint": True}:
            errors = [f"QuickJS probe mismatch: {probe.stdout.strip() or probe.stderr.strip() or probe.returncode}"]
        else:
            errors = []
        errors.extend(runtime_architecture_probe_errors(runtime, executable, runtime_root, architectures, versions))
        return errors
    errors = validate_cpython_runtime(runtime_root, executable)
    if not errors:
        probe = subprocess.run(
            [str(executable), "-I", "-S", "-c", "import sys; print(f'{sys.version_info[0]}.{sys.version_info[1]}')"],
            check=False,
            capture_output=True,
            text=True,
            env={"PATH": str(executable.parent)},
            timeout=60,
        )
        actual = probe.stdout.strip()
        if probe.returncode != 0 or actual != versions["python"]:
            errors.append(f"CPython version mismatch: expected {versions['python']}, got {actual or probe.stderr.strip()}")
    errors.extend(runtime_architecture_probe_errors(runtime, executable, runtime_root, architectures, versions))
    return errors


def validate_release_package(
    package: Path,
    record: dict[str, object],
    public_key: Path,
    versions: dict[str, str],
    release_profile: str,
) -> list[str]:
    errors = validate_package(package)
    if errors:
        return [f"{package}: {error}" for error in errors]
    with package_root(package) as root:
        try:
            manifest = json.loads((root / "manifest.json").read_text(encoding="utf-8"))
        except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
            return [f"{package}: invalid manifest: {error}"]
        provider_id = record["provider_id"]
        if manifest.get("provider_id") != provider_id:
            errors.append(f"{package}: provider_id does not match catalog record")
        if manifest.get("runtime") != record.get("runtime"):
            errors.append(f"{package}: runtime does not match catalog record")
        if manifest.get("status") != "compatible":
            errors.append(f"{package}: manifest status is not compatible")
        declared_value = manifest.get("architectures", [])
        valid_architecture_items = (
            isinstance(declared_value, list)
            and all(isinstance(value, str) for value in declared_value)
        )
        declared_architectures = set(declared_value) if valid_architecture_items else set()
        if not valid_architecture_items:
            errors.append(f"{package}: manifest architectures must be an array of strings")
        elif len(declared_architectures) != len(declared_value):
            errors.append(f"{package}: manifest architectures contains duplicates")
        effective_architectures, declaration_errors = normalize_architectures(declared_architectures)
        errors.extend(f"{package}: {error}" for error in declaration_errors)
        runtime_value = manifest.get("runtime_executable")
        if isinstance(runtime_value, str):
            executable = root / runtime_value
            runtime_root = executable.parent.parent
            errors.extend(
                f"{package}: {error}"
                for error in validate_runtime_architectures(
                    runtime_root,
                    executable,
                    declared_architectures,
                    effective_architectures,
                )
            )
        else:
            errors.append(f"{package}: manifest runtime_executable is required")
        errors.extend(
            f"{package}: {error}"
            for error in validate_provider_sandbox(
                root,
                manifest,
                expected_release_profile=release_profile,
            )
        )
        errors.extend(f"{package}: {error}" for error in verify_signature(root, public_key))
        errors.extend(
            f"{package}: {error}"
            for error in runtime_errors(manifest, root, versions, effective_architectures)
        )
    return errors


def validate_release(
    catalog_path: Path,
    packages: list[Path],
    public_key: Path,
    architectures: set[str],
    versions: dict[str, str],
    release_profile: str,
) -> list[str]:
    if release_profile not in RELEASE_PROFILES:
        return [f"unsupported Provider release profile: {release_profile}"]
    catalog = json.loads(catalog_path.read_text(encoding="utf-8"))
    if not isinstance(catalog, list):
        raise ValueError("catalog must be a JSON array")
    records = {record.get("provider_id"): record for record in catalog if isinstance(record, dict)}
    errors: list[str] = []
    coverage: dict[tuple[str, str], set[str]] = {}
    validated_records: set[str] = set()
    for package in packages:
        with package_root(package) as root:
            manifest = json.loads((root / "manifest.json").read_text(encoding="utf-8"))
        provider_id = manifest.get("provider_id")
        version = manifest.get("version")
        record = records.get(provider_id)
        if not isinstance(record, dict):
            errors.append(f"{package}: provider is absent from catalog: {provider_id}")
            continue
        declared_value = manifest.get("architectures", [])
        valid_architecture_items = (
            isinstance(declared_value, list)
            and all(isinstance(value, str) for value in declared_value)
        )
        declared = set(declared_value) if valid_architecture_items else set()
        effective, _ = normalize_architectures(declared)
        if isinstance(provider_id, str) and isinstance(version, str):
            identity = (provider_id, version)
            previous = coverage.get(identity, set())
            overlap = sorted(previous & effective)
            if overlap:
                errors.append(
                    f"{provider_id}@{version}: duplicate package architectures: {', '.join(overlap)}"
                )
            coverage[identity] = previous | effective
        if provider_id not in validated_records:
            errors.extend(validate_catalog_record(record))
            validated_records.add(provider_id)
        errors.extend(validate_release_package(
            package,
            record,
            public_key,
            versions,
            release_profile=release_profile,
        ))
    required, required_errors = normalize_architectures(architectures)
    errors.extend(f"requested {error}" for error in required_errors)
    for (provider_id, version), actual in sorted(coverage.items()):
        missing = sorted(required - actual)
        if missing:
            errors.append(
                f"{provider_id}@{version}: release set is missing architectures: {', '.join(missing)}"
            )
    return errors


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--catalog", type=Path, default=Path("docs/data/provider-runtime-catalog-v1.json"))
    parser.add_argument("--package", type=Path, action="append", required=True)
    parser.add_argument("--public-key", type=Path, required=True)
    parser.add_argument("--architecture", action="append", required=True)
    parser.add_argument("--java-version", default="21")
    parser.add_argument("--node-version", default="22.20.0")
    parser.add_argument("--python-version", default="3.12")
    parser.add_argument("--release-profile", required=True, choices=RELEASE_PROFILES)
    arguments = parser.parse_args()
    errors = validate_release(
        arguments.catalog.resolve(strict=True),
        [path.resolve(strict=True) for path in arguments.package],
        arguments.public_key.resolve(strict=True),
        set(arguments.architecture),
        {"java": arguments.java_version, "js": arguments.node_version, "python": arguments.python_version},
        arguments.release_profile,
    )
    if errors:
        for error in errors:
            print(error)
        return 1
    print(json.dumps({
        "ok": True,
        "packages": len(arguments.package),
        "architectures": arguments.architecture,
        "release_profile": arguments.release_profile,
    }, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
