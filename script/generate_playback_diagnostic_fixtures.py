#!/usr/bin/env python3
"""Generate silent synthetic AV-01 media and record independently probed facts.

The Dolby Vision fixture is supplied separately; it is never redistributed.
Example: --dolby-vision-sample /tmp/dv84.mov from FFmpeg's public FATE suite.
These small fixtures verify diagnostics, not HDR accuracy or 4K60 performance.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--dolby-vision-sample", type=Path)
    args = parser.parse_args()
    ffmpeg, ffprobe = shutil.which("ffmpeg"), shutil.which("ffprobe")
    if not ffmpeg or not ffprobe:
        parser.error("ffmpeg and ffprobe are required")
    args.output_dir.mkdir(parents=True, exist_ok=True)
    common = [
        ffmpeg, "-hide_banner", "-loglevel", "error", "-f", "lavfi",
        "-i", "testsrc2=size=320x180:rate=24", "-f", "lavfi",
        "-i", "anullsrc=r=48000:cl=stereo", "-t", "12",
    ]
    variants = {
        "sdr.mp4": ["-c:v", "libx264", "-pix_fmt", "yuv420p",
                    "-x264-params", "colorprim=bt709:transfer=bt709:colormatrix=bt709"],
        "hdr10.mkv": ["-c:v", "libx265", "-pix_fmt", "yuv420p10le", "-x265-params",
                      "log-level=error:pools=2:colorprim=9:transfer=16:colormatrix=9:"
                      "master-display=G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,50):"
                      "max-cll=1000,400"],
        "hlg.mkv": ["-c:v", "libx265", "-pix_fmt", "yuv420p10le", "-x265-params",
                    "log-level=error:pools=2:colorprim=9:transfer=18:colormatrix=9"],
        "av1.mkv": ["-c:v", "libsvtav1", "-pix_fmt", "yuv420p", "-preset", "12",
                    "-crf", "45", "-svtav1-params", "lp=2"],
    }
    commands = {}
    for filename, options in variants.items():
        output = args.output_dir / filename
        command = [*common, *options, "-c:a", "aac", "-shortest", "-n", str(output)]
        subprocess.run(command, check=True)
        commands[filename] = [*common[1:], *options, "-c:a", "aac", "-shortest", filename]
    if args.dolby_vision_sample:
        shutil.copyfile(args.dolby_vision_sample, args.output_dir / "dv84.mov")
    manifest = {
        "purpose": "diagnostic metadata only; no HDR brightness or performance claim",
        "generator": subprocess.check_output([ffmpeg, "-version"], text=True).splitlines()[0],
        "samples": [],
    }
    for sample in sorted(args.output_dir.iterdir()):
        if sample.suffix not in {".mp4", ".mkv", ".mov"}:
            continue
        probe = subprocess.check_output([
            ffprobe, "-v", "error", "-show_streams", "-show_format", "-of", "json", str(sample)
        ], text=True)
        facts = json.loads(probe)
        facts.get("format", {}).pop("filename", None)
        manifest["samples"].append({
            "file": sample.name, "sha256": hashlib.sha256(sample.read_bytes()).hexdigest(),
            "source": "https://fate-suite.ffmpeg.org/hevc/dv84.mov" if sample.name == "dv84.mov"
                      else "Self-generated FFmpeg testsrc2 and silent anullsrc",
            "command": commands.get(sample.name), "probe": facts,
        })
    (args.output_dir / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"Recorded {len(manifest['samples'])} samples in {args.output_dir / 'manifest.json'}")


if __name__ == "__main__":
    main()
