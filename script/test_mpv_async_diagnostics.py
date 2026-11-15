#!/usr/bin/env python3
"""Prove diagnostic reads bypass a blocked core and copy bounded native replies."""
import ctypes
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest

from test_mpv_http_headers import FAKE_MPV_SOURCE


FIXTURE = r"""
#undef mpv_get_property
#undef mpv_wait_event
#include <unistd.h>
static int sync_calls;
static uint64_t request_id;
static char request_name[64];
static mpv_format request_format;
static int request_error;
static char oversized[9000];
int mpv_get_property(mpv_handle *h, const char *name, mpv_format format, void *data) {
    (void)h; (void)name; (void)format; (void)data;
    sync_calls++;
    usleep(2000000);
    return MPV_ERROR_PROPERTY_UNAVAILABLE;
}
int mpv_get_property_async(mpv_handle *h, uint64_t id, const char *name, mpv_format format) {
    (void)h; request_id = id; request_format = format;
    snprintf(request_name, sizeof(request_name), "%s", name);
    return request_error;
}
mpv_event *mpv_wait_event(mpv_handle *h, double timeout) {
    (void)h; (void)timeout;
    static mpv_node value;
    static mpv_node values[2];
    static char *keys[] = {"codec", "width"};
    static mpv_node_list list;
    static mpv_event_property property;
    static mpv_event event;
    values[0] = (mpv_node){.format=MPV_FORMAT_STRING, .u.string="av1\n\"test\""};
    values[1] = (mpv_node){.format=MPV_FORMAT_INT64, .u.int64=320};
    list = (mpv_node_list){.num=2, .values=values, .keys=keys};
    value = (mpv_node){.format=MPV_FORMAT_NODE_MAP, .u.list=&list};
    if (!strcmp(request_name, "oversized")) {
        memset(oversized, 'x', sizeof(oversized)-1);
        value = (mpv_node){.format=MPV_FORMAT_STRING, .u.string=oversized};
    }
    property = (mpv_event_property){.name=request_name, .format=MPV_FORMAT_NODE, .data=&value};
    event = (mpv_event){.event_id=MPV_EVENT_GET_PROPERTY_REPLY, .reply_userdata=request_id, .data=&property};
    if (!strcmp(request_name, "missing")) {
        event.error=MPV_ERROR_PROPERTY_UNAVAILABLE;
        property.format=MPV_FORMAT_NONE; property.data=NULL;
    }
    return &event;
}
int nvp_test_sync_calls(void) { return sync_calls; }
int nvp_test_request_format(void) { return request_format; }
void nvp_test_request_error(int error) { request_error=error; }
"""

BRIDGE = r"""
#include "MPVShim.h"
#include <stddef.h>
char *nvp_test_pop(NVMPVContext *context, uint64_t *id, int *error) {
    NVMPVEvent event;
    if (nv_mpv_wait_event(context, 0, &event) < 0) { return NULL; }
    *id=event.reply_userdata; *error=event.error;
    return nv_mpv_copy_event_property_json(&event);
}
"""


class MPVAsyncDiagnosticTests(unittest.TestCase):
    def test_nonblocking_request_reply_identity_missing_values_and_size_limit(self):
        root = Path(__file__).resolve().parents[1]
        shim_root = root / "NetVplayer/Sources/MPVShim"
        include = Path("/opt/homebrew/opt/mpv/include")
        if not include.is_dir():
            include = Path("/usr/local/opt/mpv/include")
        self.assertTrue(include.is_dir())
        with tempfile.TemporaryDirectory(prefix="netvplayer-av01-async-") as temporary:
            directory = Path(temporary)
            fake_source = directory / "fake.c"
            fake_source.write_text(
                "#define mpv_get_property fixture_unused_get\n"
                "#define mpv_wait_event fixture_unused_wait\n" + FAKE_MPV_SOURCE + FIXTURE
            )
            bridge_source = directory / "bridge.c"
            bridge_source.write_text(BRIDGE)
            fake_library = directory / "fake.dylib"
            shim_library = directory / "shim.dylib"
            for output, sources, extra in [
                (fake_library, [fake_source], []),
                (shim_library, [shim_root / "MPVShim.c", shim_root / "NVMPVColorProfile.c", bridge_source],
                 ["-I" + str(shim_root / "include"), "-framework", "ColorSync", "-framework", "CoreFoundation"]),
            ]:
                subprocess.run(
                    ["cc", "-dynamiclib", "-o", str(output), *map(str, sources), "-I" + str(include), *extra],
                    check=True, capture_output=True,
                )
            previous = os.environ.get("NETVPLAYER_LIBMPV_PATH")
            os.environ["NETVPLAYER_LIBMPV_PATH"] = str(fake_library)
            try:
                shim, fake = ctypes.CDLL(str(shim_library)), ctypes.CDLL(str(fake_library))
                shim.nv_mpv_create.restype = ctypes.c_void_p
                shim.nv_mpv_destroy.argtypes = [ctypes.c_void_p]
                shim.nv_mpv_get_property_async.argtypes = [ctypes.c_void_p, ctypes.c_uint64, ctypes.c_char_p]
                shim.nvp_test_pop.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint64), ctypes.POINTER(ctypes.c_int)]
                shim.nvp_test_pop.restype = ctypes.c_void_p
                shim.nv_mpv_free_string.argtypes = [ctypes.c_void_p]
                context = shim.nv_mpv_create()
                self.assertTrue(context)
                try:
                    for index, name in enumerate([b"current-tracks/video", b"missing", b"oversized"]):
                        request_id = 0xA000000000000001 + index
                        started = time.monotonic()
                        self.assertEqual(shim.nv_mpv_get_property_async(context, request_id, name), 0)
                        self.assertLess(time.monotonic() - started, 0.25)
                        self.assertEqual(fake.nvp_test_request_format(), 6)  # MPV_FORMAT_NODE
                        reply_id, error = ctypes.c_uint64(), ctypes.c_int()
                        result = shim.nvp_test_pop(context, ctypes.byref(reply_id), ctypes.byref(error))
                        self.assertEqual(reply_id.value, request_id)
                        if name == b"current-tracks/video":
                            self.assertTrue(result)
                            try:
                                self.assertEqual(json.loads(ctypes.string_at(result)), {"codec": 'av1\n"test"', "width": 320})
                            finally:
                                shim.nv_mpv_free_string(result)
                        else:
                            self.assertFalse(result)
                        if name == b"missing":
                            self.assertLess(error.value, 0)
                    self.assertEqual(fake.nvp_test_sync_calls(), 0)
                    fake.nvp_test_request_error(-1)
                    self.assertEqual(shim.nv_mpv_get_property_async(context, 1, b"hwdec-current"), -1)
                finally:
                    shim.nv_mpv_destroy(context)
            finally:
                if previous is None:
                    os.environ.pop("NETVPLAYER_LIBMPV_PATH", None)
                else:
                    os.environ["NETVPLAYER_LIBMPV_PATH"] = previous


if __name__ == "__main__":
    unittest.main()
