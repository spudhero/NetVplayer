#!/usr/bin/env python3
"""Build reproducible architecture-specific Provider runtime roots."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import tempfile
from urllib.parse import urlparse
from urllib.request import urlopen

import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from build_provider_sandbox_launcher import RELEASE_PROFILES, validate_release_profile
from validate_cpython_runtime import validate as validate_cpython_runtime
from validate_java_runtime import validate as validate_java_runtime
from validate_macos_runtime_architectures import validate as validate_architectures
from validate_node_runtime import is_macho, validate as validate_node_runtime


ARCHITECTURES = {"arm64", "x86_64"}
RUNTIMES = {"java", "js", "python"}
HEX_DIGEST = re.compile(r"^[a-f0-9]{64}$")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def validate_lock(document: object) -> list[str]:
    if not isinstance(document, dict):
        return ["runtime lock must be an object"]
    errors: list[str] = []
    if document.get("schema_version") != 1:
        errors.append("runtime lock schema_version must be 1")
    architectures = document.get("architectures")
    if not isinstance(architectures, list) or set(architectures) != ARCHITECTURES:
        errors.append("runtime lock must cover arm64 and x86_64 exactly")
    runtimes = document.get("runtimes")
    if not isinstance(runtimes, dict) or set(runtimes) != RUNTIMES:
        return errors + ["runtime lock must contain java, js, and python"]
    for runtime, record in runtimes.items():
        if not isinstance(record, dict) or not isinstance(record.get("version"), str):
            errors.append(f"{runtime}: version is required")
            continue
        artifacts = record.get("artifacts")
        if not isinstance(artifacts, dict) or set(artifacts) != ARCHITECTURES:
            errors.append(f"{runtime}: artifacts must cover arm64 and x86_64 exactly")
            continue
        for architecture, artifact in artifacts.items():
            prefix = f"{runtime}.{architecture}"
            if not isinstance(artifact, dict):
                errors.append(f"{prefix}: artifact must be an object")
                continue
            filename = artifact.get("filename")
            if not isinstance(filename, str) or Path(filename).name != filename:
                errors.append(f"{prefix}: filename is unsafe")
            parsed = urlparse(artifact.get("url", ""))
            if parsed.scheme != "https" or not parsed.netloc:
                errors.append(f"{prefix}: URL must use HTTPS")
            digest = artifact.get("sha256")
            if not isinstance(digest, str) or not HEX_DIGEST.fullmatch(digest):
                errors.append(f"{prefix}: sha256 is invalid")
            root = artifact.get("root")
            if not isinstance(root, str) or Path(root).is_absolute() or ".." in Path(root).parts:
                errors.append(f"{prefix}: root is unsafe")
    return errors


def fetch_artifact(artifact: dict[str, str], cache: Path) -> Path:
    cache.mkdir(parents=True, exist_ok=True)
    target = cache / artifact["filename"]
    if target.exists():
        actual = sha256(target)
        if actual != artifact["sha256"]:
            raise RuntimeError(f"cached artifact hash mismatch for {target.name}: {actual}")
        return target
    temporary = cache / f".{target.name}.download"
    if temporary.exists():
        raise RuntimeError(f"incomplete runtime download already exists: {temporary}")
    with urlopen(artifact["url"], timeout=60) as response, temporary.open("xb") as output:
        shutil.copyfileobj(response, output, length=1024 * 1024)
    actual = sha256(temporary)
    if actual != artifact["sha256"]:
        temporary.unlink()
        raise RuntimeError(f"downloaded artifact hash mismatch for {target.name}: {actual}")
    temporary.replace(target)
    return target


def safe_extract(archive: Path, destination: Path) -> None:
    destination.mkdir(parents=True)
    with tarfile.open(archive, "r:gz") as bundle:
        bundle.extractall(destination, filter="data")


def materialize_runtime_symlinks(runtime_root: Path) -> None:
    canonical_root = runtime_root.resolve(strict=True)
    for path in sorted(runtime_root.rglob("*")):
        if not path.is_symlink():
            continue
        try:
            resolved = path.resolve(strict=True)
            resolved.relative_to(canonical_root)
        except (FileNotFoundError, ValueError) as error:
            raise RuntimeError(f"runtime symlink escapes package: {path}") from error
        if not resolved.is_file():
            raise RuntimeError(f"runtime symlink target is not a file: {path}")
        contents = resolved.read_bytes()
        mode = resolved.stat().st_mode & 0o777
        path.unlink()
        path.write_bytes(contents)
        path.chmod(mode)


def build_java(source: Path, target: Path, architecture: str, modules: str) -> Path:
    command = [
        "/usr/bin/arch", f"-{architecture}", str(source / "bin/jlink"),
        "--add-modules", modules,
        "--strip-debug", "--no-man-pages", "--no-header-files", "--compress=2",
        "--output", str(target),
    ]
    subprocess.run(command, check=True)
    materialize_runtime_symlinks(target)
    return target / "bin/java"


def build_node(source: Path, target: Path) -> Path:
    (target / "bin").mkdir(parents=True)
    shutil.copy2(source / "bin/node", target / "bin/node")
    shutil.copy2(source / "LICENSE", target / "LICENSE")
    return target / "bin/node"


def build_python(source: Path, target: Path) -> Path:
    shutil.copytree(source, target, symlinks=True)
    materialize_runtime_symlinks(target)
    return target / "bin/python3"


def sign_macho_tree(root: Path, identity: str | None) -> int:
    binaries = sorted(
        (path for path in root.rglob("*") if path.is_file() and is_macho(path)),
        key=lambda path: len(path.parts),
        reverse=True,
    )
    for binary in binaries:
        if identity:
            command = ["/usr/bin/codesign", "--force", "--sign", identity]
            if identity != "-":
                command.extend(["--options", "runtime", "--timestamp"])
            command.append(str(binary))
            subprocess.run(command, check=True, capture_output=True)
        subprocess.run(
            ["/usr/bin/codesign", "--verify", "--strict", str(binary)],
            check=True,
            capture_output=True,
        )
    return len(binaries)


def file_sums(root: Path) -> list[str]:
    return [
        f"{sha256(path)}  {path.relative_to(root).as_posix()}"
        for path in sorted(root.rglob("*"))
        if path.is_file()
    ]


def validate_runtime(runtime: str, root: Path, executable: Path, architecture: str, version: str) -> list[str]:
    errors = validate_architectures(root, executable, {architecture}, {architecture})
    if runtime == "java":
        errors.extend(validate_java_runtime(root, executable, version))
    elif runtime == "js":
        errors.extend(validate_node_runtime(root, executable))
        if not errors:
            result = subprocess.run(
                [str(executable), "-p", "process.versions.node"],
                check=False, capture_output=True, text=True, timeout=60,
            )
            if result.returncode != 0 or result.stdout.strip() != version:
                errors.append(f"Node version mismatch: expected {version}, got {result.stdout.strip()}")
    else:
        errors.extend(validate_cpython_runtime(root, executable))
        if not errors:
            result = subprocess.run(
                [str(executable), "-I", "-S", "-c", "import sys; print(f'{sys.version_info[0]}.{sys.version_info[1]}')"],
                check=False, capture_output=True, text=True, timeout=60,
            )
            if result.returncode != 0 or result.stdout.strip() != version:
                errors.append(f"CPython version mismatch: expected {version}, got {result.stdout.strip()}")
    return errors


def prepare(
    lock_path: Path,
    cache: Path,
    output: Path,
    codesign_identity: str | None,
    release_profile: str,
) -> dict[str, object]:
    if not codesign_identity:
        raise RuntimeError("a macOS code-signing identity is required")
    try:
        codesign_identity = validate_release_profile(release_profile, codesign_identity)
    except ValueError as error:
        raise RuntimeError(str(error)) from error
    lock = json.loads(lock_path.read_text(encoding="utf-8"))
    errors = validate_lock(lock)
    if errors:
        raise RuntimeError("; ".join(errors))
    if output.exists():
        raise RuntimeError(f"output already exists: {output}")
    output.mkdir(parents=True)
    report: dict[str, object] = {
        "schema_version": 1,
        "lock_sha256": sha256(lock_path),
        "architectures": lock["architectures"],
        "code_signing": "adhoc" if codesign_identity == "-" else "developer-id",
        "release_profile": release_profile,
        "runtimes": {},
    }
    try:
        with tempfile.TemporaryDirectory(prefix="netvplayer-provider-runtimes-") as temporary:
            work = Path(temporary)
            for runtime in sorted(RUNTIMES):
                record = lock["runtimes"][runtime]
                runtime_report: dict[str, object] = {"version": record["version"], "architectures": {}}
                for architecture in lock["architectures"]:
                    artifact = record["artifacts"][architecture]
                    archive = fetch_artifact(artifact, cache)
                    extracted = work / f"{runtime}-{architecture}"
                    safe_extract(archive, extracted)
                    source = (extracted / artifact["root"]).resolve(strict=True)
                    target = output / architecture / {"java": "jre", "js": "node", "python": "cpython"}[runtime]
                    target.parent.mkdir(parents=True, exist_ok=True)
                    if runtime == "java":
                        executable = build_java(source, target, architecture, record["modules"])
                    elif runtime == "js":
                        executable = build_node(source, target)
                    else:
                        executable = build_python(source, target)
                    signed_files = sign_macho_tree(target, codesign_identity)
                    validation_errors = validate_runtime(
                        runtime,
                        target,
                        executable,
                        architecture,
                        record["required_version"],
                    )
                    if validation_errors:
                        raise RuntimeError(f"{runtime}.{architecture}: {'; '.join(validation_errors)}")
                    sums = file_sums(target)
                    (target / "SHA256SUMS").write_text("\n".join(sums) + "\n", encoding="utf-8")
                    runtime_report["architectures"][architecture] = {
                        "artifact_sha256": artifact["sha256"],
                        "executable": executable.relative_to(output / architecture).as_posix(),
                        "files": len(sums),
                        "macho_files": signed_files,
                        "validation": "passed",
                    }
                report["runtimes"][runtime] = runtime_report
        report["production_runtime_gate"] = "passed"
        (output / "runtime-build-report.json").write_text(
            json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        return report
    except Exception:
        report["production_runtime_gate"] = "failed"
        raise


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--lock", type=Path, default=Path("provider-runners/runtime-lock-v1.json"))
    parser.add_argument("--cache", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--codesign-identity", required=True)
    parser.add_argument("--release-profile", required=True, choices=RELEASE_PROFILES)
    arguments = parser.parse_args()
    report = prepare(
        arguments.lock.resolve(strict=True),
        arguments.cache.resolve(),
        arguments.output.resolve(),
        arguments.codesign_identity,
        arguments.release_profile,
    )
    print(json.dumps(report, ensure_ascii=False, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
