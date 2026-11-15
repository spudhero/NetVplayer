#!/usr/bin/env python3
"""Original AV-03 HDR signals; no display luminance claim. Requires FFmpeg CLI."""
import argparse
from array import array
import hashlib
import json
import math
from pathlib import Path
import shutil
import subprocess
import sys
from generate_playback_color_fixtures import pq_encode, pq_decode, yuv, overlays


def linear_reference(codes, transfer):
    y, cb, cr = (codes[0]-64)/876, (codes[1]-512)/896, (codes[2]-512)/896
    kr, kb = (0.2126, 0.0722) if transfer == "bt709" else (0.2627, 0.0593)
    r, b = y+2*(1-kr)*cr, y+2*(1-kb)*cb
    rgb = [max(0, min(1, v)) for v in [r, (y-kr*r-kb*b)/(1-kr-kb), b]]
    if transfer == "smpte2084":
        # The experiment explicitly clips at 1000 signal nits. Quantizing PQ
        # may put the nominal 1000-nit patch slightly above that target.
        rgb = [min(1000, pq_decode(v))/203 for v in rgb]
    elif transfer == "arib-std-b67":
        scene = [v*v/3 if v <= .5 else (math.exp((v-.55991073)/.17883277)+.28466892)/12 for v in rgb]
        luma = sum(a*b for a, b in zip(scene, [.2627,.678,.0593]))
        rgb = [v*luma**.2*1000/203 for v in scene]
    else:
        return [v**2.4 for v in rgb]
    r,g,b = rgb
    return [1.660491*r-.587641*g-.072850*b, -.124550*r+1.1329*g-.008349*b, -.018151*r-.100579*g+1.11873*b]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()
    folder = args.output_dir
    folder.mkdir(parents=True, exist_ok=True)
    ffmpeg, ffprobe = shutil.which("ffmpeg"), shutil.which("ffprobe")
    if not ffmpeg or not ffprobe: parser.error("FFmpeg and ffprobe required")
    metadata = folder/"chapters.txt"
    metadata.write_text(";FFMETADATA1\n[CHAPTER]\nTIMEBASE=1/1000\nSTART=0\nEND=10000\ntitle=First\n[CHAPTER]\nTIMEBASE=1/1000\nSTART=10000\nEND=20000\ntitle=Second\n")
    manifest = {"width":640, "height":360, "referenceWhiteNits":203,
                "tolerance":0.035, "samples":[], "ffmpegCLI":subprocess.check_output([ffmpeg,"-version"],text=True).splitlines()[0]}
    for name, transfer in [("pq","smpte2084"),("hlg","arib-std-b67"),("sdr-limited","bt709")]:
        matrix = "bt709" if transfer == "bt709" else "bt2020nc"
        if transfer == "smpte2084":
            levels = [pq_encode(v) for v in [0,.1,1,10,100,203,400,1000]]
        else:
            levels = [0,.02,.05,.1,.25,.5,.75,1]
        colors = [(v,v,v) for v in levels] + [(.6,.4,.3),(.3,.6,.4),(.3,.4,.6),(.5,.5,.3),(.4,.5,.5),(.5,.3,.5),(.7,.6,.5),(.2,.3,.4)]
        codes = [yuv(rgb,matrix,True) for rgb in colors]
        frame = array('H')
        # 4:2:0 lossless coding exercises VideoToolbox Main 10, with patch
        # boundaries aligned to chroma samples; references use patch centers.
        for channel in range(3):
            w,h = (640,360) if channel == 0 else (320,180)
            for row in range(h):
                for col in range(w):
                    frame.append(codes[(row//(h//2))*8+col//(w//8)][channel])
        if sys.byteorder != 'little':frame.byteswap()
        tags = ['-color_range','tv','-colorspace',matrix,'-color_primaries','bt709' if matrix=='bt709' else 'bt2020','-color_trc',transfer]
        output=folder/(name+'.mkv')
        subprocess.run([ffmpeg,'-hide_banner','-loglevel','error','-f','rawvideo','-pix_fmt','yuv420p10le','-s','640x360','-r','24',*tags,'-i','pipe:0',
                        '-f','lavfi','-i','anullsrc=r=48000:cl=stereo','-f','ffmetadata','-i',str(metadata),
                        '-map','0:v','-map','1:a','-map','1:a','-map_metadata','2','-vf','loop=loop=479:size=1:start=0','-t','20',
                        '-c:v','libx265','-x265-params','log-level=error:pools=2:lossless=1:keyint=24:colorprim='+('1' if matrix=='bt709' else '9')+':transfer='+{'bt709':'1','smpte2084':'16','arib-std-b67':'18'}[transfer]+':colormatrix='+('1' if matrix=='bt709' else '9')+':range=limited',
                        '-c:a','aac','-metadata:s:a:0','language=eng','-metadata:s:a:1','language=zho',*tags,'-n',str(output)], input=frame.tobytes(),check=True)
        decoded=subprocess.check_output([ffmpeg,'-v','error','-i',str(output),'-map','0:v','-frames:v','1','-f','rawvideo','-pix_fmt','yuv420p10le','pipe:1'])
        assert decoded==frame.tobytes(), 'Lossless first-frame comparison failed'
        probe=json.loads(subprocess.check_output([ffprobe,'-v','error','-show_streams','-show_chapters','-of','json',str(output)]))
        manifest['samples'].append({'file':output.name,'sha256':hashlib.sha256(output.read_bytes()).hexdigest(),'probe':probe,
            'patches':[{'x':40+80*(i%8),'y':90+180*(i//8),'linearRGB':linear_reference(v,transfer)} for i,v in enumerate(codes)]})
        subprocess.run([ffmpeg,'-v','error','-i',str(output),'-map','0','-c','copy','-tag:v','hvc1','-n',str(folder/(name+'.mp4'))],check=True)
    overlays(folder)
    subprocess.run([ffmpeg,"-v","error","-i",str(folder/"pq.mkv"),"-i",str(folder/"color-overlay.sup"),"-map","0","-map","1","-c","copy","-n",str(folder/"contract.mkv")],check=True)
    (folder/'hdr-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')


if __name__=='__main__':main()
