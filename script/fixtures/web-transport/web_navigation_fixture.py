#!/usr/bin/env python3
"""Offline navigation receiver. Every CONNECT terminates here; no DNS or outbound IO.

Only synthetic headers are recorded. The control API uses loopback directly and is
excluded from browser receipts. Held responses enable cancellation/replacement tests.
"""
import argparse
import json
import os
import ssl
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit
from web_cookie_seed_fixture import HOSTS


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--root', type=Path, required=True)
    root = p.parse_args().root
    os.umask(0o077)
    rows, gates, drained = [], {}, set()
    lock = threading.Lock()
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(root / 'cert.pem', root / 'key.pem')
    capture = (root / 'requests.jsonl').open('x')

    class Handler(BaseHTTPRequestHandler):
        protocol_version = 'HTTP/1.1'

        def log_message(self, *args):
            pass

        def do_CONNECT(self):
            host, _, port = self.path.rpartition(':')
            if host not in HOSTS or port not in ('80', '443'):
                self.send_error(403)
                return
            self.send_response(200)
            self.end_headers()
            self.wfile.flush()
            self.tls = port == '443'
            if self.tls:
                self.connection = context.wrap_socket(self.connection, server_side=True)
                self.rfile = self.connection.makefile('rb', -1)
                self.wfile = self.connection.makefile('wb', 0)
            self.close_connection = False

        def do_GET(self):
            u = urlsplit(self.path)
            q = {k: v[0] for k, v in parse_qs(u.query).items()}
            host = self.headers.get('Host', '').split(':')[0]
            status, body, headers, gate = 200, 'ok', [], q.get('hold')
            if u.path in ('/records', '/control/release', '/control/status'):
                if host != '127.0.0.1':
                    self.send_error(403)
                    return
                with lock:
                    if u.path == '/control/release':
                        gates.setdefault(q['id'], threading.Event()).set()
                    body = json.dumps(rows if u.path == '/records' else sorted(drained))
                headers.append(('Content-Type', 'application/json'))
            else:
                if host not in HOSTS:
                    self.send_error(403)
                    return
                if u.path == '/nav/redirect':
                    target = urlsplit(q['target'])
                    if target.hostname not in HOSTS or target.scheme not in ('http', 'https') or target.port not in (None, 80, 443):
                        self.send_error(403)
                        return
                    status = int(q.get('code', '302'))
                    assert status in (301, 302, 303, 307, 308)
                    headers.append(('Location', q['target']))
                    if q.get('rotate') == '1':
                        headers.append(('Set-Cookie', 'nav=rotated; Path=/nav; HttpOnly'))
                elif u.path == '/nav/page':
                    mode, case = q.get('mode', 'done'), q.get('case', '')
                    # Probes and reloads are performed by the actual page, never
                    # synthesized from a URLRequest or the cookie-store snapshot.
                    js = "const key='reload-'+" + json.dumps(case) + ";"
                    js += "const phase=sessionStorage.getItem(key)||'0';"
                    js += "await fetch('/nav/probe?case='+encodeURIComponent(" + json.dumps(case) + ")+ '&phase='+phase,{cache:'no-store'});"
                    if mode == 'reload':
                        js += "if(phase==='0'){sessionStorage.setItem(key,'1');location.reload();return;}"
                    elif mode == 'replace':
                        target = q['next']
                        assert urlsplit(target).hostname in HOSTS
                        js += 'location.replace(' + json.dumps(target) + ');return;'
                    elif mode == 'hold-page':
                        js += "await fetch('/nav/block?hold='+encodeURIComponent(" + json.dumps(case) + "));"
                    js += "await fetch('/nav/settled?case='+encodeURIComponent(" + json.dumps(case) + "),{cache:'no-store'});"
                    js += "window.webkit?.messageHandlers.done?.postMessage('done');"
                    js += "let v=document.createElement('video');v.src='/result.m3u8';document.body.append(v);"
                    body = '<script>(async()=>{' + js + '})()</script>'
                    headers.append(('Content-Type', 'text/html'))
                elif u.path == '/nav/probe' and q.get('phase') == '0':
                    headers.append(('Set-Cookie', 'dynamic=updated; Path=/nav; HttpOnly'))
                row = dict(host=host, path=u.path, query=u.query, tls=getattr(self, 'tls', False),
                           method='GET', status=status, headers={k.lower(): v for k, v in self.headers.items()})
                with lock:
                    if gate:
                        gates.setdefault(gate, threading.Event())
                    rows.append(row)
                    capture.write(json.dumps(row) + '\n')
                    capture.flush()
                if gate:
                    gates[gate].wait(15)
            data = body.encode()
            try:
                self.send_response(status)
                for name, value in headers:
                    self.send_header(name, value)
                self.send_header('Cache-Control', 'no-store')
                self.send_header('Content-Length', str(len(data)))
                self.end_headers()
                self.wfile.write(data)
            except (BrokenPipeError, ConnectionResetError, ssl.SSLError):
                pass
            finally:
                if gate:
                    with lock:
                        drained.add(gate)

    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    print(server.server_port, flush=True)
    server.serve_forever()


if __name__ == '__main__':
    main()
