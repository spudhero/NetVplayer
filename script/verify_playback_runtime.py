#!/usr/bin/env python3
"""Check the packaged FFmpeg ABI and playback formats without opening media."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

# Run in a separate process so a previously loaded libavformat cannot mask the
# selected bundle. Enumeration creates no player, socket, or audio device.
ENUMERATE = r'''
import ctypes, json, sys
from pathlib import Path
lib = ctypes.CDLL(sys.argv[1])
lib.avformat_version.restype = ctypes.c_uint
lib.av_demuxer_iterate.argtypes = [ctypes.POINTER(ctypes.c_void_p)]
lib.av_demuxer_iterate.restype = ctypes.c_void_p
lib.avio_enum_protocols.argtypes = [ctypes.POINTER(ctypes.c_void_p), ctypes.c_int]
lib.avio_enum_protocols.restype = ctypes.c_char_p
lib.avformat_get_mov_video_tags.restype = ctypes.c_void_p
lib.av_codec_get_id.argtypes = [ctypes.POINTER(ctypes.c_void_p), ctypes.c_uint]
lib.av_codec_get_id.restype = ctypes.c_int
tags = (ctypes.c_void_p * 2)(lib.avformat_get_mov_video_tags(), None)
mov_codec = lambda tag: lib.av_codec_get_id(tags, int.from_bytes(tag, 'little'))
codec = ctypes.CDLL(str(Path(sys.argv[1]).with_name('libavcodec.63.dylib')))
codec.avcodec_find_decoder_by_name.argtypes = [ctypes.c_char_p]
codec.avcodec_find_decoder_by_name.restype = ctypes.c_void_p
bytevc2 = bool(mov_codec(b'vvc1') and mov_codec(b'bvc2') == mov_codec(b'vvc1')
               and codec.avcodec_find_decoder_by_name(b'vvc'))
opaque = ctypes.c_void_p()
demuxers = []
while p := lib.av_demuxer_iterate(ctypes.byref(opaque)):
    demuxers.append(ctypes.cast(p, ctypes.POINTER(ctypes.c_char_p))[0].decode())
opaque = ctypes.c_void_p()
protocols = []
while p := lib.avio_enum_protocols(ctypes.byref(opaque), 0):
    protocols.append(p.decode())
print(json.dumps({'avformat_major': lib.avformat_version() >> 16,
                  'demuxers': sorted(demuxers), 'protocols': sorted(protocols),
                  'bytevc2': bytevc2}))
'''


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def capabilities(binary):
    binary = Path(binary).resolve(strict=True)
    env = dict(os.environ, DYLD_LIBRARY_PATH=str(binary.parent))
    env.pop('DYLD_INSERT_LIBRARIES', None)
    result = subprocess.run([sys.executable, '-B', '-c', ENUMERATE, str(binary)],
                            env=env, capture_output=True, text=True, check=True, timeout=30)
    return json.loads(result.stdout)


def require_capabilities(info, baseline=None):
    if info.get('avformat_major') != 63:
        raise RuntimeError('Playback runtime requires the pinned libavformat 63 ABI')
    formats = {name for entry in info['demuxers'] for name in entry.split(',')}
    missing = {'dash', 'hls', 'mov'} - formats
    if missing:
        raise RuntimeError('Playback runtime missing demuxers: ' + ', '.join(sorted(missing)))
    missing = {'file', 'http', 'https', 'tcp', 'tls'} - set(info['protocols'])
    if missing:
        raise RuntimeError('Playback runtime missing input protocols: ' + ', '.join(sorted(missing)))
    if baseline is not None:
        for key in ('demuxers', 'protocols'):
            missing = set(baseline[key]) - set(info[key])
            if missing:
                raise RuntimeError('DASH build lost baseline ' + key + ': ' + ', '.join(sorted(missing)))


def _ffmpeg_component(bundle):
    return next(c for c in json.loads((bundle / 'Contents/Resources/ThirdPartyLicenses/libmpv-runtime.json').read_text())['components']
                if c['formula'] == 'ffmpeg')


def _verify_dash_receipt(bundle, binary, actual, component, capabilities):
    receipt = bundle / 'Contents/Resources/dash-runtime-build.json'
    if not receipt.is_file():
        raise RuntimeError('DASH build receipt is missing')
    dash = json.loads(receipt.read_text())
    if dash.get('packaged_libavformat_sha256') != actual:
        raise RuntimeError('Playback runtime binary differs from DASH build receipt')
    if dash.get('bytevc2', False) != capabilities.get('bytevc2', False):
        raise RuntimeError('ByteVC2 support differs from the runtime receipt')
    for patch in dash.get('patches', []):
        relative = Path(patch.get('path', ''))
        root = bundle/'Contents/Resources/ThirdPartyLicenses/libmpv/ffmpeg'
        expected = root/patch.get('name', '')
        path = bundle/relative
        if relative.is_absolute() or '..' in relative.parts or path != expected:
            raise RuntimeError('DASH source patch path is invalid')
        if not path.is_file() or not path.resolve().is_relative_to(root.resolve()):
            raise RuntimeError('DASH source patch is missing')
        if digest(path) != patch.get('sha256'):
            raise RuntimeError('DASH source patch differs from build receipt')
    if component.get('local_dash_build') != dash:
        raise RuntimeError('DASH build provenance differs from license manifest')
    record = next(x for x in component['dylibs'] if x['name'] == binary.name)
    if record.get('packaged_sha256') != actual:
        raise RuntimeError('DASH binary hash differs from license manifest')


def verify_dash_bundle(bundle):
    """Verify a build intermediate; this does not qualify a distributable runtime."""
    bundle = Path(bundle)
    binary = bundle / 'Contents/Frameworks/libavformat.63.dylib'
    info = capabilities(binary)
    require_capabilities(info)
    actual = digest(binary)
    _verify_dash_receipt(bundle, binary, actual, _ffmpeg_component(bundle), info)
    return {'libavformat_sha256': actual, **info}


def verify_bundle(bundle):
    bundle = Path(bundle)
    binary = bundle / 'Contents/Frameworks/libavformat.63.dylib'
    info = capabilities(binary)
    require_capabilities(info)
    recipe = json.loads((bundle / 'Contents/Resources/dolby-runtime-build.json').read_text())
    actual = digest(binary)
    if recipe.get('binaries', {}).get(binary.name) != actual:
        raise RuntimeError('Playback runtime binary differs from Dolby build receipt')
    component = _ffmpeg_component(bundle)
    receipt = bundle / 'Contents/Resources/dash-runtime-build.json'
    if receipt.exists() or recipe.get('dashRuntimeBuildSHA256') or component.get('local_dash_build'):
        if not receipt.is_file():
            raise RuntimeError('DASH build receipt is missing')
        if recipe.get('dashRuntimeBuildSHA256') != digest(receipt):
            raise RuntimeError('DASH receipt differs from Dolby build provenance')
        _verify_dash_receipt(bundle, binary, actual, component, info)
    return {'libavformat_sha256': actual, **info}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bundle', required=True, type=Path)
    args = parser.parse_args()
    try:
        info = verify_bundle(args.bundle)
        print(json.dumps({'libavformat_sha256': info['libavformat_sha256'],
                          'avformat_major': info['avformat_major'],
                          'demuxers': len(info['demuxers']), 'input_protocols': len(info['protocols']),
                          'DASH_HLS_MP4_verified': True, 'bytevc2': info['bytevc2']}, sort_keys=True))
    except (OSError, ValueError, RuntimeError, KeyError, StopIteration, subprocess.SubprocessError) as error:
        parser.exit(1, 'Playback runtime rejected: ' + str(error) +
                    '\nRebuild with script/build_dash_runtime.py or script/build_dolby_runtime.py.\n')


if __name__ == '__main__':
    main()
