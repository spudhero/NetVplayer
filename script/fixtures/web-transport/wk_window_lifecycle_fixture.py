#!/usr/bin/env python3
"""Original event-gated DOM fixture. No page fetch/XHR/play calls or outbound proxying."""
import json
import os
import sys
from pathlib import Path
from browser_transport_fixture import main
from wk_native_media_fixture import response as native_response


def response(u, q, headers):
    if u.path == '/lifecycle/page':
        label = q['case']
        mode = q.get('mode', 'metadata')
        preload = 'none' if mode == 'none' else 'metadata'
        if mode == 'autoplay':
            preload = 'auto'
        attrs = ' preload="' + preload + '" muted playsinline' + (' autoplay' if mode == 'autoplay' else '')
        config = json.dumps(dict(case=label, mode=mode, target=q.get('target'), next=q.get('next'))).replace('<', '\\u003c')
        page = '<!doctype html><meta charset="utf-8"><link rel="icon" href="data:,"><body><video id="original"' + attrs + '></video>'
        page += '<script>window.lifecycleConfig=' + config + ';</script><script src="/lifecycle/page.js"></script>'
        root = Path(os.environ['NETVPLAYER_NATIVE_ACTIVE_ROOT'])
        (root / ('page-' + label + '.html')).write_text(page)
        extra = [('Set-Cookie', 'account=fresh; Path=/media; HttpOnly; SameSite=Lax; Secure')] if q.get('seed','1') == '1' else []
        return 200, page.encode(), 'text/html', extra
    if u.path == '/lifecycle/page.js':
        return 200, Path(__file__).with_name('wk_window_lifecycle_page.js').read_bytes(), 'text/javascript', []
    return native_response(u, q, headers)


if __name__ == '__main__':
    os.environ['NETVPLAYER_NATIVE_ACTIVE_ROOT'] = sys.argv[sys.argv.index('--root') + 1]
    main(response)
