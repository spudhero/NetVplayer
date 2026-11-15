#!/usr/bin/env python3
"""Finite local CDP feasibility receiver, not a product proxy.

HTTP proxy/CONNECT requests terminate here. No DNS, forwarding or outbound socket
code exists. Only two synthetic hosts and a loopback spool/control origin exist.
"""
import hashlib
import argparse
import json
import os
import ssl
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

HOSTS = {'video.example.test', 'sibling.example.test'}


def main(response_builder=None, *, allow_plain_http=False):
    p = argparse.ArgumentParser()
    p.add_argument('--root', type=Path, required=True)
    p.add_argument('--media', type=Path, default=os.environ.get('NETVPLAYER_FEATURE_FIXTURE'))
    a = p.parse_args()
    os.umask(0o077)
    media = a.media.read_bytes()
    rows, gates = [], {}
    lock = threading.Lock()
    capture = (a.root / 'receiver.jsonl').open('x')
    tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    tls.load_cert_chain(a.root / 'cert.pem', a.root / 'key.pem')

    def record(row):
        with lock:
            rows.append(row)
            capture.write(json.dumps(row) + '\n')
            capture.flush()

    class Handler(BaseHTTPRequestHandler):
        protocol_version = 'HTTP/1.1'

        def log_message(self, *_):
            pass

        def do_CONNECT(self):
            host, _, port = self.path.rpartition(':')
            if host not in HOSTS or port not in (('80', '443') if allow_plain_http else ('443',)):
                record(dict(kind='proxy-denied', method='CONNECT', target=self.path))
                self.send_error(403)
                return
            record(dict(kind='connect', target=self.path))
            self.send_response(200)
            self.end_headers()
            self.wfile.flush()
            if port == '80':
                # Opt-in local plaintext tunnel, with the same closed host set.
                # No socket is opened to the requested host.
                self.tls = False
                self.close_connection = False
                return
            try:
                self.connection = tls.wrap_socket(self.connection, server_side=True)
                self.rfile = self.connection.makefile('rb', -1)
                self.wfile = self.connection.makefile('wb', 0)
                self.tls = True
                self.close_connection = False
            except ssl.SSLError as e:
                record(dict(kind='tls-rejected', error=str(e)))
                self.close_connection = True

        def do_OPTIONS(self):
            self.serve()

        def do_GET(self):
            self.serve()

        def do_POST(self):
            # Local request-context contracts need the original body receipt.
            self.request_body = self.rfile.read(int(self.headers.get('Content-Length', '0')))
            self.serve()
            del self.request_body

        def serve(self):
            u = urlsplit(self.path)
            q = {k: v[0] for k, v in parse_qs(u.query, keep_blank_values=True).items()}
            host = self.headers.get('Host', '').split(':')[0]
            headers = {k.lower(): v for k, v in self.headers.items()}
            extra, status, data, mime = [], 200, b'ok', 'text/plain'
            if host == '127.0.0.1' and (u.path.startswith('/control/') or u.path == '/records'):
                with lock:
                    if u.path == '/control/release':
                        gates.setdefault(q['id'], threading.Event()).set()
                    data = json.dumps(rows).encode()
                self.reply(200, data, 'application/json', [])
                return
            if host == '127.0.0.1' and u.path.startswith('/spool/'):
                token = u.path.removeprefix('/spool/')
                if len(token) != 64 or any(c not in '0123456789abcdef' for c in token):
                    self.send_error(404)
                    return
                file = a.root / 'spool' / (token + '.mp4')
                data = file.read_bytes() if file.is_file() else b'retired'
                status, mime = (200, 'video/mp4') if file.is_file() else (410, 'text/plain')
            elif host not in HOSTS or (u.hostname and u.hostname != host):
                record(dict(kind='proxy-denied', method=self.command, target=self.path))
                self.send_error(403)
                return
            elif response_builder is not None and (custom := response_builder(u, q, headers)) is not None:
                status, data, mime, extra = custom
            elif self.command == 'OPTIONS':
                status, data = (403 if q.get('cors') == 'preflight-deny' else 204), b''
                if status == 204:
                    extra += [('Access-Control-Allow-Methods', 'GET'),
                              ('Access-Control-Allow-Headers', 'x-local-token,authorization')]
            elif u.path == '/page':
                data = b'<!doctype html><meta charset="utf-8"><link rel="icon" href="data:,"><title>Local browser transport fixture</title>'
                mime = 'text/html'
                if q.get('seed', '1') == '1':
                    extra.append(('Set-Cookie', self.cookie('fresh')))
            elif u.path == '/rotate':
                extra.append(('Set-Cookie', self.cookie(q.get('value', 'second'))))
            elif u.path in ('/media/redirect', '/media/hold'):
                target = urlsplit(q['target'])
                if target.scheme not in ('http', 'https') or target.hostname not in HOSTS or target.port is not None:
                    self.send_error(403)
                    return
                status, data = 302, b''
                extra.append(('Location', q['target']))
                if q.get('rotate') == '1':
                    extra.append(('Set-Cookie', self.cookie('redirected')))
            elif u.path.startswith('/media/'):
                expected = q.get('expect', 'fresh')
                cookie = 'account=' + expected if expected else ''
                status = 200 if headers.get('cookie', '') == cookie else 403
                data = media if status == 200 else b'cookie-required'
                mime = 'video/mp4'
                if q.get('payload') == 'cookie':
                    data, mime = headers.get('cookie', '').encode(), 'text/plain'
            else:
                status, data = 404, b'unknown fixture path'
            if q.get('cors') in ('allow', 'preflight-deny') and status != 403:
                origin = self.headers.get('Origin', '')
                if urlsplit(origin).hostname in HOSTS:
                    extra += [('Access-Control-Allow-Origin', origin), ('Access-Control-Allow-Credentials', 'true')]
            if status == 200 and 'range' in headers and mime == 'video/mp4':
                import re
                m = re.fullmatch(r'bytes=(\d+)-(\d*)', headers['range'])
                if not m:
                    status, data = 416, b''
                else:
                    total = len(data)
                    start, end = int(m[1]), int(m[2]) if m[2] else total - 1
                    end = min(end, total - 1)
                    if start > end:
                        status, data = 416, b''
                    else:
                        status, data = 206, data[start:end + 1]
                        extra.append(('Content-Range', f'bytes {start}-{end}/{total}'))
            extra += [('Cache-Control', 'private, max-age=3600' if q.get('cache') == '1' else 'no-store'),
                      ('Accept-Ranges', 'bytes')]
            record(dict(kind='request', host=host, path=u.path, query=u.query, case=q.get('case'),
                        method=self.command, tls=getattr(self, 'tls', False), headers=headers, status=status,
                        **({'body_bytes': len(self.request_body), 'body_sha256': hashlib.sha256(self.request_body).hexdigest()} if hasattr(self, 'request_body') else {})))
            if u.path == '/media/hold':
                with lock:
                    gate = gates.setdefault(q['case'], threading.Event())
                gate.wait(15)
            sent = self.reply(status, data, mime, extra)
            if u.path == '/media/hold':
                record(dict(kind='gate-drained', case=q['case'], response_written=sent))

        def cookie(self, value):
            assert value in ('fresh', 'second', 'redirected')
            return 'account=' + value + '; Path=/media; HttpOnly; SameSite=Lax' + ('; Secure' if getattr(self, 'tls', False) else '')

        def reply(self, status, data, mime, extra):
            try:
                self.send_response(status)
                for k, v in extra:
                    self.send_header(k, v)
                self.send_header('Content-Type', mime)
                self.send_header('Content-Length', str(len(data)))
                self.end_headers()
                self.wfile.write(data)
                return True
            except (BrokenPipeError, ConnectionResetError, ssl.SSLError):
                return False

    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    print(server.server_port, flush=True)
    server.serve_forever()


if __name__ == '__main__':
    main()
