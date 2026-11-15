#!/usr/bin/env python3
"""Exercise 7.1.4 PCM -> APAC -> fMP4/HLS -> native macOS decode/playback.

Requires macOS 26+, Xcode command line tools, and access to system codec services.
Writes only a NEW output directory. Native playback is muted, not a speaker test.
Optionally renders a real TrueHD Atmos sample through the existing packaged mpv.
This in-memory feasibility probe limits each input to 120 seconds.
"""
import argparse
from array import array
from contextlib import contextmanager
from functools import partial
import hashlib
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import json
import math
from pathlib import Path
import struct
import subprocess
import sys
import threading
import time

ROOT = Path(__file__).resolve().parent.parent
ORDER = [0, 1, 2, 3, 6, 7, 4, 5, 8, 9, 10, 11]


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest() if hasattr(hashlib, "file_digest") else _digest(stream)


def _digest(stream):
    result = hashlib.sha256()
    for chunk in iter(lambda: stream.read(1024 * 1024), b""):
        result.update(chunk)
    return result.hexdigest()


def run(command, log, timeout=120):
    result = subprocess.run([str(x) for x in command], capture_output=True, timeout=timeout)
    log.with_suffix(".stdout.txt").write_bytes(result.stdout)
    log.with_suffix(".stderr.txt").write_bytes(result.stderr)
    if result.returncode:
        raise RuntimeError(f"{command[0]} exited {result.returncode}: {result.stdout.decode(errors='replace')[-3000:]} {result.stderr.decode(errors='replace')[-2000:]}")
    return json.loads(result.stdout) if result.stdout.strip() else None


def write_wave(path, pcm):
    if sys.byteorder != "little":
        pcm.byteswap()
    guid = bytes.fromhex("0300000000001000800000aa00389b71")
    fmt = struct.pack("<HHIIHHHHI", 0xFFFE, 12, 48000, 48000 * 48, 48, 32, 22, 32, 0x2D63F) + guid
    with path.open("xb") as stream:
        stream.write(b"RIFF" + struct.pack("<I", 4 + 8 + len(fmt) + 8 + len(pcm) * 4) + b"WAVE")
        stream.write(b"fmt " + struct.pack("<I", len(fmt)) + fmt)
        stream.write(b"data" + struct.pack("<I", len(pcm) * 4))
        pcm.tofile(stream)


def channel_fixture(path):
    """One source speaker at a time, including LFE and all four heights."""
    rate, slot = 48000, 24000
    pcm = array("f", [0]) * (slot * 12 * 12)
    for channel in range(12):
        frequency = 60 if channel == 3 else 220 + channel * 37
        for frame in range(4800, 19200):
            envelope = min(1, (frame - 4800) / 480, (19200 - frame) / 480)
            pcm[((channel * slot + frame) * 12) + channel] = .12 * envelope * math.sin(2 * math.pi * frequency * frame / rate)
    write_wave(path, pcm)
    return {"sampleRate": rate, "frames": slot * 12, "slotFrames": slot, "sha256": digest(path)}


