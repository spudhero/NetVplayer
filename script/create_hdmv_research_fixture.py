#!/usr/bin/env python3
"""Author an original HDMV test disc; never part of the product playback path.

Requires the separately downloaded, SHA-256-pinned bdmvkit 0.7.0 wheel,
Pillow and ffmpeg. Outputs a real BDMV with IG/PG and MovieObject commands.
This authored fixture cannot replace a real-disc compatibility matrix.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--authoring", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    sys.path.insert(0, str(args.authoring.resolve()))
    from bdmvkit import Disc, MenuButton, __version__
    from bdmvkit.encode import AudioTrack, encode_clip
    from bdmvkit import pgs
    from PIL import Image, ImageDraw, ImageFont

    if __version__ != "0.7.0":
        raise SystemExit("The fixture recipe requires bdmvkit 0.7.0")
    root = args.output.resolve()
    root.mkdir(parents=True, exist_ok=False)
    font = ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial.ttf", 44)

    def picture(name, size, color, text):
        image = Image.new("RGBA", size, color)
        ImageDraw.Draw(image).text((24, 20), text, fill="white", font=font)
        path = root / (name + ".png")
        image.save(path)
        return str(path)

    background = picture("menu", (1920, 1080), (15, 24, 36), "NetVplayer original HDMV research disc")
    normal = picture("normal", (640, 100), (45, 58, 78), "SELECT")
    selected = picture("selected", (640, 100), (190, 135, 10), "SELECTED")
    activated = picture("activated", (640, 100), (15, 150, 80), "ACTIVATED")
    # A fixed white PGS rectangle with known screen coordinates. The PG and IG
    # regions do not overlap, so disappearance/duplication can be inspected.
    pgs.write_sup(str(root / "original.sup"),
                  [(1, 14, (bytes([64]) * 600 * 64, 600, 64, 1000, 900),
                    pgs.palette("#ffffff", "#ffffff"))], (1920, 1080))
    command = ["ffmpeg", "-hide_banner", "-nostdin", "-v", "error",
               "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=24000/1001",
               "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000",
               "-f", "lavfi", "-i", "sine=frequency=660:sample_rate=48000",
               "-t", "16", "-map", "0:v", "-map", "1:a", "-map", "2:a",
               "-c:v", "libx264", "-preset", "ultrafast", "-crf", "23",
               "-c:a", "pcm_s16le", str(root / "original.mkv")]
    subprocess.run(command, check=True)
    clip = str(root / "feature.m2ts")
    encode_clip(str(root / "original.mkv"), clip, chapters=[0, 5, 10],
                audio=[AudioTrack(stream=0), AudioTrack(stream=1)],
                sups=[str(root / "original.sup")], fast=True)

    def button(key, x, y, action, **kw):
        return MenuButton(key, x, y, selected, activated, normal, action=action, **kw)

    def disc(timed=False):
        value = Disc(title_key="menu:main")
        value.add_title(clip, chapters=[0, 5, 10],
                        audio=[("ac3", 2, "en"), ("ac3", 2, "ja")],
                        subtitles=["en"], default_audio=1, default_subtitle=1,
                        end="menu:main")
        value.add_menu("main", background, [
            button("play", 180, 300, "title:1", nav={"down": "chapter"}),
            button("chapter", 180, 500, "chapter:1:2", nav={"up": "play"}),
        ], **({"loop": 1, "seconds": 5, "end": "title:1"} if timed else {}))
        value.add_popup(1, [
            button("audio", 180, 300, "audio:2", nav={"down": "suboff"}),
            button("suboff", 180, 500, "subtitle:off", nav={"up": "audio", "down": "home"}),
            button("home", 180, 700, "menu:main", nav={"up": "suboff"}),
        ])
        return value

    results = {}
    for name, timed in [("indefinite", False), ("timed", True)]:
        results[name] = disc(timed).write(str(root / name), fast=True)
    manifest = {"schema": 1, "authoringVersion": __version__, "kind": "original-authored-hdmv",
                "commercialDiscMatrixPassed": False, "command": command, "discs": results,
                "expected": {"featureSeconds": 16, "chapters": [0, 5, 10],
                             "audioPIDs": [4352, 4353], "pgPID": 4608,
                             "timedStillSeconds": 5, "angles": 1},
                "files": {str(p.relative_to(root)): {"bytes": p.stat().st_size,
                          "sha256": hashlib.sha256(p.read_bytes()).hexdigest()}
                          for p in sorted(root.rglob("*")) if p.is_file()}}
    (root / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(json.dumps(results))


if __name__ == "__main__":
    main()
