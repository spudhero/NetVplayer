#!/usr/bin/env python3
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import plistlib
import re
from urllib.parse import quote
import uuid


MACH_O_MAGICS = {
    b"\xfe\xed\xfa\xce",
    b"\xce\xfa\xed\xfe",
    b"\xfe\xed\xfa\xcf",
    b"\xcf\xfa\xed\xfe",
    b"\xca\xfe\xba\xbe",
    b"\xbe\xba\xfe\xca",
    b"\xca\xfe\xba\xbf",
    b"\xbf\xba\xfe\xca",
}


class SBOMError(RuntimeError):
    pass


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def read_json(path: Path) -> dict[str, object]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise SBOMError(f"cannot read JSON {path}: {error}") from error
    if not isinstance(value, dict):
        raise SBOMError(f"expected JSON object in {path}")
    return value


def is_mach_o(path: Path) -> bool:
    if path.is_symlink() or not path.is_file():
        return False
    try:
        with path.open("rb") as handle:
            return handle.read(4) in MACH_O_MAGICS
    except OSError:
        return False


def mach_o_inventory(app_bundle: Path) -> list[dict[str, object]]:
    inventory = []
    for path in sorted(app_bundle.rglob("*")):
        if not is_mach_o(path):
            continue
        relative = path.relative_to(app_bundle).as_posix()
        inventory.append({
            "path": relative,
            "sha256": sha256(path),
            "size": path.stat().st_size,
        })
    if not inventory:
        raise SBOMError(f"no Mach-O files found in {app_bundle}")
    return inventory


def component_key(kind: str, name: str, version: str, location: str = "") -> str:
    return f"{kind}:{name}:{version}:{location}"


def swift_components(package_resolved: Path | None) -> list[dict[str, str]]:
    if package_resolved is None or not package_resolved.is_file():
        return []
    pins = read_json(package_resolved).get("pins", [])
    components = []
    for pin in pins if isinstance(pins, list) else []:
        if not isinstance(pin, dict):
            continue
        state = pin.get("state") if isinstance(pin.get("state"), dict) else {}
        name = str(pin.get("identity") or "unknown")
        version = str(state.get("version") or state.get("revision") or "unknown")
        location = str(pin.get("location") or "")
        revision = str(state.get("revision") or "")
        components.append({
            "key": component_key("swift", name, version, location),
            "kind": "library",
            "name": name,
            "version": version,
            "purl": f"pkg:swift/{name}@{version}",
            "source": location,
            "revision": revision,
            "license": "NOASSERTION",
        })
    return components


def npm_components(lock_path: Path) -> list[dict[str, str]]:
    if not lock_path.is_file():
        return []
    packages = read_json(lock_path).get("packages", {})
    components = []
    for package_path, metadata in sorted(packages.items()) if isinstance(packages, dict) else []:
        if not package_path or not isinstance(metadata, dict):
            continue
        name = str(metadata.get("name") or package_path.rsplit("node_modules/", 1)[-1])
        version = str(metadata.get("version") or "unknown")
        license_value = metadata.get("license")
        license_name = license_value if isinstance(license_value, str) and license_value else "NOASSERTION"
        components.append({
            "key": component_key("npm", name, version),
            "kind": "library",
            "name": name,
            "version": version,
            "purl": f"pkg:npm/{quote(name, safe='/')}@{version}",
            "source": str(metadata.get("resolved") or ""),
            "revision": "",
            "license": license_name,
        })
    return components


def libmpv_components(manifest_path: Path) -> list[dict[str, str]]:
    if not manifest_path.is_file():
        return []
    raw_components = read_json(manifest_path).get("components", [])
    components = []
    for item in raw_components if isinstance(raw_components, list) else []:
        if not isinstance(item, dict):
            continue
        name = str(item.get("formula") or item.get("name") or "unknown")
        version = str(item.get("version") or "unknown")
        source = item.get("source") if isinstance(item.get("source"), dict) else {}
        source_url = str(source.get("url") or item.get("homepage") or "")
        license_name = str(item.get("license") or item.get("license_expression") or "NOASSERTION")
        components.append({
            "key": component_key("homebrew", name, version, source_url),
            "kind": "library",
            "name": name,
            "version": version,
            "purl": f"pkg:brew/{name}@{version}",
            "source": source_url,
            "revision": str(source.get("revision") or ""),
            "license": license_name,
        })
    return components


def node_runtime_components(manifest_path: Path) -> list[dict[str, str]]:
    if not manifest_path.is_file():
        return []
    manifest = read_json(manifest_path)
    name = str(manifest.get("name") or "Node.js")
    version = str(manifest.get("version") or "unknown")
    source = str(manifest.get("source") or "")
    license_name = str(manifest.get("license") or "NOASSERTION")
    architecture = str(manifest.get("architecture") or "unknown")
    return [{
        "key": component_key("runtime", name, version, architecture),
        "kind": "application",
        "name": name,
        "version": version,
        "purl": f"pkg:generic/nodejs@{version}",
        "source": source,
        "revision": str(manifest.get("artifact_sha256") or ""),
        "license": license_name,
    }]