def verify_speaker_order(path, fixture):
    pcm = array("f")
    with path.open("rb") as stream:
        pcm.fromfile(stream, path.stat().st_size // 4)
    if sys.byteorder != "little":
        pcm.byteswap()
    if not all(math.isfinite(v) for v in pcm):
        raise RuntimeError("Non-finite native decoded PCM")
    result = []
    for source in range(12):
        start = source * fixture["slotFrames"] + 6500
        end = source * fixture["slotFrames"] + 17500
        energy = [sum(v * v for v in pcm[start * 12 + channel:end * 12:12]) for channel in range(12)]
        winner = max(range(12), key=energy.__getitem__)
        share = energy[winner] / sum(energy) if sum(energy) else 0
        expected = ORDER.index(source)
        if winner != expected or share < .98 or energy[winner] < .01:
            raise RuntimeError(f"Speaker {source} mapped to {winner}, expected {expected}; energy={energy}")
        result.append({"sourceIndex": source, "decodedIndex": winner, "energyShare": share})
    return result


def wave_samples(path):
    with path.open("rb") as stream:
        if stream.read(4) != b"RIFF":
            raise RuntimeError("Expected RIFF input")
        stream.seek(12)
        while True:
            header = stream.read(8)
            if len(header) != 8:
                raise RuntimeError("WAVE input has no data chunk")
            kind, size = struct.unpack("<4sI", header)
            if kind == b"data":
                pcm = array("f")
                pcm.fromfile(stream, size // 4)
                if sys.byteorder != "little":
                    pcm.byteswap()
                return pcm
            stream.seek(size + (size & 1), 1)


def compare_waveforms(wave, decoded):
    """Check zero-lag channel correspondence; APAC is not bit-exact PCM."""
    source = wave_samples(wave)
    pcm = array("f")
    with decoded.open("rb") as stream:
        pcm.fromfile(stream, decoded.stat().st_size // 4)
    if sys.byteorder != "little":
        pcm.byteswap()
    if len(pcm) < len(source):
        raise RuntimeError("Native APAC decode lost source frames")
    results = []
    for output, channel in enumerate(ORDER):
        x = source[channel::12 * 31]
        y = pcm[output:len(source):12 * 31]
        power_x = sum(v * v for v in x)
        power_y = sum(v * v for v in y)
        if power_x < 1e-12:
            results.append({"sourceIndex": channel, "decodedIndex": output, "silentSource": True})
            continue
        correlation = sum(a * b for a, b in zip(x, y)) / math.sqrt(power_x * power_y) if power_y else 0
        ratio = math.sqrt(power_y / power_x)
        if correlation < .95 or not .8 < ratio < 1.2:
            raise RuntimeError(f"Waveform mismatch at source channel {channel}: correlation={correlation}, RMS ratio={ratio}")
        results.append({"sourceIndex": channel, "decodedIndex": output,
                        "zeroLagCorrelation": correlation, "rmsRatio": ratio})
    return {"sampleStrideFrames": 31, "comparedSourceFrames": len(source) // 12,
            "bitExactExpected": False, "channels": results}


def playlists(directory, encoded):
    segments = encoded["segments"]
    end = 0
    for segment in segments:
        if abs(segment["pts"] - end) > 1 / 48000:
            raise RuntimeError(f"fMP4 segment timestamp discontinuity at {segment}")
        end += segment["duration"]
    if abs(end - encoded["sourceDuration"]) > 1 / 48000 or not encoded["nativeDecodedFrameCountExact"]:
        raise RuntimeError("APAC/HLS presentation does not match the source frame count")
    peak = max(segment["bytes"] * 8 / segment["duration"] for segment in segments)
    average = sum(segment["bytes"] for segment in segments) * 8 / end
    (directory / "master.m3u8").write_text(
        '#EXTM3U\n#EXT-X-VERSION:7\n'
        f'#EXT-X-STREAM-INF:BANDWIDTH={math.ceil(peak)},AVERAGE-BANDWIDTH={math.ceil(average)},CODECS="apac.31.03"\n'
        'audio.m3u8\n'
    )
    return {"segmentTimelineEnd": end, "sourceDuration": encoded["sourceDuration"],
            "containerExtraSeconds": end - encoded["sourceDuration"],
            "containerDurationMatchesSource": abs(end - encoded["sourceDuration"]) <= 1 / 48000,
            "containerMinusNativeDecodedFrames": round(end * 48000) - encoded["decoded"]["frames"],
            "codec": "apac.31.03", "segmentPTSContinuous": True}


def compressed_payload(directory):
    """Hash mdat packet bytes in order, independent of changing container timing."""
    result, total = hashlib.sha256(), 0
    for path in sorted(directory.glob("segment-*.m4s")):
        data, offset = path.read_bytes(), 0
        while offset < len(data):
            if offset + 8 > len(data):
                raise RuntimeError("Truncated fMP4 box")
            size, kind = struct.unpack_from(">I4s", data, offset)
            header = 8
            if size == 1:
                if offset + 16 > len(data):
                    raise RuntimeError("Truncated extended fMP4 box")
                size, header = struct.unpack_from(">Q", data, offset + 8)[0], 16
            elif not size:
                size = len(data) - offset
            if size < header or size > len(data) - offset:
                raise RuntimeError("Invalid fMP4 box size")
            if kind == b"mdat":
                result.update(data[offset + header:offset + size])
                total += size - header
            offset += size
    if not total:
        raise RuntimeError("No APAC media payload")
    return {"bytes": total, "sha256": result.hexdigest()}


def verify_payload(directory):
    before, after = compressed_payload(directory / "encoder-output"), compressed_payload(directory)
    if before != after:
        raise RuntimeError("Packet timing remux changed APAC payload bytes")
    return {"unchanged": True, **after}


def verify_boundaries(probe, output):
    results = []
    directory = output / "boundaries"
    directory.mkdir()
    for frames in [1, 1023, 1024, 1025, 74751, 74752, 74753]:
        wave = directory / f"{frames}.wav"
        pcm = array("f", (.08 * math.sin((frame + .5) * 2 * math.pi * (200 + channel * 31) / 48000)
                          for frame in range(frames) for channel in range(12)))
        write_wave(wave, pcm)
        encoded = run([probe, "--encode", wave, directory / str(frames)], directory / f"{frames}-encode")
        manifest = playlists(directory / str(frames), encoded)
        results.append({"inputFrames": frames, "decodedFrames": encoded["decoded"]["frames"],
                        "assetDuration": encoded["decoded"]["assetDuration"], "packetTiming": encoded["packetTiming"],
                        "manifest": manifest, "compressedPayload": verify_payload(directory / str(frames))})
    return results


@contextmanager
def serve(directory):
    requests = []

    class Handler(SimpleHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_GET(self):
            requests.append(self.path)
            super().do_GET()

    server = ThreadingHTTPServer(("127.0.0.1", 0), partial(Handler, directory=str(directory)))
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{server.server_port}/master.m3u8", requests
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)


def exercise(probe, wave, output, name, fixture=None):
    directory = output / name
    encoded = run([probe, "--encode", wave, directory], output / f"{name}-encode")
    manifest = playlists(directory, encoded)
    order = verify_speaker_order(directory / "decoded.f32", fixture) if fixture else None
    waveforms = compare_waveforms(wave, directory / "decoded.f32")
    payload = verify_payload(directory)
    with serve(directory) as (url, requests):
        playback = run([probe, "--play", url, encoded["inputFrames"]], output / f"{name}-play", timeout=90)
    if not any(".m4s" in request for request in requests):
        raise RuntimeError("Native HLS player did not request media segments")
    report = {"inputSHA256": digest(wave), "encoding": encoded, "manifest": manifest,
              "nativePlayback": playback, "httpRequests": requests, "speakerOrder": order, "waveforms": waveforms,
              "compressedPayload": payload,
              "artifacts": {file.name: digest(file) for file in directory.iterdir() if file.is_file()}}
    (output / f"{name}.json").write_text(json.dumps(report, indent=2) + "\n")
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--sample", type=Path, help="Optional existing TrueHD Atmos media (never downloaded)")
    parser.add_argument("--runtime", type=Path, help="Packaged runtime .app for the same selected-track decoder")
    args = parser.parse_args()
    if bool(args.sample) != bool(args.runtime):
        parser.error("--sample and --runtime must be supplied together")
    if sys.platform != "darwin":
        parser.error("This experiment requires macOS")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    source = ROOT / "script/experiments/apac_native_probe.m"
    probe = output / "apac-native-probe"
    command = ["xcrun", "clang", "-fobjc-arc", "-fblocks", "-mmacosx-version-min=14.0", "-Wall", "-Wextra", "-Werror",
               "-Wno-deprecated-declarations", source, "-framework", "Foundation", "-framework", "AVFoundation",
               "-framework", "AudioToolbox", "-framework", "CoreMedia", "-framework", "UniformTypeIdentifiers", "-o", probe]
    run(command, output / "compile")
    caps = run([probe, "--capabilities"], output / "capabilities")
    if caps["apacEncoderQueryStatus"] or not caps["apacEncoderCount"]:
        raise RuntimeError("System APAC encoder unavailable; the process needs macOS 26+ and access to system media codec services")
    configurations = run([probe, "--configurations"], output / "encoder-configurations")
    started = time.monotonic()
    boundaries = verify_boundaries(probe, output)
    fixture = channel_fixture(output / "speaker-order.wav")
    reports = {"speaker-order": exercise(probe, output / "speaker-order.wav", output, "speaker-order", fixture)}
    real = None
    if args.sample:
        from verify_truehd_objects import verify
        pcm = output / "truehd-pcm"
        pcm.mkdir()
        real = verify(args.runtime.resolve(), args.sample.resolve(), pcm, ["7.1.4"])
        (output / "truehd-decode.json").write_text(json.dumps(real, indent=2) + "\n")
        reports["truehd"] = exercise(probe, pcm / "7.1.4.wav", output, "truehd")
    result = {"schema": 2, "capabilities": caps, "encoderConfigurations": configurations, "packetBoundaries": boundaries,
              "sourceSHA256": {str(source.relative_to(ROOT)): digest(source),
              "script/verify_apac_native.py": digest(Path(__file__))}, "elapsedSeconds": time.monotonic() - started,
              "speakerOrderVerified": True, "truehdObjectDecode": real, "cases": reports,
              "scope": "experimental audio-only VOD; APAC speaker render, not source object transport",
              "applicationPlaybackIntegrated": False, "hardwareAtmosVerified": False,
              "headTrackingVerified": False, "originalObjectMetadataTransported": False}
    (output / "validation.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({"result": str(output / "validation.json"), "cases": list(reports),
                      "speakerOrderVerified": True, "hardwareAtmosVerified": False}, indent=2))


if __name__ == "__main__":
    main()
