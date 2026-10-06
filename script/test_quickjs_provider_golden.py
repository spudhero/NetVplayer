#!/usr/bin/env python3
"""Run a real locked QuickJS provider against the host JSONL golden contract."""

from __future__ import annotations

import json
import base64
from collections import Counter
import os
import platform
from pathlib import Path
import queue
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
from prepare_embedded_quickjs_runtime import prepare


ROOT = Path(__file__).resolve().parents[1]


class QuickJSProviderGoldenTests(unittest.TestCase):
    def test_locked_qjs_executes_http_jsp_crypto_persistence_and_proxy_contract(self) -> None:
        cache = Path(os.environ.get(
            "NETVPLAYER_QUICKJS_RUNTIME_CACHE",
            "/tmp/netvplayer-quickjs-runtime-cache",
        ))
        with tempfile.TemporaryDirectory(prefix="netvplayer-quickjs-golden-") as temporary:
            root = Path(temporary)
            runtime = root / "runtimes/quickjs"
            prepare(
                ROOT / "provider-runners/quickjs-runtime-lock-v1.json",
                cache,
                runtime,
                platform.machine(),
            )
            runner = root / "provider-runners/quickjs/provider_runner.mjs"
            host_api = root / "provider-runners/quickjs/host_api.mjs"
            provider = root / "provider-runners/quickjs/http_jsp_golden_provider.mjs"
            runner.parent.mkdir(parents=True)
            shutil.copy2(ROOT / "provider-runners/quickjs/provider_runner.mjs", runner)
            shutil.copy2(ROOT / "provider-runners/quickjs/host_api.mjs", host_api)
            shutil.copy2(
                ROOT / "provider-runners/quickjs/fixtures/http_jsp_golden_provider.mjs",
                provider,
            )
            shutil.copy2(
                ROOT / "provider-runners/quickjs/fixtures/module_golden_helper.mjs",
                provider.parent / "module_golden_helper.mjs",
            )
            (root / "assets").mkdir()
            shutil.copy2(
                ROOT / "provider-runners/quickjs/fixtures/module_resource_asset.mjs",
                root / "assets/module_resource_asset.mjs",
            )
            (root / "js/lib").mkdir(parents=True)
            shutil.copy2(
                ROOT / "provider-runners/quickjs/fixtures/module_resource_lib.mjs",
                root / "js/lib/module_resource_lib.mjs",
            )

            provider_id = "fixture.quickjs.http-jsp-golden"
            environment = {
                "PATH": "/usr/bin:/bin",
                "LANG": "en_US.UTF-8",
                "LC_ALL": "en_US.UTF-8",
                "HOME": str(root / "home"),
                "TMPDIR": str(root / "tmp") + "/",
                "XDG_CACHE_HOME": str(root / "cache"),
                "XDG_CONFIG_HOME": str(root / "config"),
                "XDG_DATA_HOME": str(root / "data"),
                "NETVPLAYER_PROVIDER_ID": provider_id,
                "NETVPLAYER_PROVIDER_ROOT": str(root),
                "NETVPLAYER_PROVIDER_HOST_CAPABILITIES": "console,http,jsp,crypto,persistence,module,timer,text,local_proxy,url",
                "NETVPLAYER_MAX_PROXY_BYTES": "64",
            }
            for name in ("home", "tmp", "cache", "config", "data"):
                (root / name).mkdir()

            process = subprocess.Popen(
                [str(runtime / "bin/qjs"), str(runner), "--provider", str(provider), "--class", "Spider"],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                env=environment,
            )
            assert process.stdin is not None
            assert process.stdout is not None
            output: queue.Queue[str | None] = queue.Queue()
            recent_messages: list[dict[str, object]] = []

            def read_output() -> None:
                assert process.stdout is not None
                for line in process.stdout:
                    output.put(line)
                output.put(None)

            output_thread = threading.Thread(target=read_output, daemon=True)
            output_thread.start()

            def send(payload: dict[str, object]) -> None:
                process.stdin.write(json.dumps(payload, separators=(",", ":")) + "\n")
                process.stdin.flush()

            def receive() -> dict[str, object]:
                try:
                    line = output.get(timeout=10)
                except queue.Empty:
                    process.kill()
                    raise AssertionError(f"QuickJS golden provider timed out; recent={recent_messages[-8:]}")
                if line is None:
                    stderr = process.stderr.read() if process.stderr else ""
                    raise AssertionError(f"QuickJS golden provider exited early: {stderr}")
                message = json.loads(line)
                recent_messages.append(message)
                return message

            try:
                send({
                    "protocol": 1,
                    "request_id": "handshake",
                    "provider_id": provider_id,
                    "operation": "handshake",
                    "arguments": {},
                })
                handshake = receive()
                self.assertTrue(handshake["ok"])
                capabilities = handshake["result"]["capabilities"]
                self.assertIn("http", capabilities)
                self.assertIn("jsp", capabilities)
                self.assertIn("crypto", capabilities)
                self.assertIn("persistence", capabilities)
                self.assertIn("module", capabilities)
                self.assertIn("timer", capabilities)
                self.assertIn("text", capabilities)
                self.assertIn("local_proxy", capabilities)
                self.assertIn("url", capabilities)

                send({
                    "protocol": 1,
                    "request_id": "init",
                    "provider_id": provider_id,
                    "operation": "init",
                    "arguments": {},
                })
                host_requests: list[dict[str, object]] = []
                while True:
                    message = receive()
                    if message.get("type") == "host_cancel":
                        continue
                    if message.get("type") != "host_request":
                        init_response = message
                        break
                    host_requests.append(message)
                    if message.get("capability") == "http":
                        self.assertEqual(message["operation"], "request")
                        self.assertEqual(message["options"].get("method", "GET"), "GET")
                        if message["url"] == "https://golden.example.test/catalog":
                            self.assertEqual(message["options"]["headers"]["X-Golden"], "quickjs")
                            result = {
                                "code": 200,
                                "status": 200,
                                "headers": {"X-Golden-Response": "ok", "X-Golden-Multi": ["one", "two"]},
                                "content": "golden-body",
                                "content_base64": "Z29sZGVuLWJvZHk=",
                                "url": "https://golden.example.test/catalog",
                            }
                        elif message["url"] == "https://golden.example.test/bytes":
                            self.assertEqual(message["options"].get("buffer"), 1)
                            result = {
                                "code": 200,
                                "status": 200,
                                "headers": {"Content-Type": "application/octet-stream"},
                                "content": "",
                                "content_base64": "AH//gA==",
                                "url": "https://golden.example.test/bytes",
                            }
                        elif message["url"] == "https://golden.example.test/raw-bytes":
                            self.assertEqual(message["options"].get("buffer"), 3)
                            result = {
                                "code": 200,
                                "status": 200,
                                "headers": {"Content-Type": "application/octet-stream"},
                                "content": "",
                                "content_base64": "AP+A",
                                "url": "https://golden.example.test/raw-bytes",
                            }
                        elif message["url"] == "https://golden.example.test/unsupported-buffer":
                            self.assertEqual(message["options"].get("buffer"), 4)
                            result = {
                                "code": 200,
                                "status": 200,
                                "headers": {"Content-Type": "application/octet-stream"},
                                "content": "should-not-be-exposed",
                                "content_base64": "c2hvdWxkLW5vdC1iZS1leHBvc2Vk",
                                "url": "https://golden.example.test/unsupported-buffer",
                            }
                        elif message["url"] == "https://golden.example.test/failure":
                            send({
                                "type": "host_response",
                                "request_id": message["request_id"],
                                "ok": False,
                                "error": {"code": "request_failed", "message": "fixture failure"},
                            })
                            continue
                        elif message["url"] == "https://golden.example.test/cancel":
                            send({
                                "operation": "cancel",
                                "request_id": message["request_id"],
                            })
                            continue
                        elif message["url"] == "https://golden.example.test/module.mjs":
                            self.assertEqual(message["options"].get("buffer"), 0)
                            result = {
                                "code": 200,
                                "status": 200,
                                "headers": {"Content-Type": "text/javascript"},
                                "content": "remote-module",
                                "content_base64": "cmVtb3RlLW1vZHVsZQ==",
                                "url": "https://golden.example.test/module.mjs",
                            }
                        elif message["url"].startswith("https://golden.example.test/module-lru-"):
                            self.assertEqual(message["options"].get("buffer"), 0)
                            index = message["url"].removeprefix(
                                "https://golden.example.test/module-lru-"
                            ).removesuffix(".mjs")
                            source = f"module-lru-{index}"
                            result = {
                                "code": 200,
                                "status": 200,
                                "headers": {"Content-Type": "text/javascript"},
                                "content": source,
                                "content_base64": base64.b64encode(source.encode()).decode(),
                                "url": message["url"],
                            }
                        elif message["url"] == "http-invalid":
                            self.assertEqual(message["options"].get("buffer"), 0)
                            result = {
                                "code": 0,
                                "status": 0,
                                "headers": {},
                                "content": "",
                                "content_base64": "",
                                "url": "http-invalid",
                            }
                        else:
                            self.fail(f"Unexpected HTTP URL: {message['url']}")
                    elif message.get("capability") == "jsp":
                        options = message["options"]
                        mode = options["mode"]
                        values = {
                            "pdfa": ["<article class=\"card\">One</article>", "<article class=\"card\">Two</article>"],
                            "pdfh": "One",
                            "pd": "https://golden.example.test/two",
                            "pdfl": [
                                "One$https://golden.example.test/one",
                                "Two$https://golden.example.test/two",
                            ],
                        }
                        self.assertIn(mode, values)
                        result = {"value": values[mode]}
                    elif message.get("capability") == "crypto":
                        operation = message["operation"]
                        if operation == "aes" and message["options"]["mode"] == "AES/CBC/PKCS5":
                            result = {"value": "rkbumbtCClkN+Jkds7bQJw=="}
                        elif operation == "aes" and message["options"]["mode"] == "AES/GCM/NoPadding":
                            result = {"value": ""}
                        elif operation == "rsa" and message["options"]["key"] == "not-a-key":
                            result = {"value": ""}
                        else:
                            self.fail(f"Unexpected crypto operation: {message}")
                    elif message.get("capability") == "persistence":
                        operation = message["operation"]
                        self.assertEqual(message["options"]["rule"], "golden")
                        self.assertEqual(
                            message["options"]["key"],
                            "deleted" if operation == "delete" else "token",
                        )
                        if operation == "set":
                            self.assertEqual(message["options"]["value"], "persisted")
                            result = {"value": None}
                        elif operation == "get":
                            result = {"value": "persisted"}
                        elif operation == "delete":
                            result = {"value": None}
                        else:
                            self.fail(f"Unexpected persistence operation: {operation}")
                    elif message.get("capability") == "text":
                        operation = message["operation"]
                        value = message["options"]["value"]
                        self.assertIn(operation, {"s2t", "t2s"})
                        self.assertEqual(value, "简体中文" if operation == "s2t" else "繁體中文")
                        result = {"value": "簡體中文" if operation == "s2t" else "繁体中文"}
                    elif message.get("capability") == "local_proxy":
                        operation = message["operation"]
                        if operation == "get_port":
                            result = {"port": 9978}
                        elif operation == "get_proxy":
                            self.assertIsInstance(message["options"]["local"], bool)
                            result = {"url": "http://127.0.0.1:9978/proxy?do=js"}
                        elif operation == "js2_proxy":
                            options = message["options"]
                            self.assertIsInstance(options["dynamic"], bool)
                            self.assertEqual(options["site_type"], 1)
                            self.assertEqual(options["site_key"], "golden")
                            self.assertEqual(options["headers"], {"X-Test": "a b"})
                            result = {
                                "url": "http://127.0.0.1:9978/proxy?do=js&from=catvod&siteType=1&siteKey=golden&header=%7B%22X-Test%22%3A%22a+b%22%7D&url=https%3A%2F%2Fgolden.example.test%2Fvideo%3Ftoken%3Da%26b%3Dc",
                            }
                        else:
                            self.fail(f"Unexpected local proxy operation: {operation}")
                    else:
                        self.fail(f"Unexpected host capability: {message}")
                    send({
                        "type": "host_response",
                        "request_id": message["request_id"],
                        "ok": True,
                        "result": result,
                    })

                self.assertTrue(init_response["ok"], init_response)
                self.assertEqual(
                    init_response["result"],
                    {
                        "http": {
                            "code": 200,
                            "content_base64": "Z29sZGVuLWJvZHk=",
                            "header": "ok",
                            "multi_header": ["one", "two"],
                        },
                        "http_buffer_1": [0, 127, -1, -128],
                        "http_buffer_3": {
                            "is_uint8_array": True,
                            "bytes": [0, 255, 128],
                        },
                        "http_buffer_4_has_content": False,
                        "http_error": {"headers": {}, "content": "", "code": ""},
                        "http_callback_error": {"headers": {}, "content": "", "code": ""},
                        "http_async_error": {"headers": {}, "content": "", "code": ""},
                        "http_sync_via_http_code": 200,
                        "http_async_concurrent_codes": [200, 200, 200],
                        "http_async_stress_count": 32,
                        "fetch_async_cancelled": True,
                        "fetch_queue_cancelled_count": 8,
                        "fetch_failure_rejects": True,
                        "jsp": {
                            "cards": 2,
                            "title": "One",
                            "link": "https://golden.example.test/two",
                            "list": [
                                "One$https://golden.example.test/one",
                                "Two$https://golden.example.test/two",
                            ],
                        },
                        "crypto": {
                            "cipher": "rkbumbtCClkN+Jkds7bQJw==",
                            "invalid_cipher": "",
                            "invalid_rsa": "",
                        },
                        "local": {"token": "persisted"},
                        "timer": {
                            "cancelled_fired": False,
                            "cancelled_interval_fired": False,
                            "interval_ticks": 3,
                            "argument_sum": 5,
                            "stress_callbacks": 32,
                        },
                        "url": {
                            "relative": "https://example.test/a/detail?new=2#next",
                            "query": "https://example.test/a/b/page?new=2#next",
                            "fragment": "https://example.test/a/b/page?old=1#next",
                            "empty": "https://example.test/a/b/page?old=1",
                            "network": "https://cdn.example.test/media.ts",
                            "absolute": "https://cdn.example.test/media.ts",
                            "double_slash": "https://example.test/a//b/c",
                            "above_root": "https://example.test/x",
                        },
                        "proxy": {
                            "port": 9978,
                            "url": "http://127.0.0.1:9978/proxy?do=js",
                            "external_url": "http://127.0.0.1:9978/proxy?do=js",
                            "js": "http://127.0.0.1:9978/proxy?do=js&from=catvod&siteType=1&siteKey=golden&header=%7B%22X-Test%22%3A%22a+b%22%7D&url=https%3A%2F%2Fgolden.example.test%2Fvideo%3Ftoken%3Da%26b%3Dc",
                            "dynamic_js": "http://127.0.0.1:9978/proxy?do=js&from=catvod&siteType=1&siteKey=golden&header=%7B%22X-Test%22%3A%22a+b%22%7D&url=https%3A%2F%2Fgolden.example.test%2Fvideo%3Ftoken%3Da%26b%3Dc",
                        },
                        "text": {
                            "simplified_to_traditional": "簡體中文",
                            "traditional_to_simplified": "繁体中文",
                        },
                        "async_generator": {
                            "values": [1, 2],
                            "sum": 3,
                        },
                        "bigint": "18446744073709551616",
                        "module": {
                            "loads": 1,
                            "repeated": 1,
                            "resources": {
                                "http": True,
                                "http_repeated": True,
                                "asset": True,
                                "lib": True,
                                "missing": True,
                                "relative_denied": True,
                                "unsupported": True,
                                "remote_denied": True,
                                "uppercase_http": True,
                                "uppercase_assets": True,
                                "http_prefix_invalid": True,
                                "assets_prefix_invalid": True,
                                "http_after_clear": True,
                                "lru_values": True,
                                "lru_eviction": True,
                            },
                        },
                    },
                )
                capabilities_seen = [request["capability"] for request in host_requests]
                self.assertEqual(capabilities_seen[:46], ["http"] * 46)
                self.assertEqual(
                    Counter(capabilities_seen),
                    Counter({"http": 101, "crypto": 3, "persistence": 3, "local_proxy": 5, "text": 2, "jsp": 4}),
                )
                module_lru_requests = Counter(
                    request["url"]
                    for request in host_requests
                    if request["capability"] == "http"
                    and request["url"].startswith("https://golden.example.test/module-lru-")
                )
                self.assertEqual(
                    module_lru_requests,
                    Counter({
                        f"https://golden.example.test/module-lru-{index}.mjs": 2 if index == 0 else 1
                        for index in range(51)
                    }),
                )
                local_proxy_requests = [
                    request for request in host_requests if request["capability"] == "local_proxy"
                ]
                self.assertEqual(
                    [request["options"]["local"] for request in local_proxy_requests if request["operation"] == "get_proxy"],
                    [True, False],
                )
                self.assertEqual(
                    [request["options"]["dynamic"] for request in local_proxy_requests if request["operation"] == "js2_proxy"],
                    [False, True],
                )

                send({
                    "protocol": 1,
                    "request_id": "proxy-bytes",
                    "provider_id": provider_id,
                    "operation": "proxy",
                    "arguments": {"parameters": {"mode": "bytes"}},
                })
                proxy_bytes = receive()
                self.assertTrue(proxy_bytes["ok"])
                self.assertIsNone(proxy_bytes["result"])
                self.assertEqual(
                    proxy_bytes["proxy"],
                    {
                        "status_code": 206,
                        "content_type": "application/octet-stream",
                        "headers": {"Accept-Ranges": "bytes"},
                        "body_base64": "AAEC/w==",
                    },
                )

                send({
                    "protocol": 1,
                    "request_id": "proxy-stream",
                    "provider_id": provider_id,
                    "operation": "proxy",
                    "arguments": {"parameters": {"mode": "stream"}},
                })
                proxy_stream = receive()
                self.assertTrue(proxy_stream["ok"])
                self.assertEqual(
                    proxy_stream["proxy"],
                    {
                        "status_code": 200,
                        "content_type": "application/octet-stream",
                        "headers": {"X-Proxy": "stream"},
                        "body_base64": "AwR4eQ==",
                    },
                )

                send({
                    "protocol": 1,
                    "request_id": "proxy-buffer-base64",
                    "provider_id": provider_id,
                    "operation": "proxy",
                    "arguments": {"parameters": {"mode": "buffer-base64"}},
                })
                proxy_buffer = receive()
                self.assertTrue(proxy_buffer["ok"])
                self.assertEqual(
                    proxy_buffer["proxy"],
                    {
                        "status_code": 201,
                        "content_type": "application/octet-stream",
                        "headers": {"X-Proxy": "buffer-2"},
                        "body_base64": "AAEC/w==",
                    },
                )

                send({
                    "protocol": 1,
                    "request_id": "proxy-buffer-text",
                    "provider_id": provider_id,
                    "operation": "proxy",
                    "arguments": {"parameters": {"mode": "buffer-text"}},
                })
                proxy_buffer_text = receive()
                self.assertTrue(proxy_buffer_text["ok"])
                self.assertEqual(
                    proxy_buffer_text["proxy"],
                    {
                        "status_code": 200,
                        "content_type": "text/plain; charset=utf-8",
                        "headers": {"X-Proxy": "buffer-text"},
                        "body": "你好",
                    },
                )

                send({
                    "protocol": 1,
                    "request_id": "proxy-gzip",
                    "provider_id": provider_id,
                    "operation": "proxy",
                    "arguments": {"parameters": {"mode": "gzip"}},
                })
                proxy_gzip = receive()
                self.assertTrue(proxy_gzip["ok"])
                self.assertEqual(
                    proxy_gzip["proxy"],
                    {
                        "status_code": 206,
                        "content_type": "application/gzip",
                        "headers": {"Content-Encoding": "gzip", "X-Proxy": "gzip"},
                        "body_base64": "H4sIAAAAAAACA0tMSgYAwkEkNQMAAAA=",
                    },
                )

                send({
                    "protocol": 1,
                    "request_id": "proxy-gzip-stream",
                    "provider_id": provider_id,
                    "operation": "proxy",
                    "arguments": {"parameters": {"mode": "gzip-stream"}},
                })
                proxy_gzip_stream = receive()
                self.assertTrue(proxy_gzip_stream["ok"])
                self.assertEqual(
                    proxy_gzip_stream["proxy"],
                    {
                        "status_code": 206,
                        "content_type": "application/gzip",
                        "headers": {"Content-Encoding": "gzip", "X-Proxy": "gzip-stream"},
                        "body_base64": "H4sIAAAAAAACA0tMSgYAwkEkNQMAAAA=",
                    },
                )

                send({
                    "protocol": 1,
                    "request_id": "proxy-stream-stress",
                    "provider_id": provider_id,
                    "operation": "proxy",
                    "arguments": {"parameters": {"mode": "stream-stress"}},
                })
                proxy_stream_stress = receive()
                self.assertTrue(proxy_stream_stress["ok"])
                stress_bytes = b"".join(bytes((index, index ^ 0xff)) for index in range(32))
                self.assertEqual(
                    proxy_stream_stress["proxy"],
                    {
                        "status_code": 200,
                        "content_type": "application/octet-stream",
                        "headers": {"X-Proxy": "stream-stress"},
                        "body_base64": base64.b64encode(stress_bytes).decode(),
                    },
                )

                send({
                    "protocol": 1,
                    "request_id": "proxy-oversize",
                    "provider_id": provider_id,
                    "operation": "proxy",
                    "arguments": {"parameters": {"mode": "oversize"}},
                })
                proxy_oversize = receive()
                self.assertFalse(proxy_oversize["ok"])
                self.assertEqual(proxy_oversize["error"]["code"], "provider_error")
                self.assertIn("configured byte limit", proxy_oversize["error"]["message"])

                send({
                    "protocol": 1,
                    "request_id": "shutdown",
                    "provider_id": provider_id,
                    "operation": "shutdown",
                    "arguments": {},
                })
                shutdown = receive()
                self.assertTrue(shutdown["ok"])
                process.wait(timeout=2)
                self.assertEqual(process.returncode, 0)
            finally:
                if process.stdin:
                    process.stdin.close()
                if process.poll() is None:
                    process.terminate()
                process.wait(timeout=10)
                if process.stdout:
                    process.stdout.close()
                if process.stderr:
                    process.stderr.close()
                output_thread.join(timeout=2)


if __name__ == "__main__":
    unittest.main()
