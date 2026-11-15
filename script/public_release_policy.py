"""Shared file boundary for public source exports and their independent audit."""

PUBLIC_RELEASE_DOCUMENTS = {
    "docs/data/provider-public-boundary-v1.json",
    "docs/data/torrent-bridge-license-audit-2026-08-18.json",
    "docs/design/player-ui/assets/w700d1q75cms.jpg",
}
PUBLIC_RELEASE_DOCUMENT_PREFIXES = ("docs/releases/",)
INTERNAL_PUBLICATION_PREFIXES = (
    "NetVplayer/Docs/",
    "NetVplayer/Resources/UI_Mockups/",
    "docs/",
    "experiments/",
)
INTERNAL_PUBLICATION_FILES = {
    "AGENTS.md",
    "NetVplayer/README.md",
    "NetVplayer/PRD.md",
    "NetVplayer/TASK.md",
    "NetVplayer/migration_plan.md",
    "NetVplayer/ui_design_guidelines.md",
}


def is_internal_publication(path: str) -> bool:
    if path in INTERNAL_PUBLICATION_FILES:
        return True
    return (
        path.startswith(INTERNAL_PUBLICATION_PREFIXES)
        and path not in PUBLIC_RELEASE_DOCUMENTS
        and not path.startswith(PUBLIC_RELEASE_DOCUMENT_PREFIXES)
    )
