#!/usr/bin/env python3
"""Generate tiny local fixtures whose source default is Arabic, for native subtitle regression."""
import argparse
import shutil
import subprocess
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        parser.error("ffmpeg is required")
    root = args.output.resolve()
    root.mkdir(parents=True, exist_ok=True)
    for lang, text in [("ara", "Arabic"), ("eng", "English"), ("chi", "Chinese")]:
        (root / (lang + ".srt")).write_text("1\n00:00:00,000 --> 00:00:12,000\n" + text + "\n")
    for name, languages in [("chinese", ["ara", "eng", "chi"]), ("english", ["ara", "eng"]), ("plain", [])]:
        command = [ffmpeg, "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i",
                   "testsrc2=size=320x180:rate=24", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000"]
        for lang in languages:
            command += ["-i", str(root / (lang + ".srt"))]
        command += ["-map", "0:v", "-map", "1:a"]
        for index in range(len(languages)):
            command += ["-map", f"{index + 2}:s"]
        command += ["-c:v", "libx264", "-preset", "ultrafast", "-c:a", "aac", "-c:s", "srt", "-t", "12"]
        for index, lang in enumerate(languages):
            command += [f"-metadata:s:s:{index}", "language=" + lang,
                        f"-disposition:s:{index}", "default" if index == 0 else "0"]
        subprocess.run(command + [str(root / (name + ".mkv"))], check=True)


if __name__ == "__main__":
    main()
