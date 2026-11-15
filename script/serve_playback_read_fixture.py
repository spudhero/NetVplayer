#!/usr/bin/env python3
"""Fixed loopback network trace for opt-in VOD rebuffer comparisons.

Each /media/<case> shares one byte clock across all its Range requests. Unique
case paths replay identical traces. This is not evidence of NAS/WAN performance.
"""
import argparse
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import re
import threading
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--file", type=Path, required=True)
    parser.add_argument("--trace", type=Path, required=True,
                        help="JSON array of {untilSeconds, bytesPerSecond}; final phase repeats")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--port", type=int, default=0)
    args = parser.parse_args()
    phases = json.loads(args.trace.read_text())
    assert phases and phases[-1]["bytesPerSecond"] > 0, "Final phase must restore the connection"
    previous = 0
    for phase in phases:
        assert phase["untilSeconds"] > previous and phase["bytesPerSecond"] >= 0
        previous = phase["untilSeconds"]
    size = args.file.stat().st_size
    lock = threading.Lock()
    states = {}

    def stats():
        with lock:
            return {key: {k: v for k, v in state.items() if k not in ("clock", "first")}
                    for key, state in states.items()}

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def handle(self):
            try:
                super().handle()
            except (BrokenPipeError, ConnectionResetError):
                pass  # A cancelled libmpv Range may reset an idle keep-alive socket.

        def log_message(self, *_):
            pass

        def do_HEAD(self):
            self.respond(True)

        def do_GET(self):
            self.respond(False)

        def respond(self, head):
            if self.path == "/stats":
                data = json.dumps(stats()).encode()
                self.send_response(200); self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                if not head:
                    self.wfile.write(data)
                return
            match = re.fullmatch(r"/media/([A-Za-z0-9_-]+)", self.path)
            if not match:
                self.send_error(404); return
            case = match[1]
            start, end = 0, size - 1
            raw = self.headers.get("Range")
            if raw:
                interval = re.fullmatch(r"bytes=(\d+)-(\d*)", raw)
                if not interval:
                    self.send_error(416); return
                start = int(interval[1]); end = min(int(interval[2]) if interval[2] else size - 1, size - 1)
            if start > end:
                self.send_response(416); self.send_header("Content-Range", f"bytes */{size}")
                self.send_header("Content-Length", "0"); self.end_headers(); return
            self.send_response(206 if raw else 200)
            self.send_header("Content-Type", "video/mp4")
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("Content-Length", str(end - start + 1))
            if raw:
                self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
            self.end_headers()
            if head:
                return
            with lock:
                state = states.setdefault(case, {"first": time.monotonic(), "clock": time.monotonic(),
                    "requests": 0, "bytes": 0, "cancelledResponses": 0, "ranges": []})
                state["requests"] += 1
                state["ranges"].append([start, end])
            try:
                with args.file.open("rb") as source:
                    source.seek(start)
                    remaining = end - start + 1
                    while remaining:
                        count = min(16 * 1024, remaining)
                        while True:
                            with lock:
                                now = time.monotonic()
                                elapsed = now - state["first"]
                                phase = next((p for p in phases if elapsed < p["untilSeconds"]), phases[-1])
                                rate = phase["bytesPerSecond"]
                                if rate:
                                    send_at = max(now, state["clock"])
                                    state["clock"] = send_at + count / rate
                                    delay = max(0, send_at - now)
                                else:
                                    delay = min(0.05, max(0, phase["untilSeconds"] - elapsed))
                            if rate:
                                time.sleep(delay); break
                            time.sleep(max(0.001, delay))
                        data = source.read(count)
                        if not data:
                            break
                        self.wfile.write(data); remaining -= len(data)
                        with lock:
                            state["bytes"] += len(data)
            except (BrokenPipeError, ConnectionResetError):
                with lock:
                    state["cancelledResponses"] += 1
            finally:
                # The HTTP /stats snapshot is authoritative while other requests
                # are still active; this file is a recoverable completed snapshot.
                with lock:
                    snapshot = {key: {k: v for k, v in state.items() if k not in ("clock", "first")}
                                for key, state in states.items()}
                    args.output.with_suffix(".stats.json").write_text(json.dumps(snapshot, indent=2) + "\n")

    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    server.daemon_threads = True
    args.output.write_text(json.dumps({"baseURL": f"http://127.0.0.1:{server.server_port}", "size": size,
        "fileSHA256": hashlib.sha256(args.file.read_bytes()).hexdigest(), "trace": phases,
        "scope": "controlled-loopback-http"}, indent=2) + "\n")
    print(f"Fixed read fixture listening on loopback port {server.server_port}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
