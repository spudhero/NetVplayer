#!/usr/bin/env python3
"""Original AV-06 signals. Run AV-03 generator first; no third-party movie assets.
P5 is an encoded-domain stress signal for rejection, not a certified DV master.
"""
import argparse
from array import array
import hashlib
import json
from pathlib import Path
import shutil
import struct
import subprocess
from generate_playback_color_fixtures import pq_encode, pq_decode, yuv, bt2390, srgb_encode


def add_configuration(file, profile, compatibility):
    # ISO BMFF dvcC/dvvC layout, checked independently by ffprobe and the
    # bundled demuxer. mdat precedes moov, so no media offsets need rewriting.
    data=bytearray(file.read_bytes())
    def child(start,end,name):
        while start<end:
            size=int.from_bytes(data[start:start+4],'big')
            assert size>=8 and start+size<=end
            if data[start+4:start+8]==name: return start,size
            start+=size
        raise ValueError(name)
    moov,size=child(0,len(data),b'moov'); assert moov+size==len(data)
    ancestors=[moov]; at,end=moov+8,moov+size
    for name in [b'trak',b'mdia',b'minf',b'stbl',b'stsd']:
        box,size=child(at,end,name);ancestors.append(box);at,end=box+8,box+size
    entry,size=child(at+8,end,b'hvc1');ancestors.append(entry)
    assert b'dvcC' not in data[entry:entry+size] and b'dvvC' not in data[entry:entry+size]
    payload=bytes([1,0])+struct.pack('>H',(profile<<9)|(1<<3)|5)+bytes([compatibility<<4])+bytes(19)
    addition=struct.pack('>I',32)+(b'dvvC' if profile==8 else b'dvcC')+payload
    for box in ancestors:
        data[box:box+4]=(int.from_bytes(data[box:box+4],'big')+len(addition)).to_bytes(4,'big')
    data[entry+size:entry+size]=addition
    file.write_bytes(data)


