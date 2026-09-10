#!/usr/bin/env python3
"""Exercise a signed Provider launcher under the macOS App Sandbox."""

from __future__ import annotations

import argparse
import json
import os
import platform
import shutil
import subprocess
import sys
import tempfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from threading import Thread
import uuid
from pathlib import Path

from build_provider_sandbox_launcher import build_bundle
from build_provider_sandbox_launcher import COMMUNITY_ADHOC_RELEASE_PROFILE
from prepare_embedded_quickjs_runtime import prepare as prepare_quickjs
from prepare_provider_runtimes import (
    build_python,
    fetch_artifact,
    safe_extract,
    sign_macho_tree,
    validate_runtime,
)


ROOT = Path(__file__).resolve().parents[1]
PACKAGE_ROOT = ROOT / "NetVplayer"


class SandboxProbeError(RuntimeError):
    pass


def start_http_fixture() -> tuple[ThreadingHTTPServer, Thread]:
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self) -> None:
            body = b"sandbox-http-module"
            self.send_response(200)
            self.send_header("Content-Type", "text/javascript")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *_: object) -> None:
            pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server, thread


def run(command: list[str], **kwargs: object) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        **kwargs,
    )


def compile_launcher(destination: Path) -> Path:
    result = run(
        [
            "xcrun",
            "swiftc",
            str(PACKAGE_ROOT / "Sources/ProviderSandboxLauncher/main.swift"),
            "-module-cache-path",
            str(destination.parent / "ModuleCache"),
            "-O",
            "-o",
            str(destination),
        ]
    )
    if result.returncode != 0:
        raise SandboxProbeError(result.stderr.strip() or "Provider sandbox launcher build failed")
    return destination


def compile_probe(destination: Path) -> None:
    source = destination.with_suffix(".c")
    source.write_text(
        """
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int read_file(const char *path) {
    int fd = open(path, O_RDONLY);
    if (fd < 0) return errno;
    char byte = 0;
    int result = read(fd, &byte, 1) < 0 ? errno : 0;
    close(fd);
    return result;
}

static int write_file(const char *path) {
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (fd < 0) return errno;
    int result = write(fd, "ok", 2) == 2 ? 0 : errno;
    close(fd);
    return result;
}

int main(int argc, char **argv) {
    if (argc != 5) return 64;
    printf("{\\\"package_read\\\":%d,\\\"state_write\\\":%d,"
           "\\\"outside_read\\\":%d,\\\"outside_write\\\":%d}\\n",
           read_file(argv[1]), write_file(argv[2]),
           read_file(argv[3]), write_file(argv[4]));
    return 0;
}
""".strip()
        + "\n",
        encoding="utf-8",
    )
    result = run(["xcrun", "clang", "-O2", str(source), "-o", str(destination)])
    if result.returncode != 0:
        raise SandboxProbeError(result.stderr.strip() or "probe compilation failed")


