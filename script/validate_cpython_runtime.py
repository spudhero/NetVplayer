#!/usr/bin/env python3
"""Reject Python runtimes which resolve imports or prefixes outside their package."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from validate_node_runtime import validate_macho_dependencies


RUNTIME_PROBE_TIMEOUT = 60


def inside(path: Path, root: Path) -> bool:
    try:
        path.resolve(strict=True).relative_to(root.resolve(strict=True))
        return True
    except (FileNotFoundError, ValueError):
        return False


def inside_or_missing(path: Path, root: Path) -> bool:
    """Allow package-local sys.path entries which are optional zip files."""
    try:
        path.resolve(strict=False).relative_to(root.resolve(strict=True))
        return True
    except ValueError:
        return False


def validate(root: Path, executable: Path) -> list[str]:
    errors: list[str] = []
    root = root.resolve(strict=True)
    if not inside(executable, root):
        return [f"Python executable escapes runtime root: {executable}"]
    if not executable.is_file() or not executable.stat().st_mode & 0o111:
        return [f"Python executable is missing or not executable: {executable}"]

    probe = (
        "import json, sys; "
        "print(json.dumps({'executable': sys.executable, 'prefix': sys.prefix, "
        "'base_prefix': sys.base_prefix, 'path': sys.path}))"
    )
    try:
        completed = subprocess.run(
            [str(executable), "-I", "-S", "-c", probe],
            check=False,
            capture_output=True,
            text=True,
            env={"PATH": str(executable.parent)},
            timeout=RUNTIME_PROBE_TIMEOUT,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        return [f"could not execute isolated Python probe: {error}"]
    if completed.returncode != 0:
        return [f"isolated Python probe failed: {completed.stderr.strip() or completed.returncode}"]
    try:
        result = json.loads(completed.stdout)
    except json.JSONDecodeError as error:
        return [f"isolated Python probe returned invalid JSON: {error}"]

    for key in ("executable", "prefix", "base_prefix"):
        value = result.get(key)
        if not isinstance(value, str) or not inside(Path(value), root):
            errors.append(f"{key} escapes runtime root: {value}")
    paths = result.get("path")
    if not isinstance(paths, list):
        errors.append("isolated Python probe did not return sys.path")
    else:
        for value in paths:
            if not isinstance(value, str) or not value:
                continue
            if not inside_or_missing(Path(value), root):
                errors.append(f"sys.path escapes runtime root: {value}")
    errors.extend(validate_macho_dependencies(root, executable))
    return errors


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("root", type=Path, nargs="?")
    parser.add_argument("--root", dest="root_option", type=Path)
    parser.add_argument("--executable", type=Path)
    parser.add_argument("--version", help="Required major.minor, for example 3.12")
    arguments = parser.parse_args()
    root = arguments.root_option or arguments.root
    if root is None:
        parser.error("a runtime root is required")
    root = root.resolve(strict=True)
    if root == Path(root.anchor):
        parser.error("runtime root must not be a filesystem root")
    executable = arguments.executable or root / "bin/python3"
    errors = validate(root, executable)
    if errors:
        for error in errors:
            print(error)
        return 1
    if arguments.version:
        probe = subprocess.run(
            [str(executable), "-I", "-S", "-c", "import sys; print(f'{sys.version_info[0]}.{sys.version_info[1]}')"],
            check=False,
            capture_output=True,
            text=True,
            env={"PATH": str(executable.parent)},
            timeout=RUNTIME_PROBE_TIMEOUT,
        )
        if probe.returncode != 0 or probe.stdout.strip() != arguments.version:
            actual = probe.stdout.strip() or probe.stderr.strip() or "unknown"
            print(f"CPython version mismatch: expected {arguments.version}, got {actual}")
            return 1
    print(json.dumps({"ok": True, "runtime": str(root), "version": arguments.version}, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
