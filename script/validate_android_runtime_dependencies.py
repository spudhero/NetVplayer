#!/usr/bin/env python3
"""Inspect host Mach-O libraries embedded in the original runtime's JARs.

Archives stay byte-for-byte intact. Architecture-specific resources are checked
against their loader directory, and every library family needs the declared CPU.
Android guest ELF libraries are outside this host deployment check.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import shutil
import subprocess
import tempfile
import zipfile

from validate_macos_compatibility import inspect_slices, is_macho, version_parts
from validate_node_runtime import parse_otool_dependencies, SYSTEM_PREFIXES

RESOURCE_ARCHITECTURES = {
    "osx_arm64": "arm64", "osx_64": "x86_64",
    "darwin-aarch64": "arm64", "darwin-x86-64": "x86_64",
}


def validate(root: Path, maximum_version: str, required: set[str]) -> dict:
    root = root.resolve(strict=True)
    if not required or required - {"arm64", "x86_64"}:
        raise ValueError("expected declared macOS architecture")
    maximum = version_parts(maximum_version)
    records, failures = [], []
    jars = sorted(root.rglob("*.jar"))
    with tempfile.TemporaryDirectory(prefix="netvplayer-host-jar-probe-") as scratch:
        probe = Path(scratch) / "native.dylib"
        for jar in jars:
            jar_name = jar.relative_to(root).as_posix()
            groups: dict[str, set[str]] = {}
            with zipfile.ZipFile(jar) as archive:
                seen = set()
                for member in archive.infolist():
                    name = PurePosixPath(member.filename)
                    if name.suffix not in {".dylib", ".jnilib", ".so"}:
                        continue
                    if member.filename in seen:
                        failures.append({"jar": jar_name, "member": member.filename,
                                         "error": "duplicate native archive member"})
                        continue
                    seen.add(member.filename)
                    if member.file_size > 256 * 1024 * 1024:
                        raise ValueError("native archive member exceeds probe limit")
                    # No archive path is ever used as an extraction destination.
                    with archive.open(member) as source, probe.open("wb") as output:
                        shutil.copyfileobj(source, output)
                    if not is_macho(probe):
                        if name.suffix in {".dylib", ".jnilib"} or any(part in RESOURCE_ARCHITECTURES for part in name.parts):
                            failures.append({"jar": jar_name, "member": member.filename,
                                             "error": "Mac native archive member is not Mach-O"})
                        continue
                    record = {"jar": jar_name, "member": member.filename,
                              "sha256": hashlib.sha256(probe.read_bytes()).hexdigest()}
                    records.append(record)
                    try:
                        slices = inspect_slices(probe)
                        record["slices"] = slices
                        actual = {item["architecture"] for item in slices}
                        groups.setdefault(name.name, set()).update(actual)
                        for part in name.parts:
                            expected = RESOURCE_ARCHITECTURES.get(part)
                            if expected and expected not in actual:
                                raise ValueError("resource directory does not match its CPU slice")
                        if any(version_parts(item["minimum_version"]) > maximum for item in slices):
                            raise ValueError("embedded native deployment target exceeds " + maximum_version)
                        dependencies = {}
                        for item in slices:
                            arch = item["architecture"]
                            result = subprocess.run(["/usr/bin/otool", "-arch", arch, "-L", str(probe)],
                                                    check=True, capture_output=True, text=True)
                            identity = subprocess.run(["/usr/bin/otool", "-arch", arch, "-D", str(probe)],
                                                      check=True, capture_output=True, text=True).stdout.splitlines()[1:2]
                            refs = [ref for ref in parse_otool_dependencies(result.stdout) if ref not in identity]
                            dependencies[arch] = refs
                            if any(not ref.startswith(SYSTEM_PREFIXES) for ref in refs):
                                raise ValueError("embedded native has an unresolved non-system dependency")
                        record["dependencies"] = dependencies
                    except (ValueError, subprocess.CalledProcessError) as error:
                        failures.append({"jar": jar_name, "member": member.filename, "error": str(error)})
                for library, architectures in groups.items():
                    if required - architectures:
                        failures.append({"jar": jar_name, "library": library,
                                         "error": "missing declared architectures: " + ", ".join(sorted(required - architectures))})
    return {"jarCount": len(jars), "nativeMachOCount": len(records),
            "nativeSliceCount": sum(len(item.get("slices", [])) for item in records),
            "requiredArchitectures": sorted(required), "maximumVersion": maximum_version,
            "inspected": records, "failures": failures}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--maximum-version", default="14.0")
    parser.add_argument("--architecture", choices=["arm64", "x86_64"], action="append", required=True)
    args = parser.parse_args()
    report = validate(args.root, args.maximum_version, set(args.architecture))
    print(json.dumps(report, sort_keys=True))
    return 1 if report["failures"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
