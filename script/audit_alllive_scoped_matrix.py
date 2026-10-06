#!/usr/bin/env python3
"""Audit every playback candidate on the first room of each scoped Alllive category.

The evidence deliberately omits playback URLs and request headers. It records only
the route labels and media metadata needed to compare provider resolution behavior.
"""

from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import subprocess
import sys
import time
from typing import Any


PROVIDER_ID = "netvplayer.catalog.python"
SITE = {
    "key": "alllive_douyu",
    "name": "douyu",
    "type": 3,
    "api": "csp_Alllive",
    "ext": "",
}
CATEGORIES = (
    ("douyu_yqk", "娱乐天地"),
    ("douyu_LOL", "网游竞技"),
    ("douyu_TVgame", "单机热游"),
    ("douyu_wzry", "手游休闲"),
    ("douyu_yz", "颜值"),
    ("douyu_smkj", "科技文化"),
    ("douyu_yiqiwan", "语音互动"),
    ("douyu_yyzs", "语音直播"),
    ("douyu_znl", "正能量"),
)
SENSITIVE_HEADERS = {"authorization", "cookie", "proxy-authorization", "x-api-key"}


class AuditError(RuntimeError):
    pass


class Runner:
    def __init__(self, package: Path) -> None:
        executable = package / "runtimes/cpython/bin/python3"
        runner = package / "provider_runner.pyc"
        provider = package / "provider.pyc"
        for path in (executable, runner, provider):
            if not path.is_file():
                raise AuditError(f"missing package asset: {path.relative_to(package)}")
        environment = os.environ.copy()
        environment.update({
            "NETVPLAYER_PROVIDER_ROOT": str(package),
            "NETVPLAYER_PROVIDER_ID": PROVIDER_ID,
        })
        self.process = subprocess.Popen(
            [
                str(executable), "-I", "-B", "-S", str(runner),
                "--provider", str(provider), "--class", "Spider",
            ],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=environment,
        )
        self.serial = 0

    def request(
        self,
        operation: str,
        arguments: dict[str, Any] | None = None,
        *,
        site: dict[str, Any] | None = None,
    ) -> Any:
        self.serial += 1
        payload: dict[str, Any] = {
            "protocol": 1,
            "request_id": f"audit-{self.serial}",
            "provider_id": PROVIDER_ID,
            "operation": operation,
            "arguments": arguments or {},
        }
        if site is not None:
            payload["site"] = site
        if self.process.stdin is None or self.process.stdout is None:
            raise AuditError("runner stdio is unavailable")
        self.process.stdin.write(json.dumps(payload, separators=(",", ":")) + "\n")
        self.process.stdin.flush()
        line = self.process.stdout.readline()
        if not line:
            raise AuditError("runner exited before returning a response")
        response = json.loads(line)
        if response.get("ok") is not True:
            error = response.get("error") or {}
            diagnostic = error.get("diagnostic", "ProviderError")
            message = error.get("message", "request failed")
            raise AuditError(f"{operation} failed ({diagnostic}): {message}")
        return response.get("result")

    def close(self) -> None:
        try:
            if self.process.poll() is None:
                self.request("shutdown")
            self.process.wait(timeout=5)
        except (AuditError, subprocess.TimeoutExpired):
            self.process.terminate()
            self.process.wait(timeout=2)
        finally:
            for stream in (self.process.stdin, self.process.stdout, self.process.stderr):
                if stream is not None:
                    stream.close()


def first_record(value: Any, label: str) -> dict[str, Any]:
    if not isinstance(value, dict) or not isinstance(value.get("list"), list) or not value["list"]:
        raise AuditError(f"{label} returned no records")
    record = value["list"][0]
    if not isinstance(record, dict):
        raise AuditError(f"{label} returned an invalid record")
    return record


def playback_candidates(detail: dict[str, Any]) -> list[dict[str, str]]:
    quality_names = str(detail.get("vod_play_from", "")).split("$$$")
    groups = str(detail.get("vod_play_url", "")).split("$$$")
    candidates: list[dict[str, str]] = []
    for group_index, group in enumerate(groups):
        quality = quality_names[group_index] if group_index < len(quality_names) else f"quality-{group_index + 1}"
        for line_index, entry in enumerate(group.split("#")):
            if "$" not in entry:
                continue
            label, url = entry.split("$", 1)
            if not url.startswith(("http://", "https://")):
                continue
            candidates.append({
                "quality": quality or f"quality-{group_index + 1}",
                "line": label or f"line-{line_index + 1}",
                "url": url,
            })
    return candidates


