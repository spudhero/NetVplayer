#!/usr/bin/env python3
"""Audit the pinned FEL merge through public libmpv APIs in an isolated host.

Does not install libraries or modify product preferences. A successful audit
means the observations were collected, not that FEL product acceptance passed.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess

MPV_COMMIT = "99b4c12cccb4d8d3f72b41944cb6c640e2156650"
REPO = Path(__file__).resolve().parents[1]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n")


def difference(left, right):
    if len(left) != 640 * 360 * 4 or len(right) != len(left):
        raise ValueError("unexpected RGBA8 readback size")
    return max(abs(a-b) for i, (a, b) in enumerate(zip(left, right)) if i % 4 != 3)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--library", required=True, type=Path)
    parser.add_argument("--fixtures", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    source, library, fixtures, output = [p.resolve() for p in
        (args.source, args.library, args.fixtures, args.output)]
    commit = subprocess.check_output(["git", "-C", str(source), "rev-parse", "HEAD"], text=True).strip()
    if commit != MPV_COMMIT:
        parser.error("source must be the pinned FEL merge " + MPV_COMMIT)
    if subprocess.check_output(["git", "-C", str(source), "status", "--porcelain"], text=True).strip():
        parser.error("upstream source must be unmodified")
    if not library.is_file() or output.exists():
        parser.error("library must exist and output must be a new directory")
    manifest_path = REPO / "docs/data/playback-av06/manifest.json"
    manifest = json.loads(manifest_path.read_text())
    expected = {item["file"]: item for item in manifest["samples"]}
    names = ["p81-a.mp4", "p81-b.mp4", "p81-no-rpu.mp4", "p81-a.srt"]
    inputs = []
    for name in names:
        path = fixtures / name
        expected_hash = (digest(REPO/"docs/data/playback-av06"/name)
                         if name.endswith(".srt") else expected[name]["sha256"])
        if digest(path) != expected_hash:
            parser.error("input differs from committed AV-06 manifest: " + name)
        inputs.append({"file": name, "sha256": digest(path), "bytes": path.stat().st_size})
    output.mkdir(parents=True)
    fresh = output / "inputs"
    fresh.mkdir()
    for name in names:
        shutil.copyfile(fixtures / name, fresh / name)
    host_source = REPO / "script/probes/mpv_dovi_embed_host.m"
    host = output / "embed-host"
    compile_command = ["/usr/bin/xcrun", "clang", "-fobjc-arc", "-mmacosx-version-min=14.0",
        "-Wno-deprecated-declarations", "-I", str(source/"include"), str(host_source),
        "-framework", "AppKit", "-framework", "OpenGL", "-Wl,-rpath," + str(library.parent),
        "-o", str(host)]
    env = os.environ.copy()
    env.pop("DYLD_LIBRARY_PATH", None)
    env.pop("DYLD_FALLBACK_LIBRARY_PATH", None)
    env["CLANG_MODULE_CACHE_PATH"] = str(output/"module-cache")
    with (output/"compile.log").open("w") as log:
        subprocess.run(compile_command, env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
    observations, issues = [], []
    cases = [(api, "p81-a.mp4") for api in ["opengl", "sw", "metal", "vulkan", "gpu-next", "d3d11", "libplacebo"]]
    cases += [("opengl", name) for name in names[1:3]]
    for api, name in cases:
        label = api + "-" + name
        folder = output / label
        command = [str(host), str(library), api, str(fresh/name), str(folder), str(fresh/"p81-a.srt")]
        with (output/(label+".log")).open("w") as log:
            try:
                result = subprocess.run(command, env=env, stdout=log, stderr=subprocess.STDOUT, timeout=30)
            except subprocess.TimeoutExpired:
                issues.append(label + ": host timed out")
                continue
        if result.returncode or not (folder/"report.json").exists():
            issues.append(label + ": host failed (" + str(result.returncode) + ")")
            continue
        record = json.loads((folder/"report.json").read_text())
        record["command"] = command
        if api == "opengl":
            valid = (record.get("renderContextCreateCode") == 0 and record.get("fileLoaded")
                and record.get("activeVO") == "libmpv" and record.get("submittedFrames", 0) >= 2
                and record.get("renderErrors") == 0 and record.get("readbackGLError") == 0
                and record.get("framebufferComplete") and not record.get("optionErrors")
                and abs(record.get("pausedClockDelta", 10)) <= 0.05
                and abs(record.get("seekPosition", 0)-5) <= 0.15
                and record.get("subtitleCommandCode") == 0)
            pixels = (folder/"frame.rgba").read_bytes()
            subtitle = (folder/"subtitle.rgba").read_bytes()
            record["subtitleMaxDifferenceLSB"] = difference(pixels, subtitle)
            valid = valid and record["subtitleMaxDifferenceLSB"] > 0
            if not valid:
                issues.append(label + ": embedded frame/session/subtitle contract failed")
            record["frameSHA256"] = digest(folder/"frame.rgba")
        else:
            expected_code = 0 if api == "sw" else -19
            if record.get("renderContextCreateCode") != expected_code:
                issues.append(label + ": unexpected API creation result")
        observations.append(record)
        write_json(output/"observations.json", observations)
    comparisons = {}
    try:
        base = (output/"opengl-p81-a.mp4/frame.rgba").read_bytes()
        for name in names[1:3]:
            comparisons[name] = difference(base, (output/("opengl-"+name)/"frame.rgba").read_bytes())
    except FileNotFoundError:
        issues.append("incomplete readback comparisons")
    header = source / "include/mpv/render.h"
    report = {"schema": 1, "headerSourceCommit": commit, "library": str(library),
        "librarySHA256": digest(library), "hostSHA256": digest(host),
        "hostSourceSHA256": digest(host_source), "compileCommand": compile_command,
        "fixtureManifestSHA256": digest(manifest_path), "inputs": inputs,
        "renderHeaderSHA256": digest(header),
        "declaredRenderAPIs": re.findall(r'^#define MPV_RENDER_API_TYPE_\w+ "([^"]+)"', header.read_text(), re.M),
        "observations": observations, "comparisonMaxRGBLSB": comparisons,
        "issues": issues, "auditPassed": not issues,
        "felProductAcceptancePassed": False, "minimumMacOS14RunVerified": False,
        "scope": "Public render API and P8.1 compatibility research; no FEL master, P5 color reference, EDR/TV signal or 4K performance acceptance"}
    write_json(output/"summary.json", report)
    print(json.dumps({"output": str(output), "issues": issues, "comparisonMaxRGBLSB": comparisons}))
    return bool(issues)


if __name__ == "__main__":
    raise SystemExit(main())
