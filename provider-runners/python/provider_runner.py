#!/usr/bin/env python3
"""Signed-package Python Provider runner for NetVplayer protocol v1."""

from __future__ import annotations

import argparse
import base64
import contextlib
import importlib.util
import inspect
import json
import os
from pathlib import Path
import re
import sys
import threading
from typing import Any


sys.dont_write_bytecode = True
PROTOCOL_VERSION = 1
MAX_PROXY_BYTES = int(os.environ.get("NETVPLAYER_MAX_PROXY_BYTES", str(32 * 1024 * 1024)))
URL_PATTERN = re.compile(r"https?://[^\s\"'<>]+")
HEADER_PATTERN = re.compile(r"(?i)(cookie|authorization|proxy-authorization|x-api-key)\s*:\s*[^\r\n]+")
METHODS = {
    "init": ("init", lambda a: [a.get("extend", a.get("ext", ""))]),
    "home": ("homeContent", lambda a: [bool(a.get("filter", True))]),
    "home_video": ("homeVideoContent", lambda a: []),
    "category": (
        "categoryContent",
        lambda a: [
            str(a.get("category_id", a.get("tid", ""))),
            str(a.get("page", a.get("pg", "1"))),
            bool(a.get("filter", True)),
            a.get("extend", {}),
        ],
    ),
    "detail": ("detailContent", lambda a: [a.get("ids", [a.get("id", "")])]),
    "search": (
        "searchContent",
        lambda a: [
            str(a.get("keyword", a.get("key", ""))),
            bool(a.get("quick", False)),
            str(a.get("page", a.get("pg", "1"))),
        ],
    ),
    "player": (
        "playerContent",
        lambda a: [
            str(a.get("flag", "")),
            str(a.get("id", a.get("url", ""))),
            a.get("vip_flags", a.get("vipFlags", [])),
        ],
    ),
    "live": ("liveContent", lambda a: [str(a.get("url", ""))]),
    "manual_video_check": ("manualVideoCheck", lambda a: []),
    "is_video_format": ("isVideoFormat", lambda a: [str(a.get("url", ""))]),
    "proxy": ("localProxy", lambda a: [a.get("parameters", a.get("params", a))]),
    "action": ("action", lambda a: [str(a.get("action", "")), str(a.get("value", ""))]),
    "destroy": ("destroy", lambda a: []),
}


class RunnerError(Exception):
    pass


def safe_message(value: Any) -> str:
    return HEADER_PATTERN.sub(r"\1: <redacted>", URL_PATTERN.sub("<redacted-url>", str(value)))


def _inside(path: Path, root: Path) -> bool:
    try:
        path.resolve(strict=True).relative_to(root.resolve(strict=True))
        return True
    except (FileNotFoundError, ValueError):
        return False


def _load_provider(provider_path: Path, package_root: Path, class_name: str | None) -> Any:
    if provider_path.suffix not in {".py", ".pyc"} or not _inside(provider_path, package_root):
        raise RunnerError("provider entrypoint must be a package-local .py or .pyc file")

    dependency_dir = package_root / "dependencies"
    for candidate in (provider_path.parent, dependency_dir):
        if candidate.exists() and _inside(candidate, package_root):
            sys.path.insert(0, str(candidate))

    spec = importlib.util.spec_from_file_location("netvplayer_signed_provider", provider_path)
    if spec is None or spec.loader is None:
        raise RunnerError("provider module could not be loaded")
    module = importlib.util.module_from_spec(spec)
    with contextlib.redirect_stdout(sys.stderr):
        spec.loader.exec_module(module)

    if class_name:
        target = getattr(module, class_name, None)
    else:
        target = getattr(module, "Spider", None) or getattr(module, "spider", None)
    if target is None:
        return module
    return target() if isinstance(target, type) else target


