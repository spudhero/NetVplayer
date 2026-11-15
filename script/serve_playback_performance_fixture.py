#!/usr/bin/env python3
"""Serve exactly one authorized fixture on loopback with bounded Range reads.

This is a controlled HTTP contract, never evidence of real NAS/WAN/drive service.
Optional one-time wall-clock stall is recorded independently from decoder drops.
"""
import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import re
import threading
import time


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--file", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--stall-at", type=float, default=-1)
    parser.add_argument("--stall-for", type=float, default=0)
    args = parser.parse_args()
    size = args.file.stat().st_size
    state = {"requests": 0, "bytes": 0, "stallStarted": False, "firstRequestUptime": None}
    lock = threading.Lock()

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *_):
            pass

        def do_HEAD(self):
            self.respond(head=True)

        def do_GET(self):
            self.respond(head=False)

        def respond(self, head):
            if self.path != "/media":
                self.send_error(404); return
            start, end = 0, size - 1
            header = self.headers.get("Range")
            if header:
                match = re.fullmatch(r"bytes=(\d+)-(\d*)", header)
                if not match:
                    self.send_error(416); return
                start = int(match[1]); end = min(int(match[2]) if match[2] else size - 1, size - 1)
                if start > end:
                    self.send_response(416); self.send_header("Content-Range", f"bytes */{size}")
                    self.send_header("Content-Length", "0"); self.end_headers(); return
            self.send_response(206 if header else 200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("Content-Length", str(end - start + 1))
            if header:
                self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
            self.end_headers()
            if head:
                return
            with lock:
                state["requests"] += 1
                if state["firstRequestUptime"] is None:
                    state["firstRequestUptime"] = time.monotonic()
            try:
                with args.file.open("rb") as source:
                    source.seek(start)
                    remaining = end - start + 1
                    while remaining:
                        with lock:
                            trigger = args.stall_at >= 0 and not state["stallStarted"] and time.monotonic() - state["firstRequestUptime"] >= args.stall_at
                            if trigger:
                                state["stallStarted"] = True
                                state["stallUptime"] = time.monotonic()
                        if trigger:
                            time.sleep(max(0, min(args.stall_for, 30)))
                        data = source.read(min(256 * 1024, remaining))
                        if not data:
                            break
                        self.wfile.write(data)
                        remaining -= len(data)
                        with lock:
                            state["bytes"] += len(data)
            except (BrokenPipeError, ConnectionResetError):
                pass
            finally:
                with lock:
                    args.output.with_suffix(".stats.json").write_text(json.dumps(state, indent=2) + "\n")

    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    args.output.write_text(json.dumps({"url": f"http://127.0.0.1:{server.server_port}/media", "bytes": size,
        "scope": "controlled-loopback-http", "stallAtSeconds": args.stall_at, "stallForSeconds": args.stall_for}, indent=2) + "\n")
    print(f"Serving fixed fixture on loopback port {server.server_port}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
