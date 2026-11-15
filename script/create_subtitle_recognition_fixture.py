#!/usr/bin/env python3
"""Create original timed PGS text using the separately pinned bdmvkit 0.7.0.

Test authoring only; no third-party authoring code is shipped in the app.
Requires Pillow. The output is original text/raster material.
"""
import argparse
import hashlib
import json
from pathlib import Path
import sys


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--authoring',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args()
    sys.path.insert(0,str(args.authoring.resolve()))
    from bdmvkit import pgs,__version__
    from PIL import Image,ImageDraw,ImageFont
    if __version__ != '0.7.0':
        raise SystemExit('Requires bdmvkit 0.7.0')
    args.output.mkdir(parents=True,exist_ok=False)
    text=['Dr. Chen, please wait.','Do not open the red door.','Tuesday, not Thursday.','Turn left.','Turn left.','The price is $12.50.']
    font=ImageFont.truetype('/System/Library/Fonts/Supplemental/Arial.ttf',48)
    cues=[]
    for i,line in enumerate(text):
        image=Image.new('RGBA',(1200,130))
        ImageDraw.Draw(image).text((24,30),line,font=font,fill='white',stroke_width=2,stroke_fill='black')
        image.save(args.output/f'cue-{i}.png')
        pic=pgs.indexed(image.tobytes(),*image.size)
        pic=(*pic[:3],pic[3]+360,pic[4]+850)
        cues.append((1+i*4,4+i*4,pic,pgs.palette('#ffffff','#000000')))
    sup=args.output/'original.sup'
    pgs.write_sup(str(sup),cues,(1920,1080))
    manifest={'kind':'original-authored-PGS','authoring':'bdmvkit 0.7.0 (test-only)','cues':[{'start':a,'end':b,'text':t} for (a,b,_,_),t in zip(cues,text)],'sha256':hashlib.sha256(sup.read_bytes()).hexdigest(),'bytes':sup.stat().st_size}
    (args.output/'manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n')

if __name__=='__main__':
    main()
