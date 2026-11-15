#!/usr/bin/env python3
"""AV-11 original continuous motion, exact rational MP4 timing, silent PCM source."""
import argparse
from fractions import Fraction
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

RATES = ['24000/1001', '24', '25', '50', '30000/1001', '60000/1001', '60']


def generate(folder):
    folder.mkdir(parents=True, exist_ok=False)
    ffmpeg, ffprobe = shutil.which('ffmpeg'), shutil.which('ffprobe')
    manifest = {'schema': 1, 'origin': 'Original FFmpeg testsrc2 continuous motion; no loop, concat or third-party media',
                'generatorVersion': subprocess.check_output([ffmpeg, '-version'], text=True).splitlines()[0], 'cases': []}
    for rate in RATES:
        name = 'fps-' + rate.replace('/', '_')
        media = folder / (name + '.mp4')
        cmd = [ffmpeg, '-hide_banner', '-nostdin', '-n', '-f', 'lavfi', '-i', 'testsrc2=size=640x360:rate=' + rate,
               '-f', 'lavfi', '-i', 'anullsrc=r=48000:cl=stereo', '-t', '80', '-c:v', 'libx264', '-threads', '2',
               '-preset', 'ultrafast', '-crf', '27', '-pix_fmt', 'yuv420p', '-g', '120', '-fps_mode', 'passthrough',
               '-color_range', 'tv', '-colorspace', 'bt709', '-color_primaries', 'bt709', '-color_trc', 'bt709',
               '-c:a', 'aac', '-b:a', '32k', '-movflags', '+faststart', '-video_track_timescale', '120000', str(media)]
        with (folder / (name + '.log')).open('w') as log:
            subprocess.run(cmd, check=True, stdout=log, stderr=subprocess.STDOUT)
        probe = json.loads(subprocess.check_output([ffprobe, '-v', 'error', '-show_streams', '-show_format', '-of', 'json', str(media)]))
        video = next(s for s in probe['streams'] if s['codec_type'] == 'video')
        assert Fraction(video['r_frame_rate']) == Fraction(rate) == Fraction(video['avg_frame_rate'])
        assert video['width'] == 640 and video['height'] == 360 and video['pix_fmt'] == 'yuv420p'
        # Decode timestamps independently; reject a padded or discontinuous CFR source.
        packets = json.loads(subprocess.check_output([ffprobe, '-v', 'error', '-select_streams', 'v:0',
            '-show_entries', 'packet=pts,duration', '-of', 'json', str(media)]))['packets']
        step = Fraction(1, 1) / Fraction(rate) / Fraction(video['time_base'])
        assert step.denominator == 1
        assert all(int(p['pts']) == i * step and int(p['duration']) == step for i, p in enumerate(packets))
        manifest['cases'].append({'id': name, 'file': media.name, 'rate': rate, 'seconds': 80, 'command': cmd,
            'sha256': hashlib.sha256(media.read_bytes()).hexdigest(), 'bytes': media.stat().st_size,
            'videoPackets': len(packets), 'packetTimingVerified': True, 'ffprobe': probe})
        (folder / 'fixtures.json').write_text(json.dumps(manifest, indent=2) + '\n')
        print(name, len(packets), media.stat().st_size, flush=True)
    config = {'outputDirectory': str(folder.with_name(folder.name + '-capture-v1')), 'cases': [
        {'id': c['id'], 'url': (folder / c['file']).as_uri(), 'warmupSeconds': 5, 'measurementSeconds': 60}
        for c in manifest['cases']]}
    (folder / 'config.json').write_text(json.dumps(config, indent=2) + '\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output-dir', type=Path, required=True)
    generate(parser.parse_args().output_dir.resolve())
