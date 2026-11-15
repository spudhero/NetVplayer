#!/usr/bin/env python3
"""Measure the exported production plans with the fixed bundled libmpv.

AO pcm is digital evidence, not CoreAudio, listening or acoustic verification.
References (pan coefficients and RBJ biquad response) are independent of mpv.
"""
import argparse
import ctypes as C
import hashlib
import json
import math
import os
from pathlib import Path
import re
import subprocess
import time
import numpy as np


class Event(C.Structure):
    _fields_ = [('event_id', C.c_int), ('error', C.c_int), ('reply_userdata', C.c_uint64), ('data', C.c_void_p)]


class MPV:
    def __init__(self):
        self.lib = C.CDLL(os.environ['NETVPLAYER_LIBMPV_PATH'])
        self.lib.mpv_create.restype = C.c_void_p
        for name in ['mpv_initialize', 'mpv_terminate_destroy']:
            getattr(self.lib, name).argtypes = [C.c_void_p]
        self.lib.mpv_set_option_string.argtypes = [C.c_void_p, C.c_char_p, C.c_char_p]
        self.lib.mpv_command.argtypes = [C.c_void_p, C.POINTER(C.c_char_p)]
        self.lib.mpv_get_property_string.argtypes = [C.c_void_p, C.c_char_p]
        self.lib.mpv_get_property_string.restype = C.c_void_p
        self.lib.mpv_wait_event.argtypes = [C.c_void_p, C.c_double]
        self.lib.mpv_wait_event.restype = C.POINTER(Event)
        self.lib.mpv_free.argtypes = [C.c_void_p]

    def prop(self, ctx, name):
        pointer = self.lib.mpv_get_property_string(ctx, name.encode())
        if not pointer: return None
        value = C.string_at(pointer).decode()
        self.lib.mpv_free(pointer)
        return value

    def render(self, source, output, layout, graph=None):
        context = self.lib.mpv_create()
        assert context
        try:
            options = {'config':'no', 'vo':'null', 'video':'no', 'ao':'pcm', 'ao-pcm-file':str(output),
                       'audio-format':'float', 'audio-channels':layout, 'audio-samplerate':'48000', 'audio-normalize-downmix':'yes',
                       'ad-lavc-downmix':'no', 'audio-spdif':'', 'volume':'100', 'mute':'no', 'speed':'1', 'idle':'yes', 'msg-level':'all=warn'}
            if graph is not None: options['af'] = graph
            for key, value in options.items():
                assert self.lib.mpv_set_option_string(context, key.encode(), value.encode()) >= 0, (key, value)
            assert self.lib.mpv_initialize(context) >= 0
            versions = {key:self.prop(context,key) for key in ['mpv-version','ffmpeg-version']}
            assert '0.41.0' in versions['mpv-version'] and versions['ffmpeg-version'] == '9.0.1', versions
            command = (C.c_char_p*3)(b'loadfile', str(source).encode(), None)
            assert self.lib.mpv_command(context, command) >= 0
            deadline = time.monotonic()+60
            configured = None
            ended = False
            while time.monotonic() < deadline:
                event = self.lib.mpv_wait_event(context,.1).contents
                if event.event_id == 8: configured = self.prop(context, 'af')
                if event.event_id == 7:
                    ended = True
                    break
            assert ended, 'PCM render timed out'
            return {'versions': versions, 'requestedFilter': graph, 'observedFilter': configured}
        finally:
            self.lib.mpv_terminate_destroy(context)


def decode(path, channels):
    raw = subprocess.check_output(['ffmpeg','-v','error','-i',str(path),'-map','0:a:0','-f','f32le','-'])
    return np.frombuffer(raw,'<f4').reshape(-1,channels)


def loudness(path, start=2, seconds=34):
    process = subprocess.run(['ffmpeg','-hide_banner','-nostats','-ss',str(start),'-t',str(seconds),'-i',str(path),
                              '-af','loudnorm=I=-23:TP=-1:LRA=11:print_format=json','-f','null','-'],capture_output=True,check=True)
    match = re.findall(r'\{\s*"input_i"[\s\S]*?\}', process.stderr.decode())
    assert match, process.stderr.decode()[-1500:]
    return {key:float(value) for key,value in json.loads(match[-1]).items() if key.startswith('input_')}


def true_peak(path):
    process = subprocess.Popen(['ffmpeg','-v','error','-i',str(path),'-af','aresample=192000','-f','f32le','-'],stdout=subprocess.PIPE)
    peak = 0.
    while True:
        raw = process.stdout.read(65536)
        if not raw: break
        peak = max(peak,float(np.max(abs(np.frombuffer(raw,'<f4')))))
    assert process.wait() == 0
    return peak


