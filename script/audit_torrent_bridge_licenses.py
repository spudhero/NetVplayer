#!/usr/bin/env python3
"""Audit the installed WebTorrent npm tree against its lockfile licenses."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import sys
from typing import Any

from apply_torrent_bridge_replacements import (
    TorrentReplacementError,
    load_json as load_replacement_json,
    package_identity,
    verify_lock as verify_replacement_lock,
    verify_payload as verify_replacement_payload,
)


LICENSE_PREFIXES = ("copying", "copyright", "licence", "license", "notice")
MIT_TEXT_MARKERS = ("permission is hereby granted", "the software is provided")
BSD_TEXT_MARKERS = ("redistribution and use", "this software is provided")


class TorrentLicenseAuditError(RuntimeError):
    pass


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def is_license_filename(name: str) -> bool:
    lowered = name.casefold()
    return any(
        lowered == prefix
        or lowered.startswith(prefix + ".")
        or lowered.startswith(prefix + "-")
        or lowered.startswith(prefix + "_")
        for prefix in LICENSE_PREFIXES
    )


def declared_license(package: dict[str, Any]) -> str | None:
    value = package.get("license")
    if isinstance(value, str) and value.strip():
        return value.strip()
    legacy = package.get("licenses")
    if not isinstance(legacy, list):
        return None
    values = []
    for item in legacy:
        license_type = item.get("type") if isinstance(item, dict) else None
        if isinstance(license_type, str) and license_type.strip():
            values.append(license_type.strip())
    unique = sorted(set(values))
    return " AND ".join(unique) if unique else None


def readme_files(package_root: Path) -> list[Path]:
    return sorted(
        path
        for path in package_root.iterdir()
        if path.is_file() and path.name.casefold().startswith("readme")
    )


def full_license_readme(package_root: Path) -> Path | None:
    for path in readme_files(package_root):
        try:
            content = path.read_text(encoding="utf-8", errors="replace").casefold()
        except OSError:
            continue
        if all(marker in content for marker in MIT_TEXT_MARKERS) or all(
            marker in content for marker in BSD_TEXT_MARKERS
        ):
            return path
    return None


def readme_license_conflict(package_root: Path, license_value: str) -> str | None:
    if re.search(r"(?<![a-z0-9.-])mit(?![a-z0-9.-])", license_value, re.IGNORECASE):
        return None
    for path in readme_files(package_root):
        try:
            content = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        if re.search(r"\bmit\s+licen[cs]e\b", content, re.IGNORECASE):
            return f"package declares {license_value}, README declares MIT"
    return None


def blocker(package_path: str, name: str, version: str, reasons: list[str]) -> dict[str, Any]:
    return {
        "path": package_path,
        "name": name,
        "version": version,
        "reasons": sorted(set(reasons)),
    }


def checked_asset(root: Path, relative_value: Any, digest_value: Any, label: str) -> tuple[str, str]:
    relative = Path(required_text(relative_value, f"{label} path"))
    if relative.is_absolute() or ".." in relative.parts:
        raise TorrentLicenseAuditError(f"unsafe {label} path: {relative}")
    candidate = root / relative
    if candidate.is_symlink():
        raise TorrentLicenseAuditError(f"{label} must not be a symlink")
    path = candidate.resolve(strict=True)
    try:
        path.relative_to(root)
    except ValueError as error:
        raise TorrentLicenseAuditError(f"{label} escapes the WebTorrent root") from error
    if not path.is_file() or path.stat().st_size == 0:
        raise TorrentLicenseAuditError(f"{label} is not a non-empty regular file")
    digest = required_text(digest_value, f"{label} sha256")
    if len(digest) != 64 or sha256(path) != digest:
        raise TorrentLicenseAuditError(f"{label} hash mismatch")
    return str(relative), digest


def required_text(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise TorrentLicenseAuditError(f"{label} must be a non-empty string")
    return value.strip()


def load_license_supplements(
    root: Path,
) -> tuple[dict[tuple[str, str], dict[str, Any]], dict[str, dict[str, str]], str | None]:
    manifest_path = root / "THIRD_PARTY_LICENSES/supplements.json"
    if not manifest_path.is_file():
        return {}, {}, None
    try:
        document = json.loads(manifest_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as error:
        raise TorrentLicenseAuditError(f"invalid license supplement manifest: {manifest_path}") from error
    if not isinstance(document, dict) or document.get("schema_version") != 1:
        raise TorrentLicenseAuditError("unsupported license supplement manifest schema")
    raw_licenses = document.get("canonical_licenses")
    raw_packages = document.get("packages")
    if not isinstance(raw_licenses, dict) or not isinstance(raw_packages, list):
        raise TorrentLicenseAuditError("license supplement manifest is incomplete")

    canonical: dict[str, dict[str, str]] = {}
    for license_id, raw_record in raw_licenses.items():
        if not isinstance(raw_record, dict):
            raise TorrentLicenseAuditError(f"invalid canonical license record: {license_id}")
        identifier = required_text(license_id, "canonical license identifier")
        path, digest = checked_asset(
            root,
            raw_record.get("path"),
            raw_record.get("sha256"),
            f"canonical license {identifier}",
        )
        source = required_text(raw_record.get("source"), f"canonical license {identifier} source")
        if not re.fullmatch(
            r"https://github\.com/spdx/license-list-data/blob/[0-9a-f]{40}/text/[^/]+\.txt",
            source,
        ):
            raise TorrentLicenseAuditError(f"untrusted canonical license source: {source}")
        canonical[identifier] = {"path": path, "sha256": digest, "source": source}

    supplements: dict[tuple[str, str], dict[str, Any]] = {}
    for raw_record in raw_packages:
        if not isinstance(raw_record, dict):
            raise TorrentLicenseAuditError("invalid package license supplement")
        name = required_text(raw_record.get("name"), "supplement package name")
        version = required_text(raw_record.get("version"), f"{name} supplement version")
        license_id = required_text(raw_record.get("license"), f"{name} supplement license")
        if license_id not in canonical:
            raise TorrentLicenseAuditError(f"{name}@{version} uses an unknown canonical license")
        key = (name, version)
        if key in supplements:
            raise TorrentLicenseAuditError(f"duplicate license supplement: {name}@{version}")
        supplements[key] = raw_record
    return supplements, canonical, str(manifest_path.relative_to(root))


def validate_supplement(
    record: dict[str, Any],
    package: dict[str, Any],
    package_json_path: Path,
    locked: dict[str, Any],
) -> None:
    comparisons = {
        "license": declared_license(package),
        "package_json_sha256": sha256(package_json_path),
        "integrity": locked.get("integrity"),
        "resolved": locked.get("resolved"),
        "author": package.get("author"),
    }
    for key, actual in comparisons.items():
        if record.get(key) != actual:
            raise TorrentLicenseAuditError(
                f"license supplement {record.get('name')}@{record.get('version')} {key} drifted"
            )


def build_report(root: Path) -> dict[str, Any]:
    root = root.resolve(strict=True)
    lock_path = root / "package-lock.json"
    modules_root = root / "node_modules"
    if not lock_path.is_file() or not modules_root.is_dir():
        raise TorrentLicenseAuditError(f"WebTorrent install is incomplete: {root}")
    try:
        lock = json.loads(lock_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as error:
        raise TorrentLicenseAuditError(f"invalid package lock: {lock_path}") from error
    packages = lock.get("packages")
    if lock.get("lockfileVersion") != 3 or not isinstance(packages, dict):
        raise TorrentLicenseAuditError("WebTorrent license audit requires npm lockfile v3")

    supplements, canonical_licenses, supplement_manifest_path = load_license_supplements(root)
    used_supplements: set[tuple[str, str]] = set()

    package_count = 0
    license_file_count = len(canonical_licenses)
    standalone_text_packages = 0
    embedded_text_packages = 0
    supplemented_text_packages = 0
    replacement_packages = 0
    legacy_license_packages = 0
    blockers: list[dict[str, Any]] = []
    records: list[dict[str, Any]] = []
    for package_path, locked in sorted(packages.items()):
        if not package_path.startswith("node_modules/"):
            continue
        package_count += 1
        reasons: list[str] = []
        package_root = root / package_path
        package_json_path = package_root / "package.json"
        if not package_root.is_dir() or not package_json_path.is_file():
            blockers.append(blocker(package_path, package_path.rsplit("node_modules/", 1)[-1], "", ["missing-installed-package"]))
            continue
        try:
            package = json.loads(package_json_path.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            blockers.append(blocker(package_path, package_path.rsplit("node_modules/", 1)[-1], "", ["invalid-package-json"]))
            continue
        name = package.get("name") if isinstance(package.get("name"), str) else package_path
        version = package.get("version") if isinstance(package.get("version"), str) else ""
        locked_version = locked.get("version") if isinstance(locked, dict) else None
        integrity = locked.get("integrity") if isinstance(locked, dict) else None
        replacement_record: dict[str, Any] | None = None
        provenance_path = package_root / "PROVENANCE.json"
        if provenance_path.is_file():
            try:
                provenance = load_replacement_json(provenance_path)
                verify_replacement_payload(package_root, provenance)
                expected_root, original = verify_replacement_lock(root, provenance)
                replacement = provenance.get("replacement")
                if expected_root.resolve() != package_root.resolve() or not isinstance(replacement, dict):
                    raise TorrentReplacementError("replacement install path does not match package")
                if package_identity(package) != package_identity(replacement):
                    raise TorrentReplacementError("installed replacement identity drifted")
            except TorrentReplacementError as error:
                raise TorrentLicenseAuditError(f"invalid reviewed replacement at {package_path}") from error
            name = required_text(original.get("name"), "replacement original name")
            version = required_text(original.get("version"), "replacement original version")
            replacement_record = {
                "name": package_identity(replacement)[0],
                "version": package_identity(replacement)[1],
                "license": package_identity(replacement)[2],
                "provenance_path": str(provenance_path.relative_to(root)),
                "provenance_sha256": sha256(provenance_path),
            }
            replacement_packages += 1
        elif not version or version != locked_version:
            reasons.append("installed-version-does-not-match-lock")
        if not isinstance(integrity, str) or not integrity.startswith("sha512-"):
            reasons.append("missing-lock-integrity")

        license_value = declared_license(package)
        if not license_value:
            reasons.append("missing-license-declaration")
            license_value = "unknown"
        elif "license" not in package and "licenses" in package:
            legacy_license_packages += 1
        locked_license = locked.get("license") if isinstance(locked, dict) else None
        if replacement_record is None and isinstance(locked_license, str) and locked_license != license_value:
            reasons.append("lock-and-package-license-disagree")

        license_files = sorted(
            path
            for path in package_root.iterdir()
            if path.is_file() and is_license_filename(path.name) and path.stat().st_size > 0
        )
        evidence: list[dict[str, str]] = []
        if license_files:
            standalone_text_packages += 1
            license_file_count += len(license_files)
            evidence = [
                {
                    "kind": "standalone",
                    "path": str(path.relative_to(root)),
                    "sha256": sha256(path),
                }
                for path in license_files
            ]
        else:
            embedded = full_license_readme(package_root)
            if embedded is not None:
                embedded_text_packages += 1
                license_file_count += 1
                evidence = [
                    {
                        "kind": "embedded-readme",
                        "path": str(embedded.relative_to(root)),
                        "sha256": sha256(embedded),
                    }
                ]
            else:
                supplement = supplements.get((name, version))
                if supplement is None:
                    reasons.append("missing-license-text")
                else:
                    validate_supplement(supplement, package, package_json_path, locked)
                    license_record = canonical_licenses[license_value]
                    supplemented_text_packages += 1
                    used_supplements.add((name, version))
                    evidence = [
                        {
                            "kind": "spdx-supplement",
                            "path": license_record["path"],
                            "sha256": license_record["sha256"],
                            "manifest_path": supplement_manifest_path,
                        }
                    ]
        if replacement_record is None and license_value != "unknown":
            conflict = readme_license_conflict(package_root, license_value)
            if conflict:
                reasons.append("conflicting-license-declaration")
        if reasons:
            blockers.append(blocker(package_path, name, version, reasons))
        records.append(
            {
                "path": package_path,
                "name": name,
                "version": version,
                "locked_version": locked_version,
                "integrity": integrity,
                "declared_license": license_value,
                "locked_license": locked_license,
                "package_json_sha256": sha256(package_json_path),
                "license_evidence": evidence,
                "replacement": replacement_record,
                "reasons": sorted(set(reasons)),
            }
        )

    unused_supplements = sorted(set(supplements) - used_supplements)
    if unused_supplements:
        rendered = ", ".join(f"{name}@{version}" for name, version in unused_supplements)
        raise TorrentLicenseAuditError(f"unused license supplements: {rendered}")

    summary = {
        "package_count": package_count,
        "standalone_text_packages": standalone_text_packages,
        "embedded_text_packages": embedded_text_packages,
        "supplemented_text_packages": supplemented_text_packages,
        "replacement_packages": replacement_packages,
        "covered_packages": (
            standalone_text_packages + embedded_text_packages + supplemented_text_packages
        ),
        "license_text_count": license_file_count,
        "legacy_license_packages": legacy_license_packages,
        "blocking_packages": len(blockers),
    }
    return {
        "schema_version": 1,
        "lockfile_sha256": sha256(lock_path),
        "release_ready": not blockers,
        "summary": summary,
        "packages": records,
        "blockers": blockers,
    }


def serialized(report: dict[str, Any]) -> str:
    return json.dumps(report, indent=2, ensure_ascii=False, sort_keys=True) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--root",
        type=Path,
        default=Path("NetVplayer/Resources/TorrentBridge"),
    )
    output = parser.add_mutually_exclusive_group()
    output.add_argument("--check", type=Path)
    output.add_argument("--write", type=Path)
    parser.add_argument("--allow-known-blockers", action="store_true")
    arguments = parser.parse_args()
    if arguments.allow_known_blockers and arguments.check is None:
        raise TorrentLicenseAuditError("--allow-known-blockers requires --check")
    report = build_report(arguments.root)
    document = serialized(report)
    if arguments.write is not None:
        arguments.write.parent.mkdir(parents=True, exist_ok=True)
        arguments.write.write_text(document, encoding="utf-8")
        print(document, end="")
        return 0
    if arguments.check is not None:
        try:
            expected = arguments.check.read_text(encoding="utf-8")
        except OSError as error:
            raise TorrentLicenseAuditError(f"could not read expected audit: {arguments.check}") from error
        if expected != document:
            raise TorrentLicenseAuditError(f"WebTorrent license audit drifted: {arguments.check}")
        print(
            json.dumps(
                {
                    "known_audit_unchanged": True,
                    **report["summary"],
                    "release_ready": report["release_ready"],
                },
                sort_keys=True,
            )
        )
        if not report["release_ready"] and not arguments.allow_known_blockers:
            return 1
        return 0
    print(document, end="")
    return 0 if report["release_ready"] else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, TorrentLicenseAuditError, ValueError) as error:
        print(f"WebTorrent license audit: {error}", file=sys.stderr)
        raise SystemExit(1)
