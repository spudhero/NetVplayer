#!/usr/bin/env python3
"""Audit whether the current repository can be published as the public shell.

The report is intentionally conservative. It classifies existing source and
history blockers but does not delete, move, export, or publish any file.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
from typing import Any


FONGMI_PREFIX = "FongMi/"
PRIVATE_PROVIDER_STAGING_PREFIX = "private-providers/"
SPIDER_ENGINE_PREFIX = "NetVplayer/Sources/SpiderEngine/"
PUBLIC_PROVIDER_SOURCE_FILES = (
    f"{SPIDER_ENGINE_PREFIX}NativeProviders.swift",
)
MIXED_BOUNDARY_FILES: tuple[str, ...] = ()
LEGACY_EXECUTABLE_LOADERS: tuple[str, ...] = ()
ANDROID_BINARY_SUFFIXES = (".dex", ".jar", ".so")


class BoundaryAuditError(RuntimeError):
    pass


def git(repo: Path, *arguments: str) -> str:
    result = subprocess.run(
        ["git", *arguments],
        cwd=repo,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip()
        raise BoundaryAuditError(f"git {' '.join(arguments)} failed: {detail}")
    return result.stdout


def tracked_paths(repo: Path) -> list[str]:
    return sorted(path for path in git(repo, "ls-files", "-z").split("\0") if path)


def forbidden_history(repo: Path) -> list[str]:
    shallow = git(repo, "rev-parse", "--is-shallow-repository").strip()
    if shallow == "true":
        raise BoundaryAuditError("public boundary audit requires complete Git history")
    return [line for line in git(repo, "log", "--format=%H", "--", "FongMi").splitlines() if line]


def path_digest(paths: list[str]) -> str:
    digest = hashlib.sha256()
    for path in sorted(paths):
        digest.update(path.encode("utf-8"))
        digest.update(b"\0")
    return digest.hexdigest()


def content_digest(repo: Path, paths: list[str]) -> str:
    digest = hashlib.sha256()
    root = repo.resolve(strict=True)
    for relative in sorted(paths):
        path = repo / relative
        if path.is_symlink():
            raise BoundaryAuditError(f"boundary source cannot be a symlink: {relative}")
        if not path.is_file():
            raise BoundaryAuditError(f"tracked boundary source is missing: {relative}")
        try:
            path.resolve(strict=True).relative_to(root)
        except ValueError as error:
            raise BoundaryAuditError(f"boundary source escapes repository: {relative}") from error
        digest.update(relative.encode("utf-8"))
        digest.update(b"\0")
        digest.update(path.read_bytes())
        digest.update(b"\0")
    return digest.hexdigest()


def is_private_provider_source(path: str) -> bool:
    if not path.startswith(SPIDER_ENGINE_PREFIX) or not path.endswith(".swift"):
        return False
    name = Path(path).name
    return (
        "NativeProvider" in name
        and path not in PUBLIC_PROVIDER_SOURCE_FILES
        and path not in MIXED_BOUNDARY_FILES
    )


def is_private_provider_staging_file(path: str) -> bool:
    return path.startswith(PRIVATE_PROVIDER_STAGING_PREFIX)


def group(paths: list[str], *, sample_limit: int | None = None) -> dict[str, Any]:
    selected = sorted(paths)
    result: dict[str, Any] = {
        "count": len(selected),
        "path_sha256": path_digest(selected),
    }
    if sample_limit is None:
        result["paths"] = selected
    else:
        result["sample_paths"] = selected[:sample_limit]
        result["sample_truncated"] = len(selected) > sample_limit
    return result


def build_report(repo: Path) -> dict[str, Any]:
    repo = repo.resolve(strict=True)
    paths = tracked_paths(repo)
    history = forbidden_history(repo)
    fongmi = [path for path in paths if path.startswith(FONGMI_PREFIX)]
    android_binaries = [
        path for path in fongmi if Path(path).suffix.lower() in ANDROID_BINARY_SUFFIXES
    ]
    private_sources = [path for path in paths if is_private_provider_source(path)]
    private_staging = [path for path in paths if is_private_provider_staging_file(path)]
    mixed = [path for path in MIXED_BOUNDARY_FILES if path in paths]
    legacy = [path for path in LEGACY_EXECUTABLE_LOADERS if path in paths]
    blockers: list[str] = []
    if fongmi:
        blockers.append("tracked-fongmi-reference")
    if history:
        blockers.append("fongmi-present-in-git-history")
    if private_sources:
        blockers.append("site-specific-swift-providers")
    if private_staging:
        blockers.append("private-provider-staging-files")
    if mixed:
        blockers.append("mixed-public-private-source-files")
    if legacy:
        blockers.append("legacy-in-process-executable-loaders")

    private_group = group(private_sources)
    private_group["content_sha256"] = content_digest(repo, private_sources)
    private_staging_group = group(private_staging)
    private_staging_group["content_sha256"] = content_digest(repo, private_staging)
    mixed_group = group(mixed)
    mixed_group["content_sha256"] = content_digest(repo, mixed)
    legacy_group = group(legacy)
    legacy_group["content_sha256"] = content_digest(repo, legacy)
    return {
        "schema_version": 1,
        "policy": {
            "target": "clean-public-shell-repository",
            "forbidden_reference_prefixes": [FONGMI_PREFIX],
            "android_binary_suffixes": list(ANDROID_BINARY_SUFFIXES),
            "private_provider_detection": "SpiderEngine Swift filename containing NativeProvider, except reviewed public adapters",
            "private_provider_staging_prefix": PRIVATE_PROVIDER_STAGING_PREFIX,
            "public_provider_sources": list(PUBLIC_PROVIDER_SOURCE_FILES),
            "history_requirement": "complete",
        },
        "summary": {
            "tracked_fongmi_files": len(fongmi),
            "fongmi_history_commits": len(history),
            "android_binary_files": len(android_binaries),
            "private_provider_source_files": len(private_sources),
            "private_provider_staging_files": len(private_staging),
            "mixed_boundary_source_files": len(mixed),
            "legacy_executable_loader_files": len(legacy),
            "release_ready": not blockers,
        },
        "history": {
            "forbidden_path": "FongMi",
            "commit_count": len(history),
            "newest_commit": history[0] if history else None,
            "oldest_commit": history[-1] if history else None,
        },
        "groups": {
            "tracked_fongmi_reference": group(fongmi, sample_limit=20),
            "android_binaries": group(android_binaries),
            "private_provider_sources": private_group,
            "private_provider_staging": private_staging_group,
            "mixed_boundary_sources": mixed_group,
            "legacy_executable_loaders": legacy_group,
        },
        "blocking_reasons": blockers,
        "next_actions": [
            "Create the public shell from a clean export rather than the current Git history.",
            "Move site-specific Swift Providers and their tests/fixtures behind the signed helper protocol.",
            "Move LegacyNativeProviderRegistration.swift into the private Provider repository after signed packages replace its aliases.",
            "Move private-providers staging files to the authorized private repository before creating the public export.",
            "Keep the public shell free of in-process executable loaders; signed helper processes are the only dynamic Provider path.",
        ],
    }


def validate_report(report: dict[str, Any]) -> list[str]:
    errors: list[str] = []
    if report.get("schema_version") != 1:
        errors.append("schema_version must be 1")
    summary = report.get("summary")
    groups = report.get("groups")
    blockers = report.get("blocking_reasons")
    if not isinstance(summary, dict):
        return errors + ["summary must be an object"]
    if not isinstance(groups, dict):
        return errors + ["groups must be an object"]
    if not isinstance(blockers, list) or not all(isinstance(value, str) for value in blockers):
        errors.append("blocking_reasons must be a string array")
        blockers = []
    count_mapping = {
        "tracked_fongmi_files": "tracked_fongmi_reference",
        "android_binary_files": "android_binaries",
        "private_provider_source_files": "private_provider_sources",
        "private_provider_staging_files": "private_provider_staging",
        "mixed_boundary_source_files": "mixed_boundary_sources",
        "legacy_executable_loader_files": "legacy_executable_loaders",
    }
    for summary_key, group_key in count_mapping.items():
        group_value = groups.get(group_key)
        if not isinstance(group_value, dict):
            errors.append(f"groups.{group_key} must be an object")
        elif summary.get(summary_key) != group_value.get("count"):
            errors.append(f"summary.{summary_key} must match groups.{group_key}.count")
    ready = summary.get("release_ready")
    if not isinstance(ready, bool):
        errors.append("summary.release_ready must be boolean")
    elif ready != (len(blockers) == 0):
        errors.append("summary.release_ready must be false while blockers exist")
    history = report.get("history", {})
    if summary.get("fongmi_history_commits") != history.get("commit_count"):
        errors.append("summary.fongmi_history_commits must match history.commit_count")
    if summary.get("tracked_fongmi_files", 0) > 0 and "tracked-fongmi-reference" not in blockers:
        errors.append("tracked FongMi files require a blocker")
    if summary.get("fongmi_history_commits", 0) > 0 and "fongmi-present-in-git-history" not in blockers:
        errors.append("FongMi history requires a blocker")
    if summary.get("private_provider_staging_files", 0) > 0 and "private-provider-staging-files" not in blockers:
        errors.append("private Provider staging files require a blocker")
    if ready and any(summary.get(key, 0) != 0 for key in count_mapping):
        errors.append("release-ready report cannot retain boundary files")
    return errors


def serialized(report: dict[str, Any]) -> str:
    return json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", type=Path, default=Path("."))
    parser.add_argument("--output", type=Path)
    parser.add_argument("--check", type=Path)
    arguments = parser.parse_args()
    report = build_report(arguments.repo)
    errors = validate_report(report)
    if errors:
        raise BoundaryAuditError("; ".join(errors))
    content = serialized(report)
    if arguments.check:
        expected = arguments.check.read_text(encoding="utf-8")
        if expected != content:
            raise BoundaryAuditError(f"public boundary report drifted; regenerate {arguments.check}")
    if arguments.output:
        arguments.output.parent.mkdir(parents=True, exist_ok=True)
        arguments.output.write_text(content, encoding="utf-8")
    if not arguments.output and not arguments.check:
        print(content, end="")
    else:
        print(json.dumps({"ok": True, **report["summary"]}, sort_keys=True))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (BoundaryAuditError, OSError, ValueError, json.JSONDecodeError) as error:
        print(f"Provider public boundary audit: {error}", file=sys.stderr)
        raise SystemExit(1)
