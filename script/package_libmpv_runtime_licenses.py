#!/usr/bin/env python3
"""Package and audit license provenance for the bundled libmpv runtime."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
from typing import Any


MANIFEST_RELATIVE_PATH = Path("Contents/Resources/ThirdPartyLicenses/libmpv-runtime.json")
LICENSES_RELATIVE_PATH = Path("Contents/Resources/ThirdPartyLicenses/libmpv")
NOTICES_RELATIVE_PATH = Path("Contents/Resources/ThirdPartyLicenses/libmpv-runtime.md")
SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")
LICENSE_PREFIXES = ("copying", "copyright", "licence", "license", "notice")


class RuntimeLicenseError(RuntimeError):
    pass


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def is_license_filename(name: str) -> bool:
    lowered = name.casefold()
    return any(
        lowered == prefix
        or lowered.startswith(prefix + ".")
        or lowered.startswith(prefix + "-")
        or lowered.startswith(prefix + "_")
        for prefix in LICENSE_PREFIXES
    )


def parse_cellar_source(source: Path) -> tuple[str, str, Path]:
    resolved = source.resolve(strict=True)
    parts = resolved.parts
    try:
        cellar_index = max(index for index, part in enumerate(parts) if part == "Cellar")
    except ValueError as error:
        raise RuntimeLicenseError(f"runtime source is not inside a Homebrew Cellar: {source}") from error
    if cellar_index + 3 >= len(parts):
        raise RuntimeLicenseError(f"runtime source has an incomplete Cellar path: {source}")
    formula = parts[cellar_index + 1]
    version = parts[cellar_index + 2]
    prefix = Path(*parts[: cellar_index + 3])
    if not formula or not version or not prefix.is_dir():
        raise RuntimeLicenseError(f"runtime source has an invalid Cellar path: {source}")
    return formula, version, prefix


def load_mapping(path: Path) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    seen_names: set[str] = set()
    for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        if not line:
            continue
        fields = line.split("\t")
        if len(fields) != 2:
            raise RuntimeLicenseError(f"invalid runtime mapping line {line_number}")
        bundle_name, source_value = fields
        if Path(bundle_name).name != bundle_name or not bundle_name.endswith(".dylib"):
            raise RuntimeLicenseError(f"invalid bundled dylib name on line {line_number}: {bundle_name}")
        if bundle_name in seen_names:
            raise RuntimeLicenseError(f"duplicate bundled dylib mapping: {bundle_name}")
        source = Path(source_value).resolve(strict=True)
        formula, version, prefix = parse_cellar_source(source)
        seen_names.add(bundle_name)
        records.append(
            {
                "name": bundle_name,
                "source": source,
                "source_sha256": sha256(source),
                "formula": formula,
                "version": version,
                "prefix": prefix,
            }
        )
    if not records:
        raise RuntimeLicenseError("runtime mapping is empty")
    return records


def load_homebrew_metadata(prefixes_by_formula: dict[str, Path]) -> dict[str, dict[str, Any]]:
    metadata_by_formula: dict[str, dict[str, Any]] = {}
    ruby_script = (
        'require "json"; require "pathname"; require "formula"; '
        "formula = Formulary.factory(Pathname(ARGV.fetch(0))); "
        "puts JSON.generate(formula.to_hash)"
    )
    for formula, prefix in sorted(prefixes_by_formula.items()):
        formula_archives = sorted((prefix / ".brew").glob("*.rb"))
        if len(formula_archives) != 1 or not formula_archives[0].is_file():
            raise RuntimeLicenseError(f"formula {formula} has no unique installed formula archive")
        formula_archive = formula_archives[0]
        result = subprocess.run(
            ["brew", "ruby", "-e", ruby_script, str(formula_archive)],
            text=True,
            capture_output=True,
            check=False,
        )
        if result.returncode != 0:
            detail = result.stderr.strip() or result.stdout.strip()
            raise RuntimeLicenseError(f"installed formula metadata lookup failed for {formula}: {detail}")
        try:
            metadata = json.loads(result.stdout)
        except json.JSONDecodeError as error:
            raise RuntimeLicenseError(
                f"installed formula metadata lookup returned invalid JSON for {formula}"
            ) from error
        if not isinstance(metadata, dict) or metadata.get("name") != formula:
            raise RuntimeLicenseError(f"installed formula archive identity mismatch: {formula}")

        receipt_path = prefix / "INSTALL_RECEIPT.json"
        try:
            receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            raise RuntimeLicenseError(f"formula {formula} has no valid install receipt") from error
        receipt_source = receipt.get("source")
        if not isinstance(receipt_source, dict):
            raise RuntimeLicenseError(f"formula {formula} install receipt has no source provenance")

        archive_checksum = sha256(formula_archive)
        reported_checksum = metadata.get("ruby_source_checksum", {}).get("sha256")
        if reported_checksum is not None and reported_checksum != archive_checksum:
            raise RuntimeLicenseError(f"installed formula archive checksum mismatch: {formula}")
        metadata["tap"] = receipt_source.get("tap") or metadata.get("tap")
        metadata["tap_git_head"] = receipt_source.get("tap_git_head") or metadata.get("tap_git_head")
        metadata["ruby_source_path"] = f".brew/{formula_archive.name}"
        metadata["ruby_source_checksum"] = {"sha256": archive_checksum}
        metadata["_metadata_origin"] = "installed-keg-formula-archive"
        metadata["_install_receipt_sha256"] = sha256(receipt_path)
        metadata_by_formula[formula] = metadata
    return metadata_by_formula


def package_version(metadata: dict[str, Any]) -> str:
    stable = metadata.get("versions", {}).get("stable")
    if not isinstance(stable, str) or not stable:
        raise RuntimeLicenseError(f"formula {metadata.get('name')} has no stable version")
    revision = metadata.get("revision", 0)
    if not isinstance(revision, int) or revision < 0:
        raise RuntimeLicenseError(f"formula {metadata.get('name')} has an invalid revision")
    return stable if revision == 0 else f"{stable}_{revision}"


def formula_license_files(prefix: Path) -> list[Path]:
    candidates: list[Path] = []
    for path in prefix.rglob("*"):
        relative = path.relative_to(prefix)
        if len(relative.parts) > 3 or path.is_symlink() or not path.is_file():
            continue
        if is_license_filename(path.name) and path.stat().st_size > 0:
            candidates.append(path)
    return sorted(candidates, key=lambda path: path.relative_to(prefix).as_posix())


def load_fallback_provenance(root: Path) -> dict[str, Any]:
    path = root / "provenance.json"
    if not path.is_file():
        return {}
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as error:
        raise RuntimeLicenseError(f"invalid fallback provenance: {path}") from error
    components = payload.get("components")
    if payload.get("schema_version") != 1 or not isinstance(components, dict):
        raise RuntimeLicenseError(f"invalid fallback provenance schema: {path}")
    return components


def fallback_license_files(
    root: Path,
    provenance: dict[str, Any],
    formula: str,
    version: str,
    source: dict[str, str],
) -> list[Path]:
    record = provenance.get(formula)
    if not isinstance(record, dict):
        return []
    if record.get("version") != version:
        raise RuntimeLicenseError(f"fallback license version mismatch for {formula}")
    source_pins = {key: value for key, value in source.items() if key != "url"}
    if record.get("source_url") != source.get("url") or any(
        record.get(f"source_{key}") != value for key, value in source_pins.items()
    ):
        raise RuntimeLicenseError(f"fallback source provenance mismatch for {formula}")
    files = record.get("files")
    if not isinstance(files, dict) or not files:
        raise RuntimeLicenseError(f"fallback license files are missing for {formula}")
    resolved_files: list[Path] = []
    formula_root = (root / formula).resolve(strict=True)
    for relative_value, expected_hash in sorted(files.items()):
        if not isinstance(relative_value, str) or not isinstance(expected_hash, str):
            raise RuntimeLicenseError(f"fallback license record is invalid for {formula}")
        path = (formula_root / relative_value).resolve(strict=True)
        if formula_root not in path.parents or not path.is_file() or path.is_symlink():
            raise RuntimeLicenseError(f"fallback license path escapes its component: {formula}/{relative_value}")
        if sha256(path) != expected_hash:
            raise RuntimeLicenseError(f"fallback license hash mismatch: {formula}/{relative_value}")
        resolved_files.append(path)
    return resolved_files


def safe_destination_name(path: Path, root: Path) -> str:
    return "__".join(path.relative_to(root).parts)


def formula_source(metadata: dict[str, Any]) -> dict[str, str]:
    stable = metadata.get("urls", {}).get("stable", {})
    url = stable.get("url")
    checksum = stable.get("checksum")
    revision = stable.get("revision")
    if not isinstance(url, str) or not url:
        raise RuntimeLicenseError(f"formula {metadata.get('name')} lacks a stable source URL")
    if isinstance(checksum, str) and SHA256_PATTERN.fullmatch(checksum):
        return {"url": url, "sha256": checksum}
    if isinstance(revision, str) and re.fullmatch(r"[0-9a-f]{40}", revision):
        return {"url": url, "revision": revision}
    raise RuntimeLicenseError(f"formula {metadata.get('name')} lacks a pinned stable source")


def package_runtime(
    app_bundle: Path,
    mapping_path: Path,
    fallback_root: Path,
    metadata_by_formula: dict[str, dict[str, Any]] | None = None,
) -> dict[str, Any]:
    app_bundle = app_bundle.resolve(strict=True)
    frameworks = app_bundle / "Contents/Frameworks"
    resources = app_bundle / "Contents/Resources"
    if not frameworks.is_dir() or not resources.is_dir():
        raise RuntimeLicenseError(f"app bundle is incomplete: {app_bundle}")
    records = load_mapping(mapping_path)
    bundled_names = sorted(path.name for path in frameworks.glob("*.dylib") if path.is_file())
    mapped_names = sorted(record["name"] for record in records)
    if bundled_names != mapped_names:
        raise RuntimeLicenseError("runtime mapping does not exactly cover bundled dylibs")

    formulas = sorted({record["formula"] for record in records})
    if metadata_by_formula is None:
        prefixes_by_formula: dict[str, Path] = {}
        for formula in formulas:
            prefixes = {record["prefix"] for record in records if record["formula"] == formula}
            if len(prefixes) != 1:
                raise RuntimeLicenseError(f"formula {formula} resolves to multiple installed versions")
            prefixes_by_formula[formula] = next(iter(prefixes))
        metadata_by_formula = load_homebrew_metadata(prefixes_by_formula)
    fallback_provenance = load_fallback_provenance(fallback_root)
    licenses_root = app_bundle / LICENSES_RELATIVE_PATH
    manifest_path = app_bundle / MANIFEST_RELATIVE_PATH
    notices_path = app_bundle / NOTICES_RELATIVE_PATH
    if licenses_root.exists() or manifest_path.exists() or notices_path.exists():
        raise RuntimeLicenseError("libmpv license output already exists in staging bundle")
    licenses_root.mkdir(parents=True)

    components: list[dict[str, Any]] = []
    for formula in formulas:
        formula_records = [record for record in records if record["formula"] == formula]
        versions = {record["version"] for record in formula_records}
        prefixes = {record["prefix"] for record in formula_records}
        if len(versions) != 1 or len(prefixes) != 1:
            raise RuntimeLicenseError(f"formula {formula} resolves to multiple installed versions")
        version = next(iter(versions))
        prefix = next(iter(prefixes))
        metadata = metadata_by_formula.get(formula)
        if not isinstance(metadata, dict):
            raise RuntimeLicenseError(f"missing formula metadata: {formula}")
        if package_version(metadata) != version:
            raise RuntimeLicenseError(
                f"installed formula version is not the pinned stable version: {formula} {version}"
            )
        license_expression = metadata.get("license")
        homepage = metadata.get("homepage")
        if not isinstance(license_expression, str) or not license_expression.strip():
            raise RuntimeLicenseError(f"formula {formula} has no SPDX license expression")
        if not isinstance(homepage, str) or not homepage:
            raise RuntimeLicenseError(f"formula {formula} has no homepage")
        source_record = formula_source(metadata)
        license_sources = formula_license_files(prefix)
        license_origin = "homebrew-bottle"
        license_source_root = prefix
        if not license_sources:
            license_sources = fallback_license_files(
                fallback_root,
                fallback_provenance,
                formula,
                version,
                source_record,
            )
            if license_sources:
                license_origin = "audited-source-fallback"
        if not license_sources:
            raise RuntimeLicenseError(f"formula {formula} has no distributable license text")
        if license_origin != "homebrew-bottle":
            license_source_root = (fallback_root / formula).resolve(strict=True)

        formula_destination = licenses_root / formula
        formula_destination.mkdir()
        license_files: list[dict[str, str]] = []
        for license_source in license_sources:
            destination = formula_destination / safe_destination_name(license_source, license_source_root)
            if destination.exists():
                raise RuntimeLicenseError(f"duplicate license destination for {formula}: {destination.name}")
            shutil.copyfile(license_source, destination)
            license_files.append(
                {
                    "path": destination.relative_to(app_bundle).as_posix(),
                    "sha256": sha256(destination),
                    "origin": license_origin,
                }
            )

        formula_source_checksum = metadata.get("ruby_source_checksum", {}).get("sha256")
        tap_git_head = metadata.get("tap_git_head")
        metadata_origin = metadata.get("_metadata_origin", "brew-info-json-v2")
        install_receipt_checksum = metadata.get("_install_receipt_sha256")
        if not isinstance(formula_source_checksum, str) or not SHA256_PATTERN.fullmatch(formula_source_checksum):
            raise RuntimeLicenseError(f"formula {formula} has no pinned formula checksum")
        has_tap_revision = isinstance(tap_git_head, str) and re.fullmatch(r"[0-9a-f]{40}", tap_git_head)
        has_installed_archive = (
            metadata_origin == "installed-keg-formula-archive"
            and isinstance(install_receipt_checksum, str)
            and SHA256_PATTERN.fullmatch(install_receipt_checksum)
        )
        if not has_tap_revision and not has_installed_archive:
            raise RuntimeLicenseError(f"formula {formula} has no pinned tap revision")
        components.append(
            {
                "formula": formula,
                "version": version,
                "license": license_expression,
                "homepage": homepage,
                "source": source_record,
                "homebrew_formula": {
                    "metadata_origin": metadata_origin,
                    "tap": metadata.get("tap"),
                    "tap_git_head": tap_git_head,
                    "ruby_source_path": metadata.get("ruby_source_path"),
                    "ruby_source_sha256": formula_source_checksum,
                    "install_receipt_sha256": install_receipt_checksum,
                },
                "dylibs": [
                    {"name": record["name"], "source_sha256": record["source_sha256"]}
                    for record in sorted(formula_records, key=lambda item: item["name"])
                ],
                "license_files": license_files,
            }
        )

    manifest = {
        "schema_version": 1,
        "complete": True,
        "dylib_count": len(records),
        "formula_count": len(components),
        "components": components,
    }
    manifest_path.write_text(
        json.dumps(manifest, indent=2, ensure_ascii=False, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    notices = [
        "# libmpv Runtime Third-Party Notices",
        "",
        "The application bundle includes the following Homebrew-built runtime components.",
        "Exact source, formula, binary, and license hashes are recorded in `libmpv-runtime.json`.",
        "",
        "| Formula | Version | License | Dylibs |",
        "| --- | --- | --- | ---: |",
    ]
    for component in components:
        notices.append(
            f"| {component['formula']} | {component['version']} | {component['license']} | "
            f"{len(component['dylibs'])} |"
        )
    notices.append("")
    notices_path.write_text("\n".join(notices), encoding="utf-8")
    return audit_runtime(app_bundle)


def resolve_manifest_path(app_bundle: Path, relative_value: str) -> Path:
    relative = Path(relative_value)
    if relative.is_absolute() or ".." in relative.parts:
        raise RuntimeLicenseError(f"manifest contains an unsafe path: {relative_value}")
    resolved = (app_bundle / relative).resolve(strict=True)
    app_root = app_bundle.resolve(strict=True)
    if app_root not in resolved.parents:
        raise RuntimeLicenseError(f"manifest path escapes app bundle: {relative_value}")
    return resolved


def audit_runtime(app_bundle: Path) -> dict[str, Any]:
    app_bundle = app_bundle.resolve(strict=True)
    manifest_path = app_bundle / MANIFEST_RELATIVE_PATH
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise RuntimeLicenseError(f"invalid libmpv license manifest: {manifest_path}") from error
    if manifest.get("schema_version") != 1 or manifest.get("complete") is not True:
        raise RuntimeLicenseError("libmpv license manifest is not complete")
    components = manifest.get("components")
    if not isinstance(components, list) or not components:
        raise RuntimeLicenseError("libmpv license manifest has no components")

    expected_dylibs = sorted(
        path.name for path in (app_bundle / "Contents/Frameworks").glob("*.dylib") if path.is_file()
    )
    recorded_dylibs: list[str] = []
    recorded_formulas: set[str] = set()
    license_count = 0
    for component in components:
        if not isinstance(component, dict):
            raise RuntimeLicenseError("libmpv license component is invalid")
        formula = component.get("formula")
        if not isinstance(formula, str) or not formula or formula in recorded_formulas:
            raise RuntimeLicenseError("libmpv license manifest has a duplicate or invalid formula")
        recorded_formulas.add(formula)
        if not isinstance(component.get("license"), str) or not component["license"].strip():
            raise RuntimeLicenseError(f"libmpv component has no license expression: {formula}")
        dylibs = component.get("dylibs")
        license_files = component.get("license_files")
        if not isinstance(dylibs, list) or not dylibs or not isinstance(license_files, list) or not license_files:
            raise RuntimeLicenseError(f"libmpv component is incomplete: {formula}")
        for dylib in dylibs:
            name = dylib.get("name") if isinstance(dylib, dict) else None
            source_hash = dylib.get("source_sha256") if isinstance(dylib, dict) else None
            if not isinstance(name, str) or not SHA256_PATTERN.fullmatch(str(source_hash)):
                raise RuntimeLicenseError(f"libmpv dylib provenance is invalid: {formula}")
            recorded_dylibs.append(name)
        for license_file in license_files:
            relative_value = license_file.get("path") if isinstance(license_file, dict) else None
            expected_hash = license_file.get("sha256") if isinstance(license_file, dict) else None
            if not isinstance(relative_value, str) or not SHA256_PATTERN.fullmatch(str(expected_hash)):
                raise RuntimeLicenseError(f"libmpv license file record is invalid: {formula}")
            path = resolve_manifest_path(app_bundle, relative_value)
            if sha256(path) != expected_hash:
                raise RuntimeLicenseError(f"libmpv license file hash mismatch: {relative_value}")
            license_count += 1

    if sorted(recorded_dylibs) != expected_dylibs:
        raise RuntimeLicenseError("libmpv license manifest does not cover the bundled dylibs")
    if manifest.get("dylib_count") != len(expected_dylibs):
        raise RuntimeLicenseError("libmpv license manifest dylib count is stale")
    if manifest.get("formula_count") != len(recorded_formulas):
        raise RuntimeLicenseError("libmpv license manifest formula count is stale")
    if not (app_bundle / NOTICES_RELATIVE_PATH).is_file():
        raise RuntimeLicenseError("libmpv third-party notices are missing")
    return {
        "complete": True,
        "dylib_count": len(expected_dylibs),
        "formula_count": len(recorded_formulas),
        "license_file_count": license_count,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--app-bundle", type=Path, required=True)
    parser.add_argument("--mapping", type=Path)
    parser.add_argument("--fallback-root", type=Path)
    parser.add_argument("--audit-only", action="store_true")
    arguments = parser.parse_args()
    if arguments.audit_only:
        if arguments.mapping is not None or arguments.fallback_root is not None:
            parser.error("--audit-only cannot be combined with packaging inputs")
        report = audit_runtime(arguments.app_bundle)
    else:
        if arguments.mapping is None or arguments.fallback_root is None:
            parser.error("packaging requires --mapping and --fallback-root")
        report = package_runtime(arguments.app_bundle, arguments.mapping, arguments.fallback_root)
    print(json.dumps(report, sort_keys=True))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeLicenseError, ValueError) as error:
        print(f"libmpv runtime license error: {error}", file=sys.stderr)
        raise SystemExit(1)
