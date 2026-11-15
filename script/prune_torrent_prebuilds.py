#!/usr/bin/env python3
"""Keep only the declared macOS native prebuilds in a staged App copy."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import plistlib
import shutil


def prune(app: Path, architecture: str) -> dict:
    tag = {"arm64": "darwin-arm64", "x86_64": "darwin-x64"}[architecture]
    app = app.resolve(strict=True)
    with (app / "Contents/Info.plist").open("rb") as stream:
        if plistlib.load(stream).get("CFBundleIdentifier") != "com.netvplayer.app":
            raise ValueError("Expected a staged NetVplayer App")
    root = app / "Contents/Resources/TorrentBridge/node_modules"
    if root.is_symlink() or not root.is_dir():
        raise ValueError("Expected copied TorrentBridge node_modules")
    keep, remove = [], []
    # Validate the whole plan before deleting anything. Never touch npm's source
    # tree or follow a link out of the copied App.
    for prebuilds in sorted(root.rglob("prebuilds")):
        if not prebuilds.is_dir():
            continue
        if prebuilds.is_symlink() or not prebuilds.resolve().is_relative_to(root):
            raise ValueError("Prebuild directory escapes copied App")
        children = sorted(prebuilds.iterdir())
        for child in children:
            if child.is_symlink() or not child.resolve().is_relative_to(root):
                raise ValueError("Prebuild entry escapes copied App")
        target = prebuilds / tag
        if not target.is_dir() or not any(target.iterdir()):
            raise ValueError("Missing target prebuild: " + str(prebuilds.relative_to(root)))
        keep.append(target.relative_to(root).as_posix())
        remove.extend(child for child in children if child.is_dir() and child != target)
    for directory in remove:
        shutil.rmtree(directory)
    return {"architecture": architecture, "kept": keep,
            "removed": [path.relative_to(root).as_posix() for path in remove]}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app-bundle", type=Path, required=True)
    parser.add_argument("--architecture", choices=["arm64", "x86_64"], required=True)
    args = parser.parse_args()
    print(json.dumps(prune(args.app_bundle, args.architecture), sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
