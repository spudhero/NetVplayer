#!/usr/bin/env python3
"""Loopback-only synthetic FnOS / Zspace media services, not vendor acceptance.

Uses only explicitly selected local files. Account values are public fixtures.
Run each kind on a separate port; --port 0 chooses a free port in --summary.
"""
import argparse
import hashlib
import json
import re
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from threading import Lock
from urllib.parse import parse_qs, urlsplit

TOKEN = "nas-synthetic-token"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--kind", choices=["fnos", "zspace"], required=True)
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--media", type=Path, required=True)
    parser.add_argument("--artwork", type=Path)
    parser.add_argument("--unplayable", action="store_true", help="Simulate an unavailable original file")
    parser.add_argument("--summary", type=Path, required=True)
    args = parser.parse_args()
    media = args.media.resolve(strict=True)
    artwork = args.artwork.resolve(strict=True) if args.artwork else None
    size = media.stat().st_size
    lock = Lock()
    summary = {"synthetic": True, "kind": args.kind, "reports": [], "rangeReads": 0,
               "artworkReads": 0, "signatureFailures": 0, "logins": 0, "requests": []}

    def checkpoint():
        args.summary.parent.mkdir(parents=True, exist_ok=True)
        temporary = args.summary.with_suffix(".tmp")
        temporary.write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n")
        temporary.replace(args.summary)

    def fn_item(item_id):
        tv = item_id == "series1"
        episode = item_id.startswith("episode")
        return {"guid": item_id, "title": "模拟剧集" if tv else "协议验证样片 " + item_id,
                "original_title": "NAS protocol fixture", "type": "TV" if tv else "Episode" if episode else "Movie",
                "poster": "/fixture/poster.jpg", "posters": "/fixture/poster.jpg", "backdrops": "/fixture/backdrop.jpg",
                "overview": "本地模拟服务提供的影片资料，用于验证客户端海报、详情、播放与进度回传。",
                "release_date": "2026-10-22", "vote_average": "8.5", "duration": 90,
                "season_number": 1, "episode_number": 2 if item_id == "episode2" else 1,
                "can_play": 1, "production_countries": ["测试地区"]}

    def file(media_id):
        return {"guid": media_id, "file_name": "NAS 原始样片.mp4", "size": size, "can_play": 0 if args.unplayable else 1}

    def video(media_id):
        return {"guid": "video-" + media_id, "media_guid": media_id, "codec_name": "h264", "index": 0,
                "width": 960, "height": 540, "resolution_type": "540p", "color_range_type": "SDR", "bps": 2400000, "duration": 90}

    def audios(media_id):
        return [{"guid": "audio-" + media_id, "media_guid": media_id, "codec_name": "aac", "index": 1,
                 "channels": 1, "language": "und", "sample_rate": "48000"}]

    def subtitles(media_id):
        return [{"guid": "subtitle-" + media_id, "media_guid": media_id, "codec_name": "srt", "index": 3,
                 "is_external": 1, "title": "模拟中文字幕", "language": "zho"}]

    def emby_item(item_id):
        tv = item_id == "series1"
        return {"Id": item_id, "Name": "模拟剧集" if tv else "协议验证样片 " + item_id,
                "Type": "Series" if tv else "Episode" if item_id.startswith("episode") else "Movie",
                "IsFolder": tv, "MediaType": "Video", "ImageTags": {"Primary": "poster1"}, "BackdropImageTags": ["backdrop1"],
                "Overview": fn_item(item_id)["overview"], "ProductionYear": 2026, "RunTimeTicks": 900000000,
                "IndexNumber": 2 if item_id == "episode2" else 1, "ParentIndexNumber": 1,
                "UserData": {"PlaybackPositionTicks": summary.get("lastSeconds", 3) * 10000000},
                "MediaSources": emby_sources(item_id), "CommunityRating": 8.5, "Genres": ["测试"]}

    def emby_sources(item_id):
        return [{"Id": "source-" + item_id, "Name": "NAS 原始样片.mp4", "Size": size, "Container": "mp4",
                 "Protocol": "File", "SupportsDirectPlay": True, "MediaStreams": [
                     {"Index": 0, "Type": "Video", "Codec": "h264", "Width": 960, "Height": 540},
                     {"Index": 1, "Type": "Audio", "Codec": "aac", "Channels": 1},
                     {"Index": 3, "Type": "Subtitle", "Codec": "srt", "IsExternal": True,
                      "DeliveryUrl": "/emby/subtitle.srt", "DisplayTitle": "模拟中文字幕"}]}]

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *_):
            pass

        def send(self, data, status=200, content_type="application/json", headers=None):
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(data)))
            for key, value in (headers or {}).items():
                self.send_header(key, value)
            self.end_headers()
            try:
                self.wfile.write(data)
            except (BrokenPipeError, ConnectionResetError):
                pass

        def js(self, obj, status=200):
            self.send(json.dumps(obj, ensure_ascii=False).encode(), status)

        def reply(self, obj):
            self.js({"code": 0, "msg": "", "data": obj} if args.kind == "fnos" else obj)

        def do_GET(self):
            self.handle_api()

        def do_POST(self):
            self.handle_api()

        def handle_api(self):
            parts = urlsplit(self.path)
            path = parts.path
            if path == "/__summary":
                self.js(summary)
                return
            length = int(self.headers.get("Content-Length", "0"))
            if not 0 <= length <= 65536:
                self.js({}, 413)
                return
            raw = self.rfile.read(length)
            body = json.loads(raw) if raw else {}
            query = parse_qs(parts.query, keep_blank_values=True)
            with lock:
                summary["requests"].append(self.command + " " + path)
                checkpoint()
            is_login = path in ["/v/api/v1/login", "/emby/Users/AuthenticateByName"]
            is_public = path == "/v/api/v1/sys/config"
            if args.kind == "fnos":
                fields = dict(parse_qs(self.headers.get("Authx", "")))
                nonce = fields.get("nonce", [""])[0]
                timestamp = fields.get("timestamp", ["0"])[0]
                payload = raw if raw else "&".join(k + "=" + query[k][0] for k in sorted(query)).encode()
                digest = hashlib.md5(payload).hexdigest()
                signed = "_".join(["NDzZTVxnRKP8Z0jXg1VAMonaG8akvh", path, nonce, timestamp, digest,
                                   "16CCEB3D-AB42-077D-36A1-F355324E4237"])
                if fields.get("sign", [""])[0] != hashlib.md5(signed.encode()).hexdigest() or abs(int(timestamp) - time.time() * 1000) > 60000:
                    with lock:
                        summary["signatureFailures"] += 1
                        checkpoint()
                    self.js({"code": 403}, 403)
                    return
            elif not self.headers.get("X-Emby-Authorization", "").startswith("MediaBrowser "):
                self.js({}, 400)
                return
            expected_header = "Authorization" if args.kind == "fnos" else "X-Emby-Token"
            if not is_public and not is_login and self.headers.get(expected_header) != TOKEN:
                self.js({}, 401)
                return
            if is_login:
                user_key, password_key = ("username", "password") if args.kind == "fnos" else ("Username", "Pw")
                if body.get(user_key) != "fixture" or body.get(password_key) != "fixture-password":
                    self.js({"code": 401}, 401)
                    return
                with lock:
                    summary["logins"] += 1
                    checkpoint()
                self.reply({"token": TOKEN} if args.kind == "fnos" else {"AccessToken": TOKEN, "User": {"Id": 101, "Name": "fixture"}, "ServerId": "mock-zspace"})
                return
            tail = path.removeprefix("/v/api/v1/") if args.kind == "fnos" else path.removeprefix("/emby/")
            if tail == "sys/config":
                self.reply({"server_guid": "mock-fnos", "initialized": True})
            elif tail == "System/Info":
                self.reply({"Id": "mock-zspace", "Version": "4.7.0.0"})
            elif tail in ["user/info", "Users/101"]:
                self.reply({"guid": "user1", "username": "fixture"} if args.kind == "fnos" else {"Id": 101, "Name": "fixture"})
            elif tail in ["mediadb/list", "Users/101/Views"]:
                self.reply([{"guid": "library", "title": "飞牛模拟影视库", "category": "Mix"}] if args.kind == "fnos" else {"Items": [{"Id": "library", "Name": "极影视模拟影视库", "IsFolder": True}]})
            elif tail in ["item/list", "Users/101/Items"]:
                page = body.get("page", 1) if args.kind == "fnos" else int(query.get("StartIndex", ["0"])[0]) // 50 + 1
                ids = ["film1", "film2", "series1"] if page == 1 else []
                self.reply({"list": [fn_item(x) for x in ids], "total": 3} if args.kind == "fnos" else {"Items": [emby_item(x) for x in ids], "TotalRecordCount": 3})
            elif tail == "search/list":
                self.reply([fn_item("film1")])
            elif tail.startswith("season/list/"):
                self.reply([{"guid": "season1", "title": "第 1 季", "season_number": 1}])
            elif tail.startswith("episode/list/") or tail == "Shows/series1/Episodes":
                self.reply([fn_item("episode1"), fn_item("episode2")] if args.kind == "fnos" else {"Items": [emby_item("episode1"), emby_item("episode2")], "TotalRecordCount": 2})
            elif tail.startswith("item/") or re.fullmatch(r"Users/101/Items/[\w-]+", tail):
                item_id = tail.rsplit("/", 1)[1]
                self.reply(fn_item(item_id) if args.kind == "fnos" else emby_item(item_id))
            elif tail.startswith("stream/list/"):
                ids = ["source-" + tail.rsplit("/", 1)[1]]
                self.reply({"files": [file(x) for x in ids], "video_streams": [video(x) for x in ids],
                            "audio_streams": sum([audios(x) for x in ids], []), "subtitle_streams": sum([subtitles(x) for x in ids], [])})
            elif tail == "play/info":
                item_id = body["item_guid"]
                self.reply({"guid": item_id, "item": fn_item(item_id), "media_guid": body.get("media_guid", "source-" + item_id), "ts": summary.get("lastSeconds", 3)})
            elif tail == "stream":
                media_id = body["media_guid"]
                self.reply({"file_stream": file(media_id), "video_stream": video(media_id), "audio_streams": audios(media_id), "subtitle_streams": subtitles(media_id)})
            elif tail.endswith("/PlaybackInfo"):
                self.reply({"MediaSources": emby_sources(tail.split("/")[1]), "PlaySessionId": "fixture-session"})
            elif tail == "play/record" or tail.startswith("Sessions/Playing"):
                seconds = body.get("ts", int(body.get("PositionTicks", 0)) // 10000000)
                with lock:
                    summary["reports"].append({"seconds": seconds, "item": body.get("item_guid", body.get("ItemId")),
                                               "media": body.get("media_guid", body.get("MediaSourceId")), "phase": tail})
                    summary["lastSeconds"] = seconds
                    checkpoint()
                self.reply(True)
            elif tail in ["user/logout", "Sessions/Logout"]:
                self.reply(True)
            elif tail.startswith("media/range/") or tail.endswith("/stream"):
                value = self.headers.get("Range", "")
                match = re.fullmatch(r"bytes=(\d+)-(\d*)", value)
                if not match:
                    self.js({}, 416)
                    return
                start, end = int(match[1]), min(size, int(match[2]) + 1 if match[2] else size)
                if not 0 <= start < end <= size:
                    self.js({}, 416)
                    return
                with media.open("rb") as source:
                    source.seek(start)
                    data = source.read(end - start)
                with lock:
                    summary["rangeReads"] += 1
                    checkpoint()
                self.send(data, 206, "video/mp4", {"Accept-Ranges": "bytes", "Content-Range": f"bytes {start}-{end-1}/{size}"})
            elif tail.startswith("subtitle/dl/") or tail == "subtitle.srt":
                self.send("1\n00:00:00,000 --> 00:01:30,000\n本地模拟服务 · 字幕读取通过\n".encode(), content_type="application/x-subrip")
            elif tail.startswith("sys/img/") or "/Images/" in tail:
                with lock:
                    summary["artworkReads"] += 1
                    checkpoint()
                self.send(artwork.read_bytes() if artwork else b"synthetic-jpeg", content_type="image/jpeg")
            else:
                self.js({}, 404)

    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    server.daemon_threads = True
    summary["port"] = server.server_port
    checkpoint()
    server.serve_forever()


if __name__ == "__main__":
    main()
