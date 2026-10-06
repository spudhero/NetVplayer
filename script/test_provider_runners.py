#!/usr/bin/env python3
from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse


ROOT = Path(__file__).resolve().parents[1]
NODE = shutil.which("node")
JAVA = shutil.which("java")
JAVA_RUNNER = os.environ.get("NETVPLAYER_JAVA_RUNNER")
JAVA_PROVIDER = os.environ.get("NETVPLAYER_JAVA_PROVIDER")
JAVA_CMS_PROVIDER = os.environ.get("NETVPLAYER_JAVA_CMS_PROVIDER")
JAVA_BILI_PROVIDER = os.environ.get("NETVPLAYER_JAVA_BILI_PROVIDER")


class RunnerProcess:
    def __init__(
        self,
        command: list[str],
        provider: Path,
        provider_id: str,
        package_root: Path | None = None,
        environment_overrides: dict[str, str] | None = None,
    ) -> None:
        environment = os.environ.copy()
        environment.update({
            "NETVPLAYER_PROVIDER_ROOT": str(package_root or provider.parents[1]),
            "NETVPLAYER_PROVIDER_ID": provider_id,
        })
        environment.update(environment_overrides or {})
        self.process = subprocess.Popen(
            command,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=environment,
        )
        self.provider_id = provider_id
        self.serial = 0

    def request(self, operation: str, arguments: dict | None = None, site: dict | None = None) -> dict:
        self.serial += 1
        payload = {
            "protocol": 1,
            "request_id": f"request-{self.serial}",
            "provider_id": self.provider_id,
            "operation": operation,
            "arguments": arguments or {},
        }
        if site is not None:
            payload["site"] = site
        assert self.process.stdin is not None
        assert self.process.stdout is not None
        self.process.stdin.write(json.dumps(payload, separators=(",", ":")) + "\n")
        self.process.stdin.flush()
        response = self.process.stdout.readline()
        if not response:
            stderr = self.process.stderr.read() if self.process.stderr else ""
            raise AssertionError(f"runner exited without response: {stderr}")
        return json.loads(response)

    def close(self) -> None:
        try:
            if self.process.poll() is None:
                response = self.request("shutdown")
                if not response.get("ok"):
                    raise AssertionError(response)
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            self.process.wait(timeout=2)
            raise
        finally:
            for stream in (self.process.stdin, self.process.stdout, self.process.stderr):
                if stream is not None:
                    stream.close()


def assert_lifecycle(
    test: unittest.TestCase,
    process: RunnerProcess,
    init_arguments: dict | None = None,
) -> None:
    test.assertTrue(process.request("handshake")["ok"])
    test.assertTrue(process.request(
        "init",
        init_arguments or {"extend": {"token": "opaque"}},
    )["ok"])
    test.assertIn("class", process.request("home")["result"])
    search = process.request("search", {"keyword": "poc"})["result"]
    test.assertEqual(search["list"][0]["vod_id"], "poc")
    detail = process.request("detail", {"ids": ["poc"]})["result"]
    test.assertEqual(detail["list"][0]["vod_id"], "poc")
    player = process.request("player", {"flag": "poc", "id": "asset"})["result"]
    test.assertEqual(player["parse"], 0)
    test.assertIn("Referer", player["header"])
    live = process.request("live", {"url": "https://example.invalid/live.m3u8"})["result"]
    test.assertEqual(live["parse"], 0)
    test.assertTrue(process.request("manual_video_check")["result"])
    test.assertTrue(process.request("is_video_format", {"url": "https://example.invalid/video.m3u8"})["result"])
    proxy = process.request("proxy", {"parameters": {"range": "bytes=0-8"}})["proxy"]
    test.assertEqual(proxy["status_code"], 206)
    test.assertEqual(proxy["body_base64"], "cG9jLWJ5dGVz")
    action = process.request("action", {"action": "refresh", "value": "ignored"})["result"]
    test.assertEqual(action["action"], "refresh")
    cancel = process.request("cancel", {"target_request_id": "request-1"})["result"]
    test.assertEqual(cancel["cancelled"], "request-1")
    test.assertTrue(process.request("destroy")["ok"])


