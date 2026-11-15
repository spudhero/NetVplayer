#!/usr/bin/env python3
"""Capture bundled mpv IEC 61937 bytes to files only; never opens CoreAudio."""
import argparse
import ctypes as C
import hashlib
import json
from pathlib import Path
import struct
import subprocess
import time


class Event(C.Structure):
    _fields_ = [("event", C.c_int), ("error", C.c_int), ("userdata", C.c_uint64), ("data", C.c_void_p)]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--library", required=True, type=Path)
    parser.add_argument("--fixtures", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    args = parser.parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=False)
    lib = C.CDLL(str(args.library))
    lib.mpv_create.restype = C.c_void_p
    lib.mpv_initialize.argtypes = [C.c_void_p]
    lib.mpv_set_option_string.argtypes = [C.c_void_p, C.c_char_p, C.c_char_p]
    lib.mpv_set_property_string.argtypes = [C.c_void_p, C.c_char_p, C.c_char_p]
    lib.mpv_command.argtypes = [C.c_void_p, C.POINTER(C.c_char_p)]
    lib.mpv_get_property_string.argtypes = [C.c_void_p, C.c_char_p]
    lib.mpv_get_property_string.restype = C.c_void_p
    lib.mpv_free.argtypes = [C.c_void_p]
    lib.mpv_wait_event.argtypes = [C.c_void_p, C.c_double]
    lib.mpv_wait_event.restype = C.POINTER(Event)
    lib.mpv_terminate_destroy.argtypes = [C.c_void_p]

    def property(context, name):
        ptr = lib.mpv_get_property_string(context, name.encode())
        if not ptr:
            return None
        value = C.string_at(ptr).decode()
        lib.mpv_free(ptr)
        return value

    report = {"schema": 1, "route": "Bundled mpv AO pcm raw file sink; no physical audio device is opened",
              "receiverVerified": False, "atmosObjectsVerified": False,
              "librarySHA256": hashlib.sha256(args.library.read_bytes()).hexdigest(), "cases": []}
    for codec, data_type, stride in [("ac3", 1, 6144), ("eac3", 21, 24576), ("truehd", 22, 61440)]:
        source = args.fixtures / f"av09-{codec}.mkv"
        target = args.output_dir / f"{codec}.iec61937"
        context = lib.mpv_create()
        assert context
        facts = {}
        options = {"config": "no", "vo": "null", "video": "no", "ao": "pcm", "ao-pcm-file": str(target),
                   "ao-pcm-waveheader": "no", "audio-spdif": codec, "audio-fallback-to-null": "no",
                   "end": "3", "idle": "yes", "pause": "yes", "msg-level": "all=error"}
        try:
            for key, value in options.items():
                assert lib.mpv_set_option_string(context, key.encode(), value.encode()) >= 0, key
            assert lib.mpv_initialize(context) >= 0
            versions = {key: property(context, key) for key in ["mpv-version", "ffmpeg-version"]}
            assert "0.41.0" in versions["mpv-version"] and versions["ffmpeg-version"] == "9.0.1", versions
            command = (C.c_char_p * 3)(b"loadfile", str(source).encode(), None)
            assert lib.mpv_command(context, command) >= 0
            ended = False
            deadline = time.monotonic() + 20
            while time.monotonic() < deadline:
                event = lib.mpv_wait_event(context, 0.05).contents
                if event.event == 7:
                    ended = True
                    break
                if not facts:
                    candidate = {key: property(context, key) for key in ["current-ao", "audio-out-params/format",
                                 "audio-out-params/samplerate", "audio-out-params/channel-count"]}
                    if all(value is not None for value in candidate.values()):
                        facts = candidate
                        assert lib.mpv_set_property_string(context, b"pause", b"no") >= 0
            assert ended, "file capture timed out"
            assert facts.get("current-ao") == "pcm", facts
            assert facts.get("audio-out-params/format") == "spdif-" + codec, facts
        finally:
            lib.mpv_terminate_destroy(context)
        data = target.read_bytes()
        assert len(data) >= stride and len(data) % stride == 0
        bursts = 0
        for offset in range(0, len(data) - stride + 1, stride):
            sync1, sync2, kind, length = struct.unpack_from("<HHHH", data, offset)
            assert (sync1, sync2, kind & 31) == (0xF872, 0x4E1F, data_type), (codec, offset)
            count = length // 8 if codec == "ac3" else length
            payload = data[offset + 8:offset + 8 + count]
            payload = b"".join(payload[i:i + 2][::-1] for i in range(0, len(payload), 2))
            if codec == "truehd":
                assert len(payload) == 61424
                assert payload[:20] == bytes.fromhex("079e000384010101800056a53bf48183498077e0")
                assert payload[30708:30720] == bytes.fromhex("c3c142493bfa8283498077e0")
                assert payload[-16:] == bytes.fromhex("c3c2c0c4000000000000000000009711")
            else:
                assert payload[:2] == bytes.fromhex("0b77")
            bursts += 1
        if codec != "truehd":
            original = subprocess.check_output(["ffmpeg", "-v", "error", "-i", str(source), "-map", "0:a:0",
                                                 "-c:a", "copy", "-f", codec, "-"])
            first_length = struct.unpack_from("<H", data, 6)[0]
            first_length = first_length // 8 if codec == "ac3" else first_length
            raw = data[8:8 + first_length]
            restored = b"".join(raw[i:i + 2][::-1] for i in range(0, len(raw), 2))
            assert original.startswith(restored), codec
        report["cases"].append({"codec": codec, "versions": versions, "engine": facts, "bytes": len(data),
                                 "sha256": hashlib.sha256(data).hexdigest(), "burstType": data_type,
                                 "burstStride": stride, "completeBurstsChecked": bursts,
                                 "firstCompressedPayloadMatchesSource": True if codec != "truehd" else None,
                                 "truehdMATFrameMarkersChecked": codec == "truehd", "passed": True})
        (args.output_dir / "results.json").write_text(json.dumps(report, indent=2) + "\n")
    print(f"Captured and inspected {len(report['cases'])} file-only IEC 61937 streams; no HDMI/Atmos validation.")


if __name__ == "__main__":
    main()
