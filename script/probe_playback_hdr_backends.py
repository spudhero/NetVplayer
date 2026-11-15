#!/usr/bin/env python3
"""Inspect the specified *bundled* mpv, never infer render APIs from CLI vo names."""
import argparse
import ctypes as C
import hashlib
import json
from pathlib import Path


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--library',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args()
    # Standalone Python needs DYLD_LIBRARY_PATH set to this bundle Frameworks.
    lib=C.CDLL(str(args.library))
    lib.mpv_create.restype=C.c_void_p
    lib.mpv_set_option_string.argtypes=[C.c_void_p,C.c_char_p,C.c_char_p]
    lib.mpv_initialize.argtypes=[C.c_void_p]
    lib.mpv_terminate_destroy.argtypes=[C.c_void_p]
    lib.mpv_get_property_string.argtypes=[C.c_void_p,C.c_char_p]
    lib.mpv_get_property_string.restype=C.c_void_p
    lib.mpv_free.argtypes=[C.c_void_p]
    lib.mpv_error_string.argtypes=[C.c_int];lib.mpv_error_string.restype=C.c_char_p
    class Param(C.Structure):_fields_=[('kind',C.c_int),('value',C.c_void_p)]
    lib.mpv_render_context_create.argtypes=[C.POINTER(C.c_void_p),C.c_void_p,C.POINTER(Param)]
    lib.mpv_render_context_free.argtypes=[C.c_void_p]
    handle=lib.mpv_create()
    assert handle
    report={'libraryName':args.library.name,'librarySHA256':hashlib.sha256(args.library.read_bytes()).hexdigest()}
    try:
        for name,value in [('config','no'),('vo','libmpv'),('terminal','no'),('idle','yes')]:
            assert lib.mpv_set_option_string(handle,name.encode(),value.encode())>=0
        assert lib.mpv_initialize(handle)>=0
        for name in ['mpv-version','ffmpeg-version','mpv-configuration','option-info/gpu-api','option-info/gpu-context','option-info/vo']:
            value=lib.mpv_get_property_string(handle,name.encode())
            report[name]=C.string_at(value).decode() if value else None
            if value:lib.mpv_free(value)
        report['unsupportedRenderAPIs']=[]
        for api in ['metal','vulkan','gpu-next']:
            value=C.create_string_buffer(api.encode())
            params=(Param*2)(Param(1,C.cast(value,C.c_void_p)),Param(0,None))
            context=C.c_void_p()
            code=lib.mpv_render_context_create(C.byref(context),handle,params)
            report['unsupportedRenderAPIs'].append({'requested':api,'code':code,'error':lib.mpv_error_string(code).decode()})
            if context.value:lib.mpv_render_context_free(context)
        avutil=next(args.library.parent.glob('libavutil.*.dylib'))
        av=C.CDLL(str(avutil));av.av_version_info.restype=C.c_char_p
        report['av_version_info']=av.av_version_info().decode()
        report['ffmpegLibrarySHA256']=hashlib.sha256(avutil.read_bytes()).hexdigest()
    finally:lib.mpv_terminate_destroy(handle)
    args.output.write_text(json.dumps(report,indent=2)+'\n')


if __name__=='__main__':main()
