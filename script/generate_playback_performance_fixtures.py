#!/usr/bin/env python3
"""Original AV-05 media. Never loop/concatenate media to manufacture duration."""
import argparse
import hashlib
from fractions import Fraction
import json
from pathlib import Path
import shutil
import subprocess
import time

RATES = ["24000/1001", "24", "25", "50", "60000/1001", "60"]


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(4 * 1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def generate(folder, codec, depth, rate, duration, size, container, dynamic_range="sdr"):
    name = f"{codec}-{depth}bit-{size}-{rate.replace('/', '_')}-{duration}s.{container}"
    if dynamic_range != "sdr": name = dynamic_range + "-" + name
    target = folder / name
    report = target.with_suffix(target.suffix + ".json")
    if report.exists() and target.exists():
        existing = json.loads(report.read_text())
        if (existing.get("exitCode") != 0 or existing.get("streamValidationPassed") is not True
                or existing.get("sha256") != sha256(target)):
            raise RuntimeError(f"Prior failed/changed fixture preserved: {name}; use a new output directory")
        return existing
    ffmpeg = shutil.which("ffmpeg")
    fmt = "yuv420p10le" if depth == 10 else "yuv420p"
    source = f"testsrc2=size={size}:rate={rate},format={fmt},noise=alls=8:allf=t+u:all_seed=1307"
    audio = r"aevalsrc=0.04*sin(2*PI*880*t)*lt(mod(t\,1)\,0.05):s=48000"
    command = [ffmpeg, "-hide_banner", "-nostdin", "-n", "-stats_period", "10",
               "-f", "lavfi", "-i", source, "-f", "lavfi", "-i", audio,
               "-t", str(duration)]
    bitrate = "40M" if codec == "av1" else "50M"
    if size != "3840x2160":
        bitrate = "8M"
    if codec == "av1":
        command += ["-c:v", "libsvtav1", "-preset", "13", "-svtav1-params", "lp=10", "-pix_fmt", fmt]
    elif codec == "hevc":
        command += ["-c:v", "hevc_videotoolbox", "-profile:v", "main10" if depth == 10 else "main",
                    "-pix_fmt", "p010le" if depth == 10 else "yuv420p", "-tag:v", "hvc1"]
    else:
        command += ["-c:v", "h264_videotoolbox", "-profile:v", "high", "-pix_fmt", "yuv420p"]
    primaries = "bt709" if dynamic_range == "sdr" else "bt2020"
    matrix = "bt709" if dynamic_range == "sdr" else "bt2020nc"
    transfer = {"sdr": "bt709", "pq": "smpte2084", "hlg": "arib-std-b67"}[dynamic_range]
    if dynamic_range != "sdr":
        # VideoToolbox takes NCLC attachments from each input frame and may
        # replace output -color_* fields with unknown if the frame lacks them.
        command[command.index(source)] = source + f",setparams=range=limited:color_primaries={primaries}:color_trc={transfer}:colorspace={matrix}"
        if codec == "hevc":
            trc_code = "16" if dynamic_range == "pq" else "18"
            command += ["-bsf:v", f"hevc_metadata=colour_primaries=9:transfer_characteristics={trc_code}:matrix_coefficients=9:video_full_range_flag=0"]
    command += ["-b:v", bitrate, "-g", "120", "-color_range", "tv", "-colorspace", matrix,
                "-color_primaries", primaries, "-color_trc", transfer,
                "-c:a", "aac", "-ac", "2", "-b:a", "128k"]
    if container == "mp4":
        command += ["-movflags", "+faststart"]
    command += [str(target)]
    record = {"file": name, "origin": "Original FFmpeg procedural motion and time-varying seeded noise; no loop, concat or padding",
              "command": command, "requestedVideoBitrate": bitrate,
              "expectedHardwareDecoderOnM4Pro": "videotoolbox-copy", "durationTarget": duration,
              "ffmpegVersion": subprocess.check_output([ffmpeg, "-version"], text=True).splitlines()[0],
              "startedUnix": time.time()}
    print(f"Generating {name}", flush=True)
    with target.with_suffix(target.suffix + ".log").open("w") as log:
        result = subprocess.run(command, stdout=log, stderr=log)
    record["dynamicRange"] = dynamic_range
    record["signalDescription"] = "Procedural code-value HDR pattern, not a film master or optical luminance reference" if dynamic_range != "sdr" else "Original SDR procedural pattern"
    record.update(exitCode=result.returncode, generationSeconds=time.time() - record["startedUnix"])
    if result.returncode:
        report.write_text(json.dumps(record, indent=2) + "\n")
        raise RuntimeError(f"Encoding failed: {name}; see preserved log")
    record.update(sha256=sha256(target), bytes=target.stat().st_size)
    record["ffprobe"] = json.loads(subprocess.check_output([shutil.which("ffprobe"), "-v", "error",
        "-show_streams", "-show_format", "-of", "json", str(target)], text=True))
    record["actualContainerBitrate"] = int(record["ffprobe"]["format"]["bit_rate"])
    video = next(s for s in record["ffprobe"]["streams"] if s["codec_type"] == "video")
    width, height = map(int, size.split("x"))
    record["streamValidationPassed"] = (
        video["codec_name"] == codec and video["width"] == width and video["height"] == height
        and video.get("color_primaries") == primaries and video.get("color_transfer") == transfer and video.get("color_space") == matrix
        and video["pix_fmt"] == fmt and abs(float(Fraction(video["r_frame_rate"])) - float(Fraction(rate))) < .02
        and float(record["ffprobe"]["format"]["duration"]) >= duration - .1
    )
    report.write_text(json.dumps(record, indent=2) + "\n")
    if not record["streamValidationPassed"]:
        raise RuntimeError(f"Independent ffprobe does not match fixed plan: {name}")
    print(f"Finished {name}: {record['actualContainerBitrate'] / 1e6:.2f} Mbit/s, {record['sha256']}", flush=True)
    return record


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--suite", choices=["long", "matrix"], required=True)
    parser.add_argument("--codec", choices=["h264", "hevc", "av1"], required=True)
    parser.add_argument("--dynamic-range", choices=["sdr", "pq", "hlg"], default="sdr")
    args = parser.parse_args()
    if args.dynamic_range != "sdr" and args.codec == "h264": parser.error("HDR performance fixtures require HEVC or AV1 10-bit")
    args.output_dir.mkdir(parents=True, exist_ok=True)
    if args.suite == "long":
        samples = [generate(args.output_dir, args.codec, 8 if args.codec == "h264" else 10,
                            "60", 1920, "3840x2160", "mkv" if args.codec == "av1" else "mp4", args.dynamic_range)]
    else:
        samples = [generate(args.output_dir, args.codec, depth, rate, 4, "1920x1080", container, args.dynamic_range)
                   for depth in ([10] if args.dynamic_range != "sdr" else [8] if args.codec == "h264" else [8, 10])
                   for rate in RATES for container in ["mkv", "mp4"]]
    range_suffix = "" if args.dynamic_range == "sdr" else "-" + args.dynamic_range
    (args.output_dir / f"manifest-{args.suite}-{args.codec}{range_suffix}.json").write_text(json.dumps(
        {"schema": 1, "suite": args.suite, "samples": samples}, indent=2) + "\n")


if __name__ == "__main__":
    main()
