#!/usr/bin/env python3
"""Real navigation/history requests terminate inside the closed loopback fixture."""
import json
import os
import sys
from pathlib import Path
from browser_transport_fixture import main


def response(u, q, headers):
    if u.path == '/history/page.js':
        return 200, Path(__file__).with_name('wk_history_page.js').read_bytes(), 'text/javascript', []
    if u.path in ('/history/a', '/history/b', '/history/frame'):
        config = dict(q, page='a' if u.path.endswith('/frame') else u.path.rsplit('/', 1)[1], frame=u.path.endswith('/frame'))
        page = '<!doctype html><meta charset="utf-8"><link rel="icon" href="data:,"><body><script>window.historyConfig=' + json.dumps(config) + ';</script><script src="/history/page.js"></script>'
        root = Path(os.environ['NETVPLAYER_HISTORY_ROOT'])
        index = len(list(root.glob('page-*.html')))
        (root / ('page-' + str(index) + '-' + config['page'] + '.html')).write_text(page)
        return 200, page.encode(), 'text/html', []
    if u.path == '/history/media':
        return 200, b'original-history-response', 'text/plain', []
    return None


if __name__ == '__main__':
    os.environ['NETVPLAYER_HISTORY_ROOT'] = sys.argv[sys.argv.index('--root') + 1]
    main(response)
