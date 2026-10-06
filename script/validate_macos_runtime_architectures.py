#!/usr/bin/env python3
"""Validate that a packaged macOS runtime contains every declared CPU slice."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from validate_node_runtime import is_macho, runtime_binaries


ARCHITECTURES = {"arm64", "x86_64"}


def normalize_architectures(values: set[str]) -> tuple[set[str], list[str]]:
    errors: list[str] = []
    unknown = sorted(values - ARCHITECTURES - {"universal2"})
    if unknown:
        errors.append(f"unsupported architecture declaration: {', '.join(unknown)}")
    if "universal2" in values and len(values) != 1:
        errors.append("universal2 cannot be combined with explicit architectures")
    normalized = set(ARCHITECTURES) if "universal2" in values else values & ARCHITECTURES
    if not normalized:
        errors.append("at least one macOS architecture is required")
    return normalized, errors


def macho_architectures(path: Path) -> tuple[set[str], str | None]:
    result = subprocess.run(
        ["/usr/bin/lipo", "-archs", str(path)],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        return set(), result.stderr.strip() or result.stdout.strip() or "lipo failed"
    return set(result.stdout.split()), None


def validate(
    root: Path,
    executable: Path,
    declared: set[str],
    required: set[str],
) -> list[str]:
    root = root.resolve(strict=True)
    executable = executable.resolve(strict=True)
    declared_normalized, errors = normalize_architectures(declared)
    required_normalized, required_errors = normalize_architectures(required)
    errors.extend(f"requested {error}" for error in required_errors)
    missing_declarations = sorted(required_normalized - declared_normalized)
    if missing_declarations:
        errors.append(f"manifest is missing architectures: {', '.join(missing_declarations)}")

    binaries = [path for path in runtime_binaries(root, executable) if is_macho(path)]
    if executable not in binaries:
        errors.append(f"runtime executable is not Mach-O: {executable}")
    for binary in binaries:
        actual, probe_error = macho_architectures(binary)
        relative = binary.relative_to(root)
        if probe_error:
            errors.append(f"could not inspect architecture for {relative}: {probe_error}")
            continue
        missing = sorted(declared_normalized - actual)
        if missing:
            errors.append(
                f"{relative} is missing declared architectures: {', '.join(missing)} "
                f"(actual: {', '.join(sorted(actual)) or 'none'})"
            )
    return errors


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("root", type=Path)
    parser.add_argument("--executable", type=Path, required=True)
    parser.add_argument("--declared", action="append", required=True)
    parser.add_argument("--required", action="append", required=True)
    arguments = parser.parse_args()
    errors = validate(
        arguments.root,
        arguments.executable,
        set(arguments.declared),
        set(arguments.required),
    )
    if errors:
        for error in errors:
            print(error)
        return 1
    print(json.dumps({
        "ok": True,
        "runtime": str(arguments.root.resolve()),
        "architectures": sorted(normalize_architectures(set(arguments.declared))[0]),
    }, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
