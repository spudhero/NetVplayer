#!/usr/bin/env python3
"""Build the pinned, exact TrueHD object decoder and collect its license closure."""
import ctypes
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess

COMMIT = "aebd5ffe1046dadbea833ce87a75d00fd8b1edd1"
UPSTREAM_COMMIT = "33bae1657ceb25b5fe0347f42c544c3414e2760e"
URL = "https://github.com/superuser404notfound/LibTrueHD"
RUST_VERSION = "1.98.1"


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def capture(command, **kwargs):
    return subprocess.check_output(list(map(str, command)), text=True, **kwargs).strip()


def build(source, work, env):
    source, prefix = Path(source), Path(work) / "truehd-prefix"
    if not source.exists():
        subprocess.run(["git", "clone", "--no-checkout", URL, str(source)], check=True, env=env)
        subprocess.run(["git", "checkout", "--detach", COMMIT], cwd=source, check=True, env=env)
    if capture(["git", "rev-parse", "HEAD"], cwd=source) != COMMIT:
        raise RuntimeError("LibTrueHD source does not match the audited pin")
    # A commit check alone must not bless modified decoder code or Cargo.lock.
    if capture(["git", "status", "--porcelain", "--untracked-files=no"], cwd=source):
        raise RuntimeError("LibTrueHD checkout has modified tracked sources")
    env = dict(env, RUSTUP_TOOLCHAIN=RUST_VERSION)
    cargo = shutil.which("cargo", path=env.get("PATH"))
    rustc = shutil.which("rustc", path=env.get("PATH"))
    if not cargo or not rustc:
        raise RuntimeError("The object decoder requires Cargo and Rust " + RUST_VERSION)
    rust = capture([rustc, "-vV"], env=env)
    if "release: " + RUST_VERSION not in rust:
        raise RuntimeError("Unexpected Rust toolchain")
    target = {"arm64": "aarch64", "aarch64": "aarch64", "x86_64": "x86_64"}[platform.machine()] + "-apple-darwin"
    target_dir = Path(work) / "truehd-build"
    command = [cargo, "rustc", "--release", "--locked", "--features", "matrix-interpolation",
               "--target", target, "--target-dir", target_dir, "--lib", "--crate-type", "cdylib"]
    subprocess.run(list(map(str, command)), cwd=source, env=env, check=True)
    binary = target_dir / target / "release/libtruehd_atmos.dylib"
    library = ctypes.CDLL(str(binary))
    library.truehd_atmos_api_version.restype = ctypes.c_uint32
    if library.truehd_atmos_api_version() != 2:
        raise RuntimeError("Unexpected TrueHD object ABI")
    (prefix / "lib/pkgconfig").mkdir(parents=True, exist_ok=True)
    (prefix / "include").mkdir(exist_ok=True)
    shutil.copy2(binary, prefix / "lib" / binary.name)
    shutil.copy2(source / "include/truehd_atmos.h", prefix / "include/truehd_atmos.h")
    (prefix / "lib/pkgconfig/truehd-atmos.pc").write_text(
        f"prefix={prefix}\nlibdir=${{prefix}}/lib\nincludedir=${{prefix}}/include\n"
        "Name: truehd-atmos\nDescription: pinned exact TrueHD object decoder\nVersion: 0.1.0\n"
        "Libs: -L${libdir} -ltruehd_atmos\nCflags: -I${includedir}\n")
    metadata = json.loads(capture([cargo, "metadata", "--locked", "--format-version=1",
                                   "--features", "matrix-interpolation"], cwd=source, env=env))
    notices = prefix / "licenses"
    notices.mkdir(exist_ok=True)
    components = []
    for package in sorted(metadata["packages"], key=lambda p: (p["name"], p["version"])):
        root = Path(package["manifest_path"]).parent
        licenses = [p for p in root.iterdir() if p.is_file() and
                    p.name.lower().startswith(("license", "notice", "copying", "copyright"))]
        if not licenses or not package.get("license"):
            raise RuntimeError("Missing Rust license: " + package["name"])
        name = package["name"] + "-" + package["version"]
        dest = notices / name
        dest.mkdir(exist_ok=True)
        for path in licenses:
            shutil.copy2(path, dest / path.name)
        components.append({"name": package["name"], "version": package["version"],
                           "license": package["license"], "source": package.get("source") or URL + "/commit/" + COMMIT})
    # Rust's standard library includes third-party code beyond the crates in
    # Cargo.lock. Ship the toolchain's library copyright table and license texts.
    rust_docs = Path(capture([rustc, "--print", "sysroot"], env=env)) / "share/doc/rust"
    shutil.copytree(rust_docs / "licenses", notices / "rust-stdlib/licenses", dirs_exist_ok=True)
    shutil.copy2(rust_docs / "COPYRIGHT-library.html", notices / "rust-stdlib/COPYRIGHT-library.html")
    return prefix, {
        "commit": COMMIT, "url": URL + "/commit/" + COMMIT,
        "upstreamCommit": UPSTREAM_COMMIT, "features": ["matrix-interpolation"],
        "cargoLockSHA256": sha(source / "Cargo.lock"), "headerSHA256": sha(source / "include/truehd_atmos.h"),
        "rust": rust, "target": target, "binarySHA256": sha(binary), "components": components,
    }


def package_licenses(prefix, destination, binary, provenance):
    notices = destination / "Contents/Resources/ThirdPartyLicenses"
    root = notices / "libmpv/truehd-atmos"
    shutil.copytree(prefix / "licenses", root, dirs_exist_ok=True)
    (root / "provenance.json").write_text(json.dumps(provenance, indent=2) + "\n")
    return {
        "formula": "truehd-atmos", "version": "0.1.0+" + COMMIT[:12],
        "license": "MIT AND Apache-2.0 AND Unicode-3.0", "homepage": URL,
        "source": {"url": URL + "/commit/" + COMMIT, "commit": COMMIT},
        "dylibs": [{"name": binary.name, "source_sha256": sha(binary)}],
        "license_files": [{"path": p.relative_to(destination).as_posix(), "sha256": sha(p),
                           "origin": "pinned-source"} for p in sorted(root.rglob("*")) if p.is_file()],
    }
