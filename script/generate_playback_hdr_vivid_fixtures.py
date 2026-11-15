#!/usr/bin/env python3
"""Original HEVC test pixels with per-frame HDR Vivid T.35 SEI metadata.

No third-party movie or certified reference master is used. The pair variants
share exactly the same coded picture NAL units, so output differences must be
caused by metadata processing. ffprobe independently checks the decoded SEI.
"""
import argparse
from array import array
import hashlib
import json
import math
from pathlib import Path
import re
import shutil
import subprocess
from generate_playback_color_fixtures import pq_encode, pq_decode, srgb_encode, yuv


class Bits:
    def __init__(self):
        self.bits = ''

    def put(self, value, width):
        assert 0 <= value < 1 << width
        self.bits += format(value, f'0{width}b')

    def data(self):
        bits = self.bits + '0' * (-len(self.bits) % 8)
        return int(bits, 2).to_bytes(len(bits) // 8, 'big')


def metadata(variant):
    b = Bits()
    b.put(2 if variant == 'unsupported' else 1, 8)
    stats = (0, .45, .45, .90) if variant != 'b' else (0, .25, .08, .75)
    for value in stats:
        b.put(round(value * 4095), 12)
    authored = variant in ('authored', 'spline', 'bad-base')
    b.put(int(authored), 1)
    if authored:
        b.put(0, 1)  # one nominal target
        b.put(round(pq_encode(400) * 4095), 12)
        b.put(1, 1)
        for value, width in [(6553,14),(24,6),(700,10),(0,10),(10,6),
                             (1,2),(1,2),(0 if variant == 'bad-base' else 1,4),(1,3),(64,7)]:
            b.put(value, width)
        b.put(int(variant == 'spline'), 1)
        if variant == 'spline':
            b.put(1, 1)  # two three-point spline groups
            for mode, mb, th, d1, d2, strength in [(0,64,.20,.04,.05,127),(2,8,.55,.04,.05,150)]:
                b.put(mode,2); b.put(mb,8); b.put(round(th*4095),12)
                b.put(round(d1*4092),10); b.put(round(d2*4092),10); b.put(strength,8)
    b.put(1, 1)
    b.put(2, 3)
    b.put(230 if variant == 'saturation' else 128, 8)
    b.put(196 if variant == 'saturation' else 64, 8)
    return bytes([0x26, 0, 4, 0, 5]) + b.data()


def sei(payload):
    size = len(payload)
    raw = bytes([4]) + bytes([255]) * (size // 255) + bytes([size % 255]) + payload + b'\x80'
    escaped = bytearray()
    zeroes = 0
    for value in raw:
        if zeroes >= 2 and value <= 3:
            escaped.append(3)
            zeroes = 0
        escaped.append(value)
        zeroes = zeroes + 1 if value == 0 else 0
    return b'\x00\x00\x00\x01\x4e\x01' + escaped


def inject(data, variant):
    starts = list(re.finditer(b'\x00\x00\x00?\x01', data))
    output = bytearray()
    frame = 0
    for index, start in enumerate(starts):
        end = starts[index+1].start() if index+1 < len(starts) else len(data)
        nal = data[start.end():end]
        if len(nal) >= 3 and (nal[0] >> 1) & 63 < 32 and nal[2] & 128:
            mode = variant
            if variant == 'changing': mode = 'a' if frame < 24 else 'b'
            if variant == 'missing': mode = 'a' if frame < 24 else None
            if mode:
                output.extend(sei(metadata(mode)))
            frame += 1
        output.extend(data[start.start():end])
    assert frame == 72, frame
    return output


def gray_reference(variant):
    # Independent scalar reference for the un-splined base interval, GY/T
    # 358-2022 §11.2. Values are derived from the quantized Y samples, rather
    # than the unquantized input. The display black point is unspecified, so
    # use ideal black rather than inferring a physical contrast ratio.
    avg, variance, maximum = (.45,.45,.90) if variant == 'a' else (.25,.08,.75)
    avg, variance, maximum = [round(x*4095)/4095 for x in (avg,variance,maximum)]
    top, bottom = pq_encode(203), pq_encode(0)
    maxlum = max(top, min(pq_encode(1000), max(.5081,.2*maximum+.8*avg+.4*variance)))
    p = 6-2.5*min(1,max(0,(avg-.1)/.5)) + .3+.3*min(1,max(0,(maxlum-.67)/.08))
    unit = lambda x: (p*x/((p-1)*x+1))**2.4
    a = (top-bottom)/unit(maxlum)
    reference = []
    for index, nits in [(3,10),(4,40),(5,100)]:
        q = (round(64+876*pq_encode(nits))-64)/876
        # §10.2.6 equations 25-28: no authored first spline means TH3=0;
        # subtracting VA3 removes the default base offset for delta mode 0.
        result = min(top,max(0,a*unit(q)))
        reference.append({'x':40+80*index,'y':90,'rgb8':round(255*srgb_encode(pq_decode(result)/203))})
    assert all(math.isfinite(x['rgb8']) for x in reference)
    return reference


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--output-dir', type=Path, required=True)
    a = p.parse_args()
    out = a.output_dir
    out.mkdir(parents=True, exist_ok=True)
    if any(out.iterdir()): p.error('Output must be empty; preserve previous evidence')
    ffmpeg, ffprobe = shutil.which('ffmpeg'), shutil.which('ffprobe')
    if not ffmpeg or not ffprobe: p.error('ffmpeg and ffprobe are required')
    levels = [0, .1, 1, 10, 40, 100, 400, 1000]
    rgb = [(pq_encode(n),)*3 for n in levels] + [(.6,.4,.3),(.3,.6,.4),(.3,.4,.6),
            (.5,.5,.3),(.4,.5,.5),(.5,.3,.5),(.7,.6,.5),(.2,.3,.4)]
    data = array('H')
    for plane in range(3):
        w,h = (640,360) if plane == 0 else (320,180)
        codes = [yuv(c, 'bt2020nc', True)[plane] for c in rgb]
        for y in range(h):
            for x in range(w): data.append(round(codes[y//(h//2)*8+x//(w//8)]))
    commands = []
    with (out/'generation.log').open('w') as log:
        def run(cmd, **kw):
            commands.append([str(x) for x in cmd])
            return subprocess.run(cmd, stdout=log, stderr=log, check=True, **kw)
        samples = []
        for transfer, code in [('pq',16),('hlg',18)]:
            base = out/(transfer+'-base.hevc')
            run([ffmpeg,'-v','error','-f','rawvideo','-pix_fmt','yuv420p10le','-s','640x360','-r','24',
                 '-i','pipe:0','-vf','loop=loop=71:size=1:start=0','-frames:v','72','-c:v','libx265',
                 '-x265-params',f'log-level=error:pools=2:lossless=1:keyint=24:bframes=0:colorprim=9:transfer={code}:colormatrix=9:range=limited:master-display=G(8500,39850)B(6550,2300)R(35400,14600)WP(15635,16450)L(10000000,1):max-cll=1000,400',
                 '-f','hevc',str(base),'-n'],input=data.tobytes())
            for variant in ['plain','a','b','saturation','authored','spline','bad-base','unsupported','changing','missing']:
                hevc = out/f'{transfer}-{variant}.hevc'
                hevc.write_bytes(base.read_bytes() if variant == 'plain' else inject(base.read_bytes(), variant))
                media = hevc.with_suffix('.mp4')
                run([ffmpeg,'-v','error','-r','24','-i',str(hevc),'-c','copy','-tag:v','hvc1',str(media),'-n'])
                probe = json.loads(subprocess.check_output([ffprobe,'-v','error','-read_intervals','%+#1',
                    '-show_frames','-of','json',str(media)]))
                vivid = any('Vivid' in sd.get('side_data_type','') for f in probe.get('frames',[])
                            for sd in f.get('side_data_list',[]))
                assert vivid == (variant != 'plain'), (media, probe)
                samples.append({'file':media.name,'sha256':hashlib.sha256(media.read_bytes()).hexdigest(),
                                'bytes':media.stat().st_size,'decodedHDRVivid':vivid,'probe':probe})
    (out/'manifest.json').write_text(json.dumps({'schema':1,'rights':'Original pixels and generated HDR Vivid SEI.',
        'scope':'Synthetic integration fixtures, not a certified HDR Vivid master.', 'commands':commands,
        'patches':[{'x':40+80*(i%8),'y':90+180*(i//8),'sourcePQ':c} for i,c in enumerate(rgb)],
        'grayReference':{variant:gray_reference(variant) for variant in ['a','b']},
        'samples':samples},indent=2)+'\n')


if __name__ == '__main__': main()