class ProviderRunnerTests(unittest.TestCase):
    def test_python_catvod_lifecycle(self) -> None:
        provider = ROOT / "provider-runners/python/fixtures/mock_provider.py"
        process = RunnerProcess([
            sys.executable, "-I", "-S",
            str(ROOT / "provider-runners/python/provider_runner.py"),
            "--provider", str(provider),
        ], provider, "fixture.python")
        try:
            assert_lifecycle(self, process)
        finally:
            process.close()

    def test_python_init_optionally_receives_wire_site(self) -> None:
        provider = ROOT / "provider-runners/python/fixtures/mock_provider.py"
        process = RunnerProcess([
            sys.executable, "-I", "-S",
            str(ROOT / "provider-runners/python/provider_runner.py"),
            "--provider", str(provider),
        ], provider, "fixture.python")
        try:
            site = {"key": "fixture-key", "api": "fixture-api", "ext": "opaque"}
            self.assertTrue(process.request("init", {"extend": "opaque"}, site=site)["ok"])
            received = process.request("action", {"action": "site"})["result"]
            self.assertEqual(received["site"], site)
        finally:
            process.close()

    @unittest.skipUnless(NODE, "Node.js is not installed")
    def test_javascript_catvod_lifecycle(self) -> None:
        provider = ROOT / "provider-runners/js/fixtures/mock_provider.mjs"
        process = RunnerProcess([
            str(NODE),
            str(ROOT / "provider-runners/js/provider_runner.mjs"),
            "--provider", str(provider),
        ], provider, "fixture.js")
        try:
            assert_lifecycle(self, process)
        finally:
            process.close()

    @unittest.skipUnless(JAVA and JAVA_RUNNER and JAVA_PROVIDER, "Built Java fixture was not supplied")
    def test_java_catvod_lifecycle(self) -> None:
        provider = Path(str(JAVA_PROVIDER)).resolve()
        runner = Path(str(JAVA_RUNNER)).resolve()
        process = RunnerProcess([
            str(JAVA), "-jar", str(runner), "--provider", str(provider),
            "--class", "com.netvplayer.fixture.MockProvider",
        ], provider, "fixture.java", package_root=runner.parent)
        try:
            assert_lifecycle(self, process)
        finally:
            process.close()

    @unittest.skipUnless(JAVA and JAVA_RUNNER and JAVA_CMS_PROVIDER, "Java CMS fixture was not supplied")
    def test_java_standard_json_cms_lifecycle(self) -> None:
        class CMSHandler(BaseHTTPRequestHandler):
            def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
                body = json.dumps({
                    "class": [{"type_id": "movie", "type_name": "Movies"}],
                    "list": [{
                        "vod_id": "poc",
                        "vod_name": "JSON CMS POC",
                        "vod_play_from": "poc",
                        "vod_play_url": "Episode$https://example.invalid/poc.m3u8",
                    }],
                }).encode("utf-8")
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, format: str, *args: object) -> None:
                return

        server = ThreadingHTTPServer(("127.0.0.1", 0), CMSHandler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        provider = Path(str(JAVA_CMS_PROVIDER)).resolve()
        runner = Path(str(JAVA_RUNNER)).resolve()
        process = RunnerProcess([
            str(JAVA), "-jar", str(runner), "--provider", str(provider),
            "--class", "com.netvplayer.fixture.JsonCmsProvider",
        ], provider, "fixture.java.cms", package_root=runner.parent)
        try:
            assert_lifecycle(
                self,
                process,
                {"extend": {"base_url": f"http://127.0.0.1:{server.server_port}/cms"}},
            )
        finally:
            process.close()
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)

    @unittest.skipUnless(JAVA and JAVA_RUNNER and JAVA_BILI_PROVIDER, "Private Bili Java fixture was not supplied")
    def test_java_bili_provider_lifecycle(self) -> None:
        class BiliHandler(BaseHTTPRequestHandler):
            paths: list[str] = []
            request_headers: list[dict[str, str]] = []

            def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
                parsed = urlparse(self.path)
                query = parse_qs(parsed.query)
                self.paths.append(parsed.path)
                self.request_headers.append(dict(self.headers.items()))
                if parsed.path == "/x/web-interface/popular":
                    payload = {
                        "code": 0,
                        "data": {"list": [{
                            "aid": 123,
                            "bvid": "BV1FIXTURE",
                            "title": "Popular fixture",
                            "pic": "//img.example.invalid/popular.jpg",
                            "desc": "Popular description",
                            "duration": 90,
                        }]},
                    }
                elif parsed.path == "/x/web-interface/search/all/v2":
                    self.server.last_search_query = query  # type: ignore[attr-defined]
                    payload = {
                        "code": 0,
                        "data": {
                            "numResults": 1,
                            "numPages": 1,
                            "result": [{
                                "result_type": "video",
                                "data": [{
                                    "aid": 123,
                                    "bvid": "BV1FIXTURE",
                                    "title": "<em>Search</em> fixture",
                                    "pic": "//img.example.invalid/search.jpg",
                                    "description": "<em>Search</em> description",
                                    "duration": "01:30",
                                }],
                            }],
                        },
                    }
                elif parsed.path == "/x/web-interface/view":
                    payload = {
                        "code": 0,
                        "data": {
                            "aid": 123,
                            "bvid": "BV1FIXTURE",
                            "title": "Detail fixture",
                            "pic": "https://img.example.invalid/detail.jpg",
                            "desc": "Detail description",
                            "duration": 90,
                            "pages": [{"cid": 456, "part": "Episode 1"}],
                        },
                    }
                elif parsed.path == "/x/player/playurl":
                    payload = {
                        "code": 0,
                        "data": {
                            "durl": [{
                                "url": "https://media.example.invalid/video.mp4",
                                "size": 4096,
                            }],
                        },
                    }
                else:
                    self.send_error(404)
                    return
                body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, format: str, *args: object) -> None:
                return

        server = ThreadingHTTPServer(("127.0.0.1", 0), BiliHandler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        provider = Path(str(JAVA_BILI_PROVIDER)).resolve()
        runner = Path(str(JAVA_RUNNER)).resolve()
        process = RunnerProcess([
            str(JAVA),
            f"-Dnetvplayer.bili.apiBase=http://127.0.0.1:{server.server_port}",
            "-jar", str(runner), "--provider", str(provider),
            "--class", "com.netvplayer.privateprovider.bili.BiliProvider",
        ], provider, "migration.bili.java", package_root=runner.parent)
        try:
            self.assertTrue(process.request("handshake")["ok"])
            self.assertTrue(process.request("init")["ok"])
            home = process.request("home")["result"]
            self.assertEqual(home["list"][0]["vod_id"], "BV1FIXTURE@123")
            self.assertGreater(len(home["class"]), 0)
            category = process.request("category", {
                "category_id": "movie",
                "page": "1",
                "extend": {"order": "pubdate", "duration": "2"},
            })["result"]
            self.assertEqual(category["list"][0]["vod_name"], "Search fixture")
            self.assertEqual(server.last_search_query["order"], ["pubdate"])  # type: ignore[attr-defined]
            search = process.request("search", {"keyword": "fixture", "page": "1"})["result"]
            self.assertEqual(search["total"], 1)
            detail = process.request("detail", {"ids": ["BV1FIXTURE@123"]})["result"]
            episode = detail["list"][0]["vod_play_url"].split("$", 1)[1]
            self.assertIn("aid=123", episode)
            self.assertIn("cid=456", episode)
            player = process.request("player", {"flag": "Bilibili", "id": episode})["result"]
            self.assertEqual(player["parse"], 0)
            self.assertEqual(player["format"], "bili-mp4")
            self.assertEqual(player["contentLength"], 4096)
            self.assertEqual(player["url"], "https://media.example.invalid/video.mp4")
            self.assertEqual(player["header"]["Referer"], "https://www.bilibili.com")
            self.assertTrue(process.request("destroy")["ok"])
            self.assertEqual(set(BiliHandler.paths), {
                "/x/web-interface/popular",
                "/x/web-interface/search/all/v2",
                "/x/web-interface/view",
                "/x/player/playurl",
            })
            self.assertTrue(all(headers.get("Referer") == "https://www.bilibili.com" for headers in BiliHandler.request_headers))
            self.assertTrue(all("Cookie" not in headers for headers in BiliHandler.request_headers))
        finally:
            process.close()
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)


if __name__ == "__main__":
    unittest.main()