def run_quickjs_sandbox(
    package: Path,
    state: Path,
    provider_id: str,
    launcher_source: Path,
    runtime_work: Path,
    architecture: str,
    package_tool: Path | None,
    quickjs_cache: Path | None = None,
) -> dict[str, object]:
    runner = package / "provider-runners/quickjs/provider_runner.mjs"
    host_api = package / "provider-runners/quickjs/host_api.mjs"
    provider = package / "provider-runners/quickjs/fixtures/sandbox_capability_provider.mjs"
    runner.parent.mkdir(parents=True, exist_ok=True)
    provider.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(ROOT / "provider-runners/quickjs/provider_runner.mjs", runner)
    shutil.copy2(ROOT / "provider-runners/quickjs/host_api.mjs", host_api)
    shutil.copy2(ROOT / "provider-runners/quickjs/fixtures/sandbox_capability_provider.mjs", provider)
    assets = package / "assets"
    lib = package / "js" / "lib"
    assets.mkdir(parents=True, exist_ok=True)
    lib.mkdir(parents=True, exist_ok=True)
    shutil.copy2(ROOT / "provider-runners/quickjs/fixtures/module_resource_asset.mjs", assets / "module_resource_asset.mjs")
    shutil.copy2(ROOT / "provider-runners/quickjs/fixtures/module_resource_lib.mjs", lib / "module_resource_lib.mjs")

    quickjs_lock = ROOT / "provider-runners/quickjs-runtime-lock-v1.json"
    runtime_root = package / "runtimes/quickjs"
    try:
        runtime_manifest = prepare_quickjs(
            quickjs_lock,
            quickjs_cache or runtime_work / "quickjs-cache",
            runtime_root,
            architecture,
        )
        sign_macho_tree(runtime_root, "-")
    except (OSError, RuntimeError, subprocess.CalledProcessError, ValueError) as error:
        raise SandboxProbeError(f"bundled QuickJS preparation failed: {error}") from error

    quickjs_provider_id = provider_id
    launcher_bundle = package / "Sandbox" / "ProviderSandboxLauncher.app"
    try:
        build_bundle(
            launcher_source,
            launcher_bundle,
            quickjs_provider_id,
            "-",
            COMMUNITY_ADHOC_RELEASE_PROFILE,
        )
    except (OSError, ValueError) as error:
        raise SandboxProbeError(f"QuickJS sandbox launcher build failed: {error}") from error
    launcher = launcher_bundle / "Contents/MacOS/ProviderSandboxLauncher"
    quickjs_manifest = {
        "provider_id": quickjs_provider_id,
        "version": "1.0.0",
        "protocol": 1,
        "shell_min_version": "1.0.0",
        "macos_min_version": "14.0",
        "architectures": [architecture],
        "runtime": "quickjs",
        "entrypoint": str(provider.relative_to(package)),
        "runner": str(runner.relative_to(package)),
        "runtime_executable": str((runtime_root / "bin/qjs").relative_to(package)),
        "sandbox": {
            "profile_version": 2,
            "launcher": str(launcher.relative_to(package)),
            "bundle_id": f"com.netvplayer.provider.{quickjs_provider_id}",
            "release_profile": COMMUNITY_ADHOC_RELEASE_PROFILE,
        },
        "provider_class": "Spider",
        "capabilities": ["home", "proxy"],
        "host_capabilities": ["console", "base64", "md5", "url", "text", "persistence", "module", "http"],
        "assets": [],
        "license": "MIT",
        "status": "compatible",
        "revoked": False,
    }
    manifest_path = package / "quickjs-manifest.json"
    manifest_path.write_text(json.dumps(quickjs_manifest), encoding="utf-8")
    swift_gate = "not-applicable-private-export"
    if package_tool is not None:
        shell_verification = run([
            str(package_tool),
            "verify-sandbox",
            "--manifest", str(manifest_path),
            "--package", str(package),
            "--state", str(state),
        ])
        if shell_verification.returncode != 0:
            raise SandboxProbeError(
                f"QuickJS Swift sandbox verification failed: {shell_verification.stderr.strip()}"
            )
        try:
            shell_result = json.loads(shell_verification.stdout)
        except json.JSONDecodeError as error:
            raise SandboxProbeError(
                f"invalid QuickJS Swift sandbox verification: {shell_verification.stdout!r}"
            ) from error
        if shell_result.get("sandbox") != "app-sandbox-v2" or shell_result.get("launcher") != str(launcher):
            raise SandboxProbeError(f"QuickJS sandbox command mismatch: {shell_result}")
        swift_gate = "passed"

    for directory in ("home", "tmp", "cache", "config", "data"):
        (state / directory).mkdir(mode=0o700, exist_ok=True)
    (state / "shared_prefs.xml").write_text(
        "<?xml version=\"1.0\" encoding=\"utf-8\" standalone=\"yes\"?>"
        "<map><string name=\"cache_sandbox_legacy\">from-android</string></map>",
        encoding="utf-8",
    )
    requests = [
        {"protocol": 1, "request_id": "handshake", "provider_id": quickjs_provider_id, "operation": "handshake", "arguments": {}},
        {"protocol": 1, "request_id": "init", "provider_id": quickjs_provider_id, "operation": "init", "arguments": {}},
        {"protocol": 1, "request_id": "shutdown", "provider_id": quickjs_provider_id, "operation": "shutdown", "arguments": {}},
    ]
    environment = {
        "PATH": "/usr/bin:/bin",
        "LANG": "en_US.UTF-8",
        "LC_ALL": "en_US.UTF-8",
        "HOME": str(state / "home"),
        "TMPDIR": str(state / "tmp") + "/",
        "XDG_CACHE_HOME": str(state / "cache"),
        "XDG_CONFIG_HOME": str(state / "config"),
        "XDG_DATA_HOME": str(state / "data"),
        "NETVPLAYER_PROVIDER_ID": quickjs_provider_id,
        "NETVPLAYER_PROVIDER_PROTOCOL": "1",
        "NETVPLAYER_PROVIDER_ROOT": str(package),
        "NETVPLAYER_PROVIDER_SANDBOX": "app-sandbox-v2",
        "NETVPLAYER_PROVIDER_STATE": str(state),
        "NETVPLAYER_PROVIDER_HOST_CAPABILITIES": "console,base64,md5,url,text,persistence,module,http",
    }
    runtime_executable = runtime_root / "bin/qjs"
    bootstrap = runtime_root / "bin/.ape-1.10"
    if not bootstrap.is_file():
        raise SandboxProbeError("QuickJS runtime is missing its prewarmed .ape-1.10 bootstrap")
    command = [
        str(launcher),
        "--",
        str(runtime_executable),
        str(runner),
        "--provider",
        str(provider),
        "--class",
        "Spider",
    ]
    process = subprocess.Popen(
        command,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
        env=environment,
    )
    host_values: dict[tuple[str, str], str] = {("sandbox", "legacy"): "from-android"}
    host_operations: list[str] = []

    def send(message: dict[str, object]) -> None:
        if process.stdin is None:
            raise SandboxProbeError("QuickJS sandbox stdin is unavailable")
        process.stdin.write(json.dumps(message, separators=(",", ":")) + "\n")
        process.stdin.flush()

    def respond_to_host_request(message: dict[str, object]) -> None:
        capability = str(message.get("capability", ""))
        operation = str(message.get("operation", ""))
        options = message.get("options") if isinstance(message.get("options"), dict) else {}
        host_operations.append(f"{capability}.{operation}")
        if capability == "persistence":
            rule = str(options.get("rule", ""))
            key = str(options.get("key", ""))
            storage_key = (rule, key)
            if operation == "set":
                host_values[storage_key] = str(options.get("value", ""))
                value: object = None
            elif operation == "get":
                value = host_values.get(storage_key, "")
            elif operation == "delete":
                host_values.pop(storage_key, None)
                value = None
            else:
                send({
                    "type": "host_response",
                    "request_id": message.get("request_id"),
                    "ok": False,
                    "error": {"code": "unsupported_operation", "message": "sandbox fixture operation is unsupported"},
                })
                return
            result = {"value": value}
        elif capability == "text":
            value = str(options.get("value", ""))
            if operation == "s2t":
                value = value.replace("简", "簡")
            elif operation == "t2s":
                value = value.replace("繁體", "繁体")
            else:
                send({
                    "type": "host_response",
                    "request_id": message.get("request_id"),
                    "ok": False,
                    "error": {"code": "unsupported_operation", "message": "sandbox fixture operation is unsupported"},
                })
                return
            result = {"value": value}
        else:
            send({
                "type": "host_response",
                "request_id": message.get("request_id"),
                "ok": False,
                "error": {"code": "capability_denied", "message": "sandbox fixture capability is not enabled"},
            })
            return
        send({"type": "host_response", "request_id": message.get("request_id"), "ok": True, "result": result})

    def read_response(request_id: str) -> dict[str, object]:
        while True:
            if process.stdout is None:
                raise SandboxProbeError("QuickJS sandbox stdout is unavailable")
            line = process.stdout.readline()
            if not line:
                stderr = process.stderr.read().strip() if process.stderr is not None else ""
                raise SandboxProbeError(f"sandboxed QuickJS exited before {request_id}: {stderr}")
            try:
                message = json.loads(line)
            except json.JSONDecodeError as error:
                raise SandboxProbeError(f"invalid QuickJS Runner output: {line!r}") from error
            if message.get("type") == "host_request":
                respond_to_host_request(message)
                continue
            if message.get("request_id") == request_id:
                return message

    responses = []
    try:
        for request in requests:
            send(request)
            responses.append(read_response(str(request["request_id"])))
        if process.stdin is not None:
            process.stdin.close()
        return_code = process.wait(timeout=30)
        stderr = process.stderr.read().strip() if process.stderr is not None else ""
    except subprocess.TimeoutExpired as error:
        process.kill()
        raise SandboxProbeError("sandboxed QuickJS lifecycle timed out") from error
    if return_code != 0:
        raise SandboxProbeError(f"sandboxed QuickJS lifecycle failed ({return_code}): {stderr}")
    if [response.get("request_id") for response in responses] != ["handshake", "init", "shutdown"]:
        raise SandboxProbeError(f"QuickJS Runner lifecycle mismatch: {responses}")
    if not all(response.get("ok") is True for response in responses):
        raise SandboxProbeError(f"QuickJS Runner returned an error: {responses}")
    handshake = responses[0].get("result", {})
    if handshake.get("runtime") != "quickjs" or not {"base64", "text", "persistence", "module"}.issubset(handshake.get("capabilities", [])):
        raise SandboxProbeError(f"QuickJS handshake capability mismatch: {handshake}")
    if responses[1].get("result") != {
        "module": {"asset": True, "lib": True, "missing": True, "unsupported": True, "http": False},
        "local": {"legacy": "from-android", "token": "persisted"},
        "text": {"s2t": "簡体中文", "t2s": "繁体中文"},
    }:
        raise SandboxProbeError(f"QuickJS sandbox capability result mismatch: {responses[1]}")
    if host_operations != ["persistence.get", "persistence.set", "persistence.get", "persistence.delete", "text.s2t", "text.t2s"]:
        raise SandboxProbeError(f"QuickJS sandbox host operation mismatch: {host_operations}")
    swift_persistence_backend = "not-run"
    if package_tool is not None:
        server, thread = start_http_fixture()
        try:
            swift_probe = run(
                [
                    str(package_tool),
                    "probe-quickjs",
                    "--manifest", str(manifest_path),
                    "--package", str(package),
                    "--state", str(state),
                    "--http-fixture-url", f"http://127.0.0.1:{server.server_port}/module.mjs",
                ],
                timeout=30,
            )
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=5)
        if swift_probe.returncode != 0:
            raise SandboxProbeError(
                f"Swift-host QuickJS sandbox probe failed: {swift_probe.stderr.strip()}"
            )
        try:
            swift_result = json.loads(swift_probe.stdout)
        except json.JSONDecodeError as error:
            raise SandboxProbeError(
                f"invalid Swift-host QuickJS sandbox probe: {swift_probe.stdout!r}"
            ) from error
        if swift_result != {
            "handshake": True,
            "init": True,
            "ok": True,
            "provider_id": quickjs_provider_id,
            "shutdown": True,
            "state_file_mode": 0o600,
            "module_http": True,
            "proxy_data_plane": True,
            "swift_persistence_backend": True,
        }:
            raise SandboxProbeError(f"Swift-host QuickJS sandbox result mismatch: {swift_result}")
        swift_persistence_backend = "passed"
    return {
        "runtime": runtime_manifest["version"],
        "swift_signature_entitlement_gate": swift_gate,
        "operations": ["handshake", "init", "host-bridge", "shutdown"],
        "module_resources": "passed",
        "module_http": "passed",
        "proxy_data_plane": "passed",
        "persistence_host": "passed",
        "swift_persistence_backend": swift_persistence_backend,
        "text_host": "passed",
    }


