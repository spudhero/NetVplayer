#!/usr/bin/env python3
"""Finite, synthetic XHR bodies served by the existing loopback TLS fixture."""
from pathlib import Path
from browser_transport_fixture import main
from wk_response_clone_fixture import response as original_response

TOOLS = Path(__file__).resolve().parent

def response(url, query, headers):
    if url.path == '/clone/driver.js':
        return 200, (TOOLS/'wk_xhr_budget_page.js').read_bytes(), 'text/javascript', []
    if url.path not in {'/media/budget-binary-exact', '/media/budget-utf8-exact', '/media/budget-utf8-over'}:
        return original_response(url, query, headers)
    if headers.get('cookie', '') != 'account=fresh':
        return 403, b'cookie-required', 'text/plain', []
    if url.path == '/media/budget-binary-exact':
        return 200, b'x' * 1048576, 'application/octet-stream', []
    body = ('\U0001f600' * 262144).encode('utf-8')
    if url.path == '/media/budget-utf8-over':
        body += '\u00e9'.encode('utf-8')
    return 200, body, 'text/plain; charset=utf-8', []

if __name__ == '__main__':
    main(response)
