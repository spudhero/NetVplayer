#!/usr/bin/env python3
"""Repeat the isolated, muted Apple E-AC-3 packet/clock experiment.

Uses only the original AV-09 ordinary E-AC-3 fixture, a stream-copy MP4,
public Apple frameworks and an ad-hoc signed temporary app. No product or
global audio preferences are written. Requires native desktop/audio access.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import signal
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
FIXTURE_SHA = "414af8f6bd5e8c4d19ddb8891bcd9ee1b9cc6d9c0c73dae0ed26d5370666554f"


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def save(path, data):
    path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixture", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--ffmpeg", default="/opt/homebrew/bin/ffmpeg")
    parser.add_argument("--ffprobe", default="/opt/homebrew/bin/ffprobe")
    args = parser.parse_args()
    if sha(args.fixture) != FIXTURE_SHA:
        raise SystemExit("Input differs from the committed original AV-09 fixture")
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    commands = []
    env = {k: v for k, v in os.environ.items() if not k.startswith("DYLD_")}

    def run(command, timeout=60, required=True):
        start = time.monotonic()
        result = subprocess.run(command, env=env, text=True, capture_output=True, timeout=timeout)
        commands.append(dict(command=command, exitCode=result.returncode, seconds=time.monotonic()-start,
                             stdout=result.stdout, stderr=result.stderr))
        save(out / "commands.json", commands)
        if required and result.returncode:
            raise RuntimeError(f"Command failed ({result.returncode}); see commands.json")
        return result

    sdk = run(["xcrun", "--sdk", "macosx", "--show-sdk-path"]).stdout.strip()
    app = out / "NativeCompressedProbe.app"
    macos = app / "Contents" / "MacOS"
    macos.mkdir(parents=True)
    binary = macos / "NativeCompressedProbe"
    with (app / "Contents" / "Info.plist").open("wb") as f:
        plistlib.dump(dict(CFBundleExecutable=binary.name, CFBundleIdentifier="local.netvplayer.audio-research",
                          CFBundleName="Native Compressed Audio Research", CFBundlePackageType="APPL",
                          LSMinimumSystemVersion="14.0", LSUIElement=True), f)
    source = ROOT / "script/probes/native_compressed_audio.swift"
    run(["xcrun", "swiftc", "-parse-as-library", "-target", "arm64-apple-macosx14.0", "-sdk", sdk,
         "-module-cache-path", str(out / "module-cache"), str(source), "-o", str(binary)], timeout=120)
    run(["codesign", "--force", "--sign", "-", str(app)])
    run(["codesign", "--verify", "--deep", "--strict", str(app)])
    mp4 = out / "ordinary-eac3.mp4"
    run([args.ffmpeg, "-nostdin", "-v", "error", "-i", str(args.fixture), "-map", "0:v:0",
         "-map", "0:a:0", "-c", "copy", str(mp4)])
    reference = json.loads(run([args.ffprobe, "-v", "error", "-select_streams", "a:0", "-show_streams",
        "-show_packets", "-show_data_hash", "sha256", "-of", "json", str(mp4)]).stdout)
    # Keep independent hashes and times, not packet payloads or third-party media.
    save(out / "ffprobe.json", reference)
    raw = out / "ordinary-eac3.raw"
    run([args.ffmpeg, "-nostdin", "-v", "error", "-i", str(mp4), "-map", "0:a:0", "-c", "copy", "-f", "eac3", str(raw)])

    def launch(mode, media, name):
        report = out / f"{name}.json"
        try:
            # LaunchServices supplies a real bundle context; no raw GUI executable launch.
            run(["/usr/bin/open", "-n", "-W", "--stderr", str(out / f"{name}.stderr"), str(app),
                 "--args", mode, str(media), str(report)], timeout=45, required=False)
        except subprocess.TimeoutExpired:
            # Kill only this exact temporary executable if the framework stalls.
            listing = subprocess.run(["ps", "-axo", "pid=,comm="], capture_output=True, text=True, check=True).stdout
            for line in listing.splitlines():
                fields = line.strip().split(None, 1)
                if len(fields) == 2 and fields[1] == str(binary):
                    os.kill(int(fields[0]), signal.SIGKILL)
            save(out / f"{name}-timeout.json", {"timeoutSeconds": 45, "passed": False})
            raise
        if not report.exists():
            raise RuntimeError("Native app did not produce a report")
        return json.loads(report.read_text())

    inspect = launch("inspect", mp4, "packets")
    mkv = launch("inspect", args.fixture, "mkv-boundary")
    lifecycle = launch("lifecycle", mp4, "lifecycle")
    packets = inspect.get("packets", [])
    expected = reference["packets"]
    same_count = len(packets) == len(expected) and len(packets) > 0
    hashes_equal = same_count and all(a["sha256"] == b["data_hash"].split(":")[1].lower()
                                    and a["bytes"] == int(b["size"]) for a, b in zip(packets, expected))
    max_pts = max((abs(a["pts"] - float(b["pts_time"])) for a, b in zip(packets, expected)), default=None)
    max_duration = max((abs(a["duration"] - float(b["duration_time"])) for a, b in zip(packets, expected)), default=None)
    # FFmpeg exposes negative priming PTS + Skip Samples; CoreMedia preserves
    # TrimDurationAtStart and exposes the presentation timeline separately.
    # Compare these documented output timestamps, while retaining raw PTS mismatch.
    max_output_pts = max((abs(a["outputPTS"] - max(0, float(b["pts_time"])))
                          for a, b in zip(packets, expected)), default=None)
    checks = dict(packetCount=same_count, everyPacketBytes=hashes_equal,
                  concatenatedPayload=inspect.get("payloadSHA256") == sha(raw),
                  outputPTSWithinOneSample=same_count and max_output_pts <= 1/48000,
                  durationsWithinOneSample=same_count and max_duration <= 1/48000,
                  inputRemainsEAC3=inspect.get("format", {}).get("formatID") == "ec-3",
                  lifecycle=lifecycle.get("passed") is True,
                  systemDefaultUnchanged=lifecycle.get("systemDefaultUnchanged") is True)
    result = dict(schema=1, checks=checks, passed=all(checks.values()), packetCount=len(packets),
                  maximumRawPTSDeltaSeconds=max_pts, rawPTSDirectlyInterchangeable=same_count and max_pts <= 1/48000,
                  maximumOutputPTSDeltaSeconds=max_output_pts, maximumDurationDeltaSeconds=max_duration,
                  sourceSHA256=FIXTURE_SHA, mp4SHA256=sha(mp4), rawSHA256=sha(raw),
                  probeSourceSHA256=sha(source), probeBinarySHA256=sha(binary),
                  mkvReaderSupported=mkv.get("passed") is True,
                  sourceIsJOC=False, productIntegration=False, physicalHDMIPassed=False,
                  receiverAtmosVerified=False, acousticSyncMeasured=False, independentMacOS14Run=False,
                  minimumOS=run(["xcrun", "vtool", "-show-build", str(binary)]).stdout,
                  generatorVersion=run([args.ffmpeg, "-version"]).stdout.splitlines()[0],
                  xcode=run(["xcodebuild", "-version"]).stdout, sdk=sdk)
    save(out / "summary.json", result)
    print(json.dumps({k: v for k, v in result.items() if k not in ["minimumOS", "sdk"]}, indent=2))
    raise SystemExit(0 if result["passed"] else 1)


if __name__ == "__main__":
    main()