def ffprobe_candidate(binary: Path, url: str, headers: dict[str, str]) -> dict[str, Any]:
    header_block = "".join(f"{key}: {value}\r\n" for key, value in headers.items())
    last_failure: dict[str, Any] = {"status": "failed", "reason": "ffprobe_not_run"}
    for attempt in range(1, 4):
        try:
            result = subprocess.run(
                [
                    str(binary),
                    "-v", "error",
                    "-rw_timeout", "30000000",
                    "-analyzeduration", "7000000",
                    "-probesize", "7000000",
                    "-headers", header_block,
                    "-show_entries",
                    "format=format_name,duration:stream=codec_type,codec_name,width,height,sample_rate,channels,channel_layout,r_frame_rate",
                    "-of", "json",
                    url,
                ],
                capture_output=True,
                text=True,
                timeout=45,
                check=False,
            )
        except subprocess.TimeoutExpired:
            last_failure = {"status": "failed", "reason": "ffprobe_timeout", "attempts": attempt}
        else:
            if result.returncode != 0:
                last_failure = {
                    "status": "failed",
                    "reason": f"ffprobe_exit_{result.returncode}",
                    "attempts": attempt,
                }
            else:
                try:
                    parsed = json.loads(result.stdout)
                except json.JSONDecodeError:
                    last_failure = {
                        "status": "failed",
                        "reason": "ffprobe_invalid_json",
                        "attempts": attempt,
                    }
                else:
                    streams = parsed.get("streams")
                    media_format = parsed.get("format")
                    if isinstance(streams, list) and streams and isinstance(media_format, dict):
                        public_streams = []
                        for stream in streams:
                            if not isinstance(stream, dict):
                                continue
                            public_streams.append({
                                key: stream[key]
                                for key in (
                                    "codec_type", "codec_name", "width", "height", "sample_rate",
                                    "channels", "channel_layout", "r_frame_rate",
                                )
                                if key in stream
                            })
                        return {
                            "status": "passed",
                            "attempts": attempt,
                            "format_name": media_format.get("format_name"),
                            "duration_seconds": media_format.get("duration"),
                            "streams": public_streams,
                        }
                    last_failure = {
                        "status": "failed",
                        "reason": "ffprobe_no_streams",
                        "attempts": attempt,
                    }
        if attempt < 3:
            time.sleep(1)
    return last_failure


