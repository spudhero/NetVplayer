#!/usr/bin/env python3
"""Check the public build boundary and the delivered bundle's source-free policy.

This is a release guard, not a legal assessment or a general binary analyzer.
Dependency assets are separately covered by the runtime license/SBOM gates.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import plistlib
import subprocess
import sys

from audit_provider_public_release import build_release_report


FORBIDDEN_BINARY_MARKERS = (
    b"fty.xxooo.cf",
    b"ffzyapi.com",
    b"LegacyNativeProviderRegistration",
    b"HmysNativeProvider",
    b"NewCzNativeProvider",
    b"BiliNativeProvider",
)
SOURCE_DATA_NAMES = {"configs.json", "history.json", "keeps.json", "lives.json", "sites.json"}
SOURCE_PAYLOAD_SUFFIXES = {".m3u", ".m3u8", ".jar", ".dex", ".sqlite", ".sqlite3", ".db", ".zip", ".py"}


def audit_output_directory(output: Path) -> list[str]:
    resolved = output.resolve()
    if not output.is_absolute() or resolved == Path("/Applications") or Path("/Applications") in resolved.parents:
        return ["public-output-must-be-outside-applications"]
    if any(part.suffix.lower() == ".app" for part in (resolved, *resolved.parents)):
        return ["public-output-must-not-be-inside-an-app"]
    return []


def audit_build_inputs(repo: Path) -> list[str]:
    def git(*arguments: str) -> str:
        return subprocess.check_output(["git", "-C", str(repo), *arguments], text=True)

    errors: list[str] = []
    if git("status", "--porcelain", "--untracked-files=no").strip():
        errors.append("public-build-requires-clean-tracked-files")
    tracked = set(git("ls-files", "-z").split("\0"))
    for prefix in ("NetVplayer/Sources", "NetVplayer/Resources", "NetVplayer/script", "script"):
        for path in (repo / prefix).rglob("*"):
            relative = path.relative_to(repo).as_posix()
            if relative.startswith("NetVplayer/Resources/TorrentBridge/node_modules/"):
                # Public packaging always reinstalls this locked dependency tree.
                continue
            if relative.startswith("script/__pycache__/") and path.suffix == ".pyc":
                continue
            if (path.is_file() or path.is_symlink()) and relative not in tracked:
                errors.append(f"untracked-build-input:{relative}")
    return errors


def audit_bundle(app: Path) -> list[str]:
    errors: list[str] = []
    contents = app / "Contents"
    with (contents / "Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    if info.get("NetVplayerSourcePolicy") != "user-configured-only":
        errors.append("missing-source-free-build-policy")
    executable = info.get("CFBundleExecutable", "")
    if not isinstance(executable, str) or not executable or Path(executable).name != executable:
        return errors + ["invalid-app-executable"]
    binary = (contents / "MacOS" / executable).read_bytes()
    for marker in FORBIDDEN_BINARY_MARKERS:
        if marker in binary:
            errors.append(f"forbidden-binary-marker:{marker.decode()}")

    for path in contents.rglob("*"):
        relative = path.relative_to(contents)
        if {"Providers", "private-providers", "migration-reference"}.intersection(relative.parts):
            errors.append(f"bundled-provider-payload:{relative}")
            continue
        # Locked third-party runtime dependencies have their own provenance gate.
        if relative.parts[:3] == ("Resources", "TorrentBridge", "node_modules"):
            continue
        if not path.is_file():
            continue
        if path.name in SOURCE_DATA_NAMES or path.suffix.lower() in SOURCE_PAYLOAD_SUFFIXES:
            errors.append(f"bundled-source-data:{relative}")
        if path.suffix.lower() == ".json":
            try:
                value = json.loads(path.read_text(encoding="utf-8"))
            except (UnicodeDecodeError, ValueError):
                continue
            if isinstance(value, dict) and any(value.get(key) for key in ("sites", "lives", "spider", "source_bindings")):
                errors.append(f"bundled-source-configuration:{relative}")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", type=Path, required=True)
    parser.add_argument("--app-bundle", type=Path)
    parser.add_argument("--output-directory", type=Path)
    arguments = parser.parse_args()
    report = build_release_report(arguments.repo)
    errors = list(report["blocking_reasons"])
    errors.extend(audit_build_inputs(arguments.repo))
    if arguments.output_directory:
        errors.extend(audit_output_directory(arguments.output_directory))
    for path in (arguments.repo / "NetVplayer/Sources").rglob("*.swift"):
        if any(marker in path.read_bytes() for marker in (b"fty.xxooo.cf", b"ffzyapi.com")):
            errors.append(f"built-in-source-endpoint:{path.relative_to(arguments.repo)}")
    if arguments.app_bundle:
        errors.extend(audit_bundle(arguments.app_bundle))
    print(json.dumps({
        "source_free_checks_passed": not errors,
        "bundle_checked": arguments.app_bundle is not None,
        "blocking_reasons": errors,
    }, sort_keys=True))
    return 1 if errors else 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"source-free app audit: {error}", file=sys.stderr)
        raise SystemExit(1)
