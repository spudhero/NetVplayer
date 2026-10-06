#!/usr/bin/env python3
"""Verify audio changes can be queued while the synchronous mpv core is busy."""

import ctypes
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest

from test_mpv_http_headers import FAKE_MPV_SOURCE


AUDIO_FIXTURE = r"""
#undef mpv_set_property
#undef mpv_set_property_async
#include <unistd.h>
static int synchronous_calls;
static int async_result;
static uint64_t last_reply;
static mpv_format last_format;
static char last_name[64];
static double last_value;

int mpv_set_property(mpv_handle *handle, const char *name, mpv_format format, void *data) {
    (void)handle; (void)name; (void)format; (void)data;
    synchronous_calls++;
    usleep(2000000);  // The core is waiting for an outstanding render callback.
    return 0;
}
int mpv_set_property_async(mpv_handle *handle, uint64_t id, const char *name, mpv_format format, void *data) {
    (void)handle;
    last_reply = id;
    last_format = format;
    snprintf(last_name, sizeof(last_name), "%s", name);
    last_value = format == MPV_FORMAT_FLAG ? *(int *)data : *(double *)data;
    return async_result;
}
int nvp_test_synchronous_calls(void) { return synchronous_calls; }
uint64_t nvp_test_reply(void) { return last_reply; }
int nvp_test_format(void) { return last_format; }
const char *nvp_test_name(void) { return last_name; }
double nvp_test_value(void) { return last_value; }
void nvp_test_async_result(int result) { async_result = result; }
"""


class MPVAsyncPropertyTests(unittest.TestCase):
    def test_audio_changes_do_not_wait_for_core_and_preserve_values_and_errors(self):
        root = Path(__file__).resolve().parents[1]
        shim_root = root / "NetVplayer/Sources/MPVShim"
        include = Path("/opt/homebrew/opt/mpv/include")
        if not include.is_dir():
            include = Path("/usr/local/opt/mpv/include")
        self.assertTrue(include.is_dir(), "libmpv headers are required")
        with tempfile.TemporaryDirectory(prefix="netvplayer-mpv-audio-") as temporary:
            directory = Path(temporary)
            fake_source = directory / "fake_mpv.c"
            fake_library = directory / "fake_mpv.dylib"
            shim_library = directory / "shim.dylib"
            fake_source.write_text(
                "#define mpv_set_property fixture_unused_sync\n"
                "#define mpv_set_property_async fixture_unused_async\n"
                + FAKE_MPV_SOURCE + AUDIO_FIXTURE
            )
            for output, source, extra in [
                (fake_library, fake_source, []),
                (shim_library, shim_root / "MPVShim.c", ["-I" + str(shim_root / "include")]),
            ]:
                subprocess.run(
                    ["cc", "-dynamiclib", "-o", str(output), str(source), "-I" + str(include), *extra],
                    check=True, capture_output=True,
                )
            previous = os.environ.get("NETVPLAYER_LIBMPV_PATH")
            os.environ["NETVPLAYER_LIBMPV_PATH"] = str(fake_library)
            try:
                shim = ctypes.CDLL(str(shim_library))
                fake = ctypes.CDLL(str(fake_library))
                shim.nv_mpv_create.restype = ctypes.c_void_p
                shim.nv_mpv_destroy.argtypes = [ctypes.c_void_p]
                shim.nv_mpv_set_property_flag_async.argtypes = [ctypes.c_void_p, ctypes.c_uint64, ctypes.c_char_p, ctypes.c_int]
                shim.nv_mpv_set_property_double_async.argtypes = [ctypes.c_void_p, ctypes.c_uint64, ctypes.c_char_p, ctypes.c_double]
                shim.nv_mpv_last_error.argtypes = [ctypes.c_void_p]
                shim.nv_mpv_last_error.restype = ctypes.c_char_p
                fake.nvp_test_reply.restype = ctypes.c_uint64
                fake.nvp_test_name.restype = ctypes.c_char_p
                fake.nvp_test_value.restype = ctypes.c_double
                context = shim.nv_mpv_create()
                self.assertTrue(context)
                try:
                    for setter, reply, name, value, format_id in [
                        (shim.nv_mpv_set_property_flag_async, 10002, b"mute", 1, 3),
                        (shim.nv_mpv_set_property_double_async, 10003, b"volume", 37.0, 5),
                        (shim.nv_mpv_set_property_flag_async, 10002, b"mute", 0, 3),
                        (shim.nv_mpv_set_property_double_async, 10003, b"volume", 0.0, 5),
                    ]:
                        started = time.monotonic()
                        self.assertEqual(setter(context, reply, name, value), 0)
                        self.assertLess(time.monotonic() - started, 0.25)
                        self.assertEqual(fake.nvp_test_reply(), reply)
                        self.assertEqual(fake.nvp_test_name(), name)
                        self.assertEqual(fake.nvp_test_value(), value)
                        self.assertEqual(fake.nvp_test_format(), format_id)
                    self.assertEqual(fake.nvp_test_synchronous_calls(), 0)
                    fake.nvp_test_async_result(-1)
                    self.assertEqual(shim.nv_mpv_set_property_flag_async(context, 10002, b"mute", 1), -1)
                    self.assertIn(b"(-1)", shim.nv_mpv_last_error(context))
                finally:
                    shim.nv_mpv_destroy(context)
            finally:
                if previous is None:
                    os.environ.pop("NETVPLAYER_LIBMPV_PATH", None)
                else:
                    os.environ["NETVPLAYER_LIBMPV_PATH"] = previous


if __name__ == "__main__":
    unittest.main()