def main_quickjs_only(skip_swift_gate: bool = False) -> int:
    token = uuid.uuid4().hex
    provider_id = f"sandbox-quickjs-probe-{token}"
    providers = Path.home() / "Library" / "Application Support" / "NetVplayer" / "Providers"
    package = providers / provider_id / "1.0.0"
    state = providers / ".state" / provider_id
    runtime_work = Path(tempfile.mkdtemp(prefix="netvplayer-provider-quickjs-sandbox-"))
    package.mkdir(parents=True)
    state.mkdir(parents=True)
    try:
        launcher_source = compile_launcher(runtime_work / "ProviderSandboxLauncher")
        package_tool: Path | None = None
        if not skip_swift_gate:
            package_tool_build = run([
                "swift", "build", "--disable-sandbox", "--package-path", str(PACKAGE_ROOT),
                "--product", "ProviderPackageTool",
            ])
            if package_tool_build.returncode != 0:
                raise SandboxProbeError(package_tool_build.stderr.strip() or "ProviderPackageTool build failed")
            package_tool_path = run([
                "swift", "build", "--disable-sandbox", "--package-path", str(PACKAGE_ROOT),
                "--show-bin-path",
            ])
            if package_tool_path.returncode != 0:
                raise SandboxProbeError(package_tool_path.stderr.strip() or "ProviderPackageTool path lookup failed")
            package_tool = Path(package_tool_path.stdout.strip()) / "ProviderPackageTool"
        architecture = platform.machine()
        if architecture not in {"arm64", "x86_64"}:
            raise SandboxProbeError(f"unsupported sandbox probe architecture: {architecture}")
        result = run_quickjs_sandbox(
            package,
            state,
            provider_id,
            launcher_source,
            runtime_work,
            architecture,
            package_tool,
            Path(os.environ["NETVPLAYER_QUICKJS_RUNTIME_CACHE"]).resolve()
            if os.environ.get("NETVPLAYER_QUICKJS_RUNTIME_CACHE")
            else None,
        )
        print(json.dumps({
            "app_sandbox": "enforced",
            "quickjs_provider_lifecycle": "passed",
            "quickjs_runtime": result["runtime"],
            "operations": result["operations"],
            "swift_signature_entitlement_gate": result["swift_signature_entitlement_gate"],
            "swift_persistence_backend": result["swift_persistence_backend"],
            "swift_module_http": result["module_http"],
            "swift_proxy_data_plane": result["proxy_data_plane"],
            "release_profile": COMMUNITY_ADHOC_RELEASE_PROFILE,
            "sandbox_profile": "app-sandbox-v2",
            "apple_trust": "manual-user-approval-required",
        }, sort_keys=True))
        return 0
    except SandboxProbeError as error:
        print(f"provider app sandbox QuickJS probe: {error}", file=sys.stderr)
        return 1
    finally:
        shutil.rmtree(providers / provider_id, ignore_errors=True)
        shutil.rmtree(state, ignore_errors=True)
        shutil.rmtree(runtime_work, ignore_errors=True)


