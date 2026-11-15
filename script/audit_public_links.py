"""Check tracked Markdown file targets in the actual public repository tree.

Code fences/inline code are ignored. Supports inline and reference links and
images; remote URLs and same-file anchors are outside this local file check.
"""

from __future__ import annotations

from pathlib import Path
import posixpath
import re
from urllib.parse import unquote, urlsplit

DESTINATION = r'(?:<([^>]+)>|([^\s)]+))(?:\s+["\'][^"\']*["\'])?'
INLINE_LINK = re.compile(r'!?\[[^\]]*\]\(' + DESTINATION + r'\)')
REFERENCE = re.compile(r'^\s{0,3}\[[^\]]+\]:\s*' + DESTINATION)


def missing_markdown_targets(repo: Path, paths: list[str]) -> list[dict[str, str | int]]:
    tracked = set(paths)
    findings: list[dict[str, str | int]] = []
    for relative in paths:
        if not relative.lower().endswith('.md'):
            continue
        content = (repo / relative).read_text(encoding='utf-8')
        fence: str | None = None
        for number, line in enumerate(content.splitlines(), 1):
            marker = re.match(r'^\s{0,3}(`{3,}|~{3,})', line)
            if marker:
                if fence is None:
                    fence = marker[1][0]
                elif fence == marker[1][0]:
                    fence = None
                continue
            if fence is not None:
                continue
            line = re.sub(r'(`+).*?\1', '', line)
            matches = list(INLINE_LINK.finditer(line))
            reference = REFERENCE.match(line)
            if reference:
                matches.append(reference)
            for match in matches:
                destination = (match[1] or match[2]).strip()
                url = urlsplit(destination)
                if url.scheme or url.netloc or not url.path:
                    continue
                target = posixpath.normpath(posixpath.join(
                    posixpath.dirname(relative), unquote(url.path)))
                if target in tracked or any(path.startswith(target.rstrip('/') + '/') for path in tracked):
                    continue
                findings.append({'path': relative, 'line': number, 'target': target})
    return findings
