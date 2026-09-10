#!/usr/bin/env python3
"""Run the Provider checks that must pass in the clean public-shell repository."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[1]


def run_step(label: str, command: list[str], environment: dict[str, str] | None = None) -> str:
    print(f"[provider-public-shell] {label}", file=sys.stderr)
    result = subprocess.run(
        command,
        cwd=ROOT,
        env=environment,
        text=True,
        capture_output=True,
        check=False,
    )
    if result.stdout:
        print(result.stdout, end="", file=sys.stderr)
    if result.stderr:
        print(result.stderr, end="", file=sys.stderr)
    if result.returncode != 0:
        raise RuntimeError(f"{label} failed with exit code {result.returncode}")
    return result.stdout + result.stderr


def required_gson(path: str | None) -> Path:
    value = path or os.environ.get("NETVPLAYER_GSON_JAR")
    if not value:
        raise RuntimeError("set NETVPLAYER_GSON_JAR or pass --gson-jar")
    candidate = Path(value).expanduser().resolve(strict=True)
    if candidate.suffix.lower() != ".jar":
        raise RuntimeError(f"Gson dependency must be a JAR: {candidate}")
    return candidate


def require_runtime_versions() -> None:
    if sys.version_info[:2] != (3, 12):
        raise RuntimeError(f"Python 3.12 is required, found {sys.version.split()[0]}")

    java = shutil.which("java")
    javac = shutil.which("javac")
    node = shutil.which("node")
    if not java or not javac or not node:
        raise RuntimeError("Java 21 JDK and Node 22.20.0 are required")

    java_version = subprocess.run(
        [java, "--version"], text=True, capture_output=True, check=False
    )
    java_match = re.search(r"(?:openjdk|java)\s+(\d+)", java_version.stdout + java_version.stderr)
    if java_version.returncode != 0 or not java_match or java_match.group(1) != "21":
        raise RuntimeError("Java runtime must be major version 21")

    javac_version = subprocess.run(
        [javac, "-version"], text=True, capture_output=True, check=False
    )
    if javac_version.returncode != 0 or not re.search(
        r"javac\s+21(?:\.|\s|$)", javac_version.stdout + javac_version.stderr
    ):
        raise RuntimeError("Java compiler must be major version 21")

    node_version = subprocess.run(
        [node, "--version"], text=True, capture_output=True, check=False
    )
    if node_version.returncode != 0 or node_version.stdout.strip() != "v22.20.0":
        raise RuntimeError("Node runtime must be version 22.20.0")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--gson-jar", help="local Gson JAR used by the Java fixtures")
    arguments = parser.parse_args()

    require_runtime_versions()
    gson = required_gson(arguments.gson_jar)

    with tempfile.TemporaryDirectory(prefix="netvplayer-public-provider-") as temporary:
        output = Path(temporary) / "java-runner"
        run_step(
            "build public Java runner and fixtures",
            [str(ROOT / "provider-runners/java/build.sh"), str(gson), str(output)],
        )
        environment = os.environ.copy()
        environment.update({
            "NETVPLAYER_JAVA_RUNNER": str(output / "java-runner.jar"),
            "NETVPLAYER_JAVA_PROVIDER": str(output / "mock-provider.jar"),
            "NETVPLAYER_JAVA_CMS_PROVIDER": str(output / "json-cms-provider.jar"),
        })
        runner_output = run_step(
            "run four public Java, JS, and Python lifecycle contracts",
            [
                sys.executable,
                "-m",
                "unittest",
                "-v",
                "script.test_provider_runners.ProviderRunnerTests.test_python_catvod_lifecycle",
                "script.test_provider_runners.ProviderRunnerTests.test_python_init_optionally_receives_wire_site",
                "script.test_provider_runners.ProviderRunnerTests.test_javascript_catvod_lifecycle",
                "script.test_provider_runners.ProviderRunnerTests.test_java_catvod_lifecycle",
                "script.test_provider_runners.ProviderRunnerTests.test_java_standard_json_cms_lifecycle",
            ],
            environment,
        )
        if "Ran 5 tests" not in runner_output or "skipped" in runner_output:
            raise RuntimeError("public Runner gate did not execute all five lifecycle tests")

    run_step(
        "run public package, catalog, trust, and boundary contracts",
        [
            sys.executable,
            "-m",
            "unittest",
            "-v",
            "script/test_provider_package.py",
            "script/test_provider_distribution_index.py",
            "script/test_validate_node_runtime.py",
            "script/test_validate_java_runtime.py",
            "script/test_validate_cpython_runtime.py",
            "script/test_validate_macos_runtime_architectures.py",
            "script/test_validate_provider_release.py",
            "script/test_validate_provider_sandbox.py",
            "script/test_prepare_provider_runtimes.py",
            "script/test_validate_provider_trust_inputs.py",
            "script/test_audit_provider_public_boundary.py",
            "script/test_audit_provider_public_release.py",
            "script/test_audit_source_free_app.py",
            "script/test_export_provider_public_shell.py",
            "script/test_package_libmpv_runtime_licenses.py",
            "script/test_audit_torrent_bridge_licenses.py",
            "script/test_apply_torrent_bridge_replacements.py",
        ],
    )
    sandbox_output = run_step(
        "run App Sandbox bundled-CPython lifecycle",
        [sys.executable, "script/test_provider_app_sandbox.py"],
    )
    sandbox_summary = json.loads(sandbox_output.splitlines()[-1])
    if sandbox_summary.get("python_catvod_lifecycle") != "passed":
        raise RuntimeError("public App Sandbox lifecycle did not pass")
    boundary_output = run_step(
        "verify checked-in repository boundary",
        [
            sys.executable,
            "script/audit_provider_public_boundary.py",
            "--check",
            "docs/data/provider-public-boundary-v1.json",
        ],
    )
    boundary_summary = json.loads(boundary_output.splitlines()[-1])
    if boundary_summary.get("release_ready"):
        run_step(
            "audit public source release",
            [sys.executable, "script/audit_provider_public_release.py"],
        )
    print("public Provider shell gate: passed")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, ValueError) as error:
        print(f"public Provider shell gate: {error}", file=sys.stderr)
        raise SystemExit(1)