def quickjs_runtime_components(manifest_path: Path) -> list[dict[str, str]]:
    if not manifest_path.is_file():
        return []
    manifest = read_json(manifest_path)
    name = str(manifest.get("name") or "QuickJS")
    version = str(manifest.get("version") or "unknown")
    source = str(manifest.get("source") or "")
    license_name = str(manifest.get("license") or "NOASSERTION")
    architecture = str(manifest.get("architecture") or "unknown")
    return [{
        "key": component_key("runtime", name, version, architecture),
        "kind": "application",
        "name": name,
        "version": version,
        "purl": f"pkg:generic/quickjs@{version}",
        "source": source,
        "revision": str(manifest.get("artifact_sha256") or ""),
        "license": license_name,
    }]


def deduplicated_components(values: list[dict[str, str]]) -> list[dict[str, str]]:
    unique = {value["key"]: value for value in values}
    return [unique[key] for key in sorted(unique)]


def spdx_id(prefix: str, value: str) -> str:
    safe = re.sub(r"[^A-Za-z0-9.-]+", "-", value).strip("-") or "unknown"
    suffix = hashlib.sha256(value.encode("utf-8")).hexdigest()[:10]
    return f"SPDXRef-{prefix}-{safe[:80]}-{suffix}"


def cyclonedx_license(value: str) -> list[dict[str, dict[str, str]]]:
    if not value or value == "NOASSERTION":
        return []
    return [{"license": {"name": value}}]