def write_reference(out):
    levels=[pq_encode(v) for v in [0,.1,1,10,100,203,400,1000]]
    colors=[(v,v,v) for v in levels]+[(.6,.4,.3),(.3,.6,.4),(.3,.4,.6),(.5,.5,.3),(.4,.5,.5),(.5,.3,.5),(.7,.6,.5),(.2,.3,.4)]
    patches=[]
    for i,rgb in enumerate(colors):
        yy,u,v=yuv(rgb,'bt2020nc',True)
        yy,u,v=(yy-64)/876,(u-512)/896,(v-512)/896
        r,b=yy+1.4746*v,yy+1.8814*u
        g=(yy-.2627*r-.0593*b)/.678
        linear=[pq_decode(max(0,min(1,c)))/203 for c in [r,g,b]]
        old=max(linear)
        if old>0:
            mapped=[bt2390(c*203,1000)/203 for c in linear];new=max(mapped)
            coefficient=.9*(max(new-.18,1e-6)/max(new,1))**.2
            linear=[(1-coefficient)*c*new/old+coefficient*m for c,m in zip(linear,mapped)]
        r,g,b=linear
        linear=[1.660491*r-.587641*g-.072850*b,-.124550*r+1.132900*g-.008349*b,-.018151*r-.100579*g+1.118730*b]
        patches.append({'x':40+80*(i%8),'y':90+180*(i//8),'linearSRGB':linear,'rgb8':[round(255*srgb_encode(c)) for c in linear]})
    (out/'reference.json').write_text(json.dumps({'patches':patches,'peak':1000,'target':203,'toleranceLSB':4},indent=2)+'\n')


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--base-dir',type=Path,required=True)
    p.add_argument('--output-dir',type=Path,required=True)
    p.add_argument('--dovi-tool',type=Path,required=True)
    a=p.parse_args(); out=a.output_dir
    out.mkdir(parents=True,exist_ok=True)
    if any(out.iterdir()): p.error('Output directory must be empty; keep prior evidence')
    ffmpeg,ffprobe=shutil.which('ffmpeg'),shutil.which('ffprobe')
    commands=[]
    log=(out/'generation.log').open('w')
    def run(cmd,**kwargs):
        commands.append([str(x) for x in cmd]);subprocess.run(cmd,stdout=log,stderr=log,check=True,**kwargs)
    def ff(args,**kwargs): run([ffmpeg,'-v','error',*args,'-n'],**kwargs)
    ff(['-i',str(a.base_dir/'pq.mkv'),'-map','0:v','-c:v','libx265','-x265-params','log-level=error:pools=2:lossless=1:keyint=24:colorprim=9:transfer=16:colormatrix=9:range=limited:master-display=G(8500,39850)B(6550,2300)R(35400,14600)WP(15635,16450)L(10000000,1):max-cll=1000,400','-f','hevc',str(out/'base.hevc')])
    ff(['-i',str(a.base_dir/'hlg.mp4'),'-map','0:v','-c:v','copy','-bsf:v','hevc_mp4toannexb','-f','hevc',str(out/'hlg-base.hevc')])
    # P8.1 variants share the same BL/L6; P8.4 has a genuine HLG BL.
    for name,profile,peak in [('p81-a','8.1',3079),('p81-b','8.1',3696),('p5','5',3079),('p84','8.4',3079)]:
        cfg={'cm_version':'V29','length':480,'level6':{'max_display_mastering_luminance':1000,
             'min_display_mastering_luminance':1,'max_content_light_level':1000,'max_frame_average_light_level':400},
             'default_metadata_blocks':[{'Level1':{'min_pq':0,'max_pq':peak,'avg_pq':1500}}]}
        config=out/(name+'.json');config.write_text(json.dumps(cfg,indent=2)+'\n')
        run([str(a.dovi_tool),'generate','-j',str(config),'-p',profile,'-o',str(out/(name+'.rpu'))])
        if profile=='5':
            # Full-range IPT-like code ramps; the metadata specifies the actual
            # inverse matrices. No assertion that a conventional YUV view is valid.
            frame=array('H')
            for c in range(3):
                w,h=(640,360) if c==0 else (320,180)
                values=([0,20,80,160,320,480,640,800]*2 if c==0 else
                        [512]*8+([480,544,512,512,488,536,500,524] if c==1 else [512,512,480,544,488,536,524,500]))
                for y in range(h):
                    for x in range(w): frame.append(values[y//(h//2)*8+x//(w//8)])
            ff(['-f','rawvideo','-pix_fmt','yuv420p10le','-s','640x360','-r','24','-i','pipe:0',
                '-vf','loop=loop=479:size=1:start=0','-frames:v','480','-c:v','libx265',
                '-x265-params','log-level=error:pools=2:lossless=1:keyint=24:range=full:colorprim=9:transfer=16:colormatrix=9',
                '-f','hevc',str(out/'p5-base.hevc')],input=frame.tobytes())
        base=out/({'5':'p5-base.hevc','8.4':'hlg-base.hevc'}.get(profile,'base.hevc'))
        run([str(a.dovi_tool),'inject-rpu','-i',str(base),'-r',str(out/(name+'.rpu')),'-o',str(out/(name+'.hevc'))])
        # Raw remuxing does not reliably discover the DV configuration. Add its
        # explicit record after muxing, then verify it independently with ffprobe.
        ff(['-r','24','-i',str(out/(name+'.hevc')),'-c','copy','-strict','unofficial','-tag:v','hvc1',str(out/(name+'.mp4'))])
        add_configuration(out/(name+'.mp4'),int(float(profile)),{'8.1':1,'8.4':4}.get(profile,0))
    ff(['-i',str(out/'p81-a.mp4'),'-map','0','-c','copy','-strict','unofficial',str(out/'p81-a.mkv')])
    ff(['-i',str(out/'p81-a.mp4'),'-c','copy','-bsf:v','filter_units=remove_types=62',str(out/'p81-no-rpu.mp4')])
    add_configuration(out/'p81-no-rpu.mp4',8,1)
    ff(['-i',str(out/'p5.mp4'),'-c','copy','-bsf:v','filter_units=remove_types=62',str(out/'p5-no-rpu.mp4')])
    add_configuration(out/'p5-no-rpu.mp4',5,0)
    ff(['-i',str(out/'p81-a.mp4'),'-i',str(a.base_dir/'color-overlay.sup'),'-map','0','-map','1','-c','copy','-strict','unofficial',str(out/'p81-pgs.mkv')])
    (out/'p81-a.srt').write_text('1\n00:00:00,000 --> 00:00:19,900\nAV-06 · Original subtitle · HDR10 base layer\n')
    write_reference(out)
    manifest={'schema':1,'rights':'Original AV-03 pixels / original generated metadata and P5 encoded-domain stress pattern. Media stays local.',
              'p5Scope':'Safety rejection only; not a certified Dolby master or a color-accuracy reference.',
              'thresholds':{'baseLayerComparisonLSB':1,'dynamicMetadataComparisonLSB':1,'sRGBReferenceLSB':4,'iccReferenceLSB':6},
              'ffmpegCLI':subprocess.check_output([ffmpeg,'-version'],text=True).splitlines()[0],
              'doviTool':subprocess.check_output([str(a.dovi_tool),'--version'],text=True).strip(),
              'doviToolSHA256':hashlib.sha256(a.dovi_tool.read_bytes()).hexdigest(),'commands':commands,'samples':[]}
    for file in sorted(out.iterdir()):
        if file.suffix not in ['.mp4','.mkv','.hevc']: continue
        probe=json.loads(subprocess.check_output([ffprobe,'-v','error','-show_streams','-read_intervals','%+#8','-show_frames','-of','json',str(file)]))
        manifest['samples'].append({'file':file.name,'sha256':hashlib.sha256(file.read_bytes()).hexdigest(),'bytes':file.stat().st_size,'probe':probe})
    (out/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')

if __name__=='__main__': main()
