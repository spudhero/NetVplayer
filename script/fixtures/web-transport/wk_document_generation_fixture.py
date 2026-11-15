#!/usr/bin/env python3
"""Document/frame replacements served by the strict local CONNECT fixture only."""
import json
import os
import sys
import threading
from pathlib import Path
from browser_transport_fixture import main

visits = {}
lock = threading.Lock()

def response(u, q, headers):
    if u.path == '/generation/page.js':
        return 200, Path(__file__).with_name('wk_document_generation_page.js').read_bytes(), 'text/javascript', []
    if u.path in ('/generation/page', '/generation/frame'):
        key = (headers['host'], u.path, u.query)
        with lock:
            visits[key] = visits.get(key, 0) + 1
            visit = visits[key]
        cfg = dict(case=q['case'], mode=q['mode'], frame=u.path.endswith('/frame'),
                   phase='current' if visit > 1 or q.get('next') == '1' else 'old', visit=visit)
        page = '<!doctype html><meta charset="utf-8"><link rel="icon" href="data:,"><body><script>window.generationConfig=' + json.dumps(cfg) + ';</script><script src="/generation/page.js"></script>'
        root = Path(os.environ['NETVPLAYER_GENERATION_ROOT'])
        (root / ('page-' + q['case'] + '-' + ('frame' if cfg['frame'] else 'main') + '-' + str(visit) + '.html')).write_text(page)
        return 200, page.encode(), 'text/html', []
    return None

if __name__ == '__main__':
    os.environ['NETVPLAYER_GENERATION_ROOT'] = sys.argv[sys.argv.index('--root') + 1]
    main(response, allow_plain_http=True)
