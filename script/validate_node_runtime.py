#!/usr/bin/env python3
"""Validate that a packaged macOS Node runtime has no host-only dependencies."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import subprocess


MACHO_MAGICS = {
    b"\xfe\xed\xfa\xce",
    b"\xce\xfa\xed\xfe",
    b"\xfe\xed\xfa\xcf",
    b"\xcf\xfa\xed\xfe",
    b"\xca\xfe\xba\xbe",
    b"\xbe\xba\xfe\xca",
    b"\xca\xfe\xba\xbf",
    b"\xbf\xba\xfe\xca",
}
SYSTEM_PREFIXES = ("/usr/lib/", "/System/Library/")
RUNTIME_PROBE_TIMEOUT = 60


def inside(path: Path, root: Path) -> bool:
    try:
        path.resolve(strict=True).relative_to(root.resolve(strict=True))
        return True
    except (FileNotFoundError, ValueError):
        return False


def is_macho(path: Path) -> bool:
    try:
        with path.open("rb") as handle:
            return handle.read(4) in MACHO_MAGICS
    except OSError:
        return False


def parse_otool_dependencies(output: str) -> list[str]:
    dependencies: list[str] = []
    for line in output.splitlines()[1:]:
        value = line.strip().split(" (compatibility version", 1)[0]
        if value:
            dependencies.append(value)
    return dependencies


def parse_otool_rpaths(output: str) -> list[str]:
    rpaths: list[str] = []
    waiting_for_path = False
    for line in output.splitlines():
        value = line.strip()
        if value == "cmd LC_RPATH":
            waiting_for_path = True
        elif waiting_for_path and value.startswith("path "):
            rpaths.append(value[5:].split(" (offset", 1)[0])
            waiting_for_path = False
    return rpaths


def loader_base(reference: str, binary: Path, executable: Path) -> Path | None:
    if reference == "@loader_path":
        return binary.parent
    if reference.startswith("@loader_path/"):
        return binary.parent / reference.removeprefix("@loader_path/")
    if reference == "@executable_path":
        return executable.parent
    if reference.startswith("@executable_path/"):
        return executable.parent / reference.removeprefix("@executable_path/")
    return None


def package_reference_exists(
    reference: str,
    binary: Path,
    executable: Path,
    root: Path,
    rpaths: list[str],
    inherited_rpath_bases: list[Path] | None = None,
) -> bool:
    if reference.startswith("@loader_path/"):
        return inside(binary.parent / reference.removeprefix("@loader_path/"), root)
    if reference.startswith("@executable_path/"):
        return inside(executable.parent / reference.removeprefix("@executable_path/"), root)
    if reference.startswith("@rpath/"):
        suffix = reference.removeprefix("@rpath/")
        local_bases = [loader_base(rpath, binary, executable) for rpath in rpaths]
        bases = [base for base in local_bases if base is not None] + (inherited_rpath_bases or [])
        return any(inside(base / suffix, root) for base in bases)
    return False


def dependency_error(
    reference: str,
    binary: Path,
    executable: Path,
    root: Path,
    rpaths: list[str] | None = None,
    inherited_rpath_bases: list[Path] | None = None,
) -> str | None:
    if reference.startswith(SYSTEM_PREFIXES):
        return None
    if reference.startswith("@"):
        if package_reference_exists(
            reference,
            binary,
            executable,
            root,
            rpaths or [],
            inherited_rpath_bases,
        ):
            return None
        return f"unresolved package-relative dependency for {binary.name}: {reference}"
    if reference.startswith("/"):
        return f"host-only absolute dependency for {binary.name}: {reference}"
    return f"unsupported dependency reference for {binary.name}: {reference}"


def runtime_binaries(root: Path, executable: Path) -> list[Path]:
    candidates = {executable}
    for path in root.rglob("*"):
        if path.is_file() and (path.suffix in {".dylib", ".so"} or is_macho(path)):
            candidates.add(path)
    return sorted(candidates)


def macho_architectures(path: Path) -> list[str]:
    result = subprocess.run(
        ["/usr/bin/lipo", "-archs", str(path)],
        check=False,
        capture_output=True,
        text=True,
    )
    return result.stdout.split() if result.returncode == 0 else []


def otool_command(option: str, binary: Path, architecture: str | None) -> list[str]:
    command = ["/usr/bin/otool"]
    if architecture:
        command.extend(["-arch", architecture])
    command.extend([option, str(binary)])
    return command


def validate_macho_dependencies(root: Path, executable: Path) -> list[str]:
    errors: list[str] = []
    root = root.resolve(strict=True)
    binaries = [binary for binary in runtime_binaries(root, executable) if is_macho(binary)]
    rpaths_by_binary: dict[tuple[Path, str | None], list[str]] = {}
    inherited_rpath_bases: dict[str | None, list[Path]] = {}
    for binary in binaries:
        architectures = macho_architectures(binary) or [None]
        for architecture in architectures:
            load_commands = subprocess.run(
                otool_command("-l", binary, architecture),
                check=False,
                capture_output=True,
                text=True,
            )
            rpaths = parse_otool_rpaths(load_commands.stdout)
            rpaths_by_binary[(binary, architecture)] = rpaths
            for rpath in rpaths:
                base = loader_base(rpath, binary, executable)
                if base is not None and inside(base, root):
                    inherited_rpath_bases.setdefault(architecture, []).append(base)
                elif rpath.startswith("/") and not rpath.startswith(SYSTEM_PREFIXES):
                    errors.append(f"host-only absolute rpath for {binary.name}[{architecture or 'default'}]: {rpath}")

    for binary in binaries:
        if not is_macho(binary):
            continue
        for architecture in macho_architectures(binary) or [None]:
            rpaths = rpaths_by_binary[(binary, architecture)]
            dependencies = subprocess.run(
                otool_command("-L", binary, architecture),
                check=False,
                capture_output=True,
                text=True,
            )
            if dependencies.returncode != 0:
                errors.append(
                    f"could not inspect Mach-O dependencies: {binary.relative_to(root)}[{architecture or 'default'}]"
                )
                continue
            install_name = subprocess.run(
                otool_command("-D", binary, architecture),
                check=False,
                capture_output=True,
                text=True,
            ).stdout.splitlines()[1:2]
            for reference in parse_otool_dependencies(dependencies.stdout):
                if reference in install_name:
                    continue
                error = dependency_error(
                    reference,
                    binary,
                    executable,
                    root,
                    rpaths,
                    inherited_rpath_bases.get(architecture),
                )
                if error:
                    errors.append(f"{error} [{architecture or 'default'}]")
    return errors


def validate(root: Path, executable: Path) -> list[str]:
    errors: list[str] = []
    root = root.resolve(strict=True)
    if not inside(executable, root):
        return [f"Node executable escapes runtime root: {executable}"]
    if not executable.is_file() or not executable.stat().st_mode & 0o111:
        return [f"Node executable is missing or not executable: {executable}"]

    try:
        probe = subprocess.run(
            [str(executable), "-e", "console.log(JSON.stringify({executable:process.execPath,version:process.versions.node}))"],
            check=False,
            capture_output=True,
            text=True,
            env={"PATH": str(executable.parent)},
            timeout=RUNTIME_PROBE_TIMEOUT,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        return [f"could not execute Node runtime probe: {error}"]
    if probe.returncode != 0:
        errors.append(f"Node runtime probe failed: {probe.stderr.strip() or probe.returncode}")
    else:
        try:
            result = json.loads(probe.stdout)
            if not isinstance(result.get("executable"), str) or not inside(Path(result["executable"]), root):
                errors.append(f"process.execPath escapes runtime root: {result.get('executable')}")
        except (json.JSONDecodeError, TypeError) as error:
            errors.append(f"Node runtime probe returned invalid JSON: {error}")

    errors.extend(validate_macho_dependencies(root, executable))
    return errors


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("root", type=Path, nargs="?")
    parser.add_argument("--root", dest="root_option", type=Path)
    parser.add_argument("--executable", type=Path)
    parser.add_argument("--version", help="Required Node major version, for example 22")
    arguments = parser.parse_args()
    root = arguments.root_option or arguments.root
    if root is None:
        parser.error("a runtime root is required")
    root = root.resolve(strict=True)
    if root == Path(root.anchor):
        parser.error("runtime root must not be a filesystem root")
    executable = arguments.executable or root / "bin/node"
    errors = validate(root, executable)
    if not errors and arguments.version:
        version = subprocess.run(
            [str(executable), "-p", "process.versions.node.split('.')[0]"],
            check=False,
            capture_output=True,
            text=True,
            env={"PATH": str(executable.parent)},
            timeout=RUNTIME_PROBE_TIMEOUT,
        )
        if version.returncode != 0 or version.stdout.strip() != arguments.version:
            actual = version.stdout.strip() or version.stderr.strip() or "unknown"
            errors.append(f"Node version mismatch: expected {arguments.version}, got {actual}")
    if errors:
        for error in errors:
            print(error)
        return 1
    print(json.dumps({"ok": True, "runtime": str(root), "version": arguments.version}, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
