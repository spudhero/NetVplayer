#!/usr/bin/env python3
"""Encode AV-07's original six-channel fixture; never synthesize Atmos claims."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess


def sha256(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    args = parser.parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=False)
    manifest = {"schema": 1, "source": {"name": args.source.name, "sha256": sha256(args.source)},
                "rights": "Derived from AV-07 original synthesized speech and channel tones; local use, no third-party recording.",
                "atmos": "No JOC or TrueHD Atmos objects are generated. These samples prove PCM decoding only.",
                "generatorVersion": subprocess.check_output(["ffmpeg", "-version"], text=True).splitlines()[0],
                "cases": []}
    for codec, options in [("ac3", ["-b:a", "640k"]), ("eac3", ["-b:a", "768k"]),
                           ("truehd", ["-strict", "-2"])]:
        target = args.output_dir / f"av09-{codec}.mkv"
        command = ["ffmpeg", "-nostdin", "-v", "error", "-i", str(args.source), "-t", "40",
                   "-map", "0:v:0", "-map", "0:a:0", "-c:v", "copy", "-c:a", codec,
                   "-ar", "48000", *options, str(target)]
        subprocess.run(command, check=True)
        probe = json.loads(subprocess.check_output(["ffprobe", "-v", "error", "-show_streams", "-show_format",
                                                    "-of", "json", str(target)], text=True))
        audio = next(stream for stream in probe["streams"] if stream["codec_type"] == "audio")
        assert audio["codec_name"] == codec and audio["channels"] == 6 and audio["sample_rate"] == "48000", audio
        assert "Atmos" not in audio.get("profile", ""), audio
        manifest["cases"].append({"file": target.name, "sha256": sha256(target), "command": command,
                                  "audio": audio, "duration": probe["format"]["duration"]})
        (args.output_dir / "fixtures.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"Generated {len(manifest['cases'])} ordinary compressed audio cases; no Atmos sample.")


if __name__ == "__main__":
    main()
