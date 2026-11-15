#!/usr/bin/env python3
"""Synthetic Emby/Jellyfin-shaped loopback fixture, never a real-server acceptance.

Only serves an explicitly selected local media file. It does not scan, modify,
or upload any library. Tokens and login values below are public test constants.
"""
import argparse
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from threading import Lock
from urllib.parse import parse_qs, urlsplit

TOKEN = "netvplayer-synthetic-loopback-token"
lock = Lock()
summary = {"synthetic": True, "reports": [], "rangeReads": 0, "cdnExpired": 0, "credentialLeaks": 0, "playbackInfoRequests": 0}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--media", type=Path, required=True)
    parser.add_argument("--summary", type=Path, required=True)
    parser.add_argument("--port", type=int, default=18096)
    args = parser.parse_args()
    media = args.media.resolve(strict=True)
    size = media.stat().st_size
    args.summary.parent.mkdir(parents=True, exist_ok=True)

    def checkpoint():
        args.summary.write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n")

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *_):
            pass

        def send(self, status, body=b"", content_type="application/json", headers=None):
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            for key, value in (headers or {}).items():
                self.send_header(key, value)
            self.end_headers()
            if self.command != "HEAD":
                try:
                    self.wfile.write(body)
                except (BrokenPipeError, ConnectionResetError):
                    pass

        def js(self, obj, status=200):
            self.send(status, json.dumps(obj).encode())

        def item(self, item_id):
            return {"Id": item_id, "Name": "Synthetic server fixture " + item_id,
                    "Type": "Movie", "MediaType": "Video", "RunTimeTicks": 600_000_000,
                    "Overview": "Local contract fixture; not a connected Emby or Jellyfin server.",
                    "UserData": {"PlaybackPositionTicks": 120_000_000},
                    "Chapters": [{"Name": name, "StartPositionTicks": value * 10_000_000}
                                 for name, value in [("Start", 0), ("Middle", 10), ("End", 20)]]}

        def do_HEAD(self):
            self.do_GET()

        def do_GET(self):
            parsed = urlsplit(self.path)
            path = parsed.path
            if path.startswith("/cdn/"):
                with lock:
                    summary["cdnExpired"] += 1
                    if any(self.headers.get(key) for key in ["X-Emby-Token", "Authorization", "Cookie"]):
                        summary["credentialLeaks"] += 1
                    if TOKEN in self.path:
                        summary["credentialLeaks"] += 1
                    checkpoint()
                self.js({}, 410)
                return
            if path.endswith("/System/Info/Public"):
                self.js({"Id": "synthetic-server1"})
                return
            if self.headers.get("X-Emby-Token") != TOKEN:
                self.js({}, 401)
                return
            user_path = "/Users/synthetic-user1" if "/emby/" in path else "/Users/Me"
            if path.endswith(user_path):
                self.js({"Id": "synthetic-user1"})
            elif path.endswith("/Views"):
                self.js({"Items": [{"Id": "library", "Name": "Synthetic library", "IsFolder": True}]})
            elif "/Users/" in path and path.endswith("/Items"):
                self.js({"Items": [self.item("film1"), self.item("film2")], "TotalRecordCount": 2})
            elif path.endswith("/Items/film1") or path.endswith("/Items/film2"):
                self.js(self.item(path.rsplit("/", 1)[1]))
            elif path.endswith("/Stream.srt"):
                self.send(200, b"1\n00:00:00,000 --> 00:01:00,000\nSynthetic external subtitle\n", "application/x-subrip")
            elif path.endswith("/stream"):
                value = self.headers.get("Range", "")
                lower, upper = 0, size
                if value.startswith("bytes="):
                    start, end = value[6:].split("-", 1)
                    lower = int(start)
                    upper = min(size, int(end) + 1 if end else size)
                if lower < 0 or lower >= size or upper <= lower:
                    self.send(416)
                    return
                with media.open("rb") as source:
                    source.seek(lower)
                    body = source.read(upper - lower)
                with lock:
                    summary["rangeReads"] += 1
                    checkpoint()
                self.send(206 if value else 200, body, "video/x-matroska", {
                    "Accept-Ranges": "bytes", "Content-Range": f"bytes {lower}-{upper-1}/{size}"})
            else:
                self.js({}, 404)

        def do_POST(self):
            data = self.rfile.read(min(int(self.headers.get("Content-Length", "0")), 65536))
            body = json.loads(data or b"{}")
            path = urlsplit(self.path).path
            if path.endswith("/AuthenticateByName"):
                if body.get("Username") != "fixture" or body.get("Pw") != "fixture-password":
                    self.js({}, 401)
                else:
                    self.js({"AccessToken": TOKEN, "User": {"Id": "synthetic-user1"}, "ServerId": "synthetic-server1"})
                return
            if self.headers.get("X-Emby-Token") != TOKEN:
                self.js({}, 401)
                return
            if path.endswith("/PlaybackInfo"):
                item_id = path.split("/")[-2]
                with lock:
                    summary["playbackInfoRequests"] += 1
                    session_id = "synthetic-play-" + str(summary["playbackInfoRequests"])
                    checkpoint()
                self.js({"PlaySessionId": session_id, "MediaSources": [{
                    "Id": "source-" + item_id, "Size": size, "SupportsDirectPlay": True,
                    "Protocol": "Http", "Path": f"http://localhost:{args.port}/cdn/nested/film.mkv?signature=expired-fixture",
                    "MediaStreams": [{"Index": 4, "Type": "Subtitle", "Codec": "subrip", "Language": "eng", "IsExternal": True,
                                      "DisplayTitle": "Synthetic external subtitle"}]}]})
            elif "/Sessions/Playing" in path:
                with lock:
                    summary["reports"].append({"phase": path.split("/Sessions/Playing")[1] or "/Started",
                        **{key: body.get(key) for key in ["ItemId", "MediaSourceId", "PlaySessionId", "PositionTicks", "IsPaused",
                                                         "AudioStreamIndex", "SubtitleStreamIndex", "PlaybackRate"]}})
                    checkpoint()
                self.send(204)
            elif path.endswith("/Sessions/Logout"):
                self.send(204)
            else:
                self.js({}, 404)

    checkpoint()
    print(f"Synthetic fixture listening on 127.0.0.1:{args.port}; not a real media server.", flush=True)
    ThreadingHTTPServer(("127.0.0.1", args.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
