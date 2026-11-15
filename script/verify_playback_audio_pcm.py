#!/usr/bin/env python3
"""Measure bundled libmpv PCM mapping digitally; never claims speaker hardware validation."""
import argparse
import ctypes as C
import json
import os
from pathlib import Path
import subprocess
import time
import numpy as np

class Event(C.Structure):
    _fields_=[('event_id',C.c_int),('error',C.c_int),('reply_userdata',C.c_uint64),('data',C.c_void_p)]

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--fixtures',type=Path,required=True)
    parser.add_argument('--output-dir',type=Path,required=True)
    parser.add_argument('--sample-rate', type=int, default=0)
    args=parser.parse_args()
    args.output_dir.mkdir(parents=True,exist_ok=False)
    library=Path(os.environ['NETVPLAYER_LIBMPV_PATH'])
    lib=C.CDLL(str(library))
    lib.mpv_create.restype=C.c_void_p
    lib.mpv_initialize.argtypes=[C.c_void_p]
    lib.mpv_set_option_string.argtypes=[C.c_void_p,C.c_char_p,C.c_char_p]
    lib.mpv_command.argtypes=[C.c_void_p,C.POINTER(C.c_char_p)]
    lib.mpv_get_property_string.argtypes=[C.c_void_p,C.c_char_p];lib.mpv_get_property_string.restype=C.c_void_p
    lib.mpv_wait_event.argtypes=[C.c_void_p,C.c_double];lib.mpv_wait_event.restype=C.POINTER(Event)
    lib.mpv_free.argtypes=[C.c_void_p]
    lib.mpv_terminate_destroy.argtypes=[C.c_void_p]
    def prop(ctx,name):
        ptr=lib.mpv_get_property_string(ctx,name.encode())
        if not ptr:return None
        value=C.string_at(ptr).decode();lib.mpv_free(ptr);return value
    def decode(path,count,rate):
        raw=subprocess.check_output(['ffmpeg','-v','error','-i',str(path),'-t','16','-map','0:a:0','-ar',str(rate),'-f','f32le','-'])
        return np.frombuffer(raw,'<f4').reshape(-1,count)
    manifest=json.loads((args.fixtures/'manifest.json').read_text())
    results=[]
    marker_results=[]
    for fixture in manifest['files']:
        count=len(fixture['channelOrder']);rate=args.sample_rate or fixture['sampleRate']
        source=decode(args.fixtures/fixture['file'],count,rate)
        # Independently decode the encoded flash area and PCM onset. This is
        # file timing only, excluding display, CoreAudio and acoustic latency.
        pixels=subprocess.check_output(['ffmpeg','-v','error','-i',str(args.fixtures/fixture['file']),
            '-t','16','-an','-vf','crop=20:20:580:40,format=gray','-f','rawvideo','-'])
        white=np.frombuffer(pixels,np.uint8).reshape(-1,400).mean(1)>200
        flash_frames=np.flatnonzero(white & ~np.r_[False,white[:-1]])
        assert len(flash_frames)==8,(fixture['file'],flash_frames)
        offsets=[]
        for slot,frame in enumerate(flash_frames):
            start=2*slot*rate
            active=np.flatnonzero(np.max(abs(source[start:start+int(.2*rate)]),axis=1)>.001)
            assert len(active),(fixture['file'],slot,'missing tone')
            delta=(start+int(active[0]))/rate-int(frame)/30
            assert abs(delta)<=manifest['thresholds']['digitalMarkerTimingSeconds'],(fixture['file'],slot,delta)
            offsets.append(delta)
        marker_results.append({'fixture':fixture['file'],'offsetSeconds':offsets,'passed':True})
        for target in [fixture['layout'],'stereo'] if count>2 else ['stereo']:
            destination=args.output_dir/(fixture['file']+'-'+target+'.wav')
            ctx=lib.mpv_create();assert ctx
            try:
                opts={'config':'no','vo':'null','ao':'pcm','ao-pcm-file':str(destination),'audio-format':'float','audio-channels':target,
                      'audio-samplerate':str(args.sample_rate),'audio-normalize-downmix':'yes','ad-lavc-downmix':'no','audio-spdif':'','video':'no','end':'16','volume':'100','idle':'yes','msg-level':'all=warn'}
                for k,v in opts.items():assert lib.mpv_set_option_string(ctx,k.encode(),v.encode())>=0,(k,v)
                assert lib.mpv_initialize(ctx)>=0
                versions={k:prop(ctx,k) for k in ['mpv-version','ffmpeg-version']}
                assert '0.41.0' in versions['mpv-version'],versions
                assert versions['ffmpeg-version']=='9.0.1',versions
                command=(C.c_char_p*3)(b'loadfile',str(args.fixtures/fixture['file']).encode(),None)
                assert lib.mpv_command(ctx,command)>=0
                deadline=time.monotonic()+30;ended=False
                while time.monotonic()<deadline:
                    ev=lib.mpv_wait_event(ctx,.1).contents
                    if ev.event_id==7: ended=True;break
                assert ended,'timed out'
            finally:lib.mpv_terminate_destroy(ctx)
            outcount=count if target==fixture['layout'] else 2
            decoded=decode(destination,outcount,rate)
            coefficients=[];leak=0.0
            # Reference coefficients from the standard normalized FFmpeg stereo
            # matrix: FL/FR=1, FC/surround=sqrt(.5), LFE=0, normalized by each row sum.
            norm=1+(2 if count==6 else 3)*np.sqrt(.5) if count>2 else 1
            for channel,label in enumerate(fixture['channelOrder']):
                start=int((2*channel+.03)*rate);end=int((2*channel+.17)*rate)
                x=source[start:end,channel].astype('f8');y=decoded[start:end].astype('f8')
                gain=(x[:,None]*y).sum(0)/(x*x).sum()
                if target==fixture['layout']:
                    expected=np.eye(count)[channel]
                elif label=='FL':expected=np.array([1/norm,0])
                elif label=='FR':expected=np.array([0,1/norm])
                elif label=='FC':expected=np.array([np.sqrt(.5)/norm]*2)
                elif label=='LFE':expected=np.zeros(2)
                elif label in ['BL','SL']:expected=np.array([np.sqrt(.5)/norm,0])
                else:expected=np.array([0,np.sqrt(.5)/norm])
                error=float(abs(gain-expected).max())
                rms=float(np.sqrt(np.mean((y-x[:,None]*gain)**2)))
                leak=max(leak,rms)
                coefficients.append({'channel':label,'gains':gain.tolist(),'expected':expected.tolist(),'maxError':error,'residualRMS':rms})
                assert error<=manifest['thresholds']['downmixCoefficientTolerance'],(fixture['file'],target,label,gain,expected)
                assert rms<=manifest['thresholds']['digitalChannelLeakRMS'],(label,rms)
            result={'fixture':fixture['file'],'target':target,'sampleRate':rate,'frames':len(decoded),'versions':versions,'coefficients':coefficients,'maximumResidualRMS':leak,'passed':True}
            results.append(result)
            (args.output_dir/'results.json').write_text(json.dumps({'schema':1,'route':'Bundled libmpv AO pcm file output, not CoreAudio or physical speaker measurement','results':results,'digitalFileMarkers':marker_results},indent=2)+'\n')
    print(json.dumps({'passed':len(results),'output':str(args.output_dir/'results.json')}))

if __name__=='__main__':main()
