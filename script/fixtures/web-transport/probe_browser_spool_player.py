#!/usr/bin/env python3
"""Decode a finite browser-owned local spool with the installed app's libmpv."""
import argparse
import ctypes as c
import json
import re
import time
from urllib.parse import urlsplit


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--library', required=True)
    p.add_argument('--url', required=True)
    a = p.parse_args()
    u = urlsplit(a.url)
    assert u.scheme == 'http' and u.hostname == '127.0.0.1' and u.port
    assert re.fullmatch(r'/spool/[a-f0-9]{64}', u.path) and not u.query
    lib = c.CDLL(a.library)
    lib.mpv_create.restype = c.c_void_p
    lib.mpv_set_option_string.argtypes = [c.c_void_p, c.c_char_p, c.c_char_p]
    lib.mpv_initialize.argtypes = [c.c_void_p]
    lib.mpv_command.argtypes = [c.c_void_p, c.POINTER(c.c_char_p)]
    lib.mpv_get_property_string.argtypes = [c.c_void_p, c.c_char_p]
    lib.mpv_get_property_string.restype = c.c_void_p
    lib.mpv_free.argtypes = [c.c_void_p]
    lib.mpv_terminate_destroy.argtypes = [c.c_void_p]
    handle = lib.mpv_create()
    assert handle

    def prop(name):
        pointer = lib.mpv_get_property_string(handle, name.encode())
        if not pointer:
            return None
        try:
            return c.string_at(pointer).decode()
        finally:
            lib.mpv_free(pointer)

    try:
        for k, v in {'config': 'no', 'vo': 'null', 'ao': 'null', 'hwdec': 'no',
                     'keep-open': 'yes', 'terminal': 'no', 'ytdl': 'no'}.items():
            assert lib.mpv_set_option_string(handle, k.encode(), v.encode()) >= 0, k
        assert lib.mpv_initialize(handle) >= 0
        assert lib.mpv_command(handle, (c.c_char_p * 3)(b'loadfile', a.url.encode(), None)) >= 0
        deadline = time.monotonic() + 12
        result = {}
        while time.monotonic() < deadline:
            result = {n: prop(n) for n in ['video-format', 'audio-codec-name', 'video-params/w',
                                          'video-params/h', 'time-pos', 'duration', 'eof-reached']}
            if result['video-format'] == 'h264' and result['audio-codec-name'] == 'aac' and float(result['time-pos'] or 0) >= 0.5:
                print(json.dumps({'decoded': True, 'properties': result}))
                return
            time.sleep(0.02)
        raise AssertionError(result)
    finally:
        lib.mpv_terminate_destroy(handle)


if __name__ == '__main__':
    main()
