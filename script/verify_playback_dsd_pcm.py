#!/usr/bin/env python3
"""Measure frozen libmpv DSD decoding digitally; no CoreAudio or DAC claims."""
import argparse
import ctypes as C
import hashlib
import json
import os
from pathlib import Path
import struct
import time

import numpy as np


class Event(C.Structure):
    _fields_ = [('event_id', C.c_int), ('error', C.c_int), ('reply_userdata', C.c_uint64), ('data', C.c_void_p)]


def wav_float(path):
    data = path.read_bytes()
    assert data[:4] == b'RIFF' and data[8:12] == b'WAVE'
    i = 12
    fmt = None
    while i + 8 <= len(data):
        tag, size = struct.unpack_from('<4sI', data, i)
        body = data[i + 8:i + 8 + size]
        if tag == b'fmt ':
            fmt = struct.unpack_from('<HHIIHH', body)
        elif tag == b'data':
            assert fmt and fmt[0] in (3, 65534) and fmt[1] == 2 and fmt[2] == 48000 and fmt[5] == 32, fmt
            return np.frombuffer(body, '<f4').reshape(-1, 2).astype(np.float64)
        i += 8 + size + size % 2
    raise AssertionError('Missing PCM data')


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--fixtures', type=Path, required=True)
    p.add_argument('--output-dir', type=Path, required=True)
    args = p.parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=False)
    manifest = json.loads((args.fixtures / 'manifest.json').read_text())
    lib = C.CDLL(os.environ['NETVPLAYER_LIBMPV_PATH'])
    lib.mpv_create.restype = C.c_void_p
    for name in ['mpv_initialize', 'mpv_terminate_destroy']:
        getattr(lib, name).argtypes = [C.c_void_p]
    lib.mpv_set_option_string.argtypes = [C.c_void_p, C.c_char_p, C.c_char_p]
    lib.mpv_command.argtypes = [C.c_void_p, C.POINTER(C.c_char_p)]
    lib.mpv_get_property_string.argtypes = [C.c_void_p, C.c_char_p]
    lib.mpv_get_property_string.restype = C.c_void_p
    lib.mpv_wait_event.argtypes = [C.c_void_p, C.c_double]
    lib.mpv_wait_event.restype = C.POINTER(Event)
    lib.mpv_free.argtypes = [C.c_void_p]

    def prop(ctx, name):
        ptr = lib.mpv_get_property_string(ctx, name.encode())
        if not ptr:
            return None
        try:
            value = C.string_at(ptr).decode()
            return int(value) if value.isdigit() else value
        finally:
            lib.mpv_free(ptr)

    results = []
    waves = []
    for fixture in manifest['files']:
        path = args.fixtures / fixture['file']
        assert hashlib.sha256(path.read_bytes()).hexdigest() == fixture['sha256']
        destination = args.output_dir / (path.name + '.wav')
        ctx = lib.mpv_create()
        assert ctx
        snapshots = []
        try:
            opts = {'config': 'no', 'vo': 'null', 'ao': 'pcm', 'ao-pcm-file': str(destination),
                    'audio-format': 'float', 'audio-channels': 'stereo', 'audio-samplerate': '48000',
                    'audio-spdif': '', 'audio-exclusive': 'no', 'video': 'no', 'end': '4',
                    'volume': '100', 'idle': 'yes', 'pause': 'yes', 'msg-level': 'all=warn'}
            for key, value in opts.items():
                assert lib.mpv_set_option_string(ctx, key.encode(), value.encode()) >= 0
            assert lib.mpv_initialize(ctx) >= 0
            versions = {name: prop(ctx, name) for name in ['mpv-version', 'ffmpeg-version']}
            assert '0.41.0' in versions['mpv-version'] and versions['ffmpeg-version'] == '9.0.1', versions
            assert lib.mpv_command(ctx, (C.c_char_p * 3)(b'loadfile', str(path).encode(), None)) >= 0
            deadline = time.monotonic() + 30
            ended = False
            while time.monotonic() < deadline:
                ev = lib.mpv_wait_event(ctx, .01).contents
                if ev.event_id == 7:
                    ended = True
                    break
                if not snapshots:
                    fields = {'current-tracks/audio': {k: prop(ctx, 'current-tracks/audio/' + k)
                               for k in ['codec', 'decoder', 'demux-samplerate', 'demux-channel-count']},
                              'current-ao': prop(ctx, 'current-ao')}
                    for name in ['audio-params', 'audio-out-params']:
                        fields[name] = {k: prop(ctx, name + '/' + k)
                                        for k in ['format', 'samplerate', 'channel-count', 'channels']}
                    if fields['audio-out-params']['format'] and fields['audio-params']['format']:
                        snapshots.append(fields)
                        assert lib.mpv_command(ctx, (C.c_char_p * 4)(b'set', b'pause', b'no', None)) >= 0
            assert ended, 'Decode timeout'
        finally:
            lib.mpv_terminate_destroy(ctx)
        assert snapshots, 'No negotiated decoder/AO snapshot'
        facts = snapshots[0]
        track, decoded, output = [facts[k] for k in ['current-tracks/audio', 'audio-params', 'audio-out-params']]
        assert track['codec'] == fixture['codec'] and track['demux-samplerate'] == fixture['demuxSampleRate'], facts
        assert decoded['format'] == 'floatp' and decoded['samplerate'] == fixture['demuxSampleRate'], facts
        assert output['format'] == 'float' and output['samplerate'] == 48000 and output['channel-count'] == 2, facts
        samples = wav_float(destination)
        # mpv end is a timestamp boundary, not an exact sample-count command.
        # Decode past the fixed three-second measurement window and keep the
        # actual file length as evidence; never pad or align measured samples.
        assert len(samples) >= 144000 and np.isfinite(samples).all(), len(samples)
        waves.append(samples[:144000])
        start, end = 4800, 139200
        times = np.arange(start, end) / 48000
        measurements = []
        for ch, freq in enumerate(manifest['frequenciesHz']):
            basis = np.stack([np.sin(2 * np.pi * freq * times), np.cos(2 * np.pi * freq * times), np.ones_like(times)], axis=1)
            coefficients = np.linalg.lstsq(basis, samples[start:end, ch], rcond=None)[0]
            amp = float(np.hypot(*coefficients[:2]))
            rms = float(np.sqrt(np.mean((samples[start:end, ch] - basis @ coefficients) ** 2)))
            assert abs(amp - .08) <= manifest['thresholds']['amplitudeAbsoluteError'], amp
            assert rms <= manifest['thresholds']['residualRMS'], rms
            measurements.append({'channel': ch, 'referenceHz': freq, 'amplitude': amp, 'residualRMS': rms})
        results.append({'fixture': path.name, 'versions': versions, 'facts': facts,
                        'frames': len(samples), 'comparisonWindowFrames': 144000,
                        'measurements': measurements, 'passed': True})
    difference = float(np.max(abs(waves[0] - waves[1])))
    assert difference <= manifest['thresholds']['containerPCMMaxDifference'], difference
    report = {'schema': 1, 'route': 'Frozen libmpv PCM file output; no DAC measurement',
              'results': results, 'dsfDffMaxDifference': difference, 'passed': True}
    (args.output_dir / 'results.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
