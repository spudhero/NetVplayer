#!/usr/bin/env python3
"""One-host loopback CONNECT fixture with a post-header body gate."""
import argparse
import json
import os
from pathlib import Path
import ssl
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', type=Path, required=True)
    args = parser.parse_args()
    os.umask(0o077)
    rows, gates = [], {}
    lock = threading.Lock()
    log = (args.root / 'receiver.jsonl').open('x')
    tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    tls.load_cert_chain(args.root / 'cert.pem', args.root / 'key.pem')
    body = b's' * 32768 + b't' * 32768

    def record(value):
        with lock:
            rows.append(value)
            log.write(json.dumps(value) + '\n')
            log.flush()

    class Handler(BaseHTTPRequestHandler):
        protocol_version = 'HTTP/1.1'

        def log_message(self, *_):
            pass

        def do_CONNECT(self):
            if self.path != 'video.example.test:443':
                record({'kind': 'proxy-denied', 'target': self.path})
                self.send_error(403)
                return
            record({'kind': 'connect', 'target': self.path})
            self.send_response(200)
            self.end_headers()
            self.wfile.flush()
            try:
                self.connection = tls.wrap_socket(self.connection, server_side=True)
                self.rfile = self.connection.makefile('rb', -1)
                self.wfile = self.connection.makefile('wb', 0)
                self.tls = True
                self.close_connection = False
            except ssl.SSLError:
                record({'kind': 'tls-rejected'})
                self.close_connection = True

        def reply(self, status, data, mime, extra=()):
            self.send_response(status)
            self.send_header('Content-Type', mime)
            self.send_header('Content-Length', str(len(data)))
            self.send_header('Cache-Control', 'no-store')
            for key, value in extra:
                self.send_header(key, value)
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            target = urlsplit(self.path)
            query = {key: values[0] for key, values in parse_qs(target.query).items()}
            host = self.headers.get('Host', '').split(':')[0]
            if host == '127.0.0.1' and target.path.startswith('/control/'):
                with lock:
                    if target.path == '/control/release':
                        gates.setdefault(query['id'], threading.Event()).set()
                    data = json.dumps(rows).encode()
                self.reply(200, data, 'application/json')
                return
            if host != 'video.example.test' or not getattr(self, 'tls', False):
                record({'kind': 'proxy-denied', 'target': self.path})
                self.send_error(403)
                return
            record({'kind': 'request', 'host': host, 'path': target.path,
                    'case': query.get('case'), 'method': 'GET', 'tls': True,
                    'cookie': self.headers.get('Cookie', '')})
            if target.path == '/lifetime/page':
                self.reply(200, b'<!doctype html><meta charset="utf-8"><link rel="icon" href="data:,"><body><script src="/lifetime/page.js"></script>',
                           'text/html', [('Set-Cookie', 'account=fresh; Path=/media; HttpOnly; Secure; SameSite=Lax')])
                return
            if target.path == '/lifetime/page.js':
                self.reply(200, (Path(__file__).parent / 'wk_fetch_lifetime_page.js').read_bytes(), 'text/javascript')
                return
            if target.path != '/media/lifetime' or self.headers.get('Cookie') != 'account=fresh':
                self.reply(403, b'cookie-required', 'text/plain')
                return
            held = query.get('hold') == '1'
            label = query['case']
            with lock:
                gate = gates.setdefault(label, threading.Event())
            sent = False
            try:
                self.send_response(200)
                self.send_header('Content-Type', 'application/octet-stream')
                self.send_header('Content-Length', str(len(body)))
                self.send_header('Cache-Control', 'no-store')
                self.end_headers()
                self.wfile.write(body[:32768])
                self.wfile.flush()
                record({'kind': 'first-block', 'case': label, 'bytes': 32768, 'held': held})
                if held:
                    released = gate.wait(8)
                    record({'kind': 'gate-release', 'case': label, 'explicit_release': released})
                self.wfile.write(body[32768:])
                self.wfile.flush()
                sent = True
            except (BrokenPipeError, ConnectionResetError, ssl.SSLError):
                pass
            finally:
                record({'kind': 'gate-drained', 'case': label, 'response_written': sent})

    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    print(server.server_port, flush=True)
    server.serve_forever()


if __name__ == '__main__':
    main()
