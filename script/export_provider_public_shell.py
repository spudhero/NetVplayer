#!/usr/bin/env python3
"""Create a buildable, one-commit public-shell export from the migration repository."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from typing import Any

from audit_provider_public_boundary import build_report, is_private_provider_source, serialized


FORBIDDEN_PREFIXES = ("FongMi/", "private-providers/")
PUBLIC_RELEASE_DOCUMENTS = {
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
PRIVATE_TEST_FILES = {
    "NetVplayer/Tests/ConfigEngineTests/BaiduLivePlaybackTests.swift",
    "NetVplayer/Tests/ConfigEngineTests/ConfigEngineTests.swift",
    "NetVplayer/Tests/ConfigEngineTests/ExternalSourceCompatibilityTests.swift",
    "NetVplayer/Tests/ConfigEngineTests/NewCzBrowserSessionTests.swift",
    "NetVplayer/Tests/ConfigEngineTests/RealVodPlaybackAuditTests.swift",
    "NetVplayer/Tests/ConfigEngineTests/VodCardRoutingTests.swift",
}
INTERNAL_MIGRATION_FILES = {
    "script/audit_all_provider_release_candidates.py",
    "script/build_all_private_java_providers.sh",
    "script/build_diagnostic_provider_release.py",
    "script/publish_diagnostic_provider_release.py",
    "script/test_diagnostic_release.py",
    "script/build_configurable_provider_release.py",
    "script/build_catalog_python_provider_release.py",
    "script/build_catalog_java_provider_release.py",
    "script/build_catalog_script_provider_release.py",
    "script/publish_configurable_provider_release.py",
    "script/publish_catalog_provider_release.py",
    "script/test_configurable_provider_release.py",
    "script/test_publish_catalog_provider_release.py",
    "script/test_catalog_java_provider_release.py",
    "script/test_catalog_script_provider_release.py",
    "script/test_provider_build_distribution.py",
    "script/test_validate_provider_source_policy.py",
    "script/validate_provider_source_policy.py",
    "script/templates/provider-diagnostic-release.yml",
    ".github/workflows/provider-runtime-poc.yml",
    "script/analyze_fongmi_home_posters.py",
    "script/audit_android_provider.py",
    "script/audit_fongmi_source_catalog.py",
    "script/audit_netvplayer_fongmi_advantage_playback.py",
    "script/audit_provider_private_source.py",
    "script/audit_legacy_provider_disposition.py",
    "script/capture_fongmi_guard.sh",
    "script/drive_fongmi_guard.py",
    "script/export_fongmi_flows.py",
    "script/export_provider_private_source.py",
    "script/fongmi_capture_addon.py",
    "script/fongmi_guard_targets.json",
    "script/inventory_fongmi_provider_candidates.py",
    "script/render_fongmi_compatibility_audit.py",
    "script/render_netvplayer_fongmi_advantage_playback_audit.py",
    "script/run_provider_private_source_gate.py",
    "script/templates/provider-private-source.yml",
    "script/test_audit_fongmi_source_catalog.py",
    "script/test_audit_legacy_provider_disposition.py",
    "script/test_audit_netvplayer_fongmi_advantage_playback.py",
    "script/test_anime1_python_verification.py",
    "script/test_app99_java_verification.py",
    "script/test_appdrama_java_verification.py",
    "script/test_appsx_java_verification.py",
    "script/test_appgz_java_verification.py",
    "script/test_livegz_java_verification.py",
    "script/test_tingshu275_java_verification.py",
    "script/test_auete_python_verification.py",
    "script/test_ibox_appapi_python_verification.py",
    "script/test_hbpq_python_verification.py",
    "script/test_doubao_python_verification.py",
    "script/test_duboku_python_verification.py",
    "script/test_ygp_python_verification.py",
    "script/test_sixv_python_verification.py",
    "script/test_libvio_python_verification.py",
    "script/test_dytt_python_verification.py",
    "script/test_wwgz_python_verification.py",
    "script/test_kanqiu_python_verification.py",
    "script/test_bili_java_verification.py",
    "script/test_bili_live_python_verification.py",
    "script/test_first_aid_python_verification.py",
    "script/test_hbpianku8_java_verification.py",
    "script/test_inventory_fongmi_provider_candidates.py",
    "script/test_private_anime1_provider.py",
    "script/test_private_app99_provider.py",
    "script/test_private_appdrama_provider.py",
    "script/test_private_appsx_provider.py",
    "script/test_private_appgz_provider.py",
    "script/test_private_livegz_provider.py",
    "script/test_private_tingshu275_provider.py",
    "script/test_private_bili_live_provider.py",
    "script/test_private_bili_script_providers.py",
    "script/test_private_auete_provider.py",
    "script/test_private_ibox_appapi_provider.py",
    "script/test_private_hbpq_provider.py",
    "script/test_private_douban_frodo_provider.py",
    "script/test_private_apptt_provider.py",
    "script/test_private_doubao_provider.py",
    "script/test_private_duboku_provider.py",
    "script/test_private_ygp_provider.py",
    "script/test_private_sixv_provider.py",
    "script/test_private_nmyswv_provider.py",
    "script/test_private_nmvod_provider.py",
    "script/test_private_ycyz_provider.py",
    "script/test_private_music_provider.py",
    "script/test_private_wcai_provider.py",
    "script/test_private_alllive_provider.py",
    "script/test_private_dm84_provider.py",
    "script/test_private_libvio_provider.py",
    "script/test_private_dytt_provider.py",
    "script/test_private_wwgz_provider.py",
    "script/test_private_kanqiu_provider.py",
    "script/test_private_first_aid_provider.py",
    "script/test_private_hbpianku8_provider.py",
    "script/test_private_tangdou_provider.py",
    "script/test_private_tuxiaobei_provider.py",
    "script/test_provider_runtime_matrix.py",
    "script/test_provider_runtime_matrix_helpers.py",
    "script/test_provider_runtime_packages.py",
    "script/test_provider_runtime_packages_helpers.py",
    "script/test_provider_production_release_gate.py",
    "script/test_provider_catalog.py",
    "script/validate_provider_catalog.py",
    "script/test_export_provider_private_source.py",
    "script/test_tangdou_python_verification.py",
    "script/test_tuxiaobei_python_verification.py",
    "script/verify_anime1_python_provider.py",
    "script/verify_bili_quickjs_live.py",
    "script/verify_generic_python_provider.py",
    "script/verify_app99_java_provider.py",
    "script/verify_appdrama_java_provider.py",
    "script/verify_appsx_java_provider.py",
    "script/verify_appgz_java_provider.py",
    "script/verify_livegz_java_provider.py",
    "script/verify_tingshu275_java_provider.py",
    "script/verify_bili_java_provider.py",
    "script/verify_auete_python_provider.py",
    "script/verify_ibox_appapi_python_provider.py",
    "script/verify_hbpq_python_provider.py",
    "script/verify_doubao_python_provider.py",
    "script/verify_duboku_python_provider.py",
    "script/verify_ygp_python_provider.py",
    "script/verify_sixv_python_provider.py",
    "script/verify_nmyswv_python_provider.py",
    "script/test_nmyswv_python_verification.py",
    "script/verify_nmvod_python_provider.py",
    "script/test_nmvod_python_verification.py",
    "script/test_ycyz_python_verification.py",
    "script/test_music_python_verification.py",
    "script/test_wcai_python_verification.py",
    "script/test_alllive_python_verification.py",
    "script/test_dm84_python_verification.py",
    "script/verify_ycyz_python_provider.py",
    "script/verify_music_python_provider.py",
    "script/verify_wcai_python_provider.py",
    "script/verify_alllive_python_provider.py",
    "script/verify_dm84_python_provider.py",
    "script/verify_libvio_python_provider.py",
    "script/verify_dytt_python_provider.py",
    "script/verify_wwgz_python_provider.py",
    "script/verify_kanqiu_python_provider.py",
    "script/verify_bili_live_python_provider.py",
    "script/verify_bili_script_provider.py",
    "script/verify_first_aid_python_provider.py",
    "script/verify_hbpianku8_java_provider.py",
    "script/verify_hmys_java_provider.py",
    "script/verify_tangdou_python_provider.py",
    "script/verify_tuxiaobei_python_provider.py",
}
GENERATED_BOUNDARY_REPORT = "docs/data/provider-public-boundary-v1.json"
SWIFT_TEST_COMMAND = ("swift", "test", "--disable-sandbox", "--no-parallel")


class PublicExportError(RuntimeError):
    pass


def is_private_provider_test(path: str) -> bool:
    return path.startswith("script/test_private_") and path.endswith(".py")


def run(
    command: list[str],
    *,
    cwd: Path,
    environment: dict[str, str] | None = None,
    capture: bool = True,
) -> str:
    result = subprocess.run(
        command,
        cwd=cwd,
        env=environment,
        text=True,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.PIPE if capture else None,
        check=False,
    )
    if result.returncode != 0:
        detail = ""
        if capture:
            detail = (result.stderr or result.stdout).strip()
        raise PublicExportError(f"{' '.join(command)} failed: {detail or result.returncode}")
    return result.stdout if capture else ""


def swift_test_environment(home: Path) -> dict[str, str]:
    paths = {
        "HOME": home,
        "CFFIXED_USER_HOME": home,
        "XDG_CACHE_HOME": home / ".cache",
        "CLANG_MODULE_CACHE_PATH": home / ".cache" / "clang",
        "SWIFTPM_MODULECACHE_OVERRIDE": home / ".cache" / "swiftpm-modules",
        "TMPDIR": home / "tmp",
    }
    for path in set(paths.values()):
        path.mkdir(parents=True, exist_ok=True)
    environment = os.environ.copy()
    environment.update({key: str(value) for key, value in paths.items()})
    return environment


def tracked_paths(source: Path) -> list[str]:
    output = run(["git", "ls-files", "-z"], cwd=source)
    return sorted(path for path in output.split("\0") if path)


def require_clean_source(source: Path) -> None:
    if run(["git", "status", "--porcelain"], cwd=source).strip():
        raise PublicExportError(
            "source repository is dirty; commit the reviewed state or pass --allow-dirty for a local preview"
        )


def exclusion_reason(path: str) -> str | None:
    if path == GENERATED_BOUNDARY_REPORT:
        return "regenerated-boundary-report"
    if any(path.startswith(prefix) for prefix in FORBIDDEN_PREFIXES):
        return "forbidden-private-tree"
    if path in INTERNAL_PUBLICATION_FILES:
        return "internal-publication-artifact"
    if any(path.startswith(prefix) for prefix in INTERNAL_PUBLICATION_PREFIXES):
        if path not in PUBLIC_RELEASE_DOCUMENTS:
            return "internal-publication-artifact"
    if is_private_provider_source(path):
        return "site-specific-swift-provider"
    if path in PRIVATE_TEST_FILES:
        return "site-specific-swift-provider-test"
    if is_private_provider_test(path):
        return "internal-migration-tooling"
    if path in INTERNAL_MIGRATION_FILES:
        return "internal-migration-tooling"
    return None


def copy_tracked_public_files(source: Path, destination: Path) -> dict[str, Any]:
    source = source.resolve(strict=True)
    if destination.exists():
        raise PublicExportError(f"output already exists: {destination}")
    destination.mkdir(parents=True)

    included: list[str] = []
    excluded: dict[str, list[str]] = {}
    for relative in tracked_paths(source):
        reason = exclusion_reason(relative)
        if reason:
            excluded.setdefault(reason, []).append(relative)
            continue
        source_path = source / relative
        if source_path.is_symlink():
            raise PublicExportError(f"tracked symlinks require explicit review: {relative}")
        if not source_path.is_file():
            raise PublicExportError(f"tracked path is not a regular file: {relative}")
        destination_path = destination / relative
        destination_path.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source_path, destination_path)
        included.append(relative)
    return {
        "included_count": len(included),
        "excluded_count": sum(len(paths) for paths in excluded.values()),
        "excluded_by_reason": {
            reason: len(paths) for reason, paths in sorted(excluded.items())
        },
    }


def export_commit_environment() -> dict[str, str]:
    """Use the release account and real export time for GitHub-visible history."""
    environment = os.environ.copy()
    timestamp = datetime.now(timezone.utc).isoformat(timespec="seconds")
    environment.update({
        "GIT_AUTHOR_NAME": "spudhero",
        "GIT_AUTHOR_EMAIL": "318930237+spudhero@users.noreply.github.com",
        "GIT_COMMITTER_NAME": "spudhero",
        "GIT_COMMITTER_EMAIL": "318930237+spudhero@users.noreply.github.com",
        "GIT_AUTHOR_DATE": timestamp,
        "GIT_COMMITTER_DATE": timestamp,
    })
    return environment


def initialize_clean_history(destination: Path) -> str:
    run(["git", "init", "--initial-branch=main"], cwd=destination)
    run(["git", "add", "-f", "--", "."], cwd=destination)
    environment = export_commit_environment()
    run(["git", "commit", "-m", "Initial public shell export"], cwd=destination, environment=environment)

    report = build_report(destination)
    if not report["summary"]["release_ready"]:
        raise PublicExportError(
            "generated repository violates public boundary: "
            + ", ".join(report["blocking_reasons"])
        )
    report_path = destination / GENERATED_BOUNDARY_REPORT
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(serialized(report), encoding="utf-8")
    run(["git", "add", "--", GENERATED_BOUNDARY_REPORT], cwd=destination)
    run(
        ["git", "commit", "--amend", "--no-edit"],
        cwd=destination,
        environment=environment,
    )
    return run(["git", "rev-parse", "HEAD"], cwd=destination).strip()


def verify_export(destination: Path, *, run_swift_tests: bool) -> dict[str, Any]:
    report = build_report(destination)
    if not report["summary"]["release_ready"]:
        raise PublicExportError(f"public boundary failed: {report['blocking_reasons']}")
    commit_count = int(run(["git", "rev-list", "--count", "HEAD"], cwd=destination).strip())
    if commit_count != 1:
        raise PublicExportError(f"public export must have one clean-history commit, found {commit_count}")
    if run(["git", "status", "--porcelain"], cwd=destination).strip():
        raise PublicExportError("public export worktree is dirty")
    if run_swift_tests:
        with tempfile.TemporaryDirectory(prefix="netvplayer-public-swift-") as directory:
            run(
                list(SWIFT_TEST_COMMAND),
                cwd=destination / "NetVplayer",
                environment=swift_test_environment(Path(directory)),
                capture=False,
            )
        if run(["git", "status", "--porcelain"], cwd=destination).strip():
            raise PublicExportError("Swift verification changed tracked public-export files")
    return {
        "release_ready": True,
        "commit_count": commit_count,
        "swift_tests": "passed" if run_swift_tests else "not-run",
        **report["summary"],
    }


def export_public_shell(
    source: Path,
    destination: Path,
    *,
    run_swift_tests: bool = False,
    allow_dirty: bool = False,
) -> dict[str, Any]:
    source = source.resolve(strict=True)
    if not allow_dirty:
        require_clean_source(source)
    copy_result = copy_tracked_public_files(source, destination)
    commit = initialize_clean_history(destination)
    verification = verify_export(destination, run_swift_tests=run_swift_tests)
    return {"ok": True, "commit": commit, **copy_result, "verification": verification}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", type=Path, default=Path("."))
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--swift-test", action="store_true")
    parser.add_argument(
        "--allow-dirty",
        action="store_true",
        help="allow a local preview from uncommitted tracked content",
    )
    arguments = parser.parse_args()
    result = export_public_shell(
        arguments.repo,
        arguments.output,
        run_swift_tests=arguments.swift_test,
        allow_dirty=arguments.allow_dirty,
    )
    print(json.dumps(result, ensure_ascii=False, sort_keys=True))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, PublicExportError, ValueError) as error:
        print(f"Provider public export: {error}", file=sys.stderr)
        raise SystemExit(1)
