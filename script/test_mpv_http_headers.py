#!/usr/bin/env python3
"""Verify the MPV shim's HTTP-header list commands with a deterministic fake libmpv."""

import ctypes
import os
from pathlib import Path
import subprocess
import tempfile
import textwrap
import unittest


FAKE_MPV_SOURCE = r"""
#include <mpv/client.h>
#include <mpv/render.h>
#include <mpv/render_gl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static char command_args[8][256];
static int command_arg_count = 0;
static int set_property_string_count = 0;
static mpv_event empty_event = { .event_id = MPV_EVENT_NONE };

static void capture_command(const char **args) {
    command_arg_count = 0;
    memset(command_args, 0, sizeof(command_args));
    while (args && args[command_arg_count] && command_arg_count < 8) {
        snprintf(command_args[command_arg_count], sizeof(command_args[0]), "%s", args[command_arg_count]);
        command_arg_count += 1;
    }
}

int nvp_test_arg_count(void) { return command_arg_count; }
const char *nvp_test_arg(int index) {
    return index >= 0 && index < command_arg_count ? command_args[index] : NULL;
}
int nvp_test_set_property_string_count(void) { return set_property_string_count; }

mpv_handle *mpv_create(void) { return (mpv_handle *)(uintptr_t)1; }
int mpv_initialize(mpv_handle *handle) { return handle ? 0 : -1; }
void mpv_terminate_destroy(mpv_handle *handle) { (void)handle; }
int mpv_set_option(mpv_handle *handle, const char *name, mpv_format format, void *data) {
    (void)handle; (void)name; (void)format; (void)data; return 0;
}
int mpv_set_option_string(mpv_handle *handle, const char *name, const char *value) {
    (void)handle; (void)name; (void)value; return 0;
}
int mpv_set_property(mpv_handle *handle, const char *name, mpv_format format, void *data) {
    (void)handle; (void)name; (void)format; (void)data; return 0;
}
int mpv_set_property_async(mpv_handle *handle, uint64_t id, const char *name, mpv_format format, void *data) {
    (void)id; return mpv_set_property(handle, name, format, data);
}
int mpv_set_property_string(mpv_handle *handle, const char *name, const char *value) {
    (void)handle; (void)name; (void)value; set_property_string_count += 1; return 0;
}
int mpv_get_property(mpv_handle *handle, const char *name, mpv_format format, void *data) {
    (void)handle; (void)name; (void)format; (void)data; return MPV_ERROR_PROPERTY_UNAVAILABLE;
}
void mpv_free_node_contents(mpv_node *node) { (void)node; }
void mpv_free(void *data) { free(data); }
int mpv_command(mpv_handle *handle, const char **args) {
    (void)handle; capture_command(args); return 0;
}
int mpv_command_async(mpv_handle *handle, uint64_t id, const char **args) {
    (void)id; return mpv_command(handle, args);
}
int mpv_observe_property(mpv_handle *handle, uint64_t id, const char *name, mpv_format format) {
    (void)handle; (void)id; (void)name; (void)format; return 0;
}
mpv_event *mpv_wait_event(mpv_handle *handle, double timeout) {
    (void)handle; (void)timeout; return &empty_event;
}
int mpv_request_log_messages(mpv_handle *handle, const char *level) {
    (void)handle; (void)level; return 0;
}
const char *mpv_event_name(mpv_event_id event) { (void)event; return "none"; }
const char *mpv_error_string(int error) { (void)error; return "fixture"; }
int mpv_render_context_create(mpv_render_context **context, mpv_handle *handle, mpv_render_param *params) {
    (void)handle; (void)params; *context = (mpv_render_context *)(uintptr_t)2; return 0;
}
void mpv_render_context_free(mpv_render_context *context) { (void)context; }
void mpv_render_context_set_update_callback(mpv_render_context *context, mpv_render_update_fn callback, void *callback_context) {
    (void)context; (void)callback; (void)callback_context;
}
int mpv_render_context_render(mpv_render_context *context, mpv_render_param *params) {
    (void)context; (void)params; return 0;
}
uint64_t mpv_render_context_update(mpv_render_context *context) { (void)context; return 0; }
void mpv_render_context_report_swap(mpv_render_context *context) { (void)context; }
"""


class MPVHTTPHeaderTests(unittest.TestCase):
    def test_clear_uses_change_list_instead_of_an_empty_property_item(self):
        root = Path(__file__).resolve().parents[1]
        shim_root = root / "NetVplayer/Sources/MPVShim"
        mpv_include = Path("/opt/homebrew/opt/mpv/include")
        if not mpv_include.is_dir():
            mpv_include = Path("/usr/local/opt/mpv/include")
        self.assertTrue(mpv_include.is_dir(), "libmpv headers are required")

        with tempfile.TemporaryDirectory(prefix="netvplayer-mpv-headers-") as temporary:
            directory = Path(temporary)
            fake_source = directory / "fake_mpv.c"
            fake_library = directory / "fake_mpv.dylib"
            shim_library = directory / "shim.dylib"
            fake_source.write_text(textwrap.dedent(FAKE_MPV_SOURCE))
            include_flags = ["-I" + str(mpv_include)]
            subprocess.run(
                ["cc", "-dynamiclib", "-o", str(fake_library), str(fake_source), *include_flags],
                check=True,
                capture_output=True,
            )
            subprocess.run(
                [
                    "cc", "-dynamiclib", "-o", str(shim_library), str(shim_root / "MPVShim.c"),
                    "-I" + str(shim_root / "include"), *include_flags,
                ],
                check=True,
                capture_output=True,
            )

            previous_path = os.environ.get("NETVPLAYER_LIBMPV_PATH")
            os.environ["NETVPLAYER_LIBMPV_PATH"] = str(fake_library)
            try:
                shim = ctypes.CDLL(str(shim_library))
                fake = ctypes.CDLL(str(fake_library))
                shim.nv_mpv_create.restype = ctypes.c_void_p
                shim.nv_mpv_destroy.argtypes = [ctypes.c_void_p]
                shim.nv_mpv_clear_http_headers.argtypes = [ctypes.c_void_p]
                shim.nv_mpv_append_http_header.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
                fake.nvp_test_arg_count.restype = ctypes.c_int
                fake.nvp_test_arg.argtypes = [ctypes.c_int]
                fake.nvp_test_arg.restype = ctypes.c_char_p
                fake.nvp_test_set_property_string_count.restype = ctypes.c_int

                context = shim.nv_mpv_create()
                self.assertTrue(context)
                try:
                    self.assertGreaterEqual(shim.nv_mpv_clear_http_headers(context), 0)
                    self.assertEqual(
                        [fake.nvp_test_arg(index) for index in range(fake.nvp_test_arg_count())],
                        [b"change-list", b"http-header-fields", b"clr", b""],
                    )
                    self.assertEqual(fake.nvp_test_set_property_string_count(), 0)

                    self.assertGreaterEqual(
                        shim.nv_mpv_append_http_header(context, b"User-Agent: NetVplayer-header-fixture"),
                        0,
                    )
                    self.assertEqual(
                        [fake.nvp_test_arg(index) for index in range(fake.nvp_test_arg_count())],
                        [
                            b"change-list", b"http-header-fields", b"append",
                            b"User-Agent: NetVplayer-header-fixture",
                        ],
                    )
                finally:
                    shim.nv_mpv_destroy(context)
            finally:
                if previous_path is None:
                    os.environ.pop("NETVPLAYER_LIBMPV_PATH", None)
                else:
                    os.environ["NETVPLAYER_LIBMPV_PATH"] = previous_path


if __name__ == "__main__":
    unittest.main()
