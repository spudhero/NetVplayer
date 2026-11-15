#!/usr/bin/env python3
"""Isolated, muted AVFoundation AO feasibility probe; does not verify spatial effects."""
import argparse
import ctypes as C
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import time


def child(args):
    lib = C.CDLL(str(args.library))
    lib.mpv_create.restype = C.c_void_p
    lib.mpv_initialize.argtypes = [C.c_void_p]
    lib.mpv_set_option_string.argtypes = [C.c_void_p, C.c_char_p, C.c_char_p]
    lib.mpv_set_property_string.argtypes = [C.c_void_p, C.c_char_p, C.c_char_p]
    lib.mpv_get_property_string.argtypes = [C.c_void_p, C.c_char_p]
    lib.mpv_get_property_string.restype = C.c_void_p
    lib.mpv_command.argtypes = [C.c_void_p, C.POINTER(C.c_char_p)]
    lib.mpv_free.argtypes = [C.c_void_p]
    lib.mpv_terminate_destroy.argtypes = [C.c_void_p]
    context = lib.mpv_create()
    assert context
    observations = []
    def prop(name):
        ptr = lib.mpv_get_property_string(context, name.encode())
        if not ptr:
            return None
        value = C.string_at(ptr).decode()
        lib.mpv_free(ptr)
        return value
    def record(stage):
        result = {key: prop(key) for key in ["mpv-version", "ffmpeg-version", "current-ao", "audio-params/channels",
                  "audio-out-params/channels", "audio-out-params/format", "audio-out-params/samplerate",
                  "time-pos", "duration", "eof-reached", "idle-active", "pause", "speed", "mute"]}
        observations.append({"stage": stage, "facts": result})
        print(json.dumps(observations[-1]), flush=True)
        return result
    def setprop(key, value):
        assert lib.mpv_set_property_string(context, key.encode(), str(value).encode()) >= 0
    def command(*parts):
        assert lib.mpv_command(context, (C.c_char_p * (len(parts) + 1))(*[p.encode() for p in parts], None)) >= 0
    def wait(predicate):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if predicate():
                return
            time.sleep(0.03)
        record("timeout")
        raise AssertionError("bounded observation timed out")
    try:
        for key, value in {"config": "no", "video": "no", "vo": "null", "ao": "avfoundation",
                           "audio-channels": "7.1,5.1,stereo", "audio-format": "float", "audio-spdif": "",
                           "audio-exclusive": "no", "audio-fallback-to-null": "no", "idle": "yes",
                           "mute": "yes", "volume": "0", "msg-level": "all=warn"}.items():
            assert lib.mpv_set_option_string(context, key.encode(), value.encode()) >= 0
        assert lib.mpv_initialize(context) >= 0
        command("loadfile", str(args.media))
        wait(lambda: prop("current-ao") == "avfoundation" and float(prop("time-pos") or 0) > 0.2)
        running = record("advancing")
        assert "0.41.0" in running["mpv-version"] and running["ffmpeg-version"] == "9.0.1"
        setprop("pause", "yes")
        command("seek", "1", "absolute+exact")
        wait(lambda: abs(float(prop("time-pos") or 0) - 1) < 0.1)
        paused = record("paused-seek")
        assert paused["pause"] == "yes"
        setprop("speed", "1.5"); setprop("pause", "no")
        wait(lambda: float(prop("time-pos") or 0) > 1.5)
        record("resumed-1.5x")
        command("stop")
        wait(lambda: prop("time-pos") is None)
        record("stopped")
    finally:
        lib.mpv_terminate_destroy(context)
    print(json.dumps({"destroyed": True}), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--library", required=True, type=Path)
    parser.add_argument("--media", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--child", action="store_true")
    args = parser.parse_args()
    if args.child:
        child(args)
        return
    args.output_dir.mkdir(parents=True, exist_ok=False)
    command = [sys.executable, __file__, "--child", "--library", str(args.library), "--media", str(args.media),
               "--output-dir", str(args.output_dir)]
    start = time.monotonic()
    with (args.output_dir / "stdout.jsonl").open("w") as stdout, (args.output_dir / "stderr.log").open("w") as stderr:
        try:
            result = subprocess.run(command, stdout=stdout, stderr=stderr, timeout=25)
            outcome = {"exitCode": result.returncode, "timeout": False}
        except subprocess.TimeoutExpired:
            outcome = {"exitCode": None, "timeout": True}
    outcome.update({"schema": 1, "elapsedSeconds": time.monotonic() - start,
                    "librarySHA256": hashlib.sha256(args.library.read_bytes()).hexdigest(),
                    "sourceSHA256": hashlib.sha256(args.media.read_bytes()).hexdigest(),
                    "route": "Isolated muted CLI; not a packaged-app spatial test",
                    "physicalOutputChannelsVerified": False, "spatialAudioVerified": False,
                    "headTrackingVerified": False, "atmosObjectsVerified": False})
    (args.output_dir / "result.json").write_text(json.dumps(outcome, indent=2) + "\n")
    print(json.dumps(outcome, indent=2))


if __name__ == "__main__":
    main()
