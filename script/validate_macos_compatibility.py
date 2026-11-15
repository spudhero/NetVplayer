#!/usr/bin/env python3
"""Fail when a packaged Mach-O requires a newer macOS than advertised."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import subprocess

from validate_node_runtime import is_macho as has_macho_magic


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
    if not has_macho_magic(path):
        return False
    # Java classes share the big-endian fat Mach-O magic. Ask file only for
    # that ambiguous header; most resources need no subprocess at all.
    with path.open("rb") as handle:
        if handle.read(4) != b"\xca\xfe\xba\xbe":
            return True
    result = subprocess.run(["/usr/bin/file", "-b", str(path)],
                            check=False, capture_output=True, text=True)
    return result.returncode == 0 and "Mach-O" in result.stdout


def deployment_target(vtool_output: str) -> str:
    """Require exactly one macOS deployment command for one CPU slice."""
    commands = re.split(r"(?m)^Load command \d+\s*$", vtool_output)
    targets: list[str] = []
    for command in commands:
        match = re.search(r"(?m)^\s*cmd (LC_\w+)\s*$", command)
        if not match:
            continue
        name = match.group(1)
        if name == "LC_BUILD_VERSION":
            platform = re.search(r"(?m)^\s*platform (\S+)\s*$", command)
            if not platform or platform.group(1) not in {"MACOS", "1"}:
                raise ValueError("deployment platform is not macOS")
            value = re.search(r"(?m)^\s*minos (\S+)\s*$", command)
        elif name == "LC_VERSION_MIN_MACOSX":
            value = re.search(r"(?m)^\s*version (\S+)\s*$", command)
        elif name.startswith("LC_VERSION_MIN_"):
            raise ValueError("deployment platform is not macOS")
        else:
            continue
        if not value:
            raise ValueError("missing macOS deployment version")
        version_parts(value.group(1))
        targets.append(value.group(1))
    if len(targets) != 1:
        raise ValueError("expected exactly one macOS deployment target per slice")
    return targets[0]


def inspect_slices(path: Path) -> list[dict[str, str]]:
    architectures = subprocess.run(
        ["/usr/bin/lipo", "-archs", str(path)],
        check=False, capture_output=True, text=True,
    )
    if architectures.returncode or not architectures.stdout.split():
        raise ValueError(architectures.stderr.strip() or "cannot inspect Mach-O architectures")
    slices: list[dict[str, str]] = []
    for architecture in architectures.stdout.split():
        result = subprocess.run(
            ["/usr/bin/vtool", "-arch", architecture, "-show-build", str(path)],
            check=False, capture_output=True, text=True,
        )
        if result.returncode:
            raise ValueError(result.stderr.strip() or "vtool failed for " + architecture)
        slices.append({"architecture": architecture, "platform": "macOS",
                       "minimum_version": deployment_target(result.stdout)})
    return slices


def inspect_macho(path: Path) -> list[str]:
    return [item["minimum_version"] for item in inspect_slices(path)]


def validate(root: Path, maximum_version: str,
             required_architectures: set[str] | None = None) -> dict[str, object]:
    root = root.resolve(strict=True)
    maximum = version_parts(maximum_version)
    required = set(required_architectures or ())
    if required - {"arm64", "x86_64"}:
        raise ValueError("unsupported required macOS architecture")
    paths = [root] if root.is_file() else sorted(path for path in root.rglob("*") if path.is_file())
    inspected: list[dict[str, object]] = []
    failures: list[dict[str, object]] = []
    for path in paths:
        if path.is_symlink() or not is_macho(path):
            continue
        relative = path.name if root.is_file() else path.relative_to(root).as_posix()
        record: dict[str, object] = {"path": relative}
        inspected.append(record)
        try:
            slices = inspect_slices(path)
            versions = [item["minimum_version"] for item in slices]
            actual = {item["architecture"] for item in slices}
            record.update(deployment_targets=versions, slices=slices)
            errors = []
            if any(version_parts(version) > maximum for version in versions):
                errors.append("deployment target exceeds " + maximum_version)
            if required - actual:
                errors.append("missing required architectures: " + ", ".join(sorted(required - actual)))
            if errors:
                failures.append({**record, "errors": errors})
        except ValueError as error:
            failures.append({**record, "errors": [str(error)]})
    return {
        "root": str(root),
        "maximum_version": maximum_version,
        "required_architectures": sorted(required),
        "macho_count": len(inspected),
        "failures": failures,
        "inspected": inspected,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--maximum-version", required=True)
    parser.add_argument("--require-mach-o", action="store_true")
    parser.add_argument("--required-architecture", action="append", choices=["arm64", "x86_64"], default=[])
    args = parser.parse_args()
    report = validate(args.root, args.maximum_version, set(args.required_architecture))
    print(json.dumps(report, sort_keys=True))
    if args.require_mach_o and report["macho_count"] == 0:
        return 2
    return 1 if report["failures"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
