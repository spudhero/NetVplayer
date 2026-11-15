#!/usr/bin/env python3
"""Adds original-page routes to the existing strictly loopback CONNECT fixture."""
import gzip
from pathlib import Path
from browser_transport_fixture import main

TOOLS = Path(__file__).resolve().parent


def response(u, q, headers):
    if u.path == '/clone/page':
        seed = q.get('seed', '1') == '1'
        extra = [('Set-Cookie', 'account=fresh; Path=/media; HttpOnly; SameSite=Lax; Secure')] if seed else []
        return 200, b'<!doctype html><meta charset="utf-8"><link rel="icon" href="data:,"><body><script src="/clone/driver.js"></script>', 'text/html', extra
    if u.path == '/clone/driver.js':
        return 200, (TOOLS / 'wk_response_clone_page.js').read_bytes(), 'text/javascript', []
    if u.path not in {'/media/text', '/media/json', '/media/document', '/media/big', '/media/gzip', '/media/finite'}:
        return None
    # Keep the original receiver's credential check, with fully synthetic accounts.
    expected = q.get('expect', 'fresh')
    if headers.get('cookie', '') != ('account=' + expected if expected else ''):
        return 403, b'cookie-required', 'text/plain', []
    if u.path == '/media/text':
        return 200, b'caf\xe9\r\n', 'text/plain; charset=windows-1252', []
    if u.path == '/media/json':
        return 200, b'{"original":true, "n":1}', 'application/json', []
    if u.path == '/media/document':
        return 200, b'<original value="1"/>', 'application/xml', []
    if u.path == '/media/finite':
        return 200, b'z' * 262144, 'application/octet-stream', []
    body = b'x' * (2 * 1024 * 1024)
    if u.path == '/media/gzip':
        return 200, gzip.compress(body, mtime=0), 'application/octet-stream', [('Content-Encoding', 'gzip')]
    return 200, body, 'application/octet-stream', []


if __name__ == '__main__':
    main(response)
