#!/usr/bin/env python3
"""Prepare the pinned QuickJS runtime used by the macOS compatibility probe."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile
from urllib.parse import urlparse
import zipfile

from prepare_provider_runtimes import fetch_artifact, sha256


ARCHITECTURE_ALIASES = {
    "arm64": "arm64",
    "aarch64": "arm64",
    "x86_64": "x86_64",
    "amd64": "x86_64",
}


def normalize_architecture(value: str) -> str:
    architecture = ARCHITECTURE_ALIASES.get(value.lower())
    if not architecture:
        raise RuntimeError(f"unsupported QuickJS runtime architecture: {value}")
    return architecture


def validate_lock(document: object) -> list[str]:
    if not isinstance(document, dict):
        return ["QuickJS runtime lock must be an object"]
    errors: list[str] = []
    if document.get("schema_version") != 1:
        errors.append("QuickJS runtime lock schema_version must be 1")
    if document.get("runtime") != "quickjs":
        errors.append("QuickJS runtime lock runtime must be quickjs")
    if not isinstance(document.get("version"), str) or not document["version"]:
        errors.append("QuickJS runtime lock version is required")
    artifacts = document.get("artifacts")
    if not isinstance(artifacts, dict) or set(artifacts) != {"arm64", "x86_64"}:
        return errors + ["QuickJS runtime lock must cover arm64 and x86_64 exactly"]
    for architecture, artifact in artifacts.items():
        prefix = f"quickjs.{architecture}"
        if not isinstance(artifact, dict):
            errors.append(f"{prefix}: artifact must be an object")
            continue
        filename = artifact.get("filename")
        if not isinstance(filename, str) or Path(filename).name != filename:
            errors.append(f"{prefix}: filename is unsafe")
        parsed = urlparse(str(artifact.get("url", "")))
        if parsed.scheme != "https" or not parsed.netloc:
            errors.append(f"{prefix}: URL must use HTTPS")
        digest = artifact.get("sha256")
        if not isinstance(digest, str) or len(digest) != 64 or any(c not in "0123456789abcdef" for c in digest):
            errors.append(f"{prefix}: sha256 is invalid")
        root = artifact.get("root")
        if not isinstance(root, str) or Path(root).is_absolute() or ".." in Path(root).parts:
            errors.append(f"{prefix}: root is unsafe")
    return errors


def quickjs_spec(lock_path: Path, architecture: str) -> tuple[dict[str, object], dict[str, str]]:
    document = json.loads(lock_path.read_text(encoding="utf-8"))
    errors = validate_lock(document)
    if errors:
        raise RuntimeError("; ".join(errors))
    architecture = normalize_architecture(architecture)
    return document, document["artifacts"][architecture]


def safe_extract(archive: Path, destination: Path) -> None:
    destination.mkdir(parents=True)
    root = destination.resolve()
    with zipfile.ZipFile(archive) as bundle:
        for member in bundle.infolist():
            candidate = (destination / member.filename).resolve()
            try:
                candidate.relative_to(root)
            except ValueError as error:
                raise RuntimeError(f"QuickJS archive path escapes extraction root: {member.filename}") from error
            bundle.extract(member, destination)


def build_runtime(source: Path, output: Path) -> Path:
    executable = source / "qjs"
    if not executable.is_file():
        raise RuntimeError(f"QuickJS archive does not contain qjs: {executable}")
    (output / "bin").mkdir(parents=True)
    polyglot = output / "bin/qjs-cosmo"
    shutil.copy2(executable, polyglot)
    polyglot.chmod(0o755)
    target = output / "bin/qjs"
    target.write_text(
        "#!/bin/sh\n"
        "set -eu\n"
        "runtime_dir=$(CDPATH= cd -- \"$(dirname -- \"$0\")\" && pwd)\n"
        "export TMPDIR=\"$runtime_dir\"\n"
        "exec /bin/sh \"$runtime_dir/qjs-cosmo\" \"$@\"\n",
        encoding="utf-8",
    )
    target.chmod(0o755)
    license_path = Path(__file__).resolve().parent.parent / "provider-runners/quickjs/LICENSE"
    shutil.copy2(license_path, output / "LICENSE")
    return target


def warm_runtime_bootstrap(executable: Path, output: Path) -> Path | None:
    """Prebuild Cosmopolitan's arm64 loader so App Sandbox never invokes cc."""
    with tempfile.TemporaryDirectory(prefix="netvplayer-quickjs-bootstrap-") as temporary:
        environment = os.environ.copy()
        environment["TMPDIR"] = temporary
        result = subprocess.run(
            ["/bin/sh", str(executable), "-e", "console.log('quickjs-bootstrap')"],
            check=False,
            capture_output=True,
            text=True,
            env=environment,
            timeout=60,
        )
        if result.returncode != 0:
            raise RuntimeError(f"QuickJS bootstrap probe failed: {result.stderr.strip()}")
        bootstrap = Path(temporary) / ".ape-1.10"
        if not bootstrap.is_file():
            return None
        target = output / "bin/.ape-1.10"
        shutil.copy2(bootstrap, target)
        target.chmod(0o755)
        return target