def rms(x): return float(np.sqrt(np.mean(np.asarray(x,dtype='f8')**2)))


def eq_gain(frequency, gain):
    # RBJ peaking EQ with Q=.7 at 1800 Hz, then the declared preattenuation.
    omega = 2*math.pi*1800/48000
    a = 10**(gain/40)
    alpha = math.sin(omega)/(2*.7)
    b = np.array([1+alpha*a, -2*math.cos(omega), 1-alpha*a])
    c = np.array([1+alpha/a, -2*math.cos(omega), 1-alpha/a])
    z = np.exp(-2j*math.pi*frequency/48000*np.arange(3))
    return abs(np.dot(b,z)/np.dot(c,z))*10**(-gain/20)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--fixtures',required=True,type=Path)
    parser.add_argument('--output-dir',required=True,type=Path)
    args = parser.parse_args()
    args.output_dir.mkdir(parents=True,exist_ok=False)
    manifest = json.loads((args.fixtures/'manifest.json').read_text())
    plans = json.loads((args.fixtures/'production-plans.json').read_text())
    thresholds = manifest['thresholds']
    results = []
    report = {'schema':1, 'route':'Bundled libmpv AO pcm, not CoreAudio or acoustic/listening verification',
              'manifestSHA256':hashlib.sha256((args.fixtures/'manifest.json').read_bytes()).hexdigest(),
              'productionPlansSHA256':hashlib.sha256((args.fixtures/'production-plans.json').read_bytes()).hexdigest(),
              'thresholds':thresholds,'results':results}
    mpv = MPV()
    def save(): (args.output_dir/'results.json').write_text(json.dumps(report,indent=2)+'\n')
    for fixture in manifest['files']:
        source = args.fixtures/fixture['file']
        assert hashlib.sha256(source.read_bytes()).hexdigest() == fixture['sha256']
        layout = fixture['layout']; channels = fixture['channels']; count = len(channels)
        original_pcm = decode(args.fixtures/fixture['audio'],count)
        pixels = subprocess.check_output(['ffmpeg','-v','error','-i',str(source),'-an','-sn',
            '-vf','crop=20:20:580:40,format=gray','-f','rawvideo','-'])
        white = np.frombuffer(pixels,np.uint8).reshape(-1,400).mean(1)>200
        video_markers = (np.flatnonzero(white & ~np.r_[False,white[:-1]])/30).tolist()
        assert video_markers == [.5,58.],(fixture['file'],video_markers)
        for target in [layout] if count == 2 else [layout,'stereo']:
            outcount = count if target == layout else 2
            prefix = Path(fixture['file']).stem+'-to-'+target.replace('(','-').replace(')','')
            baseline_path = args.output_dir/(prefix+'-baseline.wav')
            mpv.render(source,baseline_path,target)
            baseline = decode(baseline_path,outcount)
            assert len(baseline) == fixture['seconds']*48000, (prefix,len(baseline))
            baseline_loudness = loudness(baseline_path)
            for index,strength in enumerate(['off','light','medium','strong']):
                output = args.output_dir/(prefix+'-'+strength+'.wav')
                details = mpv.render(source,output,target,plans[layout][strength])
                y = decode(output,outcount)
                record = {'fixture':fixture['file'],'target':target,'strength':strength,'frames':len(y),**details}
                results.append(record); save()
                assert len(y) == len(baseline), (prefix,strength,'duration changed',len(y),len(baseline))
                assert np.isfinite(y).all()
                record['samplePeak'] = float(np.max(abs(y)))
                record['truePeak4x'] = true_peak(output)
                record['clippedSamples'] = int(np.sum(abs(y)>=1))
                record['silencePeak'] = float(np.max(abs(y[60*48000:63*48000])))
                assert record['silencePeak'] <= thresholds['silencePeak'],record
                if strength == 'off':
                    record['maximumBaselineDifference'] = float(np.max(abs(y-baseline)))
                    assert record['maximumBaselineDifference'] == 0,record
                else:
                    assert record['samplePeak'] <= thresholds['samplePeak'],record
                    assert record['truePeak4x'] <= thresholds['truePeak4x'],record
                    assert record['clippedSamples'] == 0,record
                    if count > 2:
                        measured=[]
                        norm=1+(2 if count==6 else 3)*math.sqrt(.5)
                        gain=10**(-2*index/20)
                        for channel,label in enumerate(channels):
                            start=int((46+channel+.2)*48000); end=int((46+channel+.8)*48000)
                            x=original_pcm[start:end,channel].astype('f8')
                            actual=(x[:,None]*y[start:end]).sum(0)/(x*x).sum()
                            base=np.eye(count)[channel] if target==layout else (
                                np.array([1/norm,0]) if label=='FL' else np.array([0,1/norm]) if label=='FR' else
                                np.array([math.sqrt(.5)/norm]*2) if label=='FC' else np.zeros(2) if label=='LFE' else
                                np.array([math.sqrt(.5)/norm,0]) if label in ['BL','SL'] else np.array([0,math.sqrt(.5)/norm]))
                            expected=base*(1 if label=='FC' else gain)
                            error=float(np.max(abs(actual-expected)))
                            assert error<=thresholds['coefficientError'],(prefix,strength,label,actual,expected)
                            measured.append({'channel':label,'actual':actual.tolist(),'expected':expected.tolist(),'error':error})
                        record['coefficients']=measured
                        # Relative FL/FC change measured on isolated labelled tones.
                        fc=max(abs(np.array(measured[2]['actual']))); fl=max(abs(np.array(measured[0]['actual'])))
                        base_fc=1 if target==layout else math.sqrt(.5)/norm
                        base_fl=1 if target==layout else 1/norm
                        ratio=20*math.log10((fc/fl)/(base_fc/base_fl))
                        record['centerRelativeGainDB']=ratio
                        assert abs(ratio-2*index)<=thresholds['centerRatioErrorDB'],record
                    else:
                        measurements=[]
                        for slot,frequency in enumerate([100,500,1800,6000]):
                            start=int((40+slot+.2)*48000);end=int((40+slot+.8)*48000)
                            actual=rms(y[start:end])/rms(baseline[start:end])
                            expected=eq_gain(frequency,index*1.5)
                            error=abs(20*math.log10(actual/expected))
                            assert error<=thresholds['equalizerErrorDB'],(frequency,actual,expected,error)
                            measurements.append({'frequency':frequency,'gain':actual,'reference':expected,'errorDB':error})
                        record['equalizer']=measurements
                        original=np.max(abs(baseline[27*48000:36*48000]))/rms(baseline[2*48000:10*48000])
                        processed=np.max(abs(y[27*48000:36*48000]))/rms(y[2*48000:10*48000])
                        record['actionToDialogueChangeDB']=float(20*math.log10(processed/original))
                        assert processed<=original,(prefix,strength,processed,original)
                offsets=[]
                for onset in video_markers:
                    start=int((onset-.05)*48000);end=int((onset+.2)*48000)
                    active=np.flatnonzero(np.max(abs(y[start:end]),axis=1)>.001)
                    assert len(active)
                    offset=(start+int(active[0]))/48000-onset
                    assert abs(offset)<=thresholds['digitalMarkerSeconds'],(prefix,strength,offset)
                    offsets.append(offset)
                record['markerOffsetsSeconds']=offsets
                record['decodedVideoMarkerSeconds']=video_markers
                measured_loudness=loudness(output)
                record['programLoudness']=measured_loudness
                # Two stereo listening pairs use fixed program sections, no pressure tones.
                if target=='stereo':
                    target_lu=min(-23.,baseline_loudness['input_i']-baseline_loudness['input_tp']-1.,
                                  measured_loudness['input_i']-measured_loudness['input_tp']-1.)
                    matched=[]
                    for label,path,stats in [('off',baseline_path,baseline_loudness),('processed',output,measured_loudness)]:
                        listen=args.output_dir/(prefix+'-'+strength+'-matched-'+label+'.wav')
                        subprocess.run(['ffmpeg','-v','error','-ss','2','-t','34','-i',str(path),'-af',f'volume={target_lu-stats["input_i"]}dB',
                                        '-c:a','pcm_s24le',str(listen)],check=True)
                        matched.append(loudness(listen,start=0,seconds=34)['input_i'])
                    record['matchedLoudness']={'targetLUFS':target_lu,'measuredLUFS':matched,'differenceLU':abs(matched[0]-matched[1])}
                    assert abs(matched[0]-matched[1])<=thresholds['loudnessMatchLU'],record
                record['passed']=True
                save()
                print(json.dumps({'fixture':fixture['file'],'target':target,'strength':strength,'peak':record['samplePeak'],'passed':True}),flush=True)
    report['passed']=len(results)
    save()


if __name__=='__main__': main()
