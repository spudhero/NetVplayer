#!/usr/bin/env python3
"""Generate original direction signals or independently analyze offline HRTF PCM."""
import argparse
import ctypes as C
import hashlib
import json
from pathlib import Path
import subprocess
import time

import numpy as np


class Event(C.Structure):
    _fields_ = [("event", C.c_int), ("error", C.c_int), ("userdata", C.c_uint64), ("data", C.c_void_p)]


def bundled_decode(library, source, target, layout):
    lib = C.CDLL(str(library))
    lib.mpv_create.restype = C.c_void_p
    lib.mpv_initialize.argtypes = [C.c_void_p]
    lib.mpv_set_option_string.argtypes = [C.c_void_p, C.c_char_p, C.c_char_p]
    lib.mpv_command.argtypes = [C.c_void_p, C.POINTER(C.c_char_p)]
    lib.mpv_get_property_string.argtypes = [C.c_void_p, C.c_char_p]
    lib.mpv_get_property_string.restype = C.c_void_p
    lib.mpv_free.argtypes = [C.c_void_p]
    lib.mpv_wait_event.argtypes = [C.c_void_p, C.c_double]
    lib.mpv_wait_event.restype = C.POINTER(Event)
    lib.mpv_terminate_destroy.argtypes = [C.c_void_p]
    context = lib.mpv_create()
    assert context
    try:
        options = {"config": "no", "video": "no", "ao": "pcm", "ao-pcm-file": str(target),
                   "ao-pcm-waveheader": "no", "audio-format": "float", "audio-channels": layout,
                   "audio-spdif": "", "volume": "100", "idle": "yes", "msg-level": "all=error"}
        for key, value in options.items():
            assert lib.mpv_set_option_string(context, key.encode(), value.encode()) >= 0
        assert lib.mpv_initialize(context) >= 0
        versions = {}
        for key in ["mpv-version", "ffmpeg-version"]:
            ptr = lib.mpv_get_property_string(context, key.encode())
            assert ptr
            versions[key] = C.string_at(ptr).decode()
            lib.mpv_free(ptr)
        assert "0.41.0" in versions["mpv-version"] and versions["ffmpeg-version"] == "9.0.1", versions
        assert lib.mpv_command(context, (C.c_char_p * 3)(b"loadfile", str(source).encode(), None)) >= 0
        deadline = time.monotonic() + 20
        ended = False
        while time.monotonic() < deadline:
            event = lib.mpv_wait_event(context, 0.05).contents
            if event.event == 7:
                ended = True
                break
        assert ended, "bundled decoder timed out"
    finally:
        lib.mpv_terminate_destroy(context)
    return versions


