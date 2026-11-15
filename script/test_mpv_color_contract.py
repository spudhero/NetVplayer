#!/usr/bin/env python3
"""Verify the ICC render ABI, bounded blobs, errors, and SDR framebuffer facts."""
import ctypes
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from test_mpv_http_headers import FAKE_MPV_SOURCE


SPY = r"""
#undef mpv_render_context_render
static int calls, depth, format, failure;
static size_t blob_size;
static char copied[128];
static int info_calls;
static uint64_t frame_flags = MPV_RENDER_FRAME_INFO_PRESENT;
int mpv_render_context_get_info(mpv_render_context *ctx, mpv_render_param param) {
    (void)ctx;
    if (param.type != MPV_RENDER_PARAM_NEXT_FRAME_INFO || !param.data) return -1;
    info_calls++;
    ((mpv_render_frame_info *)param.data)->flags = frame_flags;
    return failure;
}
int nvp_test_info_calls(void) { return info_calls; }
void nvp_test_frame_flags(int flags) { frame_flags = flags; }
int mpv_render_context_set_parameter(mpv_render_context *ctx, mpv_render_param param) {
    (void)ctx;
    if (param.type != MPV_RENDER_PARAM_ICC_PROFILE || !param.data) return -1;
    mpv_byte_array *blob = param.data;
    calls++; blob_size=blob->size;
    memset(copied, 0, sizeof(copied));
    if (blob->size) memcpy(copied, blob->data, blob->size < 127 ? blob->size : 127);
    return failure;
}
int mpv_render_context_render(mpv_render_context *ctx, mpv_render_param *params) {
    (void)ctx;
    for (; params->type; params++) {
        if (params->type == MPV_RENDER_PARAM_DEPTH) depth=*(int *)params->data;
        if (params->type == MPV_RENDER_PARAM_OPENGL_FBO) format=((mpv_opengl_fbo *)params->data)->internal_format;
    }
    return failure;
}
int nvp_test_calls(void) { return calls; }
size_t nvp_test_size(void) { return blob_size; }
const char *nvp_test_blob(void) { return copied; }
int nvp_test_depth(void) { return depth; }
int nvp_test_format(void) { return format; }
void nvp_test_failure(int code) { failure=code; }
"""

# The fake render context has no GL context. Stub only the unrelated GL error
# poll; the native Swift test exercises the real GL entrypoints and render path.
GL_STUB = r"""
#undef dlopen
#undef dlsym
#include <dlfcn.h>
#include <string.h>
static unsigned int nvp_test_gl_error(void) { return 0; }
void *nvp_test_dlopen(const char *name, int mode) {
    if (name && strstr(name, "OpenGL.framework")) return 0;
    return dlopen(name, mode);
}
void *nvp_test_dlsym(void *handle, const char *name) {
    if (!strcmp(name, "glGetError")) return (void *)nvp_test_gl_error;
    return dlsym(handle, name);
}
"""


