#!/usr/bin/env python3
"""Original HTML media routes; existing CONNECT server terminates every request locally."""
import hashlib
import html
import json
import os
import re
import threading
from pathlib import Path
from urllib.parse import urlencode
from browser_transport_fixture import main

TOOLS = Path(__file__).resolve().parent
MEDIA = Path(os.environ['NETVPLAYER_FEATURE_FIXTURE']).read_bytes()
LOCK = threading.Lock()


def response(u, q, headers):
    if u.path == '/native/page':
        label = q['case']
        target = q.get('target', 'https://video.example.test/media/native.mp4?' + urlencode({'case': label}))
        mode, cors = q.get('mode', 'html-src'), q.get('crossorigin', '')
        attrs = ' preload="' + html.escape(q.get('preload', 'auto'), quote=True) + '" muted playsinline' + (' crossorigin="' + html.escape(cors, quote=True) + '"' if cors else '')
        source = html.escape(target, quote=True)
        media = ('<video id="original"' + attrs + ' src="' + source + '"></video>' if mode == 'html-src' else
                 '<video id="original"' + attrs + '><source src="' + source + '" type="video/mp4"></video>' if mode == 'html-source' else '')
        config = json.dumps(dict(target=target, mode=mode, crossorigin=cors)).replace('<', '\\u003c')
        page = '<!doctype html><meta charset="utf-8"><link rel="icon" href="data:,"><body>' + media
        page += '<script>window.nativeConfig=' + config + ';</script><script src="/native/driver.js"></script>'
        extra = [('Set-Cookie', 'account=fresh; Path=/media; HttpOnly; SameSite=Lax; Secure')] if q.get('seed', '1') == '1' else []
        return 200, page.encode(), 'text/html', extra
    if u.path == '/native/driver.js':
        return 200, (TOOLS / 'wk_native_media_page.js').read_bytes(), 'text/javascript', []
    if u.path != '/media/native.mp4':
        return None
    expected = q.get('expect', 'fresh')
    body, status = MEDIA, 200
    if headers.get('cookie', '') != ('account=' + expected if expected else ''):
        body, status = b'cookie-required', 403
    extra = []
    if status == 200 and 'range' in headers:
        match = re.fullmatch(r'bytes=(\d+)-(\d*)', headers['range'])
        if not match:
            body, status = b'', 416
        else:
            start, end = int(match[1]), min(int(match[2]) if match[2] else len(MEDIA) - 1, len(MEDIA) - 1)
            if start > end:
                body, status = b'', 416
            else:
                body, status = MEDIA[start:end + 1], 206
                extra.append(('Content-Range', f'bytes {start}-{end}/{len(MEDIA)}'))
    # A separate response receipt pins the exact bytes handed to the base server.
    row = dict(case=q['case'], host=headers['host'], path=u.path, query=u.query,
               request_headers=headers, status=status, bytes=len(body), sha256=hashlib.sha256(body).hexdigest(),
               response_headers=dict(extra), original_media_sha256=hashlib.sha256(MEDIA).hexdigest())
    with LOCK:
        with (Path(os.environ['NETVPLAYER_NATIVE_ACTIVE_ROOT']) / 'native-responses.jsonl').open('a') as out:
            out.write(json.dumps(row) + '\n')
    return status, body, 'video/mp4', extra


if __name__ == '__main__':
    # SeedScopeFixture always passes --root ABS; no new networking implementation.
    import sys
    os.environ['NETVPLAYER_NATIVE_ACTIVE_ROOT'] = sys.argv[sys.argv.index('--root') + 1]
    main(response)