def main(skip_swift_gate: bool = False) -> int:
    token = uuid.uuid4().hex
    provider_id = f"sandbox-probe-{token}"
    providers = Path.home() / "Library" / "Application Support" / "NetVplayer" / "Providers"
    provider_root = providers / provider_id
    package = provider_root / "1.0.0"
    state = providers / ".state" / provider_id
    quickjs_provider_root = providers / f"{provider_id}-quickjs"
    quickjs_package = quickjs_provider_root / "1.0.0"
    quickjs_state = providers / ".state" / f"{provider_id}-quickjs"
    outside = providers / f"sandbox-outside-{token}"
    runtime_work = Path(tempfile.mkdtemp(prefix="netvplayer-provider-sandbox-runtime-"))
    package.mkdir(parents=True)
    state.mkdir(parents=True)
    quickjs_package.mkdir(parents=True)
    quickjs_state.mkdir(parents=True)
    outside.mkdir(parents=True)
    try:
        package_sentinel = package / "readable.txt"
        outside_sentinel = outside / "forbidden.txt"
        package_sentinel.write_text("package", encoding="utf-8")
        outside_sentinel.write_text("outside", encoding="utf-8")
        probe = package / "probe"
        compile_probe(probe)

        launcher_source = compile_launcher(runtime_work / "ProviderSandboxLauncher")
        if not launcher_source.is_file():
            raise SandboxProbeError(f"launcher missing: {launcher_source}")
        launcher_bundle = package / "Sandbox" / "ProviderSandboxLauncher.app"
        try:
            build_bundle(
                launcher_source,
                launcher_bundle,
                provider_id,
                "-",
                COMMUNITY_ADHOC_RELEASE_PROFILE,
            )
        except (OSError, ValueError) as error:
            raise SandboxProbeError(str(error)) from error
        launcher = launcher_bundle / "Contents" / "MacOS" / "ProviderSandboxLauncher"

        state_output = state / "written.txt"
        outside_output = outside / "forbidden-write.txt"
        executed = run(
            [
                str(launcher),
                "--",
                str(probe),
                str(package_sentinel),
                str(state_output),
                str(outside_sentinel),
                str(outside_output),
            ]
        )
        if executed.returncode != 0:
            raise SandboxProbeError(
                f"sandboxed child failed ({executed.returncode}): {executed.stderr.strip()}"
            )
        try:
            result = json.loads(executed.stdout)
        except json.JSONDecodeError as error:
            raise SandboxProbeError(f"invalid probe output: {executed.stdout!r}") from error

        expected = {
            "package_read": 0,
            "state_write": 0,
            "outside_read": 1,
            "outside_write": 1,
        }
        if result != expected:
            raise SandboxProbeError(f"sandbox result mismatch: expected {expected}, got {result}")
        if not state_output.is_file() or outside_output.exists():
            raise SandboxProbeError("sandbox filesystem effects do not match the reported result")

        runner = package / "provider_runner.py"
        provider = package / "fixtures" / "mock_provider.py"
        dependency = package / "dependencies" / "fixture_dependency.py"
        runner.parent.mkdir(parents=True, exist_ok=True)
        provider.parent.mkdir(parents=True, exist_ok=True)
        dependency.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / "provider-runners/python/provider_runner.py", runner)
        shutil.copy2(ROOT / "provider-runners/python/fixtures/mock_provider.py", provider)
        shutil.copy2(ROOT / "provider-runners/python/dependencies/fixture_dependency.py", dependency)
        architecture = platform.machine()
        if architecture not in {"arm64", "x86_64"}:
            raise SandboxProbeError(f"unsupported sandbox probe architecture: {architecture}")
        lock = json.loads((ROOT / "provider-runners/runtime-lock-v1.json").read_text(encoding="utf-8"))
        python_lock = lock["runtimes"]["python"]
        artifact = python_lock["artifacts"][architecture]
        try:
            archive = fetch_artifact(artifact, runtime_work / "cache")
            extracted = runtime_work / "extracted"
            safe_extract(archive, extracted)
            runtime_root = package / "runtimes" / "cpython"
            runtime_executable = build_python(
                (extracted / artifact["root"]).resolve(strict=True),
                runtime_root,
            )
            sign_macho_tree(runtime_root, "-")
            runtime_errors = validate_runtime(
                "python",
                runtime_root,
                runtime_executable,
                architecture,
                python_lock["required_version"],
            )
        except (OSError, RuntimeError, subprocess.CalledProcessError, ValueError) as error:
            raise SandboxProbeError(f"bundled CPython preparation failed: {error}") from error
        if runtime_errors:
            raise SandboxProbeError(f"bundled CPython validation failed: {'; '.join(runtime_errors)}")

        sandbox_manifest = {
            "provider_id": provider_id,
            "version": "1.0.0",
            "protocol": 1,
            "shell_min_version": "1.0.0",
            "macos_min_version": "14.0",
            "architectures": [architecture],
            "runtime": "python",
            "entrypoint": str(provider.relative_to(package)),
            "runner": str(runner.relative_to(package)),
            "runtime_executable": str(runtime_executable.relative_to(package)),
            "sandbox": {
                "profile_version": 2,
                "launcher": str(launcher.relative_to(package)),
                "bundle_id": f"com.netvplayer.provider.{provider_id}",
                "release_profile": COMMUNITY_ADHOC_RELEASE_PROFILE,
            },
            "provider_class": "Spider",
            "capabilities": ["home", "search", "proxy"],
            "assets": [],
            "license": "fixture-only",
            "status": "compatible",
            "revoked": False,
        }
        manifest_path = package / "sandbox-manifest.json"
        manifest_path.write_text(json.dumps(sandbox_manifest), encoding="utf-8")
        package_tool: Path | None = None
        if skip_swift_gate:
            swift_gate = "not-applicable-private-export"
        else:
            package_tool_build = run(
                [
                    "swift", "build", "--disable-sandbox", "--package-path", str(PACKAGE_ROOT),
                    "--product", "ProviderPackageTool",
                ]
            )
            if package_tool_build.returncode != 0:
                raise SandboxProbeError(package_tool_build.stderr.strip() or "ProviderPackageTool build failed")
            package_tool_path = run(
                [
                    "swift", "build", "--disable-sandbox", "--package-path", str(PACKAGE_ROOT),
                    "--show-bin-path",
                ]
            )
            if package_tool_path.returncode != 0:
                raise SandboxProbeError(package_tool_path.stderr.strip() or "ProviderPackageTool path lookup failed")
            package_tool = Path(package_tool_path.stdout.strip()) / "ProviderPackageTool"
            shell_verification = run(
                [
                    str(package_tool),
                    "verify-sandbox",
                    "--manifest",
                    str(manifest_path),
                    "--package",
                    str(package),
                    "--state",
                    str(state),
                ]
            )
            if shell_verification.returncode != 0:
                raise SandboxProbeError(
                    f"Swift sandbox verification failed: {shell_verification.stderr.strip()}"
                )
            try:
                shell_result = json.loads(shell_verification.stdout)
            except json.JSONDecodeError as error:
                raise SandboxProbeError(
                    f"invalid Swift sandbox verification: {shell_verification.stdout!r}"
                ) from error
            if (
                shell_result.get("sandbox") != "app-sandbox-v2"
                or shell_result.get("launcher") != str(launcher)
            ):
                raise SandboxProbeError(f"Swift sandbox command mismatch: {shell_result}")
            swift_gate = "passed"
        for directory in ("home", "tmp", "cache", "config", "data"):
            (state / directory).mkdir(mode=0o700, exist_ok=True)
        requests = [
            {"protocol": 1, "request_id": "handshake", "provider_id": provider_id, "operation": "handshake", "arguments": {}},
            {
                "protocol": 1,
                "request_id": "init",
                "provider_id": provider_id,
                "operation": "init",
                "site": {"key": "sandbox", "name": "Sandbox", "api": "sandbox"},
                "arguments": {"extend": "sandbox-ext"},
            },
            {
                "protocol": 1,
                "request_id": "search",
                "provider_id": provider_id,
                "operation": "search",
                "arguments": {"keyword": "sandboxed"},
            },
            {"protocol": 1, "request_id": "proxy", "provider_id": provider_id, "operation": "proxy", "arguments": {}},
            {"protocol": 1, "request_id": "shutdown", "provider_id": provider_id, "operation": "shutdown", "arguments": {}},
        ]
        environment = {
            "PATH": "/usr/bin:/bin",
            "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8",
            "HOME": str(state / "home"),
        "TMPDIR": str(state / "tmp") + "/",
            "XDG_CACHE_HOME": str(state / "cache"),
            "XDG_CONFIG_HOME": str(state / "config"),
            "XDG_DATA_HOME": str(state / "data"),
            "PYTHONPYCACHEPREFIX": str(state / "cache" / "python"),
            "PYTHONDONTWRITEBYTECODE": "1",
            "PYTHONNOUSERSITE": "1",
            "NETVPLAYER_PROVIDER_ID": provider_id,
            "NETVPLAYER_PROVIDER_PROTOCOL": "1",
            "NETVPLAYER_PROVIDER_ROOT": str(package),
            "NETVPLAYER_PROVIDER_SANDBOX": "app-sandbox-v2",
            "NETVPLAYER_PROVIDER_STATE": str(state),
        }
        lifecycle = run(
            [
                str(launcher),
                "--",
                str(runtime_executable),
                "-I",
                "-S",
                str(runner),
                "--provider",
                str(provider),
                "--class",
                "Spider",
            ],
            input="".join(json.dumps(request, separators=(",", ":")) + "\n" for request in requests),
            env=environment,
            timeout=30,
        )
        if lifecycle.returncode != 0:
            raise SandboxProbeError(
                f"sandboxed Python lifecycle failed ({lifecycle.returncode}): {lifecycle.stderr.strip()}"
            )
        try:
            responses = [json.loads(line) for line in lifecycle.stdout.splitlines() if line.strip()]
        except json.JSONDecodeError as error:
            raise SandboxProbeError(f"invalid Python Runner output: {lifecycle.stdout!r}") from error
        if [response.get("request_id") for response in responses] != [
            "handshake", "init", "search", "proxy", "shutdown"
        ] or not all(response.get("ok") is True for response in responses):
            raise SandboxProbeError(f"Python Runner lifecycle mismatch: {responses}")
        if responses[0].get("result", {}).get("runtime") != "python":
            raise SandboxProbeError("Python Runner handshake did not report the Python runtime")
        if responses[2].get("result", {}).get("list", [{}])[0].get("vod_name") != "sandboxed":
            raise SandboxProbeError("Python Runner search result mismatch")
        if responses[3].get("proxy", {}).get("body_base64") != "cG9jLWJ5dGVz":
            raise SandboxProbeError("Python Runner proxy byte stream mismatch")

        quickjs_result = run_quickjs_sandbox(
            quickjs_package,
            quickjs_state,
            f"{provider_id}-quickjs",
            launcher_source,
            runtime_work,
            architecture,
            package_tool,
        )

        print(
            json.dumps(
                {
                    "app_sandbox": "enforced",
                    "child_exec": "passed",
                    "python_catvod_lifecycle": "passed",
                    "python_runtime": python_lock["version"],
                    "quickjs_provider_lifecycle": "passed",
                    "quickjs_runtime": quickjs_result["runtime"],
                    "quickjs_swift_signature_entitlement_gate": quickjs_result["swift_signature_entitlement_gate"],
                    "quickjs_swift_persistence_backend": quickjs_result["swift_persistence_backend"],
                    "quickjs_swift_module_http": quickjs_result["module_http"],
                    "quickjs_swift_proxy_data_plane": quickjs_result["proxy_data_plane"],
                    "runtime_packaging": "passed",
                    "swift_signature_entitlement_gate": swift_gate,
                    "operations": ["handshake", "init", "search", "proxy", "shutdown"],
                    "package_read": "allowed",
                    "provider_state_write": "allowed",
                    "outside_read": "denied",
                    "outside_write": "denied",
                    "release_profile": COMMUNITY_ADHOC_RELEASE_PROFILE,
                    "sandbox_profile": "app-sandbox-v2",
                    "apple_trust": "manual-user-approval-required",
                },
                sort_keys=True,
            )
        )
        return 0
    except SandboxProbeError as error:
        print(f"provider app sandbox probe: {error}", file=sys.stderr)
        return 1
    finally:
        shutil.rmtree(provider_root, ignore_errors=True)
        shutil.rmtree(quickjs_provider_root, ignore_errors=True)
        shutil.rmtree(providers / ".state" / f"{provider_id}-quickjs", ignore_errors=True)
        shutil.rmtree(outside, ignore_errors=True)
        shutil.rmtree(runtime_work, ignore_errors=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--skip-swift-gate", action="store_true")
    parser.add_argument("--quickjs-only", action="store_true")
    arguments = parser.parse_args()
    if arguments.quickjs_only:
        raise SystemExit(main_quickjs_only(skip_swift_gate=arguments.skip_swift_gate))
    raise SystemExit(main(skip_swift_gate=arguments.skip_swift_gate))