def create_documents(
    app_bundle: Path,
    package_resolved: Path | None,
) -> tuple[dict[str, object], dict[str, object], dict[str, object]]:
    info_path = app_bundle / "Contents/Info.plist"
    if not info_path.is_file():
        raise SBOMError(f"missing Info.plist in {app_bundle}")
    with info_path.open("rb") as handle:
        info = plistlib.load(handle)

    name = str(info.get("CFBundleName") or app_bundle.stem)
    version = str(info.get("CFBundleShortVersionString") or info.get("CFBundleVersion") or "unknown")
    bundle_id = str(info.get("CFBundleIdentifier") or "unknown")
    mach_o_files = mach_o_inventory(app_bundle)
    torrent_lock = app_bundle / "Contents/Resources/TorrentBridge/package-lock.json"
    libmpv_manifest = app_bundle / "Contents/Resources/ThirdPartyLicenses/libmpv-runtime.json"
    node_runtime_manifest = app_bundle / "Contents/Resources/NodeRuntime/runtime-manifest.json"
    quickjs_runtime_manifest = app_bundle / "Contents/Resources/QuickJSRuntime/runtime-manifest.json"
    components = deduplicated_components(
        swift_components(package_resolved)
        + npm_components(torrent_lock)
        + libmpv_components(libmpv_manifest)
        + node_runtime_components(node_runtime_manifest)
        + quickjs_runtime_components(quickjs_runtime_manifest)
    )

    evidence = {
        "schema_version": 1,
        "application": {"name": name, "version": version, "bundle_id": bundle_id},
        "mach_o_files": mach_o_files,
        "mach_o_path_set": [item["path"] for item in mach_o_files],
        "inputs": {
            "package_resolved_sha256": sha256(package_resolved) if package_resolved and package_resolved.is_file() else None,
            "torrent_package_lock_sha256": sha256(torrent_lock) if torrent_lock.is_file() else None,
            "libmpv_runtime_manifest_sha256": sha256(libmpv_manifest) if libmpv_manifest.is_file() else None,
            "node_runtime_manifest_sha256": sha256(node_runtime_manifest) if node_runtime_manifest.is_file() else None,
            "quickjs_runtime_manifest_sha256": sha256(quickjs_runtime_manifest) if quickjs_runtime_manifest.is_file() else None,
        },
        "component_count": len(components),
    }
    inventory_digest = hashlib.sha256(
        json.dumps(evidence, sort_keys=True, separators=(",", ":")).encode("utf-8")
    ).hexdigest()
    created = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
    root_spdx = "SPDXRef-Package-NetVplayer"
    root_bom_ref = f"pkg:generic/{bundle_id}@{version}"

    spdx_packages = [{
        "name": name,
        "SPDXID": root_spdx,
        "versionInfo": version,
        "downloadLocation": "NOASSERTION",
        "filesAnalyzed": False,
        "licenseConcluded": "NOASSERTION",
        "licenseDeclared": "NOASSERTION",
        "copyrightText": "NOASSERTION",
        "externalRefs": [{
            "referenceCategory": "PACKAGE-MANAGER",
            "referenceType": "purl",
            "referenceLocator": root_bom_ref,
        }],
    }]
    relationships = [{
        "spdxElementId": "SPDXRef-DOCUMENT",
        "relationshipType": "DESCRIBES",
        "relatedSpdxElement": root_spdx,
    }]
    for component in components:
        identifier = spdx_id("Package", component["key"])
        spdx_packages.append({
            "name": component["name"],
            "SPDXID": identifier,
            "versionInfo": component["version"],
            "downloadLocation": component["source"] or "NOASSERTION",
            "filesAnalyzed": False,
            "licenseConcluded": "NOASSERTION",
            "licenseDeclared": "NOASSERTION",
            "copyrightText": "NOASSERTION",
            "externalRefs": [{
                "referenceCategory": "PACKAGE-MANAGER",
                "referenceType": "purl",
                "referenceLocator": component["purl"],
            }],
        })
        relationships.append({
            "spdxElementId": root_spdx,
            "relationshipType": "DEPENDS_ON",
            "relatedSpdxElement": identifier,
        })

    spdx_files = []
    for item in mach_o_files:
        identifier = spdx_id("File", str(item["path"]))
        spdx_files.append({
            "fileName": f"./{item['path']}",
            "SPDXID": identifier,
            "checksums": [{"algorithm": "SHA256", "checksumValue": item["sha256"]}],
            "fileTypes": ["BINARY"],
            "licenseConcluded": "NOASSERTION",
            "copyrightText": "NOASSERTION",
        })
        relationships.append({
            "spdxElementId": root_spdx,
            "relationshipType": "CONTAINS",
            "relatedSpdxElement": identifier,
        })

    spdx = {
        "spdxVersion": "SPDX-2.3",
        "dataLicense": "CC0-1.0",
        "SPDXID": "SPDXRef-DOCUMENT",
        "name": f"{name}-{version}",
        "documentNamespace": f"https://netvplayer.local/spdx/{inventory_digest}",
        "creationInfo": {"created": created, "creators": ["Tool: NetVplayer-generate-release-sbom"]},
        "packages": spdx_packages,
        "files": spdx_files,
        "relationships": relationships,
    }

    cdx_components = []
    dependency_refs = []
    for component in components:
        ref = component["purl"]
        dependency_refs.append(ref)
        cdx_component = {
            "type": component["kind"],
            "bom-ref": ref,
            "name": component["name"],
            "version": component["version"],
            "purl": component["purl"],
        }
        licenses = cyclonedx_license(component["license"])
        if licenses:
            cdx_component["licenses"] = licenses
        if component["source"]:
            cdx_component["externalReferences"] = [{"type": "distribution", "url": component["source"]}]
        cdx_components.append(cdx_component)
    for item in mach_o_files:
        ref = f"file:{item['path']}"
        dependency_refs.append(ref)
        cdx_components.append({
            "type": "file",
            "bom-ref": ref,
            "name": Path(str(item["path"])).name,
            "hashes": [{"alg": "SHA-256", "content": item["sha256"]}],
            "properties": [{"name": "netvplayer:bundle-path", "value": item["path"]}],
        })

    cyclonedx = {
        "bomFormat": "CycloneDX",
        "specVersion": "1.6",
        "serialNumber": f"urn:uuid:{uuid.uuid5(uuid.NAMESPACE_URL, inventory_digest)}",
        "version": 1,
        "metadata": {
            "timestamp": created,
            "tools": {"components": [{"type": "application", "name": "NetVplayer SBOM Generator"}]},
            "component": {
                "type": "application",
                "bom-ref": root_bom_ref,
                "name": name,
                "version": version,
                "purl": root_bom_ref,
            },
        },
        "components": cdx_components,
        "dependencies": [{"ref": root_bom_ref, "dependsOn": sorted(dependency_refs)}],
    }
    return spdx, cyclonedx, evidence


def generate_sbom(app_bundle: Path, package_resolved: Path | None, output_directory: Path) -> dict[str, Path]:
    app_bundle = app_bundle.resolve()
    package_resolved = package_resolved.resolve() if package_resolved else None
    spdx, cyclonedx, evidence = create_documents(app_bundle, package_resolved)
    output_directory.mkdir(parents=True, exist_ok=True)
    outputs = {
        "spdx": output_directory / "NetVplayer.spdx.json",
        "cyclonedx": output_directory / "NetVplayer.cdx.json",
        "evidence": output_directory / "NetVplayer.build-artifacts.json",
    }
    for key, value in (("spdx", spdx), ("cyclonedx", cyclonedx), ("evidence", evidence)):
        outputs[key].write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return outputs


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate release SBOMs from a built NetVplayer.app")
    parser.add_argument("--app-bundle", type=Path, required=True)
    parser.add_argument("--package-resolved", type=Path)
    parser.add_argument("--output-directory", type=Path, required=True)
    args = parser.parse_args()
    try:
        outputs = generate_sbom(args.app_bundle, args.package_resolved, args.output_directory)
    except SBOMError as error:
        parser.error(str(error))
    print("Generated release SBOM: " + ", ".join(str(path) for path in outputs.values()))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
