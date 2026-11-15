#!/usr/bin/env python3
"""Original AV-07 speaker callouts and synchronized flash/tone markers.

Uses local macOS speech for original two-word labels; no external recordings.
The media remain local. Manifest fixes hashes, layout, sample rate and timing.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import numpy as np
from PIL import Image, ImageDraw, ImageFont


def run(args):
    return subprocess.run(args, check=True, capture_output=True).stdout


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output-dir', type=Path, required=True)
    args = parser.parse_args()
    out = args.output_dir
    out.mkdir(parents=True, exist_ok=False)
    labels = [('FL', 'Front left'), ('FR', 'Front right'), ('FC', 'Front center'), ('LFE', 'Low frequency'),
              ('BL', 'Back left'), ('BR', 'Back right'), ('SL', 'Side left'), ('SR', 'Side right')]
    voice = 'Samantha'
    speech = {}
    for name, words in labels:
        if name == 'LFE': continue
        aiff = out / (name + '.aiff')
        run(['/usr/bin/say', '-v', voice, '-r', '165', '-o', str(aiff), words])
        speech[name] = aiff
    font = ImageFont.truetype('/System/Library/Fonts/Supplemental/Arial.ttf', 34)
    small = ImageFont.truetype('/System/Library/Fonts/Supplemental/Arial.ttf', 18)
    records = []
    for count, rate, layout in [(2, 44100, 'stereo'), (6, 48000, '5.1'), (8, 96000, '7.1')]:
        chosen = labels[:count]
        duration = 48
        samples = np.zeros((rate * duration, count), dtype=np.float32)
        # Every two seconds a 200 ms calibrated marker precedes the spoken label.
        for slot in range(duration // 2):
            channel = slot % count
            name, words = chosen[channel]
            start = slot * 2 * rate
            n = round(.2 * rate)
            t = np.arange(n) / rate
            frequency = 80 if name == 'LFE' else 400 + channel * 100
            envelope = np.minimum(np.arange(n) / (.01 * rate), 1) * np.minimum((n - 1 - np.arange(n)) / (.01 * rate), 1)
            samples[start:start+n, channel] = .125 * np.sin(2 * np.pi * frequency * t) * envelope
            if name != 'LFE':
                raw = run(['ffmpeg', '-v', 'error', '-i', str(speech[name]), '-f', 'f32le', '-ac', '1', '-ar', str(rate), '-'])
                spoken = np.frombuffer(raw, '<f4').copy()[:int(1.5 * rate)]
                if not len(spoken): raise RuntimeError('Speech output is empty; rerun with native macOS speech service access in a new directory')
                spoken *= .18 / max(float(abs(spoken).max()), .001)
                samples[start+int(.35*rate):start+int(.35*rate)+len(spoken), channel] = spoken
        rawpath = out / f'{count}ch-{rate}.f32'
        rawpath.write_bytes(samples.astype('<f4').tobytes())
        # Static per-slot cards plus a precisely timed white flash, 30 fps.
        frames = out / f'cards-{count}'
        frames.mkdir()
        for i,(name,words) in enumerate(chosen):
            im = Image.new('RGB', (640,360), '#10242d')
            d = ImageDraw.Draw(im)
            d.text((30,32), 'AV-07 / PCM CHANNEL CHECK', font=small, fill='#72d1ca')
            d.text((30,100), f'{name}  /  {words}', font=font, fill='white')
            d.text((30,172), f'{layout}  /  {rate} Hz  /  original callouts', font=small, fill='white')
            d.text((30,220), 'White marker and tone start together every 2 s.', font=small, fill='#bad0d7')
            d.text((30,260), 'Device mapping requires a physical listening check.', font=small, fill='#bad0d7')
            im.save(frames / f'{i}.png')
        concat = out / f'cards-{count}.txt'
        concat.write_text(''.join(f"file '{frames / str(i%count)}.png'\nduration 2\n" for i in range(duration//2)) + f"file '{frames / str((duration//2-1)%count)}.png'\n")
        name = f'av07-{count}ch-{rate}.mkv'
        command = ['ffmpeg','-v','error','-f','concat','-safe','0','-i',str(concat),'-f','f32le','-ar',str(rate),'-ac',str(count),'-channel_layout',layout,'-i',str(rawpath),
                   '-vf',"fps=30,drawbox=x=560:y=20:w=60:h=60:color=white:t=fill:enable='lt(mod(t,2),0.2)'",'-t',str(duration),'-c:v','libx264','-threads','2','-pix_fmt','yuv420p','-crf','18','-c:a','pcm_s24le',str(out/name)]
        run(command)
        run(['ffmpeg','-v','error','-i',str(out/name),'-vn','-c:a','pcm_s24le',str(out/f'av07-{count}ch-{rate}.wav')])
        probe = json.loads(run(['ffprobe','-v','error','-show_streams','-of','json',str(out/name)]))
        records.append(dict(file=name,sha256=hashlib.sha256((out/name).read_bytes()).hexdigest(),duration=duration,layout=layout,sampleRate=rate,
                            channelOrder=[x[0] for x in chosen],markerSeconds=.2,slotSeconds=2,peak=float(abs(samples).max()),streams=probe['streams'],command=command))
        rawpath.unlink()
    manifest = dict(schema=1,rights='Original text, graphics and synthesized tones. Local macOS speech; no third-party recording or media redistributed.',voice=voice,
                    generatorFFmpeg=run(['ffmpeg','-version']).decode().splitlines()[0],files=records,
                    thresholds={'digitalChannelLeakRMS':1e-6,'downmixCoefficientTolerance':.003,'digitalMarkerTimingSeconds':1/30,'engineAVOffsetSeconds':.080},
                    limitations='Digital markers and engine offsets do not measure acoustic or display latency. LFE downmix is not guaranteed; expected separate LFE mapping only on matching surround output.')
    (out/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
    print(json.dumps({'directory':str(out),'files':[x['file'] for x in records]}))

if __name__ == '__main__': main()