def _json_value(value: Any) -> Any:
    if value is None or isinstance(value, (bool, int, float, str)):
        if isinstance(value, str):
            stripped = value.strip()
            if stripped and stripped[0] in "[{" and stripped[-1] in "]}":
                try:
                    return json.loads(stripped)
                except json.JSONDecodeError:
                    pass
        return value
    if isinstance(value, bytes):
        return {"body_base64": base64.b64encode(value).decode("ascii")}
    if isinstance(value, (list, tuple)):
        return [_json_value(item) for item in value]
    if isinstance(value, dict):
        return {str(key): _json_value(item) for key, item in value.items()}
    if hasattr(value, "toJson"):
        return _json_value(value.toJson())
    if hasattr(value, "__dict__"):
        return _json_value(vars(value))
    return str(value)


def _proxy_payload(value: Any) -> dict[str, Any]:
    if isinstance(value, dict):
        payload = dict(value)
        body = payload.pop("body", payload.pop("content", None))
        body, stream_body = _proxy_body(body)
        if isinstance(body, bytes):
            payload["body_base64"] = base64.b64encode(body).decode("ascii")
        elif body is not None:
            payload["body"] = str(body)
        return {
            "status_code": int(payload.pop("status_code", payload.pop("code", 200))),
            "content_type": payload.pop("content_type", payload.pop("mime", None)),
            "url": payload.pop("url", None),
            "headers": payload.pop("headers", {}) or {},
            **payload,
        }

    if isinstance(value, (list, tuple)):
        status = int(value[0]) if len(value) > 0 and value[0] is not None else 200
        content_type = str(value[1]) if len(value) > 1 and value[1] is not None else None
        body = value[2] if len(value) > 2 else None
        headers = value[3] if len(value) > 3 and isinstance(value[3], dict) else {}
        body, stream_body = _proxy_body(body)
        use_base64 = bool(value[4]) if len(value) > 4 else isinstance(body, bytes) or stream_body
        payload = {
            "status_code": status,
            "content_type": content_type,
            "headers": {str(key): str(item) for key, item in headers.items()},
        }
        if body is not None:
            raw = body if isinstance(body, bytes) else str(body).encode("utf-8")
            payload["body_base64" if use_base64 else "body"] = (
                base64.b64encode(raw).decode("ascii") if use_base64 else raw.decode("utf-8")
            )
        return payload
    raise RunnerError("proxy/localProxy must return an object or CatVod response array")


def _proxy_body(body: Any) -> tuple[Any, bool]:
    if body is None or isinstance(body, (str, bytes)):
        return body, isinstance(body, bytes)
    if hasattr(body, "read"):
        chunks: list[bytes] = []
        size = 0
        while True:
            chunk = body.read(64 * 1024)
            if not chunk:
                break
            encoded = chunk if isinstance(chunk, bytes) else str(chunk).encode("utf-8")
            size += len(encoded)
            if size > MAX_PROXY_BYTES:
                raise RunnerError("proxy stream exceeds the configured byte limit")
            chunks.append(encoded)
        return b"".join(chunks), True
    if hasattr(body, "__iter__") and not isinstance(body, (dict, list, tuple)):
        chunks = []
        size = 0
        for chunk in body:
            encoded = chunk if isinstance(chunk, bytes) else str(chunk).encode("utf-8")
            size += len(encoded)
            if size > MAX_PROXY_BYTES:
                raise RunnerError("proxy stream exceeds the configured byte limit")
            chunks.append(encoded)
        return b"".join(chunks), True
    return body, False


