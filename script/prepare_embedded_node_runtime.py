#!/usr/bin/env python3
"""Prepare the pinned Node runtime embedded in NetVplayer.app."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import platform
import shutil
import tempfile

from prepare_provider_runtimes import (
    build_node,
    fetch_artifact,
    safe_extract,
    sha256,
    validate_lock,
    validate_runtime,
)


ARCHITECTURE_ALIASES = {
    "arm64": "arm64",
    "aarch64": "arm64",
    "x86_64": "x86_64",
    "amd64": "x86_64",
}


def normalize_architecture(value: str) -> str:
    architecture = ARCHITECTURE_ALIASES.get(value.lower())
    if not architecture:
        raise RuntimeError(f"unsupported Node runtime architecture: {value}")
    return architecture


def node_spec(lock_path: Path, architecture: str) -> tuple[dict[str, object], dict[str, str]]:
    lock = json.loads(lock_path.read_text(encoding="utf-8"))
    errors = validate_lock(lock)
    if errors:
        raise RuntimeError("; ".join(errors))
    record = lock["runtimes"]["js"]
    artifact = record["artifacts"][architecture]
    return record, artifact


def prepare(
    lock_path: Path,
    cache: Path,
    output: Path,
    architecture: str,
    npm_output: Path | None = None,
) -> dict[str, object]:
    architecture = normalize_architecture(architecture)
    record, artifact = node_spec(lock_path, architecture)
    if output.exists():
        raise RuntimeError(f"output already exists: {output}")
    if npm_output and npm_output.exists():
        raise RuntimeError(f"npm output already exists: {npm_output}")

    try:
        with tempfile.TemporaryDirectory(prefix="netvplayer-embedded-node-") as temporary:
            archive = fetch_artifact(artifact, cache)
            extracted = Path(temporary) / "archive"
            safe_extract(archive, extracted)
            source = (extracted / artifact["root"]).resolve(strict=True)
            executable = build_node(source, output)
            if npm_output:
                npm_source = source / "lib/node_modules/npm"
                if not (npm_source / "bin/npm-cli.js").is_file():
                    raise RuntimeError(f"pinned Node archive does not contain npm: {npm_source}")
                shutil.copytree(npm_source, npm_output)
            validation_errors = validate_runtime(
                "js",
                output,
                executable,
                architecture,
                record["required_version"],
            )
            if validation_errors:
                raise RuntimeError("; ".join(validation_errors))

        manifest: dict[str, object] = {
            "schema_version": 1,
            "name": "Node.js",
            "version": record["version"],
            "architecture": architecture,
            "executable": "bin/node",
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
        if npm_output and npm_output.exists():
            shutil.rmtree(npm_output)
        raise


def main() -> int:
    parser = argparse.ArgumentParser(description="Prepare NetVplayer's embedded Node runtime")
    parser.add_argument("--lock", type=Path, default=Path("provider-runners/runtime-lock-v1.json"))
    parser.add_argument("--cache", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--npm-output", type=Path)
    parser.add_argument("--architecture", default=platform.machine())
    arguments = parser.parse_args()
    manifest = prepare(
        arguments.lock.resolve(strict=True),
        arguments.cache.resolve(),
        arguments.output.resolve(),
        arguments.architecture,
        arguments.npm_output.resolve() if arguments.npm_output else None,
    )
    print(json.dumps(manifest, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
