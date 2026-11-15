#!/usr/bin/env python3
"""Independent AV-03/04 linear CPU references; no changes to prior fixtures."""
import argparse
from array import array
import hashlib
import json
import math
from pathlib import Path
import shutil
import subprocess
import sys
from generate_playback_color_fixtures import pq_decode, bt2390


def source_rgb(codes, transfer):
    y, cb, cr = (codes[0]-64)/876, (codes[1]-512)/896, (codes[2]-512)/896
    kr, kb = .2627, .0593
    r, b = y+2*(1-kr)*cr, y+2*(1-kb)*cb
    rgb = [max(0, min(1, v)) for v in [r, (y-kr*r-kb*b)/(1-kr-kb), b]]
    if transfer == 'pq':
        return [pq_decode(v)/203 for v in rgb]
    scene = [v*v/3 if v <= .5 else (math.exp((v-.55991073)/.17883277)+.28466892)/12 for v in rgb]
    luma = sum(a*b for a,b in zip(scene, [.2627,.678,.0593]))
    return [v*luma**.2*1000/203 for v in scene]


def mapped(rgb, source_peak, target):
    old = max(rgb)
    if source_peak > target and old > 0:
        values = [bt2390(v*203, source_peak, target)/203 for v in rgb]
        new = max(values)
        coefficient = .9 * (max(new-.18, 1e-6)/max(new, 1))**.2
        rgb = [(1-coefficient)*v*new/old+coefficient*m for v,m in zip(rgb,values)]
    r,g,b = rgb
    linear = [1.660491*r-.587641*g-.072850*b, -.124550*r+1.132900*g-.008349*b, -.018151*r-.100579*g+1.118730*b]
    return [min(v, target/203) for v in linear]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('folder', type=Path)
    parser.add_argument('--maximum-peak', type=int, default=1000)
    args = parser.parse_args()
    assert 203 <= args.maximum_peak <= 10000
    samples = {}
    for stem, source_peak in [('pq',10000),('hlg',1000)]:
        path = args.folder/(stem+'.mkv')
        raw = subprocess.check_output([shutil.which('ffmpeg'),'-v','error','-i',str(path),'-map','0:v','-frames:v','1','-f','rawvideo','-pix_fmt','yuv420p10le','pipe:1'])
        words = array('H'); words.frombytes(raw)
        if sys.byteorder != 'little': words.byteswap()
        patches=[]
        for i in range(16):
            x,y = 40+80*(i%8),90+180*(i//8)
            codes = [words[y*640+x], words[640*360+(y//2)*320+x//2], words[640*360+320*180+(y//2)*320+x//2]]
            patches.append({'x':x,'y':y,'codes':codes,'sourceLinearRGB':source_rgb(codes,stem)})
        samples[stem+'.mkv']={'sha256':hashlib.sha256(path.read_bytes()).hexdigest(),'patches':patches,
            'referencesByPeak':{str(peak):[mapped(p['sourceLinearRGB'],source_peak,peak) for p in patches]
                                for peak in range(203,args.maximum_peak+1)}}
    report={'schema':1,'width':640,'height':360,'tolerance':.035,'referenceWhiteSignalNits':203,
            'scope':'Signal values only; independent YUV/transfer/OOTF/BT.2390/matrix CPU math, then compositor-headroom ceiling. No optical luminance claim.', 'samples':samples}
    target=args.folder/'hdr-product-reference.json'
    with target.open('x') as f: json.dump(report,f,separators=(',',':')); f.write('\n')
    print(target)

if __name__ == '__main__': main()
