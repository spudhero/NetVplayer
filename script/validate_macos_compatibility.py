#!/usr/bin/env python3
"""Fail when a packaged Mach-O requires a newer macOS than advertised."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import subprocess


VERSION_PATTERN = re.compile(r"^\d+(?:\.\d+){0,2}$")


def version_parts(value: str) -> tuple[int, int, int]:
    if not VERSION_PATTERN.fullmatch(value):
        raise ValueError(f"invalid macOS version: {value}")
    parts = [int(part) for part in value.split(".")]
    return tuple((parts + [0, 0])[:3])


def deployment_versions(vtool_output: str) -> list[str]:
    versions: list[str] = []
    load_command = ""
    for line in vtool_output.splitlines():
        fields = line.split()
        if len(fields) == 2 and fields[0] == "cmd":
            load_command = fields[1]
            continue
        is_modern_target = len(fields) == 2 and fields[0] == "minos" and load_command == "LC_BUILD_VERSION"
        is_legacy_target = (
            len(fields) == 2
            and fields[0] == "version"
            and load_command == "LC_VERSION_MIN_MACOSX"
        )
        if is_modern_target or is_legacy_target:
            version_parts(fields[1])
            versions.append(fields[1])
    return versions


def is_macho(path: Path) -> bool:
    result = subprocess.run(
        ["/usr/bin/file", "-b", str(path)],
        check=False,
        capture_output=True,
        text=True,
    )
    return result.returncode == 0 and "Mach-O" in result.stdout


def inspect_macho(path: Path) -> list[str]:
    result = subprocess.run(
        ["/usr/bin/vtool", "-show-build", str(path)],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise ValueError(result.stderr.strip() or f"vtool failed for {path}")
    versions = deployment_versions(result.stdout)
    if not versions:
        raise ValueError(f"no macOS deployment target found: {path}")
    return versions


def validate(root: Path, maximum_version: str) -> dict[str, object]:
    root = root.resolve(strict=True)
    maximum = version_parts(maximum_version)
    paths = [root] if root.is_file() else sorted(path for path in root.rglob("*") if path.is_file())
    inspected: list[dict[str, object]] = []
    failures: list[dict[str, object]] = []
    for path in paths:
        if path.is_symlink() or not is_macho(path):
            continue
        versions = inspect_macho(path)
        relative = path.name if root.is_file() else path.relative_to(root).as_posix()
        record = {"path": relative, "deployment_targets": versions}
        inspected.append(record)
        if any(version_parts(version) > maximum for version in versions):
            failures.append(record)
    return {
        "root": str(root),
        "maximum_version": maximum_version,
        "macho_count": len(inspected),
        "failures": failures,
        "inspected": inspected,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--maximum-version", required=True)
    parser.add_argument("--require-mach-o", action="store_true")
    args = parser.parse_args()
    report = validate(args.root, args.maximum_version)
    print(json.dumps(report, sort_keys=True))
    if args.require_mach_o and report["macho_count"] == 0:
        return 2
    return 1 if report["failures"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
