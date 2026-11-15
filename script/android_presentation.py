"""Validate the one reviewed, app-owned Java presentation resource.

This exception never permits Provider code, an Android framework, or a host APK.
Archive changes require reviewing a new pin and rebuilding from the public Java
sources with the separately supplied compile dependencies.
"""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
import re
import zipfile

RESOURCE_PATH = "NetVplayer/Sources/NetVplayerApp/Resources/AndroidPresentation"
SOURCE_DIRECTORY = "android-presentation/src/main/java/com/netvplayer/provider/android"
SOURCE_NAMES = ("DesktopAndroidUI.java", "DesktopAndroidTheme.java", "DesktopPlaybackContext.java")
ARCHIVE_NAME = "android-presentation.jar"
# Reviewed application code, not a downloaded source Provider or runtime.
ARCHIVE_SHA256 = "f2a290f3087b628d624268f8a6076a0b4488ea8c63640c60a27b5ba63cc31f11"
CLASS_PATH = re.compile(
    r"com/netvplayer/provider/android/(?:DesktopAndroidUI|DesktopAndroidTheme|DesktopPlaybackContext)"
    r"(?:\$[A-Za-z0-9_$]+)?\.class"
)


def validate_presentation(directory: Path, *, repo: Path | None = None) -> list[str]:
    """Check pinned bytes and class scope, and source provenance when available."""
    try:
        archive, provenance = directory / ARCHIVE_NAME, directory / "provenance.json"
        if directory.is_symlink() or archive.is_symlink() or provenance.is_symlink():
            return ["presentation-symlink"]
        receipt = json.loads(provenance.read_text(encoding="utf-8"))
        if receipt.get("schema") != 1 or receipt.get("javaRelease") != 21:
            return ["presentation-schema"]
        sources = receipt.get("sources")
        expected_paths = {f"{SOURCE_DIRECTORY}/{name}" for name in SOURCE_NAMES}
        if not isinstance(sources, dict) or set(sources) != expected_paths:
            return ["presentation-source-inventory"]
        if any(not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{64}", value)
               for value in sources.values()):
            return ["presentation-source-digest"]
        if repo is not None:
            for relative, expected in sources.items():
                path = repo / relative
                if path.is_symlink() or not path.resolve(strict=True).is_relative_to(repo.resolve()):
                    return ["presentation-source-path"]
                if hashlib.sha256(path.read_bytes()).hexdigest() != expected:
                    return ["presentation-source-digest"]
        dependencies = receipt.get("compileDependencies")
        if not isinstance(dependencies, dict) or set(dependencies) != {"android-framework.jar", "android-adapter.jar"}:
            return ["presentation-dependency-inventory"]
        if any(not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{64}", value)
               for value in dependencies.values()):
            return ["presentation-dependency-digest"]
        if (receipt.get("archiveSHA256") != ARCHIVE_SHA256
                or archive.stat().st_size > 2 * 1024 * 1024
                or hashlib.sha256(archive.read_bytes()).hexdigest() != ARCHIVE_SHA256):
            return ["presentation-archive-digest"]
        with zipfile.ZipFile(archive) as bundle:
            names = bundle.namelist()
            if not names or len(names) != len(set(names)):
                return ["presentation-archive-entries"]
            if any(not CLASS_PATH.fullmatch(name) for name in names):
                return ["presentation-class-scope"]
        return []
    except (OSError, ValueError, TypeError, AttributeError, zipfile.BadZipFile):
        return ["presentation-invalid-or-missing"]
