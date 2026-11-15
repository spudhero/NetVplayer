#!/usr/bin/env python3
"""Decode TrueHD into files through the packaged libmpv; never opens an audio device."""
import argparse
import ctypes as C
import hashlib
import json
from pathlib import Path
import time


class Node(C.Structure):
    pass


class NodeList(C.Structure):
    _fields_ = [("num", C.c_int), ("values", C.POINTER(Node)), ("keys", C.POINTER(C.c_char_p))]


class Value(C.Union):
    _fields_ = [("string", C.c_char_p), ("flag", C.c_int), ("integer", C.c_int64),
                ("number", C.c_double), ("list", C.POINTER(NodeList)), ("ptr", C.c_void_p)]


Node._fields_ = [("u", Value), ("format", C.c_int)]


def decode(node):
    if node.format == 1: return node.u.string.decode()
    if node.format == 3: return bool(node.u.flag)
    if node.format == 4: return node.u.integer
    if node.format == 5: return node.u.number
    if node.format in (7, 8):
        items = node.u.list.contents
        values = [decode(items.values[i]) for i in range(items.num)]
        return values if node.format == 7 else {items.keys[i].decode(): values[i] for i in range(items.num)}
    return None


def verify(runtime, sample, destination, modes):
    lib = C.CDLL(str(runtime / "Contents/Frameworks/libmpv.2.dylib"))
    lib.mpv_create.restype = C.c_void_p
    lib.mpv_set_option_string.argtypes = [C.c_void_p, C.c_char_p, C.c_char_p]
    lib.mpv_initialize.argtypes = [C.c_void_p]
    lib.mpv_command.argtypes = [C.c_void_p, C.POINTER(C.c_char_p)]
    lib.mpv_get_property.argtypes = [C.c_void_p, C.c_char_p, C.c_int, C.c_void_p]
    lib.mpv_set_property_string.argtypes = [C.c_void_p, C.c_char_p, C.c_char_p]
    lib.mpv_free_node_contents.argtypes = [C.POINTER(Node)]
    lib.mpv_terminate_destroy.argtypes = [C.c_void_p]
    lib.mpv_netvplayer_runtime_capabilities.restype = C.c_uint64
    assert lib.mpv_netvplayer_runtime_capabilities() & 512

    def get(handle, name):
        node = Node()
        if lib.mpv_get_property(handle, name.encode(), 6, C.byref(node)) < 0: return None
        try: return decode(node)
        finally: lib.mpv_free_node_contents(C.byref(node))

    results = []
    for mode in modes:
        handle = lib.mpv_create()
        assert handle
        try:
            file = destination / (mode + ".wav")
            options = {"config": "no", "load-scripts": "no", "vo": "null", "vid": "no", "ao": "pcm",
                "ao-pcm-file": str(file), "audio-format": "float", "audio-spdif": "", "keep-open": "always",
                "untimed": "yes", "ad-queue-enable": "no", "netvplayer-truehd-objects": mode,
                "audio-channels": "fl-fr-fc-lfe-bl-br-sl-sr-tfl-tfr-tbl-tbr" if mode == "7.1.4" else "stereo"}
            if sample.suffix.lower() in (".thd", ".mlp"):
                options.update({"demuxer": "lavf", "demuxer-lavf-format": "truehd"})
            for name, value in options.items():
                assert lib.mpv_set_option_string(handle, name.encode(), value.encode()) >= 0, name
            assert lib.mpv_initialize(handle) >= 0
            args = (C.c_char_p * 3)(b"loadfile", str(sample).encode(), None)
            assert lib.mpv_command(handle, args) >= 0
            deadline = time.monotonic() + 120
            start = time.monotonic()
            status = None
            while time.monotonic() < deadline:
                status = get(handle, "netvplayer-object-audio") or status
                if get(handle, "eof-reached") and status: break
                time.sleep(.01)
            else: raise RuntimeError("Object decode stalled: " + mode)
            assert status["frames"] > 0 and status["has-objects"] and status["object-blocks"] > 0, status
            assert status["metadata-updates"] > 0 and status["metadata-errors"] == 0, status
            assert status["decode-errors"] == 0 and status["sync-errors"] == 0 and status["fallback-blocks"] == 0, status
            if mode != "7.1.4":
                assert status["binaural-frames"] == status["frames"]
                # No connected headset is inferred from selecting a mode.
                assert not status["tracking-active"] and status["poses"] == 0
            output = get(handle, "audio-out-params")
            assert output["channel-count"] == (12 if mode == "7.1.4" else 2), output
            results.append({"mode": mode, "status": status, "output": output,
                            "seconds": time.monotonic() - start, "file": file.name, "physicalOutput": False})
        finally:
            lib.mpv_terminate_destroy(handle)
    lifecycle = None
    if results and results[0]["status"]["frames"] / results[0]["status"]["samplerate"] > 5:
        handle = lib.mpv_create()
        try:
            options.update({"ao": "null", "pause": "yes", "netvplayer-truehd-objects": "7.1.4",
                            "audio-channels": "fl-fr-fc-lfe-bl-br-sl-sr-tfl-tfr-tbl-tbr"})
            options.pop("ao-pcm-file", None)
            for name, value in options.items():
                assert lib.mpv_set_option_string(handle, name.encode(), value.encode()) >= 0, name
            assert lib.mpv_initialize(handle) >= 0
            args = (C.c_char_p * 3)(b"loadfile", str(sample).encode(), None)
            assert lib.mpv_command(handle, args) >= 0

            def wait(predicate):
                deadline = time.monotonic() + 15
                while time.monotonic() < deadline:
                    if predicate(): return
                    time.sleep(.01)
                raise RuntimeError("Seek/mode transition did not settle")

            def set_value(key, value):
                assert lib.mpv_set_property_string(handle, key.encode(), value.encode()) >= 0

            wait(lambda: (get(handle, "netvplayer-object-audio") or {}).get("object-blocks", 0) > 0)
            identity = get(handle, "path"), get(handle, "aid")
            set_value("volume", "37"); set_value("mute", "yes")
            args = (C.c_char_p * 4)(b"seek", b"3", b"absolute+exact", None)
            assert lib.mpv_command(handle, args) >= 0
            wait(lambda: get(handle, "seeking") is False and abs((get(handle, "time-pos") or 0)-3) < .05
                 and (get(handle, "netvplayer-object-audio") or {}).get("object-blocks", 0) > 0)
            after_seek = get(handle, "netvplayer-object-audio")
            assert after_seek["frames"] < results[0]["status"]["frames"], after_seek
            set_value("audio-channels", "stereo")
            set_value("netvplayer-truehd-objects", "binaural")
            wait(lambda: (get(handle, "netvplayer-object-audio") or {}).get("mode") == 2
                 and (get(handle, "netvplayer-object-audio") or {}).get("binaural-frames", 0) > 0)
            set_value("netvplayer-truehd-objects", "off")
            wait(lambda: get(handle, "netvplayer-object-audio") is None)
            set_value("audio-channels", "fl-fr-fc-lfe-bl-br-sl-sr-tfl-tfr-tbl-tbr")
            set_value("netvplayer-truehd-objects", "7.1.4")
            wait(lambda: (get(handle, "netvplayer-object-audio") or {}).get("object-blocks", 0) > 0)
            assert (get(handle, "path"), get(handle, "aid")) == identity
            assert get(handle, "pause") is True and get(handle, "mute") is True and get(handle, "volume") == 37
            lifecycle = {"seekSeconds": 3, "afterSeek": after_seek, "sameMediaAndTrack": True,
                         "pauseVolumeMutePreserved": True, "modeTransitions": ["7.1.4", "binaural", "off", "7.1.4"],
                         "physicalOutput": False}
        finally:
            lib.mpv_terminate_destroy(handle)
    return {"sampleSHA256": hashlib.sha256(sample.read_bytes()).hexdigest(), "results": results, "lifecycle": lifecycle}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime", type=Path, required=True)
    parser.add_argument("--sample", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--modes", nargs="+", choices=["7.1.4", "binaural", "tracked"], default=["7.1.4", "binaural", "tracked"])
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    result = verify(args.runtime.resolve(), args.sample.resolve(), args.output.resolve(), args.modes)
    (args.output / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))
