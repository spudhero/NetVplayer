"""Map the internal three-project workspace to stable publication paths.

Standalone public/private repositories keep their existing paths. Internal
compatibility links are never publication inputs; each input has one owner.
"""
from __future__ import annotations

from functools import lru_cache
import json
from pathlib import Path, PurePosixPath
import subprocess

MANIFEST = ".netvplayer-workspace.json"


def _relative(value: str) -> str:
    path = PurePosixPath(value)
    if path.is_absolute() or not path.parts or ".." in path.parts:
        raise ValueError(f"invalid workspace path: {value}")
    return path.as_posix()


def workspace_manifest(repo: Path) -> dict | None:
    path = repo / MANIFEST
    if not path.is_file():
        return None
    document = json.loads(path.read_text())
    expected = {"app": "NetVplayer", "providers": "NetVplayer-Providers",
                "distribution": "NetVplayer-Provider-Distribution"}
    if document.get("schema_version") != 1 or any(
        document.get("projects", {}).get(key, {}).get("directory") != value
        for key, value in expected.items()
    ):
        raise ValueError("invalid three-project workspace manifest")
    for section in ("compatibility_links", "shared_links"):
        for link, target in document.get(section, {}).items():
            _relative(link)
            _relative(target)
    for logical, target in document.get("private_overrides", {}).items():
        _relative(logical)
        _relative(target)
        if not target.startswith("NetVplayer-Providers/"):
            raise ValueError("private override must belong to Providers")
    for physical, logical in document.get("publication_inputs", {}).items():
        _relative(physical)
        _relative(logical)
    return document


def publication_path(path: str, manifest: dict | None) -> str | None:
    if manifest is None:
        return path
    ignored = set(manifest["compatibility_links"]) | set(manifest["shared_links"])
    ignored.update(manifest.get("internal_root_files", []))
    ignored.update(manifest.get("internal_component_files", []))
    ignored.update(manifest.get("private_overrides", {}).values())
    if path in ignored or path.startswith("NetVplayer-Provider-Distribution/"):
        return None
    if path in manifest.get("publication_inputs", {}):
        return manifest["publication_inputs"][path]
    if path.startswith("NetVplayer-Providers/"):
        return path.removeprefix("NetVplayer-Providers/").removeprefix("migration-reference/")
    if path.startswith("NetVplayer/"):
        return path.removeprefix("NetVplayer/")
    return path


@lru_cache(maxsize=8)
def _entries(repo: str, index_stamp: int, manifest_stamp: int) -> dict[str, str]:
    root = Path(repo)
    manifest = workspace_manifest(root)
    raw = subprocess.check_output(["git", "ls-files", "-z"], cwd=root, text=True)
    entries: dict[str, str] = {}
    for physical in filter(None, raw.split("\0")):
        logical = publication_path(physical, manifest)
        if logical is None:
            continue
        if logical in entries:
            raise ValueError(f"duplicate publication input: {logical}")
        entries[logical] = physical
    return entries


def source_entries(repo: Path) -> dict[str, str]:
    repo = repo.resolve()
    index = repo / ".git/index"
    manifest = repo / MANIFEST
    if not manifest.is_file():
        raw = subprocess.check_output(["git", "ls-files", "-z"], cwd=repo, text=True)
        return {path: path for path in filter(None, raw.split("\0"))}
    return _entries(str(repo), index.stat().st_mtime_ns if index.exists() else 0,
                    manifest.stat().st_mtime_ns)


def tracked_paths(repo: Path) -> list[str]:
    return sorted(source_entries(repo))


def source_file(repo: Path, relative: str, *, component: str = "app") -> Path:
    if not (repo / MANIFEST).is_file():
        return repo / relative
    manifest = workspace_manifest(repo)
    if component == "providers" and relative in manifest.get("private_overrides", {}):
        return repo / manifest["private_overrides"][relative]
    entries = source_entries(repo)
    return repo / entries.get(relative, relative)


def logical_relative(repo: Path, physical: Path) -> str:
    relative = physical.relative_to(repo).as_posix()
    return publication_path(relative, workspace_manifest(repo)) or relative


def validate_links(repo: Path) -> dict:
    manifest = workspace_manifest(repo)
    if manifest is None:
        raise ValueError("workspace manifest is missing")
    root = repo.resolve()
    checked = 0
    for section in ("compatibility_links", "shared_links"):
        for link, target in manifest[section].items():
            path = root / link
            resolved = path.resolve(strict=True)
            if not path.is_symlink() or not resolved.is_relative_to(root):
                raise ValueError(f"unsafe workspace link: {link}")
            if resolved != (root / target).resolve(strict=True) or not resolved.is_file():
                raise ValueError(f"workspace link target drifted: {link}")
            checked += 1
    entries = source_entries(root)
    tracked = set(subprocess.check_output(["git", "ls-files", "-z"], cwd=root, text=True).split("\0"))
    for logical, target in manifest.get("private_overrides", {}).items():
        path = root / target
        if logical not in entries or target not in tracked or path.is_symlink() or not path.is_file():
            raise ValueError(f"invalid private override: {logical}")
    return {"links_checked": checked, "logical_inputs": len(entries)}