def generate(args):
    args.output_dir.mkdir(parents=True, exist_ok=False)
    rate = 48000
    # Fixed seeds and label order are source evidence, independent of HRTF output.
    layouts = [("rear51", "5.1", ["FL", "FR", "FC", "LFE", "BL", "BR"], [-30, 30, 0, None, -110, 110]),
               ("side51", "5.1(side)", ["FL", "FR", "FC", "LFE", "SL", "SR"], [-30, 30, 0, None, -90, 90]),
               ("surround71", "7.1", ["FL", "FR", "FC", "LFE", "BL", "BR", "SL", "SR"], [-30, 30, 0, None, -150, 150, -90, 90])]
    report = {"schema": 1, "rights": "Original seeded noise, impulses and 80 Hz tones. No third-party recording or HRTF dataset redistributed.",
              "librarySHA256": hashlib.sha256(args.library.read_bytes()).hexdigest(), "fixtures": []}
    noise = np.random.default_rng(1016).uniform(-0.03, 0.03, 4800).astype("<f4")
    for name, layout, labels, angles in layouts:
        frames = (len(labels) // 2 + 1) * rate
        data = np.zeros((frames, len(labels)), dtype="<f4")
        for channel, label in enumerate(labels):
            start = channel * rate // 2
            data[start + 6000, channel] = 0.1
            data[start + 9600:start + 14400, channel] = noise if label != "LFE" else (
                0.03 * np.sin(2 * np.pi * 80 * np.arange(4800) / rate)).astype("<f4")
        # Last half-second includes simultaneous signals, to test superposition.
        data[-24000:-19200] = noise[:, None]
        raw = args.output_dir / (name + "-original.f32")
        raw.write_bytes(data.tobytes())
        source = args.output_dir / (name + ".wav")
        command = ["ffmpeg", "-v", "error", "-f", "f32le", "-ar", str(rate), "-ac", str(len(labels)),
                   "-channel_layout", layout, "-i", str(raw), "-c:a", "pcm_f32le", str(source)]
        subprocess.run(command, check=True, timeout=20)
        probe = json.loads(subprocess.check_output(["ffprobe", "-v", "error", "-show_streams", "-of", "json", str(source)]))
        assert probe["streams"][0]["channel_layout"] == layout
        target = args.output_dir / (name + "-decoded.f32")
        versions = bundled_decode(args.library, source, target, layout)
        decoded = np.fromfile(target, "<f4").reshape(-1, len(labels))
        assert decoded.shape == data.shape and np.array_equal(data, decoded), "bundled PCM changed source/channel identity"
        report["fixtures"].append({"id": name, "layout": layout, "labels": labels, "azimuthDegrees": angles,
                                   "frames": frames, "sampleRate": rate, "decodedFile": target.name,
                                   "decodedSHA256": hashlib.sha256(target.read_bytes()).hexdigest(),
                                   "sourceSHA256": hashlib.sha256(source.read_bytes()).hexdigest(),
                                   "versions": versions, "generatorCommand": command,
                                   "bundledPCMMaximumError": 0, "ffprobe": probe})
    (args.output_dir / "manifest.json").write_text(json.dumps(report, indent=2) + "\n")
    print("Generated and independently verified three exact multichannel PCM layouts.")


def analyze(args):
    assert not args.output.exists(), "refuse to overwrite evidence"
    manifest = json.loads((args.fixtures / "manifest.json").read_text())
    results = []
    for fixture in manifest["fixtures"]:
        name = fixture["id"]
        def read(suffix):
            return np.fromfile(args.renders / (name + "-" + suffix + ".f32"), "<f4").reshape(-1, 2).astype("f8")
        combined, repeat = read("all"), read("repeat")
        isolated = [read(label) for label in fixture["labels"]]
        assert len(combined) == fixture["frames"] + fixture["sampleRate"]
        peak = float(abs(combined).max())
        tail = float(abs(combined[-24000:]).max())
        repeat_error = float(abs(combined - repeat).max())
        sum_error = float(abs(combined - np.sum(isolated, axis=0)).max())
        directions = []
        for channel, (label, angle) in enumerate(zip(fixture["labels"], fixture["azimuthDegrees"])):
            start = channel * 24000 + 6000
            impulse = isolated[channel][start:start + 2048]
            energy = (impulse * impulse).sum(axis=0)
            assert np.all(energy > 1e-12), (name, label, "empty impulse")
            left_right_db = float(10 * np.log10(energy[0] / energy[1]))
            passed = abs(left_right_db) <= 0.1 if angle in (None, 0) else (left_right_db > 0.5 if angle < 0 else left_right_db < -0.5)
            directions.append({"label": label, "azimuthDegrees": angle, "leftMinusRightEnergyDB": left_right_db,
                               "peakOffsetSamples": abs(impulse).argmax(axis=0).tolist(), "passed": passed})
        passed = (np.isfinite(combined).all() and peak < 1 and tail <= 1e-6 and repeat_error <= 1e-6
                  and sum_error <= 1e-5 and all(x["passed"] for x in directions))
        results.append({"fixture": name, "frames": len(combined), "peak": peak, "tailPeak": tail,
                        "repeatMaxError": repeat_error, "superpositionMaxError": sum_error,
                        "directions": directions, "outputSHA256": hashlib.sha256((args.renders / (name + "-all.f32")).read_bytes()).hexdigest(),
                        "passed": bool(passed)})
    report = {"schema": 1, "scope": "Digital offline HRTF only; no acoustic, live clock, pose or object validation", "results": results}
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
    assert all(x["passed"] for x in results), "fixed digital thresholds failed; preserve this result"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="action", required=True)
    gen = sub.add_parser("generate")
    gen.add_argument("--library", type=Path, required=True)
    gen.add_argument("--output-dir", type=Path, required=True)
    check = sub.add_parser("analyze")
    check.add_argument("--fixtures", type=Path, required=True)
    check.add_argument("--renders", type=Path, required=True)
    check.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    (generate if args.action == "generate" else analyze)(args)


if __name__ == "__main__":
    main()