class MPVColorContractTests(unittest.TestCase):
    def exercise(self, include_icc):
        root = Path(__file__).resolve().parents[1]
        shim_root = root / "NetVplayer/Sources/MPVShim"
        include = next((p for p in [Path('/opt/homebrew/opt/mpv/include'), Path('/usr/local/opt/mpv/include')] if p.is_dir()), None)
        self.assertIsNotNone(include)
        with tempfile.TemporaryDirectory(prefix='netvplayer-color-abi-') as temporary:
            folder = Path(temporary)
            fake_source = folder/'fake.c'
            source = '#define mpv_render_context_render unused_render\n' + FAKE_MPV_SOURCE + SPY if include_icc else FAKE_MPV_SOURCE
            fake_source.write_text(source)
            fake_path, shim_path = folder/'fake.dylib', folder/'shim.dylib'
            gl_stub = folder/'gl_stub.c'
            gl_stub.write_text(GL_STUB)
            for output, sources, flags in [(fake_path, [fake_source], []), (shim_path, [shim_root/'MPVShim.c', gl_stub], ['-I'+str(shim_root/'include'), '-Ddlopen=nvp_test_dlopen', '-Ddlsym=nvp_test_dlsym'])]:
                if output == shim_path:
                    sources.append(shim_root / 'NVMPVColorProfile.c')
                    flags += ['-framework', 'ColorSync', '-framework', 'CoreFoundation']
                subprocess.run(['cc', '-dynamiclib', '-o', str(output), *map(str, sources), '-I'+str(include), *flags], check=True, capture_output=True)
            previous = os.environ.get('NETVPLAYER_LIBMPV_PATH')
            os.environ['NETVPLAYER_LIBMPV_PATH'] = str(fake_path)
            try:
                shim, fake = ctypes.CDLL(str(shim_path)), ctypes.CDLL(str(fake_path))
                shim.nv_mpv_create.restype = ctypes.c_void_p
                shim.nv_mpv_destroy.argtypes = [ctypes.c_void_p]
                shim.nv_mpv_create_render_context.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p]
                shim.nv_mpv_set_render_icc.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t]
                shim.nv_mpv_render.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_int]
                shim.nv_mpv_render_fp16.argtypes = shim.nv_mpv_render.argtypes
                shim.nv_mpv_render_target_format.argtypes = [ctypes.c_void_p]
                shim.nv_mpv_observe_render_frames.argtypes = [ctypes.c_void_p, ctypes.c_int]
                shim.nv_mpv_last_render_frame_flags.argtypes = [ctypes.c_void_p]
                shim.nv_mpv_last_render_frame_flags.restype = ctypes.c_int64
                shim.nv_mpv_free_render_context.argtypes = [ctypes.c_void_p]
                context = shim.nv_mpv_create()
                self.assertTrue(context)
                try:
                    self.assertLess(shim.nv_mpv_set_render_icc(context, None, 0), 0)
                    self.assertEqual(shim.nv_mpv_create_render_context(context, None, None), 0)
                    if not include_icc:
                        self.assertLess(shim.nv_mpv_set_render_icc(context, None, 0), 0)
                        shim.nv_mpv_observe_render_frames(context, 1)
                        self.assertEqual(shim.nv_mpv_render(context, 0, 640, 360, 1), 0)
                        self.assertEqual(shim.nv_mpv_last_render_frame_flags(context), -1)
                        return
                    fake.nvp_test_size.restype = ctypes.c_size_t
                    fake.nvp_test_blob.restype = ctypes.c_char_p
                    data = ctypes.create_string_buffer(b'bounded-display-profile')
                    self.assertEqual(shim.nv_mpv_set_render_icc(context, data, 23), 0)
                    self.assertEqual(fake.nvp_test_calls(), 1)
                    self.assertEqual(fake.nvp_test_size(), 23)
                    self.assertEqual(fake.nvp_test_blob(), b'bounded-display-profile')
                    self.assertLess(shim.nv_mpv_set_render_icc(context, None, 1), 0)
                    self.assertLess(shim.nv_mpv_set_render_icc(context, data, 4*1024*1024+1), 0)
                    self.assertEqual(fake.nvp_test_calls(), 1)
                    self.assertEqual(shim.nv_mpv_set_render_icc(context, None, 0), 0)
                    self.assertEqual(fake.nvp_test_size(), 0)
                    fake.nvp_test_failure(-3)
                    self.assertEqual(shim.nv_mpv_set_render_icc(context, data, 23), -3)
                    self.assertEqual(shim.nv_mpv_render(context, 0, 640, 360, 1), -3)
                    self.assertEqual(shim.nv_mpv_render_target_format(context), 0)
                    fake.nvp_test_failure(0)
                    self.assertEqual(shim.nv_mpv_render(context, 0, 640, 360, 1), 0)
                    self.assertEqual(fake.nvp_test_depth(), 8)
                    self.assertEqual(fake.nvp_test_format(), 0x8058)
                    self.assertEqual(shim.nv_mpv_render_target_format(context), 0x8058)
                    self.assertEqual(fake.nvp_test_info_calls(), 0)
                    self.assertEqual(shim.nv_mpv_last_render_frame_flags(context), -1)
                    shim.nv_mpv_observe_render_frames(context, 1)
                    self.assertEqual(shim.nv_mpv_render(context, 0, 640, 360, 1), 0)
                    self.assertEqual(shim.nv_mpv_last_render_frame_flags(context), 1)
                    fake.nvp_test_frame_flags(3)
                    self.assertEqual(shim.nv_mpv_render(context, 0, 640, 360, 1), 0)
                    self.assertEqual(shim.nv_mpv_last_render_frame_flags(context), 3)
                    self.assertLess(shim.nv_mpv_render_fp16(context, 0, 640, 360, 0), 0)
                    self.assertEqual(shim.nv_mpv_last_render_frame_flags(context), -1)
                    self.assertEqual(shim.nv_mpv_render_target_format(context), 0x8058)
                    self.assertEqual(shim.nv_mpv_render_fp16(context, 3, 640, 360, 0), 0)
                    self.assertEqual(fake.nvp_test_depth(), 16)
                    self.assertEqual(fake.nvp_test_format(), 0x881A)
                    self.assertEqual(shim.nv_mpv_render_target_format(context), 0x881A)
                    fake.nvp_test_failure(-3)
                    self.assertEqual(shim.nv_mpv_render(context, 0, 640, 360, 1), -3)
                    self.assertEqual(shim.nv_mpv_last_render_frame_flags(context), -1)
                    self.assertEqual(shim.nv_mpv_render_target_format(context), 0x881A)
                    fake.nvp_test_failure(0)
                    self.assertEqual(shim.nv_mpv_render(context, 0, 640, 360, 1), 0)
                    self.assertEqual(shim.nv_mpv_render_target_format(context), 0x8058)
                    self.assertEqual(shim.nv_mpv_free_render_context(context), 0)
                    self.assertEqual(shim.nv_mpv_render_target_format(context), 0)
                    self.assertEqual(shim.nv_mpv_last_render_frame_flags(context), -1)
                    self.assertLess(shim.nv_mpv_set_render_icc(context, data, 23), 0)
                finally:
                    shim.nv_mpv_destroy(context)
            finally:
                if previous is None:
                    os.environ.pop('NETVPLAYER_LIBMPV_PATH', None)
                else:
                    os.environ['NETVPLAYER_LIBMPV_PATH'] = previous

    def test_icc_blob_and_sdr_target_contract(self):
        self.exercise(True)

    def test_old_runtime_without_icc_api_keeps_playing(self):
        self.exercise(False)


if __name__ == '__main__':
    unittest.main()