def validate_runtime(executable: Path, version: str, tmpdir: Path | None = None) -> None:
    probe = "console.log(JSON.stringify({engine:'QuickJS',version:'%s',es2025:typeof BigInt==='function'}))" % version
    environment = None
    if tmpdir is not None:
        environment = os.environ.copy()
        environment["TMPDIR"] = str(tmpdir)
    result = subprocess.run(
        ["/bin/sh", str(executable), "-e", probe],
        check=False,
        capture_output=True,
        text=True,
        env=environment,
        timeout=60,
    )
    if result.returncode != 0:
        raise RuntimeError(f"QuickJS probe failed: {result.stderr.strip()}")
    try:
        payload = json.loads(result.stdout.strip())
    except json.JSONDecodeError as error:
        raise RuntimeError(f"QuickJS probe returned invalid JSON: {result.stdout!r}") from error
    if payload != {"engine": "QuickJS", "version": version, "es2025": True}:
        raise RuntimeError(f"QuickJS probe mismatch: {payload!r}")


def prepare(lock_path: Path, cache: Path, output: Path, architecture: str) -> dict[str, object]:
    architecture = normalize_architecture(architecture)
    lock, artifact = quickjs_spec(lock_path, architecture)
    if output.exists():
        raise RuntimeError(f"output already exists: {output}")
    try:
        with tempfile.TemporaryDirectory(prefix="netvplayer-embedded-quickjs-") as temporary:
            archive = fetch_artifact(artifact, cache)
            extracted = Path(temporary) / "archive"
            safe_extract(archive, extracted)
            executable = build_runtime(extracted / artifact["root"], output)
            bootstrap = warm_runtime_bootstrap(output / "bin/qjs-cosmo", output)
            validate_runtime(executable, lock["required_version"], output / "bin")
        manifest: dict[str, object] = {
            "schema_version": 1,
            "runtime": "quickjs",
            "name": "QuickJS",
            "version": lock["version"],
            "architecture": architecture,
            "executable": "bin/qjs",
            "launcher": "/bin/sh",
            "bootstrap": "bin/.ape-1.10" if bootstrap is not None else None,
            "polyglot": "bin/qjs-cosmo",
            "source": artifact["url"],
            "artifact_sha256": artifact["sha256"],
            "lock_sha256": sha256(lock_path),
            "license": "MIT",
            "license_file": "LICENSE",
            "validation": "passed",
        }
        (output / "runtime-manifest.json").write_text(
            json.dumps(manifest, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        return manifest
    except Exception:
        if output.exists():
            shutil.rmtree(output)
        raise


def main() -> int:
    parser = argparse.ArgumentParser(description="Prepare NetVplayer's embedded QuickJS runtime")
    parser.add_argument("--lock", type=Path, default=Path("provider-runners/quickjs-runtime-lock-v1.json"))
    parser.add_argument("--cache", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--architecture", default=platform.machine())
    arguments = parser.parse_args()
    manifest = prepare(
        arguments.lock.resolve(strict=True),
        arguments.cache.resolve(),
        arguments.output.resolve(),
        arguments.architecture,
    )
    print(json.dumps(manifest, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
