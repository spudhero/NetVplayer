#!/usr/bin/env python3
"""Local, synthetic media for the optional OV87 catch-up native integration test."""
import argparse
import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import re
import shutil
import subprocess
import time
from urllib.parse import urlparse, parse_qs


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--directory", type=Path, required=True)
    parser.add_argument("--ffmpeg", default=shutil.which("ffmpeg"))
    args = parser.parse_args()
    if not args.ffmpeg:
        parser.error("ffmpeg is required to generate synthetic media")
    root = args.directory.resolve()
    root.mkdir(parents=True, exist_ok=True)
    subprocess.run([args.ffmpeg, "-hide_banner", "-loglevel", "error", "-y",
                    "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=24", "-t", "30",
                    "-an", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-preset", "ultrafast",
                    "-g", "24", "-movflags", "+faststart", str(root / "fixture.mp4")], check=True)
    subprocess.run([args.ffmpeg, "-hide_banner", "-loglevel", "error", "-y",
                    "-i", str(root / "fixture.mp4"), "-c", "copy", "-hls_time", "2", "-hls_list_size", "0",
                    "-hls_segment_filename", str(root / "segment-%02d.ts"), str(root / "fixture.m3u8")], check=True)
    records = root / "requests.jsonl"
    archive_start = int(time.time() // 86_400) * 86_400 - 86_400 + 4 * 3_600 + 10 * 60 + 7

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def do_GET(self):
            parsed = urlparse(self.path)
            query = parse_qs(parsed.query)
            logged_path = re.sub(r"^/(timeshift|live)/[^/]+/[^/]+/", r"/\1/<account>/<secret>/", parsed.path)
            logged_query = {key: value for key, value in query.items() if key not in ("username", "password")}
            with records.open("a") as output:
                output.write(json.dumps({"time": time.time(), "path": logged_path, "query": logged_query,
                                         "range": self.headers.get("Range")}) + "\n")
            if parsed.path == "/player_api.php":
                if query.get("username") != ["fixture-user"] or query.get("password") != ["fixture-pass"]:
                    self.send_error(401)
                    return
                action = query.get("action", ["auth"])[0]
                payload = {
                    "auth": {"user_info": {"auth": 1, "status": "Active"}, "server_info": {"timezone": "Asia/Kathmandu"}},
                    "get_live_categories": [{"category_id": "1", "category_name": "Synthetic archives"}],
                    "get_live_streams": [{"stream_id": 41, "name": "Synthetic Xtream archive", "category_id": "1", "tv_archive": 1, "tv_archive_duration": 7}],
                    "get_simple_data_table": {"epg_listings": [
                        {"title": "Synthetic archive with second offset", "start_timestamp": archive_start,
                         "stop_timestamp": archive_start + 3600, "has_archive": 1},
                        {"title": "No recording retained", "start_timestamp": archive_start + 3600,
                         "stop_timestamp": archive_start + 7200, "has_archive": 0}]},
                    "get_short_epg": {"epg_listings": []},
                }.get(action, {})
                data, kind = json.dumps(payload).encode(), "application/json"
            elif parsed.path.startswith(("/timeshift/", "/live/")):
                if "/fixture-user/fixture-pass/" not in parsed.path:
                    self.send_error(401)
                    return
                data, kind = (root / "fixture.mp4").read_bytes(), "video/mp4"
            elif parsed.path == "/epg":
                date = query.get("date", [""])[0]
                try:
                    if datetime.date.fromisoformat(date).isoformat() != date:
                        raise ValueError("noncanonical date")
                except ValueError:
                    self.send_error(400)
                    return
                data = json.dumps({"date": date, "epg_data": [
                    {"start": f"{hour:02}:00", "end": f"{hour + 1:02}:00",
                     "title": f"Synthetic history {date} {hour:02}"} for hour in range(24)
                ]}).encode()
                kind = "application/json"
            elif parsed.path == "/live.m3u8":
                data = (root / "fixture.m3u8").read_bytes().replace(b"#EXT-X-ENDLIST\n", b"")
                kind = "application/vnd.apple.mpegurl"
            else:
                path = root / Path(parsed.path).name
                if not path.is_file():
                    self.send_error(404)
                    return
                data = path.read_bytes()
                kind = "video/mp4" if path.suffix == ".mp4" else "video/mp2t"
            size = len(data)
            match = re.fullmatch(r"bytes=(\d+)-(\d*)", self.headers.get("Range", ""))
            if match:
                start = int(match[1])
                end = min(size - 1, int(match[2]) if match[2] else size - 1)
                if start >= size:
                    self.send_response(416)
                    self.send_header("Content-Range", f"bytes */{size}")
                    self.end_headers()
                    return
                self.send_response(206)
                self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
                data = data[start:end + 1]
            else:
                self.send_response(200)
            self.send_header("Content-Type", kind)
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            try:
                self.wfile.write(data)
            except (BrokenPipeError, ConnectionResetError):
                pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    (root / "server.json").write_text(json.dumps({"baseURL": f"http://127.0.0.1:{server.server_port}", "programmeStart": archive_start}))
    print(f"Fixture ready: {root / 'server.json'}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
