"""Pinned, generated host metadata; private source rules are not public build inputs."""
import hashlib
import json
from pathlib import Path

RESOURCE_PATH = "NetVplayer/Sources/SpiderEngine/Resources"
ARTIFACT_NAME = "AndroidCompatibilityPolicy.bin"
ARTIFACT_SHA256 = "f198970c1934a43cd32169520bc1a80c25e5b0d998e80ef97d458b25bbe1920e"
SOURCE_SHA256 = "339923c61c4d8ccb43c5a6cd4b6b08e6ceb10621143515bd706905704397c8b7"


def validate(directory: Path) -> list[str]:
    try:
        artifact = directory / ARTIFACT_NAME
        provenance = directory / "AndroidCompatibilityPolicy.provenance.json"
        if artifact.is_symlink() or provenance.is_symlink():
            return ["compatibility-resource-symlink"]
        receipt = json.loads(provenance.read_text())
        if hashlib.sha256(artifact.read_bytes()).hexdigest() != ARTIFACT_SHA256:
            return ["compatibility-artifact-digest-mismatch"]
        if receipt.get("source_sha256") != SOURCE_SHA256 or receipt.get("artifact_sha256") != ARTIFACT_SHA256:
            return ["compatibility-provenance-mismatch"]
        return []
    except (OSError, ValueError):
        return ["compatibility-resource-missing-or-invalid"]
