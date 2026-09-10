#!/usr/bin/env python3
"""Build and sign a per-Provider App Sandbox launcher bundle."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile


PROVIDER_ID = re.compile(r"^[a-z0-9.-]+$")
LAUNCHER_RELATIVE_PATH = "Sandbox/ProviderSandboxLauncher.app/Contents/MacOS/ProviderSandboxLauncher"
COMMUNITY_ADHOC_RELEASE_PROFILE = "community-adhoc"
DEVELOPER_ID_RELEASE_PROFILE = "developer-id"
RELEASE_PROFILES = (COMMUNITY_ADHOC_RELEASE_PROFILE, DEVELOPER_ID_RELEASE_PROFILE)


def validate_release_profile(release_profile: str, codesign_identity: str) -> str:
    if release_profile not in RELEASE_PROFILES:
        raise ValueError(f"unsupported Provider release profile: {release_profile}")
    identity = codesign_identity.strip()
    if not identity:
        raise ValueError("a code-signing identity is required")
    if release_profile == COMMUNITY_ADHOC_RELEASE_PROFILE and identity != "-":
        raise ValueError("community-adhoc requires the ad-hoc code-signing identity '-'")
    if release_profile == DEVELOPER_ID_RELEASE_PROFILE and identity == "-":
        raise ValueError("developer-id requires an Apple code-signing identity")
    return identity


def signature_scope_errors(signature_details: str, release_profile: str) -> list[str]:
    is_adhoc = "Signature=adhoc" in signature_details
    has_developer_id_authority = any(
        line.startswith("Authority=Developer ID Application:")
        for line in signature_details.splitlines()
    )
    team_identifier: str | None = None
    for line in signature_details.splitlines():
        if line.startswith("TeamIdentifier="):
            value = line.partition("=")[2].strip()
            if value and value != "not set":
                team_identifier = value
            break
    if release_profile == COMMUNITY_ADHOC_RELEASE_PROFILE:
        if not is_adhoc or team_identifier is not None:
            return ["community-adhoc sandbox launcher requires an ad-hoc signature without a TeamIdentifier"]
    elif release_profile == DEVELOPER_ID_RELEASE_PROFILE:
        if is_adhoc or team_identifier is None or not has_developer_id_authority:
            return ["developer-id sandbox launcher requires a Developer ID Application signature with a TeamIdentifier"]
    else:
        return [f"unsupported Provider release profile: {release_profile}"]
    return []


def bundle_identifier(provider_id: str) -> str:
    if not PROVIDER_ID.fullmatch(provider_id):
        raise ValueError("sandboxed Provider IDs must use lowercase letters, digits, dots, or hyphens")
    return f"com.netvplayer.provider.{provider_id}"


def package_read_path(provider_id: str) -> str:
    return f"/Library/Application Support/NetVplayer/Providers/{provider_id}/"


def state_write_path(provider_id: str) -> str:
    return f"/Library/Application Support/NetVplayer/Providers/.state/{provider_id}/"


def build_bundle(
    launcher: Path,
    output: Path,
    provider_id: str,
    codesign_identity: str,
    release_profile: str,
) -> dict[str, object]:
    launcher = launcher.resolve(strict=True)
    if not launcher.is_file():
        raise ValueError("sandbox launcher must be a regular file")
    if output.exists():
        raise ValueError(f"sandbox launcher output already exists: {output}")
    codesign_identity = validate_release_profile(release_profile, codesign_identity)

    identifier = bundle_identifier(provider_id)
    executable = output / "Contents" / "MacOS" / "ProviderSandboxLauncher"
    executable.parent.mkdir(parents=True)
    shutil.copy2(launcher, executable)
    executable.chmod(0o755)
    info = {
        "CFBundleDevelopmentRegion": "en",
        "CFBundleExecutable": "ProviderSandboxLauncher",
        "CFBundleIdentifier": identifier,
        "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundleName": "ProviderSandboxLauncher",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": "1.0",
        "CFBundleVersion": "1",
        "LSBackgroundOnly": True,
        "LSMinimumSystemVersion": "14.0",
    }
    with (output / "Contents" / "Info.plist").open("wb") as handle:
        plistlib.dump(info, handle, sort_keys=True)
    entitlements = {
        "com.apple.security.app-sandbox": True,
        "com.apple.security.network.client": True,
        "com.apple.security.temporary-exception.files.home-relative-path.read-only": [
            package_read_path(provider_id)
        ],
        "com.apple.security.temporary-exception.files.home-relative-path.read-write": [
            state_write_path(provider_id)
        ],
    }
    with tempfile.NamedTemporaryFile(suffix=".plist") as entitlement_file:
        plistlib.dump(entitlements, entitlement_file, sort_keys=True)
        entitlement_file.flush()
        signed = subprocess.run(
            [
                "/usr/bin/codesign",
                "--force",
                "--sign",
                codesign_identity,
                "--identifier",
                identifier,
                "--entitlements",
                entitlement_file.name,
                str(output),
            ],
            check=False,
            capture_output=True,
            text=True,
        )
    if signed.returncode != 0:
        raise ValueError(signed.stderr.strip() or "sandbox launcher signing failed")
    verified = subprocess.run(
        ["/usr/bin/codesign", "--verify", "--deep", "--strict", "--verbose=2", str(output)],
        check=False,
        capture_output=True,
        text=True,
    )
    if verified.returncode != 0:
        raise ValueError(verified.stderr.strip() or "sandbox launcher signature verification failed")
    details = subprocess.run(
        ["/usr/bin/codesign", "--display", "--verbose=4", str(output)],
        check=False,
        capture_output=True,
        text=True,
    )
    profile_errors = signature_scope_errors(details.stderr + details.stdout, release_profile)
    if profile_errors:
        raise ValueError(profile_errors[0])
    return {
        "profile_version": 2,
        "launcher": LAUNCHER_RELATIVE_PATH,
        "bundle_id": identifier,
        "release_profile": release_profile,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--launcher", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--provider-id", required=True)
    parser.add_argument("--codesign-identity", required=True)
    parser.add_argument("--release-profile", required=True, choices=RELEASE_PROFILES)
    arguments = parser.parse_args()
    result = build_bundle(
        arguments.launcher,
        arguments.output,
        arguments.provider_id,
        arguments.codesign_identity,
        arguments.release_profile,
    )
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError) as error:
        print(f"Provider sandbox launcher: {error}")
        raise SystemExit(1)
