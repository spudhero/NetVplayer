"""Embed Sentry's static-SDK resources and public DSN in a staged macOS app."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
from urllib.parse import urlsplit


def validate_dsn(value: str) -> str:
    value = value.strip()
    if not value:
        return ""
    url = urlsplit(value)
    allowed = (".ingest.sentry.io", ".ingest.us.sentry.io", ".ingest.de.sentry.io")
    if (url.scheme != "https" or not (url.hostname or "").endswith(allowed)
            or not re.fullmatch(r"[a-fA-F0-9]+", url.username or "")
            or url.password is not None or url.query or url.fragment
            or not re.fullmatch(r"/[0-9]+", url.path)):
        raise ValueError("NetVplayerSentryDSN must be a public HTTPS Sentry Cloud DSN")
    return value


def package_resources(package_root: Path, app_bundle: Path, dsn_override: str | None = None) -> dict:
    source_info = plistlib.loads((package_root / "Sources/NetVplayerApp/Info.plist").read_bytes())
    dsn = validate_dsn(dsn_override if dsn_override is not None else source_info.get("NetVplayerSentryDSN", ""))
    sdk = package_root / ".build/artifacts/sentry-apple-binaries/Sentry-Static/Sentry.xcframework"
    metadata = plistlib.loads((sdk / "Info.plist").read_bytes())
    library = next(item for item in metadata["AvailableLibraries"] if item["SupportedPlatform"] == "macos")
    resources = sdk / library["LibraryIdentifier"] / library["LibraryPath"] / "Resources"
    privacy = resources / "PrivacyInfo.xcprivacy"
    # Parse before modifying the staged app, so missing/malformed resources fail packaging.
    plistlib.loads(privacy.read_bytes())
    license_file = package_root / ".build/checkouts/sentry-apple-binaries/LICENSE.md"
    if not license_file.read_text().strip():
        raise ValueError("Sentry license is empty")
    app_resources = app_bundle / "Contents/Resources"
    bundle = app_resources / "Sentry.bundle/Contents"
    (bundle / "Resources").mkdir(parents=True, exist_ok=True)
    shutil.copy2(privacy, bundle / "Resources/PrivacyInfo.xcprivacy")
    (bundle / "Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": "com.netvplayer.sentry-resources",
        "CFBundlePackageType": "BNDL",
        "CFBundleName": "Sentry",
    }))
    licenses = app_resources / "ThirdPartyLicenses"
    licenses.mkdir(parents=True, exist_ok=True)
    shutil.copy2(license_file, licenses / "Sentry.LICENSE")
    info_path = app_bundle / "Contents/Info.plist"
    info = plistlib.loads(info_path.read_bytes())
    info["NetVplayerSentryDSN"] = dsn
    info_path.write_bytes(plistlib.dumps(info))
    return {"sentry_configured": bool(dsn), "privacy_manifest": "embedded", "license": "embedded"}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--package-root", type=Path, required=True)
    parser.add_argument("--app-bundle", type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(package_resources(args.package_root, args.app_bundle, os.environ.get("NETVPLAYER_SENTRY_DSN"))))
