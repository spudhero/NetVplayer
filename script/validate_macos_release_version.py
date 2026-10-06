#!/usr/bin/env python3
"""Reject a release whose public version or build number moves backward."""

from __future__ import annotations

import argparse
import plistlib
import re
import subprocess
from pathlib import Path


VERSION = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")


def version_tuple(version: str) -> tuple[int, int, int]:
    if not VERSION.fullmatch(version):
        raise ValueError(f"invalid release version: {version}")
    return tuple(map(int, version.split(".")))


def validate(repo: Path, tag: str, info_plist: Path) -> None:
    current = plistlib.loads(info_plist.read_bytes())
    current_version = current["CFBundleShortVersionString"]
    current_build = int(current["CFBundleVersion"])
    if tag != current_version:
        raise ValueError("tag and app version differ")

    tags = subprocess.check_output(
        ["git", "tag", "--list"], cwd=repo, text=True
    ).splitlines()
    previous = max(
        (candidate for candidate in tags if VERSION.fullmatch(candidate) and candidate != tag),
        key=version_tuple,
        default=None,
    )
    if previous is None:
        return
    if version_tuple(tag) <= version_tuple(previous):
        raise ValueError(f"version {tag} must be greater than {previous}")
    previous_plist = subprocess.check_output(
        ["git", "show", f"{previous}:NetVplayer/Sources/NetVplayerApp/Info.plist"],
        cwd=repo,
    )
    previous_build = int(plistlib.loads(previous_plist)["CFBundleVersion"])
    if current_build <= previous_build:
        raise ValueError(f"build {current_build} must be greater than {previous_build}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", type=Path, required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--info-plist", type=Path, required=True)
    args = parser.parse_args()
    validate(args.repo, args.tag, args.info_plist)


if __name__ == "__main__":
    main()
