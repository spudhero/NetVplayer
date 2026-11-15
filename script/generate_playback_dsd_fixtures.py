#!/usr/bin/env python3
"""Author deterministic, original DSD test signals. No third-party media required."""
import argparse
import hashlib
import json
from pathlib import Path
import struct
import subprocess
import tempfile
import wave

import numpy as np


def dsd_channel(rate, frames, frequency):
    # Two integrators improve the authored signal's in-band quantization noise.
    # This is a test signal, not a production DSD encoder.
    source = Path(__file__).parent / 'probes/generate_dsd_signal.c'
    with tempfile.TemporaryDirectory(prefix='netvplayer-dsd-author-') as temp:
        binary = Path(temp) / 'signal'
        subprocess.run(['cc', '-O2', '-std=c11', str(source), '-lm', '-o', str(binary)], check=True)
        return subprocess.check_output([str(binary), str(rate), str(frames), str(frequency)])


def dsf(path, rate, channels, frames):
    block = 4096
    payload = b''.join(c[i:i + block].ljust(block, b'\x96')
                       for i in range(0, len(channels[0]), block) for c in channels)
    fmt = b'fmt ' + struct.pack('<QIIIIIIQII', 52, 1, 0, 2, 2, rate, 1, frames, block, 0)
    data = b'data' + struct.pack('<Q', 12 + len(payload)) + payload
    path.write_bytes(b'DSD ' + struct.pack('<QQQ', 28, 28 + len(fmt) + len(data), 0) + fmt + data)


def dff(path, rate, channels):
    def chunk(tag, payload):
        return tag + struct.pack('>Q', len(payload)) + payload + (b'\0' if len(payload) % 2 else b'')
    reverse = np.array([int(f'{i:08b}'[::-1], 2) for i in range(256)], dtype=np.uint8)
    payload = np.stack([reverse[np.frombuffer(c, np.uint8)] for c in channels], axis=1).tobytes()
    prop = (b'SND ' + chunk(b'FS  ', struct.pack('>I', rate))
            + chunk(b'CHNL', struct.pack('>H', 2) + b'SLFTSRGT')
            + chunk(b'CMPR', b'DSD \x00') + chunk(b'LSCO', struct.pack('>H', 0)))
    path.write_bytes(chunk(b'FRM8', b'DSD ' + chunk(b'FVER', struct.pack('>I', 0x01050000))
                           + chunk(b'PROP', prop) + chunk(b'DSD ', payload)))


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--output-dir', type=Path, required=True)
    args = p.parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=False)
    rows = []
    # Fixed beforehand: tone fit ignores first 0.1 s filter warmup; no fitted
    # frequency, gain adjustment, quality or analog-output claim.
    manifest = {'schema': 1, 'license': 'Original generated test signals; CC0-1.0',
                'nominalDurationSeconds': 24, 'modulation': 'second-order sigma-delta',
                'channels': 2, 'frequenciesHz': [440, 880], 'amplitude': .08,
                'thresholds': {'amplitudeAbsoluteError': .0015, 'residualRMS': .001,
                               'containerPCMMaxDifference': .000001}, 'files': rows}
    for multiple in [64, 128]:
        rate = 44100 * multiple
        # Whole DSF blocks avoid container-dependent trailing padding duration.
        frames = ((rate * 24 + 32767) // 32768) * 32768
        channels = [dsd_channel(rate, frames, f) for f in manifest['frequenciesHz']]
        formats = [('dsf', 'dsd_lsbf_planar', dsf)]
        if multiple == 64:
            formats.append(('dff', 'dsd_msbf', dff))
        for ext, codec, writer in formats:
            path = args.output_dir / f'original-dsd{multiple}.{ext}'
            if ext == 'dsf':
                writer(path, rate, channels, frames)
            else:
                writer(path, rate, channels)
            rows.append({'file': path.name, 'codec': codec, 'sourceBitSampleRate': rate,
                         'demuxSampleRate': rate // 8, 'decodedFormat': 'floatp',
                         'sourceBitFrames': frames, 'actualDurationSeconds': frames / rate,
                         'sha256': hashlib.sha256(path.read_bytes()).hexdigest()})
    # Misleading filename is intentional: it must remain ordinary PCM.
    path = args.output_dir / 'DSD128-native-name-only.wav'
    t = np.arange(48000 * 24) / 48000
    pcm = np.stack([.08 * np.sin(2 * np.pi * f * t) for f in [440, 880]], axis=1)
    with wave.open(str(path), 'wb') as wav:
        wav.setparams((2, 2, 48000, 0, 'NONE', 'not compressed'))
        wav.writeframes((pcm * 32767).astype('<i2').tobytes())
    manifest['pcmControl'] = {'file': path.name, 'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}
    (args.output_dir / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(json.dumps(manifest, indent=2))


if __name__ == '__main__':
    main()