def write_evidence(path: Path, evidence: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(evidence, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    temporary.chmod(0o600)
    temporary.replace(path)


def audit(package: Path, ffprobe: Path, output: Path) -> dict[str, Any]:
    evidence: dict[str, Any] = {
        "schema_version": 1,
        "captured_at": datetime.now(timezone.utc).isoformat(),
        "provider_id": PROVIDER_ID,
        "provider_version": "1.0.6",
        "scope": "douyu",
        "sampling_policy": "first room in every scoped category; every advertised quality and CDN candidate",
        "gui_playback_verified": False,
        "categories": [],
        "summary": {},
        "sensitive_values_persisted": False,
    }
    runner = Runner(package)
    try:
        handshake = runner.request("handshake")
        if not isinstance(handshake, dict) or handshake.get("runtime") != "python":
            raise AuditError("runner handshake did not confirm Python")
        runner.request("init", {"extend": ""}, site=SITE)
        home = runner.request("home", {"filter": True})
        home_classes = home.get("class") if isinstance(home, dict) else None
        evidence["home_category_ids"] = [
            str(item.get("type_id"))
            for item in home_classes or []
            if isinstance(item, dict)
        ]

        for category_id, category_name in CATEGORIES:
            row: dict[str, Any] = {
                "category_id": category_id,
                "category_name": category_name,
                "room": None,
                "routes": [],
            }
            try:
                category = runner.request("category", {
                    "category_id": category_id,
                    "page": "1",
                    "filter": False,
                    "extend": {},
                })
                room = first_record(category, f"category {category_id}")
                room_id = str(room.get("vod_id", ""))
                if not room_id.startswith("douyu_"):
                    raise AuditError(f"category {category_id} returned a non-Douyu room")
                row["room"] = {
                    "id_shape": "douyu_numeric",
                    "title": str(room.get("vod_name", "")),
                }
                detail = first_record(runner.request("detail", {"ids": [room_id]}), f"detail {room_id}")
                candidates = playback_candidates(detail)
                if not candidates:
                    raise AuditError("detail returned no HTTP(S) playback candidates")

                probe_jobs = {}
                with ThreadPoolExecutor(max_workers=min(4, len(candidates))) as executor:
                    for candidate_index, candidate in enumerate(candidates):
                        route: dict[str, Any] = {
                            "candidate_index": candidate_index,
                            "quality": candidate["quality"],
                            "line": candidate["line"],
                            "resolver": "failed",
                            "decode": {"status": "not_run"},
                        }
                        row["routes"].append(route)
                        try:
                            player = runner.request("player", {
                                "flag": candidate["quality"],
                                "id": candidate["url"],
                            })
                            if not isinstance(player, dict) or player.get("parse") != 0:
                                route["resolver_reason"] = "player_parse_not_zero"
                                continue
                            resolved_url = str(player.get("url", ""))
                            if not resolved_url.startswith(("http://", "https://")):
                                route["resolver_reason"] = "player_url_not_http"
                                continue
                            headers = player.get("header") or {}
                            if not isinstance(headers, dict):
                                route["resolver_reason"] = "player_headers_invalid"
                                continue
                            public_headers = {str(key): str(value) for key, value in headers.items()}
                            if any(key.lower() in SENSITIVE_HEADERS for key in public_headers):
                                route["resolver_reason"] = "sensitive_header_boundary_violation"
                                continue
                            route["resolver"] = "passed"
                            route["player_format"] = player.get("format")
                            future = executor.submit(ffprobe_candidate, ffprobe, resolved_url, public_headers)
                            probe_jobs[future] = route
                        except AuditError as error:
                            route["resolver_reason"] = str(error)
                    for future in as_completed(probe_jobs):
                        route = probe_jobs[future]
                        try:
                            route["decode"] = future.result()
                        except subprocess.TimeoutExpired:
                            route["decode"] = {"status": "failed", "reason": "ffprobe_timeout"}
                        except OSError:
                            route["decode"] = {"status": "failed", "reason": "ffprobe_os_error"}
                row["status"] = "passed" if all(
                    route["resolver"] == "passed" and route["decode"].get("status") == "passed"
                    for route in row["routes"]
                ) else "failed"
            except AuditError as error:
                row["status"] = "empty" if "returned no records" in str(error) else "failed"
                row["reason"] = str(error)
            evidence["categories"].append(row)
            write_evidence(output, evidence)
        runner.request("destroy")
    finally:
        runner.close()

    routes = [route for row in evidence["categories"] for route in row["routes"]]
    category_passed = sum(row.get("status") == "passed" for row in evidence["categories"])
    all_sampled_routes_passed = bool(routes) and all(
        route.get("resolver") == "passed" and route.get("decode", {}).get("status") == "passed"
        for route in routes
    )
    evidence["summary"] = {
        "category_count": len(evidence["categories"]),
        "category_passed": category_passed,
        "category_empty": sum(row.get("status") == "empty" for row in evidence["categories"]),
        "category_failed": sum(row.get("status") == "failed" for row in evidence["categories"]),
        "route_count": len(routes),
        "resolver_passed": sum(route.get("resolver") == "passed" for route in routes),
        "decode_passed": sum(route.get("decode", {}).get("status") == "passed" for route in routes),
        "all_sampled_routes_passed": all_sampled_routes_passed,
        "all_categories_audited": category_passed == len(evidence["categories"]),
        "complete_pass": category_passed == len(evidence["categories"]) and all_sampled_routes_passed,
    }
    evidence["captured_at"] = datetime.now(timezone.utc).isoformat()
    write_evidence(output, evidence)
    return evidence


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--package", type=Path, required=True)
    parser.add_argument("--ffprobe", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    arguments = parser.parse_args()
    package = arguments.package.expanduser().resolve(strict=True)
    ffprobe = arguments.ffprobe.expanduser().resolve(strict=True)
    evidence = audit(package, ffprobe, arguments.output.expanduser().resolve())
    print(json.dumps(evidence["summary"], ensure_ascii=False, sort_keys=True))
    return 0 if evidence["summary"]["complete_pass"] else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (AuditError, OSError, json.JSONDecodeError) as error:
        print(f"Alllive scoped matrix audit: {error}", file=sys.stderr)
        raise SystemExit(1)
