#!/usr/bin/env python3
"""Audit a clean public-shell repository for source-release blockers."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import subprocess
import sys
from typing import Any

from audit_provider_public_boundary import build_report


REQUIRED_FILES = (
    "LICENSE",
    "provider-sdk/LICENSE",
    "NetVplayer/Sources/ProviderSandboxLauncher/main.swift",
    ".github/ISSUE_TEMPLATE/user-feedback.yml",
    ".github/ISSUE_TEMPLATE/config.yml",
    ".github/workflows/provider-public-shell.yml",
    "docs/data/provider-public-boundary-v1.json",
    "script/build_provider_sandbox_launcher.py",
    "script/validate_provider_sandbox.py",
    "script/test_provider_app_sandbox.py",
)
INTERNAL_ONLY_FILES = (
    ".github/workflows/provider-runtime-poc.yml",
    "script/audit_provider_private_source.py",
    "script/build_all_private_java_providers.sh",
    "script/export_provider_private_source.py",
    "script/run_provider_private_source_gate.py",
    "script/test_provider_runtime_matrix.py",
    "script/test_provider_runtime_packages.py",
    "script/test_provider_catalog.py",
    "script/validate_provider_catalog.py",
    "script/verify_bili_quickjs_live.py",
    "script/verify_generic_python_provider.py",
    "script/verify_hmys_java_provider.py",
)
PUBLIC_RELEASE_DOCUMENTS = {
    "docs/data/provider-public-boundary-v1.json",
    "docs/data/torrent-bridge-license-audit-2026-08-18.json",
    "docs/design/player-ui/assets/w700d1q75cms.jpg",
}
INTERNAL_PUBLICATION_PREFIXES = (
    "NetVplayer/Docs/",
    "NetVplayer/Resources/UI_Mockups/",
    "docs/",
)
INTERNAL_PUBLICATION_FILES = {
    "NetVplayer/README.md",
    "NetVplayer/PRD.md",
    "NetVplayer/TASK.md",
    "NetVplayer/migration_plan.md",
    "NetVplayer/ui_design_guidelines.md",
}
FORBIDDEN_BINARY_SUFFIXES = (
    ".dex",
    ".dylib",
    ".jar",
    ".mobileprovision",
    ".p12",
    ".pem",
    ".pfx",
    ".so",
)
FORBIDDEN_BUILD_PARTS = {
    ".build",
    "DerivedData",
    "__pycache__",
    "build",
    "dist",
    "node_modules",
}
SECRET_PATTERNS = {
    "aws-access-key": re.compile("AKIA" + r"[0-9A-Z]{16}"),
    "github-token": re.compile("gh" + r"[pousr]_[A-Za-z0-9_]{20,}"),
    "openai-style-key": re.compile("sk" + r"-[A-Za-z0-9]{20,}"),
    "slack-token": re.compile("xox" + r"[baprs]-[A-Za-z0-9-]{10,}"),
}
PRIVATE_KEY_BLOCK_PATTERN = re.compile(
    r"-----BEGIN (?P<kind>(?:RSA |EC |OPENSSH )?PRIVATE KEY)-----"
    r"\s+(?P<body>[A-Za-z0-9+/=\s]{80,}?)\s+"
    r"-----END (?P=kind)-----",
    re.MULTILINE,
)


class PublicReleaseAuditError(RuntimeError):
    pass


def git(repo: Path, *arguments: str) -> str:
    result = subprocess.run(
        ["git", *arguments],
        cwd=repo,
        text=True,
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip()
        raise PublicReleaseAuditError(f"git {' '.join(arguments)} failed: {detail}")
    return result.stdout


def tracked_paths(repo: Path) -> list[str]:
    return sorted(path for path in git(repo, "ls-files", "-z").split("\0") if path)


def secret_findings(repo: Path, paths: list[str]) -> list[dict[str, Any]]:
    findings: list[dict[str, Any]] = []
    for relative in paths:
        path = repo / relative
        if path.is_symlink() or not path.is_file():
            continue
        try:
            content = path.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            continue
        for match in PRIVATE_KEY_BLOCK_PATTERN.finditer(content):
            findings.append({
                "path": relative,
                "line": content.count("\n", 0, match.start()) + 1,
                "kind": "private-key",
            })
        for line_number, line in enumerate(content.splitlines(), start=1):
            for kind, pattern in SECRET_PATTERNS.items():
                if pattern.search(line):
                    findings.append({"path": relative, "line": line_number, "kind": kind})
    return findings


def build_release_report(repo: Path) -> dict[str, Any]:
    repo = repo.resolve(strict=True)
    boundary = build_report(repo)
    paths = tracked_paths(repo)
    missing_required = [path for path in REQUIRED_FILES if path not in paths]
    license_files_present = all(path in paths for path in ("LICENSE", "provider-sdk/LICENSE"))
    sdk_license_matches_root = license_files_present and (
        (repo / "LICENSE").read_bytes() == (repo / "provider-sdk/LICENSE").read_bytes()
    )
    internal_only = [path for path in INTERNAL_ONLY_FILES if path in paths]
    internal_publication = [
        path for path in paths
        if path in INTERNAL_PUBLICATION_FILES
        or (
            any(path.startswith(prefix) for prefix in INTERNAL_PUBLICATION_PREFIXES)
            and path not in PUBLIC_RELEASE_DOCUMENTS
        )
    ]
    binary_files = [
        path for path in paths if Path(path).suffix.lower() in FORBIDDEN_BINARY_SUFFIXES
    ]
    build_artifacts = [
        path for path in paths if any(part in FORBIDDEN_BUILD_PARTS for part in Path(path).parts)
    ]
    symlinks = [path for path in paths if (repo / path).is_symlink()]
    secrets = secret_findings(repo, paths)
    blockers: list[str] = []
    if not boundary["summary"]["release_ready"]:
        blockers.append("provider-boundary-not-release-ready")
    if missing_required:
        blockers.append("missing-required-public-files")
    if license_files_present and not sdk_license_matches_root:
        blockers.append("provider-sdk-license-mismatch")
    if internal_only:
        blockers.append("internal-migration-tooling-present")
    if internal_publication:
        blockers.append("internal-publication-artifacts-present")
    if binary_files:
        blockers.append("forbidden-executable-binaries")
    if build_artifacts:
        blockers.append("tracked-build-artifacts")
    if symlinks:
        blockers.append("tracked-symlinks")
    if secrets:
        blockers.append("potential-secrets")
    return {
        "schema_version": 1,
        "release_ready": not blockers,
        "tracked_files": len(paths),
        "missing_required_files": missing_required,
        "provider_sdk_license_matches_root": sdk_license_matches_root,
        "internal_only_files": internal_only,
        "internal_publication_artifacts": internal_publication,
        "forbidden_binary_files": binary_files,
        "tracked_build_artifacts": build_artifacts,
        "tracked_symlinks": symlinks,
        "secret_findings": secrets,
        "blocking_reasons": blockers,
        "provider_boundary": boundary["summary"],
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", type=Path, default=Path("."))
    arguments = parser.parse_args()
    report = build_release_report(arguments.repo)
    print(json.dumps(report, ensure_ascii=False, sort_keys=True))
    return 0 if report["release_ready"] else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, PublicReleaseAuditError, ValueError) as error:
        print(f"Provider public release audit: {error}", file=sys.stderr)
        raise SystemExit(1)
