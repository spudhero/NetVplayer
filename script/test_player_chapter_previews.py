#!/usr/bin/env python3
"""Run chapter preview regressions with a real frame and authenticated Range fixture."""

import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
from threading import Thread


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixture", type=Path, help="existing 320x180 video: 3 seconds red, then 3 seconds blue")
    parser.add_argument("--full", action="store_true", help="run all serial Swift tests instead of the chapter selection")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]

    with tempfile.TemporaryDirectory(prefix="netvplayer-chapter-tests-") as temporary:
        fixture = args.fixture.resolve() if args.fixture else Path(temporary) / "red-blue.mp4"
        if args.fixture:
            if not fixture.is_file():
                parser.error("--fixture must be an existing video file")
        else:
            ffmpeg = shutil.which("ffmpeg")
            if not ffmpeg:
                parser.error("install FFmpeg for fixture generation or provide --fixture; the app does not need FFmpeg")
            subprocess.run([
                ffmpeg, "-hide_banner", "-loglevel", "error", "-y",
                "-f", "lavfi", "-i", "color=c=red:s=320x180:r=2:d=3",
                "-f", "lavfi", "-i", "color=c=blue:s=320x180:r=2:d=3",
                "-filter_complex", "[0:v][1:v]concat=n=2:v=1:a=0[v]", "-map", "[v]",
                "-an", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-movflags", "+faststart", str(fixture),
            ], check=True)
        blob = fixture.read_bytes()

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *unused):
                pass

            def do_HEAD(self):
                self.serve(send_body=False)

            def do_GET(self):
                self.serve(send_body=True)

            def serve(self, send_body):
                if (self.path != "/fixture.mp4"
                    or self.headers.get("Cookie") != "preview-token=fixture"
                    or self.headers.get("Referer") != "https://fixture.invalid/"):
                    self.send_response(403)
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
                start, end = 0, len(blob) - 1
                requested = self.headers.get("Range")
                match = re.fullmatch(r"bytes=(\d+)-(\d*)", requested or "")
                if match:
                    start = int(match[1])
                    end = min(end, int(match[2])) if match[2] else end
                if (requested and not match) or start >= len(blob) or end < start:
                    self.send_response(416)
                    self.send_header("Content-Range", f"bytes */{len(blob)}")
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
                self.send_response(206 if match else 200)
                self.send_header("Content-Type", "video/mp4")
                self.send_header("Accept-Ranges", "bytes")
                self.send_header("Content-Length", str(end - start + 1))
                if match:
                    self.send_header("Content-Range", f"bytes {start}-{end}/{len(blob)}")
                self.end_headers()
                if send_body:
                    self.wfile.write(blob[start:end + 1])

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            env = os.environ.copy()
            env["NETVPLAYER_CHAPTER_PREVIEW_FIXTURE"] = str(fixture)
            env["NETVPLAYER_CHAPTER_PREVIEW_URL"] = f"http://127.0.0.1:{server.server_port}/fixture.mp4"
            command = ["swift", "test", "--package-path", "NetVplayer", "--disable-sandbox", "--no-parallel"]
            if not args.full:
                command += ["--filter", "PlayerChapterPreviewTests|PlayerChapterThumbnailViewTests|PlayerTimelinePreviewTests|PlayerHUDVisualPolicyTests|PlayerVisualRegressionTests|chapterMetadata"]
            return subprocess.run(command, cwd=root, env=env).returncode
        finally:
            server.shutdown()
            server.server_close()
            thread.join()


if __name__ == "__main__":
    raise SystemExit(main())
