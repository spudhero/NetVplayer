#!/usr/bin/env python3
"""Validate a Provider's signed App Sandbox launcher and entitlements."""

from __future__ import annotations

import json
from pathlib import Path
import plistlib
import subprocess

from build_provider_sandbox_launcher import (
    RELEASE_PROFILES,
    bundle_identifier,
    package_read_path,
    signature_scope_errors,
    state_write_path,
)


ALLOWED_ENTITLEMENTS = {
    "com.apple.security.app-sandbox",
    "com.apple.security.network.client",
    "com.apple.security.temporary-exception.files.home-relative-path.read-only",
    "com.apple.security.temporary-exception.files.home-relative-path.read-write",
    "com.apple.application-identifier",
    "com.apple.developer.team-identifier",
}


def launcher_bundle(root: Path, launcher_value: object) -> tuple[Path, Path] | None:
    if not isinstance(launcher_value, str):
        return None
    try:
        canonical_root = root.resolve(strict=True)
        launcher = (canonical_root / launcher_value).resolve(strict=True)
        launcher.relative_to(canonical_root)
    except (FileNotFoundError, OSError, ValueError):
        return None
    if (
        launcher.parent.name != "MacOS"
        or launcher.parent.parent.name != "Contents"
        or launcher.parent.parent.parent.suffix != ".app"
    ):
        return None
    return launcher, launcher.parent.parent.parent


def entitlements(bundle: Path) -> tuple[dict[str, object] | None, str]:
    displayed = subprocess.run(
        ["/usr/bin/codesign", "--display", "--entitlements", "-", "--xml", str(bundle)],
        check=False,
        capture_output=True,
    )
    if displayed.returncode != 0:
        return None, displayed.stderr.decode(errors="replace").strip()
    try:
        value = plistlib.loads(displayed.stdout)
    except plistlib.InvalidFileException as error:
        return None, str(error)
    return value if isinstance(value, dict) else None, ""


def validate(
    root: Path,
    manifest: dict[str, object],
    expected_release_profile: str | None = None,
) -> list[str]:
    errors: list[str] = []
    sandbox = manifest.get("sandbox")
    provider_id = manifest.get("provider_id")
    if not isinstance(sandbox, dict):
        return ["manifest sandbox configuration is required"]
    if sandbox.get("profile_version") != 2:
        errors.append("sandbox profile_version must be 2")
    release_profile = sandbox.get("release_profile")
    if release_profile not in RELEASE_PROFILES:
        errors.append("sandbox release_profile must be community-adhoc or developer-id")
    elif expected_release_profile is not None and release_profile != expected_release_profile:
        errors.append(
            f"sandbox release_profile mismatch: expected {expected_release_profile}, got {release_profile}"
        )
    if not isinstance(provider_id, str):
        errors.append("sandbox requires a string provider_id")
        return errors
    try:
        expected_identifier = bundle_identifier(provider_id)
    except ValueError as error:
        errors.append(str(error))
        return errors
    if sandbox.get("bundle_id") != expected_identifier:
        errors.append("sandbox bundle_id does not match provider_id")
    resolved = launcher_bundle(root, sandbox.get("launcher"))
    if resolved is None:
        errors.append("sandbox launcher must use an app bundle Contents/MacOS path")
        return errors
    launcher, bundle = resolved
    if not launcher.is_file():
        errors.append("sandbox launcher executable is missing")
        return errors
    try:
        info = plistlib.loads((bundle / "Contents" / "Info.plist").read_bytes())
    except (OSError, plistlib.InvalidFileException) as error:
        errors.append(f"sandbox Info.plist is invalid: {error}")
        return errors
    if info.get("CFBundleIdentifier") != expected_identifier:
        errors.append("sandbox Info.plist bundle identifier mismatch")
    if info.get("CFBundleExecutable") != launcher.name:
        errors.append("sandbox Info.plist executable mismatch")

    verified = subprocess.run(
        [
            "/usr/bin/codesign", "--verify", "--deep", "--strict",
            "--all-architectures", "--verbose=2", str(bundle),
        ],
        check=False,
        capture_output=True,
        text=True,
    )
    if verified.returncode != 0:
        errors.append(f"sandbox launcher code signature is invalid: {verified.stderr.strip()}")
        return errors
    values, detail = entitlements(bundle)
    if values is None:
        errors.append(f"sandbox launcher entitlements are invalid: {detail}")
        return errors
    if values.get("com.apple.security.app-sandbox") is not True:
        errors.append("sandbox launcher does not enable App Sandbox")
    if values.get("com.apple.security.network.client") is not True:
        errors.append("sandbox launcher does not declare outbound network access")
    read_key = "com.apple.security.temporary-exception.files.home-relative-path.read-only"
    write_key = "com.apple.security.temporary-exception.files.home-relative-path.read-write"
    if values.get(read_key) != [package_read_path(provider_id)]:
        errors.append("sandbox package read entitlement mismatch")
    if values.get(write_key) != [state_write_path(provider_id)]:
        errors.append("sandbox state write entitlement mismatch")
    unexpected = sorted(set(values) - ALLOWED_ENTITLEMENTS)
    if unexpected:
        errors.append(f"sandbox launcher contains unexpected entitlements: {', '.join(unexpected)}")

    details = subprocess.run(
        ["/usr/bin/codesign", "--display", "--verbose=4", str(bundle)],
        check=False,
        capture_output=True,
        text=True,
    )
    signature_details = details.stderr + details.stdout
    if isinstance(release_profile, str):
        errors.extend(signature_scope_errors(signature_details, release_profile))
    return errors


def main() -> int:
    import argparse

    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--release-profile", choices=RELEASE_PROFILES)
    arguments = parser.parse_args()
    manifest = json.loads(arguments.manifest.read_text(encoding="utf-8"))
    errors = validate(arguments.root.resolve(strict=True), manifest, arguments.release_profile)
    if errors:
        for error in errors:
            print(error)
        return 1
    print(json.dumps({
        "ok": True,
        "sandbox": "app-sandbox-v2",
        "release_profile": manifest["sandbox"]["release_profile"],
    }, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
