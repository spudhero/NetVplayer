#!/usr/bin/env python3
"""Original AV-08 dialogue/music/action, with predeclared stems and timing.

Generated media stay local; commit only the manifest and measurement evidence.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import numpy as np

RATE = 48000
DURATION = 64
TEXT = "Keep your voice calm. The lights are on, and the path ahead is clear. We can leave when the music ends."
LAYOUTS = {"stereo": ["FL", "FR"], "5.1": ["FL", "FR", "FC", "LFE", "BL", "BR"],
           "5.1(side)": ["FL", "FR", "FC", "LFE", "SL", "SR"],
           "7.1": ["FL", "FR", "FC", "LFE", "BL", "BR", "SL", "SR"]}


def run(args):
    return subprocess.check_output(args, stderr=subprocess.PIPE)


def encode_wav(samples, path, layout):
    raw = path.with_suffix('.f32')
    raw.write_bytes(samples.astype('<f4').tobytes())
    run(['ffmpeg', '-v', 'error', '-f', 'f32le', '-ar', str(RATE), '-ac', str(samples.shape[1]),
         '-channel_layout', layout, '-i', str(raw), '-c:a', 'pcm_s24le', str(path)])
    raw.unlink()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output-dir', type=Path, required=True)
    args = parser.parse_args()
    out = args.output_dir
    out.mkdir(parents=True, exist_ok=False)
    say = ['/usr/bin/say', '-v', 'Samantha', '-r', '180', '-o', str(out/'speech.aiff'), TEXT]
    run(say)
    speech = np.frombuffer(run(['ffmpeg', '-v', 'error', '-i', str(out/'speech.aiff'), '-ac', '1', '-ar', str(RATE), '-f', 'f32le', '-']), '<f4').copy()
    assert len(speech) > RATE and np.max(abs(speech)) > .01, 'Empty or silent macOS speech; requires native speech service access'
    speech *= .24 / np.max(abs(speech))
    rng = np.random.default_rng(81016)
    t = np.arange(RATE * DURATION) / RATE
    music = sum(np.sin(2*np.pi*f*t + i*.3) / (i+2) for i,f in enumerate([110, 164.8138, 220, 277.1826, 329.6276, 440, 880]))
    music *= .16 / np.max(abs(music))
    # Original procedural percussion / explosion: low tones plus seeded noise,
    # with a 20 ms onset and exponential tail, no discontinuous step.
    action = np.zeros_like(t)
    for onset in [27., 29.5, 32., 34.5]:
        dt = t - onset
        envelope = np.where(dt >= 0, np.minimum(np.maximum(dt, 0)/.02, 1) * np.exp(-np.maximum(dt, 0)/.45), 0)
        noise = rng.standard_normal(len(t))
        low_noise = np.convolve(noise, np.ones(24)/24, mode='same')
        burst = envelope * (np.sin(2*np.pi*65*t) + .35*np.sin(2*np.pi*130*t) + .5*low_noise)
        burst *= .75 / max(np.max(abs(burst)), .001)
        action += burst
    speech_stem = np.zeros_like(t)
    for onset in [2., 16., 26.]:
        n = min(len(speech), int(8*RATE))
        speech_stem[int(onset*RATE):int(onset*RATE)+n] = speech[:n]
    music *= ((t >= 10) & (t < 24))
    music *= np.minimum(np.abs(t-10)/.05, 1) * np.minimum(np.abs(t-24)/.05, 1)
    records = []
    for layout, channels in LAYOUTS.items():
        count = len(channels)
        samples = np.zeros((len(t), count), dtype=np.float64)
        voice = np.zeros_like(samples)
        background = np.zeros_like(samples)
        if count == 2:
            voice[:, :] = speech_stem[:, None]
            background[:, 0] = music + action
            background[:, 1] = .9*music + action
        else:
            voice[:, 2] = speech_stem
            for index, channel in enumerate(channels):
                if channel != 'FC': background[:, index] = (music + action) * (0.7 if channel == 'LFE' else 1)
        samples = voice + background
        # Smooth full-scale pressure: correlated channels challenge downmix/limiter.
        start, end = 36*RATE, 40*RATE
        u = np.arange(end-start)/RATE
        envelope = np.minimum(u/.05, 1)*np.minimum((4-u)/.05, 1)
        samples[start:end, :] = (.999*np.sin(2*np.pi*100*u)*envelope)[:, None]
        # Low-level stationary tones for independent EQ and coefficient checks.
        for slot, frequency in enumerate([100, 500, 1800, 6000]):
            start = (40+slot)*RATE
            u = np.arange(RATE)/RATE
            wave = .01*np.sin(2*np.pi*frequency*u)*np.minimum(u/.02, 1)*np.minimum((1-u)/.02, 1)
            samples[start:start+RATE, :] = wave[:, None]
        for index in range(count):
            start = (46+index)*RATE
            u = np.arange(RATE)/RATE
            samples[start:start+RATE, index] = .125*np.sin(2*np.pi*(400+100*index)*u)*np.minimum(u/.02, 1)*np.minimum((1-u)/.02, 1)
        # Two isolated 1 kHz markers, paired with a video flash.
        for onset in [.5, 58.]:
            u = np.arange(int(.1*RATE))/RATE
            wave = .1*np.sin(2*np.pi*1000*u)*np.minimum(u/.005, 1)*np.minimum((.1-u)/.005, 1)
            samples[int(onset*RATE):int(onset*RATE)+len(u), :] = wave[:, None]
        stem = f'av08-{layout.replace("(", "-").replace(")", "")}'
        # PCM in Matroska does not preserve the side-vs-rear channel mask.
        # MOV writes the explicit channel layout; confirm it below.
        filename = stem + '.mov'
        wav = out/(stem+'.wav')
        encode_wav(samples, wav, layout)
        encode_wav(voice, out/(stem+'-voice.wav'), layout)
        encode_wav(background, out/(stem+'-background.wav'), layout)
        srt = out/(stem+'.srt')
        srt.write_text('1\n00:00:01,000 --> 00:00:09,500\nAV-08: Original dialogue, music and action comparison.\n\n2\n00:00:15,000 --> 00:00:35,000\nDialogue clarity is optional. This is not voice separation.\n')
        command = ['ffmpeg', '-v', 'error', '-f', 'lavfi', '-i', f'color=c=0x152e36:s=640x360:r=30:d={DURATION}', '-i', str(wav), '-i', str(srt),
                   '-map', '0:v', '-map', '1:a', '-map', '2:s', '-vf', "drawbox=x=560:y=20:w=60:h=60:color=white:t=fill:enable='between(t,0.5,0.59)+between(t,58,58.09)'",
                   '-c:v', 'libx264', '-threads', '2', '-crf', '18', '-pix_fmt', 'yuv420p', '-c:a', 'copy', '-c:s', 'mov_text', str(out/filename)]
        run(command)
        streams = json.loads(run(['ffprobe', '-v', 'error', '-show_streams', '-of', 'json', str(out/filename)]))['streams']
        assert next(stream for stream in streams if stream['codec_type']=='audio')['channel_layout'] == layout
        records.append({'file': filename, 'audio': wav.name, 'layout': layout, 'channels': channels,
                        'sampleRate': RATE, 'seconds': DURATION, 'command': command,
                        'sha256': hashlib.sha256((out/filename).read_bytes()).hexdigest(),
                        'peak': float(abs(samples).max()), 'streams': streams})
    # Continuous low-frequency signal for on/off transitions (no source transients).
    t2 = np.arange(RATE*24)/RATE
    transition = .25*np.sin(2*np.pi*120*t2)
    encode_wav(np.column_stack([transition, transition]), out/'transition.wav', 'stereo')
    run(['ffmpeg', '-v', 'error', '-f', 'lavfi', '-i', 'color=c=0x152e36:s=320x180:r=30:d=24',
         '-i', str(out/'transition.wav'), '-c:v', 'libx264', '-threads', '2', '-pix_fmt', 'yuv420p',
         '-c:a', 'copy', str(out/'transition.mov')])
    manifest = {'schema': 1, 'rights': 'Original text, synthesized music/tones/action; local macOS synthesized voice. No third-party recording or media redistributed.',
                'text': TEXT, 'voice': 'Samantha', 'sayCommand': say, 'randomSeed': 81016,
                'generatorFFmpeg': run(['ffmpeg', '-version']).decode().splitlines()[0], 'files': records,
                'windows': {'voice': [2,10], 'music': [10,16], 'voiceMusic': [16,24], 'voiceAction': [26,36], 'pressure': [36,40], 'tones': [40,44], 'channels': [46,54], 'silence': [60,63]},
                'thresholds': {'samplePeak': .951, 'truePeak4x': 1., 'clippedSamples': 0, 'offMaximumDifference': 0., 'coefficientError': .003,
                               'centerRatioErrorDB': .1, 'equalizerErrorDB': .2, 'loudnessMatchLU': .2, 'engineAVOffsetSeconds': .080,
                               'digitalMarkerSeconds': 1/30, 'silencePeak': 1e-5, 'transitionExtraStep': .02}}
    manifest['artifacts'] = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in out.iterdir() if p.is_file()}
    (out/'manifest.json').write_text(json.dumps(manifest, indent=2)+'\n')
    print(json.dumps({'fixtures': len(records), 'manifest': str(out/'manifest.json')}))


if __name__ == '__main__': main()
