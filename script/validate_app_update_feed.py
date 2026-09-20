#!/usr/bin/env python3
"""Validate the release feed against the exact archive uploaded with it."""

from __future__ import annotations

import argparse
import base64
from pathlib import Path
import re
import xml.etree.ElementTree as ET


SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
VERSION = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")


def validate(feed: Path, archive: Path, version: str, repository: str) -> str:
    if not VERSION.fullmatch(version):
        raise ValueError("release version must be MAJOR.MINOR.PATCH")
    tree = ET.parse(feed)
    items = tree.findall("./channel/item")
    if len(items) != 1:
        raise ValueError("appcast must contain exactly one stable update")

    item = items[0]
    enclosure = item.find("enclosure")
    if enclosure is None:
        raise ValueError("appcast update has no archive enclosure")
    expected_url = (
        f"https://github.com/{repository}/releases/download/{version}/{archive.name}"
    )
    if enclosure.get("url") != expected_url:
        raise ValueError("appcast archive URL does not match this release")
    if item.findtext(f"{{{SPARKLE}}}shortVersionString") != version:
        raise ValueError("appcast display version does not match release tag")
    build = item.findtext(f"{{{SPARKLE}}}version")
    if not build or not build.isdigit():
        raise ValueError("appcast build number is missing")
    if int(enclosure.get("length", "0")) != archive.stat().st_size:
        raise ValueError("appcast archive length is incorrect")
    signature = enclosure.get(f"{{{SPARKLE}}}edSignature")
    if not signature or len(base64.b64decode(signature, validate=True)) != 64:
        raise ValueError("appcast archive signature is missing or invalid")
    if item.findtext(f"{{{SPARKLE}}}hardwareRequirements") != "arm64":
        raise ValueError("appcast must require Apple Silicon")
    return signature


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--feed", type=Path, required=True)
    parser.add_argument("--archive", type=Path, required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--repository", required=True)
    args = parser.parse_args()
    print(validate(args.feed, args.archive, args.version, args.repository))


if __name__ == "__main__":
    main()
