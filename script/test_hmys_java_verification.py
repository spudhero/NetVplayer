from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import shutil
import threading
from types import SimpleNamespace
import unittest
from http.server import ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit
from unittest.mock import patch

from script.test_private_hmys_provider import FIXED_CLOCK, HmysHandler
from script.verify_hmys_java_provider import (
    VerificationError,
    ffprobe_sample,
    probe_hmys_media,
    validated_public_url,
    verify,
)


class FakeResponse:
    def __init__(self, data: bytes, *, status: int = 200, content_type: str = "application/vnd.apple.mpegurl") -> None:
        self.data = data
        self.status = status
        self.headers = {"Content-Type": content_type}

    def __enter__(self) -> FakeResponse:
        return self

    def __exit__(self, *_arguments: object) -> None:
        return None

    def read(self, limit: int) -> bytes:
        return self.data[:limit]


class FakeOpener:
    def __init__(self, responses: list[FakeResponse]) -> None:
        self.responses = iter(responses)
        self.requests: list[str] = []

    def open(self, request: object, timeout: int) -> FakeResponse:
        self.requests.append(request.full_url)  # type: ignore[attr-defined]
        return next(self.responses)


class HmysJavaVerificationTests(unittest.TestCase):
    def test_verification_rejects_local_network_targets(self) -> None:
        with self.assertRaisesRegex(VerificationError, "outside the public network"):
            validated_public_url("http://127.0.0.1/private.m3u8")
        with self.assertRaisesRegex(VerificationError, "local hostname"):
            validated_public_url("https://media.local/private.m3u8")
        self.assertEqual(
            validated_public_url("https://8.8.8.8/public.m3u8"),
            "https://8.8.8.8/public.m3u8",
        )
        with self.assertRaisesRegex(VerificationError, "escaped the audited media host"):
            validated_public_url("https://other.example/public.m3u8", "media.example")
        self.assertEqual(
            validated_public_url("https://media.example/public.m3u8", "media.example"),
            "https://media.example/public.m3u8",
        )

    def test_media_probe_resigns_manifest_child_and_requires_video_audio(self) -> None:
        opener = FakeOpener([
            FakeResponse(b"#EXTM3U\nsegment.ts\n"),
            FakeResponse(b"media-bytes", content_type="video/mp2t"),
        ])
        decoded = {
            "format_name": "mpegts",
            "duration_seconds": "5.0",
            "streams": [
                {"codec_type": "video", "codec_name": "h264"},
                {"codec_type": "audio", "codec_name": "aac"},
            ],
        }
        with (
            patch("script.verify_hmys_java_provider.build_opener", return_value=opener),
            patch("script.verify_hmys_java_provider.ffprobe_sample", return_value=decoded),
        ):
            media, actual_decode, hops = probe_hmys_media(
                "https://dgxj.ruxiangsuisu.cn/master.m3u8?channel=1",
                {"User-Agent": "NetVplayer-Hmys-Verification"},
                "fixture-secret",
                Path("/usr/bin/true"),
            )

        self.assertEqual(hops, 1)
        self.assertEqual(media["bytes_read"], len(b"media-bytes"))
        self.assertEqual(actual_decode, decoded)
        self.assertEqual(len(opener.requests), 2)
        parsed_requests = [urlsplit(request_url) for request_url in opener.requests]
        self.assertEqual([request.path for request in parsed_requests], ["/master.m3u8", "/segment.ts"])
        signatures: list[str] = []
        for request in parsed_requests:
            query = parse_qs(request.query)
            self.assertEqual(query["channel"], ["1"])
            self.assertIn("wsSecret", query)
            self.assertIn("wsTime", query)
            expected = hashlib.md5(
                f"fixture-secret{request.path}{query['wsTime'][0]}".encode()
            ).hexdigest()
            self.assertEqual(query["wsSecret"], [expected])
            signatures.append(query["wsSecret"][0])
        self.assertNotEqual(signatures[0], signatures[1])

        ffprobe_result = SimpleNamespace(
            returncode=0,
            stdout=json.dumps({
                "format": {"format_name": "mpegts"},
                "streams": [{"codec_type": "video", "codec_name": "h264"}],
            }),
        )
        with patch("script.verify_hmys_java_provider.subprocess.run", return_value=ffprobe_result):
            with self.assertRaisesRegex(VerificationError, "both video and audio"):
                ffprobe_sample(Path("/usr/bin/true"), b"sample", "https://media.example/sample.ts", "video/mp2t")

    def test_media_probe_rejects_excessive_manifest_hops(self) -> None:
        opener = FakeOpener([FakeResponse(b"#EXTM3U\nnext.m3u8\n") for _ in range(6)])
        with patch("script.verify_hmys_java_provider.build_opener", return_value=opener):
            with self.assertRaisesRegex(VerificationError, "exceeded six manifest hops"):
                probe_hmys_media(
                    "https://dgxj.ruxiangsuisu.cn/master.m3u8",
                    {},
                    "fixture-secret",
                    Path("/usr/bin/true"),
                )

    def test_verification_separates_crypto_network_media_and_sensitive_evidence(self) -> None:
        java = os.environ.get("NETVPLAYER_JAVA_EXECUTABLE") or shutil.which("java")
        runner = os.environ.get("NETVPLAYER_JAVA_RUNNER")
        provider = os.environ.get("NETVPLAYER_JAVA_HMYS_PROVIDER")
        if not java or not runner or not provider:
            self.skipTest("Java Runner and Hmys Provider artifacts are required")
        HmysHandler.requests = []
        server = ThreadingHTTPServer(("127.0.0.1", 0), HmysHandler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        base = f"http://127.0.0.1:{server.server_port}"
        try:
            with (
                patch.dict(os.environ, {
                    "JAVA_TOOL_OPTIONS": " ".join((
                        "-Dnetvplayer.hmys.allowLoopback=true",
                        f"-Dnetvplayer.hmys.initialBase={base}",
                        "-Dnetvplayer.hmys.deviceId=abcdefghijklmnop",
                        f"-Dnetvplayer.hmys.fixedClock={FIXED_CLOCK}",
                    )),
                }),
                patch(
                    "script.verify_hmys_java_provider.validated_public_url",
                    side_effect=lambda value, _allowed_hostname=None: value,
                ),
                patch("script.verify_hmys_java_provider.probe_hmys_media", return_value=({
                    "host": "media.example.invalid",
                    "http_status": 206,
                    "content_type": "video/mp2t",
                    "bytes_read": 262_144,
                    "sample_sha256": "0" * 64,
                }, {
                    "format_name": "mpegts",
                    "duration_seconds": "10.0",
                    "streams": [
                        {"codec_type": "video", "codec_name": "h264", "width": 1280, "height": 720},
                        {"codec_type": "audio", "codec_name": "aac"},
                    ],
                }, 2)),
            ):
                evidence = verify(Path(java), Path(runner), Path(provider), Path("/usr/bin/true"))
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)

        self.assertEqual(evidence["provider_id"], "migration.hmys.java")
        self.assertEqual(evidence["compatibility"], "compatible")
        self.assertEqual(evidence["network"]["status"], "usable")
        self.assertEqual(evidence["parser"]["proxy_descriptor"], "hmys-hls-v1")
        self.assertEqual(evidence["parser"]["hls_manifest_hops"], 2)
        self.assertEqual(evidence["parser"]["aes_256_cbc_response_decryption"], "passed")
        self.assertTrue(evidence["playback_verified"])
        self.assertFalse(evidence["sensitive_values_persisted"])
        serialized = json.dumps(evidence, ensure_ascii=False)
        self.assertNotIn("http://", serialized)
        self.assertNotIn("https://", serialized)
        self.assertNotIn("hmys-token", serialized)
        self.assertNotIn("abcdefghijklmnop", serialized)
        self.assertNotIn("vT1RQRz8YzlzTgN26pIXNJ7Mi65juwSP", serialized)


if __name__ == "__main__":
    unittest.main()