class Runner:
    def __init__(self, provider: Any, provider_id: str) -> None:
        self.provider = provider
        self.provider_id = provider_id
        self.initialized = False
        self.cancelled: set[str] = set()
        self.lock = threading.RLock()

    def handle(self, request: dict[str, Any]) -> dict[str, Any]:
        request_id = str(request.get("request_id", ""))
        try:
            if request.get("protocol") != PROTOCOL_VERSION:
                raise RunnerError("unsupported protocol")
            if request.get("provider_id") not in (None, "", self.provider_id):
                raise RunnerError("provider_id does not match the launched package")
            operation = str(request.get("operation", ""))
            arguments = request.get("arguments") or {}
            if operation == "handshake":
                return self.success(request_id, {
                    "protocol": PROTOCOL_VERSION,
                    "provider_id": self.provider_id,
                    "runtime": "python",
                    "operations": list(METHODS),
                })
            if operation == "health":
                return self.success(request_id, {"status": "ok"})
            if operation == "cancel":
                target = str(arguments.get("target_request_id", ""))
                if target:
                    self.cancelled.add(target)
                return self.success(request_id, {"cancelled": target})
            if operation == "shutdown":
                self._destroy()
                return self.success(request_id, {"shutdown": True})
            if request_id in self.cancelled:
                self.cancelled.discard(request_id)
                raise RunnerError("request was cancelled")
            if operation not in METHODS:
                raise RunnerError(f"unsupported operation: {operation}")

            method_name, make_args = METHODS[operation]
            method = getattr(self.provider, method_name, None)
            if method is None and operation == "proxy":
                method = getattr(self.provider, "proxy", None)
            if method is None:
                raise RunnerError(f"provider does not implement {method_name}")
            with self.lock, contextlib.redirect_stdout(sys.stderr):
                method_arguments = make_args(arguments)
                if operation == "init" and len(inspect.signature(method).parameters) >= 2:
                    method_arguments.append(request.get("site") or {})
                if operation == "action" and len(inspect.signature(method).parameters) == 1:
                    method_arguments = method_arguments[:1]
                value = method(*method_arguments)
            if operation == "init":
                self.initialized = True
            if operation == "destroy":
                self.initialized = False
            if operation == "proxy":
                return {"request_id": request_id, "ok": True, "result": None, "proxy": _proxy_payload(value), "error": None}
            return self.success(request_id, _json_value(value))
        except Exception as error:  # Provider exceptions must cross the wire, never stdout.
            print(f"{type(error).__name__}: {safe_message(error)}", file=sys.stderr)
            return {
                "request_id": request_id,
                "ok": False,
                "result": None,
                "error": {
                    "code": "provider_error",
                    "message": safe_message(error),
                    "retryable": False,
                    "diagnostic": type(error).__name__,
                },
            }

    def _destroy(self) -> None:
        method = getattr(self.provider, "destroy", None)
        if method is not None:
            with self.lock, contextlib.redirect_stdout(sys.stderr):
                method()
        self.initialized = False

    @staticmethod
    def success(request_id: str, result: Any) -> dict[str, Any]:
        return {"request_id": request_id, "ok": True, "result": result, "error": None}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--provider", required=True)
    parser.add_argument("--class", dest="class_name")
    args = parser.parse_args()

    package_root = Path(os.environ.get("NETVPLAYER_PROVIDER_ROOT", Path(args.provider).parent)).resolve()
    provider_path = Path(args.provider).resolve()
    provider_id = os.environ.get("NETVPLAYER_PROVIDER_ID", provider_path.stem)
    try:
        provider = _load_provider(provider_path, package_root, args.class_name)
    except Exception as error:
        print(f"{type(error).__name__}: {safe_message(error)}", file=sys.stderr)
        print(json.dumps({"request_id": "startup", "ok": False, "error": {
            "code": "startup_failed", "message": safe_message(error), "retryable": False,
            "diagnostic": type(error).__name__,
        }}, separators=(",", ":")), flush=True)
        return 2

    runner = Runner(provider, provider_id)
    for line in sys.stdin:
        request: dict[str, Any] = {}
        try:
            request = json.loads(line)
            response = runner.handle(request)
        except Exception as error:
            response = {"request_id": "", "ok": False, "result": None, "error": {
                "code": "invalid_request", "message": safe_message(error), "retryable": False,
                "diagnostic": type(error).__name__,
            }}
        print(json.dumps(response, ensure_ascii=False, separators=(",", ":")), flush=True)
        if request.get("operation") == "shutdown":
            break
    runner._destroy()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
