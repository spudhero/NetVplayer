#!/usr/bin/env python3
"""Original page requests terminate inside the strict local CONNECT fixture."""
import json
import os
import sys
from pathlib import Path
from browser_transport_fixture import main


def response(u, q, headers):
    if u.path == '/context/page.js':
        return 200, Path(__file__).with_name('wk_request_dedup_page.js').read_bytes(), 'text/javascript', []
    if u.path == '/context/page':
        page = '<!doctype html><meta charset="utf-8"><link rel="icon" href="data:,"><body><script>window.contextConfig=' + json.dumps(q) + ';</script><script src="/context/page.js"></script>'
        (Path(os.environ['NETVPLAYER_CONTEXT_ROOT']) / ('page-' + q['case'] + '.html')).write_text(page)
        return 200, page.encode(), 'text/html', [('Set-Cookie', 'context=local; Domain=example.test; Path=/context; HttpOnly; Secure; SameSite=Lax')]
    if u.path == '/context/media':
        extra = []
        if headers.get('origin') == 'https://video.example.test':
            extra = [('Access-Control-Allow-Origin', headers['origin']), ('Access-Control-Allow-Credentials', 'true')]
        return 200, b'original-response', 'text/plain', extra
    return None


if __name__ == '__main__':
    os.environ['NETVPLAYER_CONTEXT_ROOT'] = sys.argv[sys.argv.index('--root') + 1]
    main(response)
