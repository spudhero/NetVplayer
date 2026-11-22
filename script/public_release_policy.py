"""Shared file boundary for public source exports and their independent audit."""

PUBLIC_RELEASE_DOCUMENTS = {
    "docs/guide.md",
    "docs/marketing/xiaohongshu/update-2.0.7-20261120/README.md",
    "docs/marketing/xiaohongshu/update-2.0.7-20261120/copy.md",
    "docs/marketing/xiaohongshu/update-2.0.7-20261120/getting-started.md",
    "docs/marketing/xiaohongshu/update-2.0.7-20261120/changes-from-1.1.4.md",
    "docs/marketing/xiaohongshu/update-2.0.7-20261120/index.html",
    "docs/marketing/xiaohongshu/update-2.0.7-20261120/layout.json",
    "docs/marketing/xiaohongshu/update-2.0.7-20261120/images.json",
    "docs/marketing/xiaohongshu/update-2.0.7-20261120/preview.jpg",
    "docs/marketing/xiaohongshu/update-2.0.7-20261120/assets/home.png",
    "docs/marketing/xiaohongshu/update-2.0.7-20261120/assets/cloud-folders.png",
    "docs/marketing/xiaohongshu/update-2.0.7-20261120/assets/file-services.png",
    "docs/marketing/xiaohongshu/update-2.0.7-20261120/assets/media-servers.png",
    "docs/marketing/xiaohongshu/update-2.0.7-20261120/assets/video-output.png",
    "docs/marketing/xiaohongshu/update-2.0.7-20261120/assets/audio.png",
    "docs/marketing/xiaohongshu/update-2.0.7-20261120/assets/subtitles.png",
    "docs/marketing/xiaohongshu/update-2.0.7-20261120/assets/themes.png",
    "docs/marketing/xiaohongshu/update-2.0.7-20261120/assets/nas-detail.png",
    "docs/marketing/xiaohongshu/update-2.0.7-20261120/assets/player.png",
    "docs/marketing/xiaohongshu/update-2.0.7-20261120/assets/player-controls.png",
    "docs/marketing/xiaohongshu/update-2.0.7-20261120/cards/01-cover.png",
    "docs/marketing/xiaohongshu/update-2.0.7-20261120/cards/02-major-changes.png",
    "docs/marketing/xiaohongshu/update-2.0.7-20261120/cards/03-tvbox-fongmi.png",
    "docs/marketing/xiaohongshu/update-2.0.7-20261120/cards/04-nas-detail.png",
    "docs/marketing/xiaohongshu/update-2.0.7-20261120/cards/05-player.png",
    "docs/marketing/xiaohongshu/update-2.0.7-20261120/cards/06-dolby.png",
    "docs/marketing/xiaohongshu/update-2.0.7-20261120/cards/07-subtitles.png",
    "docs/marketing/xiaohongshu/update-2.0.7-20261120/cards/08-install.png",
    "docs/marketing/xiaohongshu/update-2.0.7-20261120/cards/09-first-play.png",
    "docs/marketing/xiaohongshu/update-2.0.7-20261120/cards/10-tvbox-setup.png",
    "docs/marketing/xiaohongshu/update-2.0.7-20261120/cards/11-nas-setup.png",
    "docs/overview-screenshots.json",
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
