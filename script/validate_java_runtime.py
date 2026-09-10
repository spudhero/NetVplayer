#!/usr/bin/env python3
"""Validate a package-local macOS jlink runtime and its Java major version."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from validate_node_runtime import inside, validate_macho_dependencies


RUNTIME_PROBE_TIMEOUT = 60


def parse_java_properties(output: str) -> dict[str, str]:
    properties: dict[str, str] = {}
    for line in output.splitlines():
        match = re.match(r"^\s*([A-Za-z0-9._-]+)\s*=\s*(.+?)\s*$", line)
        if match:
            properties[match.group(1)] = match.group(2)
    return properties


def probe(executable: Path) -> tuple[dict[str, str], str | None]:
    try:
        completed = subprocess.run(
            [str(executable), "-XshowSettings:properties", "-version"],
            check=False,
            capture_output=True,
            text=True,
            env={"PATH": str(executable.parent)},
            timeout=RUNTIME_PROBE_TIMEOUT,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        return {}, f"could not execute Java runtime probe: {error}"
    if completed.returncode != 0:
        return {}, f"Java runtime probe failed: {completed.stderr.strip() or completed.returncode}"
    return parse_java_properties(completed.stderr), None


def validate(root: Path, executable: Path, required_version: str | None = None) -> list[str]:
    errors: list[str] = []
    root = root.resolve(strict=True)
    if not inside(executable, root):
        return [f"Java executable escapes runtime root: {executable}"]
    if not executable.is_file() or not executable.stat().st_mode & 0o111:
        return [f"Java executable is missing or not executable: {executable}"]
    properties, probe_error = probe(executable)
    if probe_error:
        errors.append(probe_error)
    else:
        java_home = properties.get("java.home")
        if not java_home or not inside(Path(java_home), root):
            errors.append(f"java.home escapes runtime root: {java_home}")
        version = properties.get("java.version", "")
        major = version.split(".", 1)[0]
        if required_version and major != required_version:
            errors.append(f"Java version mismatch: expected {required_version}, got {version or 'unknown'}")
    errors.extend(validate_macho_dependencies(root, executable))
    return errors


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("root", type=Path, nargs="?")
    parser.add_argument("--root", dest="root_option", type=Path)
    parser.add_argument("--executable", type=Path)
    parser.add_argument("--version", default="21", help="Required Java major version")
    arguments = parser.parse_args()
    root = arguments.root_option or arguments.root
    if root is None:
        parser.error("a runtime root is required")
    root = root.resolve(strict=True)
    if root == Path(root.anchor):
        parser.error("runtime root must not be a filesystem root")
    executable = arguments.executable or root / "bin/java"
    errors = validate(root, executable, arguments.version)
    if errors:
        for error in errors:
            print(error)
        return 1
    print(json.dumps({"ok": True, "runtime": str(root), "version": arguments.version}, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
