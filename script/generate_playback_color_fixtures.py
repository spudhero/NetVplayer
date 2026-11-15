#!/usr/bin/env python3
"""AV-02 lossless YUV charts and a fixed CPU reference, independent of mpv.

Reference: BT.709/2020 NCL matrix and ranges, BT.1886, ST.2084, BT.2100
HLG (1000 nit OOTF), BT.2390 EETF (zero black, 203 nit destination), sRGB.
The BT.2390 knee is the original 0.5 convention used by mpv 0.41 vo_gpu.
No display luminance or physical color accuracy is inferred from these files.
"""
import argparse
from array import array
import hashlib
import json
import math
from pathlib import Path
import shutil
import subprocess
import struct
import sys
import zlib

M1, M2 = 2610 / 16384, 2523 / 32
C1, C2, C3 = 3424 / 4096, 2413 / 128, 2392 / 128
WIDTH, HEIGHT, COLUMNS, ROWS = 640, 360, 8, 4


def pq_encode(nits):
    value = max(0, nits / 10000) ** M1
    return ((C1 + C2 * value) / (1 + C3 * value)) ** M2


def pq_decode(signal):
    value = max(0, signal) ** (1 / M2)
    return (max(0, value - C1) / (C2 - C3 * value)) ** (1 / M1) * 10000


def bt2390(nits, source_peak, target_peak=203):
    source_pq = pq_encode(source_peak)
    value = pq_encode(min(nits, source_peak)) / source_pq
    maximum = pq_encode(target_peak) / source_pq
    knee = 1.5 * maximum - 0.5
    if value >= knee:
        t = (value - knee) / (1 - knee)
        value = (2*t**3 - 3*t**2 + 1)*knee + (t**3 - 2*t**2 + t)*(1-knee) + (-2*t**3 + 3*t**2)*maximum
    return pq_decode(value * source_pq)


def srgb_encode(linear):
    linear = min(1, max(0, linear))
    return 12.92 * linear if linear <= 0.0031308 else 1.055 * linear ** (1 / 2.4) - 0.055


def yuv(rgb, matrix, limited):
    kr, kb = (0.2126, 0.0722) if matrix == "bt709" else (0.2627, 0.0593)
    r, g, b = rgb
    y = kr*r + (1-kr-kb)*g + kb*b
    cb, cr = (b-y)/(2*(1-kb)), (r-y)/(2*(1-kr))
    return [round(64+876*y), round(512+896*cb), round(512+896*cr)] if limited else [round(1023*y), round(512+1023*cb), round(512+1023*cr)]


def reference(codes, matrix, limited, transfer, output_linear=False):
    y, cb, cr = codes
    y = (y-64)/876 if limited else y/1023
    cb, cr = (cb-512)/(896 if limited else 1023), (cr-512)/(896 if limited else 1023)
    kr, kb = (0.2126, 0.0722) if matrix == "bt709" else (0.2627, 0.0593)
    r, b = y+2*(1-kr)*cr, y+2*(1-kb)*cb
    g = (y-kr*r-kb*b)/(1-kr-kb)
    signal = [max(0, min(1, c)) for c in [r, g, b]]
    if transfer == "smpte2084":
        linear = [pq_decode(c)/203 for c in signal]
        peak = 10000
    elif transfer == "arib-std-b67":
        # BT.2100 inverse OETF and scene-to-display OOTF, 1000 nit reference.
        scene = [c*c/3 if c <= .5 else (math.exp((c-.55991073)/.17883277)+.28466892)/12 for c in signal]
        luma = .2627*scene[0] + .678*scene[1] + .0593*scene[2]
        linear = [1000/203 * c * luma**.2 for c in scene]
        peak = 1000
    else:
        linear = [c**2.4 for c in signal]
        peak = 203
    if peak > 203:
        old = max(linear)
        if old > 0:
            mapped = [bt2390(c*203, peak)/203 for c in linear]
            new = max(mapped)
            # mpv's fixed highlight desaturation, operating after the EETF.
            coefficient = .9 * (max(new-.18, 1e-6)/max(new, 1))**.2
            linear = [(1-coefficient)*c*new/old + coefficient*m for c, m in zip(linear, mapped)]
    if matrix == "bt2020nc":
        # BT.2020 D65 -> BT.709 D65 in linear light, relative colorimetric.
        r, g, b = linear
        linear = [1.660491*r-.587641*g-.072850*b, -.124550*r+1.132900*g-.008349*b, -.018151*r-.100579*g+1.118730*b]
    return linear if output_linear else [srgb_encode(c) for c in linear]


def overlays(folder):
    """Original ASS vectors, PGS bitmap and sRGB artwork; no third-party media."""
    colors = ["FFFFFF", "808080", "0000FF", "00FF00"]  # ASS BGR
    header = """[Script Info]
ScriptType: v4.00+
PlayResX: 640
PlayResY: 360
YCbCr Matrix: None
[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,Arial,24,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,0,0,7,0,0,0,1
[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
"""
    events = [f"Dialogue: 0,0:00:00.00,0:00:12.00,Default,,0,0,0,,{{\\an7\\pos({10+64*i},10)\\bord0\\shad0\\1c&H{color}&\\p1}}m 0 0 l 64 0 64 60 0 60{{\\p0}}\n"
              for i, color in enumerate(colors)]
    events.append("Dialogue: 1,0:00:00.00,0:00:12.00,Default,,0,0,0,,{\\pos(10,90)\\bord2}ASS white / near-black readability\n")
    (folder/"color-overlay.ass").write_text(header+"".join(events))

    def segment(kind, payload, pts=0):
        return b"PG" + struct.pack(">IIBH", pts, 0, kind, len(payload)) + payload

    # PGS presentation/window/palette/object/end segments. A 360-line palette
    # uses BT.601 limited YCbCr per the decoder's documented SD convention.
    pcs = struct.pack(">HHBHBBBBHBBHH", WIDTH, HEIGHT, 0x10, 0, 0x80, 0, 0, 1, 0, 0, 0, 10, 10)
    wds = struct.pack(">BBHHHH", 1, 0, 10, 10, 256, 60)
    palette = bytes([0, 0, 1,235,128,128,255, 2,126,128,128,255,
                     3,81,240,90,255, 4,145,34,54,255])
    row = bytes([1])*64 + bytes([2])*64 + bytes([3])*64 + bytes([4])*64 + b"\0\0"
    rle = row*60
    ods = struct.pack(">HBB", 0, 0, 0xC0) + (len(rle)+4).to_bytes(3,"big") + struct.pack(">HH",256,60) + rle
    clear = struct.pack(">HHBHBBBB", WIDTH, HEIGHT, 0x10, 1, 0, 0, 0, 0)
    (folder/"color-overlay.sup").write_bytes(segment(0x16,pcs)+segment(0x17,wds)+segment(0x14,palette)
                                           +segment(0x15,ods)+segment(0x80,b"")
                                           +segment(0x16,clear,12*90000)+segment(0x80,b"",12*90000))

    def chunk(kind, payload):
        return struct.pack(">I",len(payload))+kind+payload+struct.pack(">I",zlib.crc32(kind+payload))
    rgb = [(255,255,255), (128,128,128), (255,0,0), (0,255,0)]
    pixels = b"".join(b"\0" + b"".join(bytes(rgb[x//160]) for x in range(WIDTH)) for _ in range(HEIGHT))
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR",struct.pack(">IIBBBBB",WIDTH,HEIGHT,8,2,0,0,0))
    png += chunk(b"sRGB",b"\0") + chunk(b"IDAT",zlib.compress(pixels)) + chunk(b"IEND",b"")
    (folder/"color-artwork.png").write_bytes(png)
    files = ["color-overlay.ass", "color-overlay.sup", "color-artwork.png"]
    for stem in ["sdr-limited", "pq", "hlg"]:
        if not (folder/(stem+".mkv")).is_file():
            continue
        output = folder/(stem+"-pgs.mkv")
        subprocess.run([shutil.which("ffmpeg"), "-hide_banner", "-loglevel", "error", "-i", str(folder/(stem+".mkv")),
                        "-i", str(folder/"color-overlay.sup"), "-map", "0:v", "-map", "1:0", "-c", "copy", "-y", str(output)], check=True)
        files.append(output.name)
    (folder/"overlay-manifest.json").write_text(json.dumps({
        "origin": "Original synthetic vectors, PGS bitmap and sRGB PNG; no third-party media",
        "files": [{"file": name, "sha256": hashlib.sha256((folder/name).read_bytes()).hexdigest()} for name in files]
    }, indent=2)+"\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--overlays-only", action="store_true", help="Add original overlays to an existing chart directory")
    args = parser.parse_args()
    ffmpeg, ffprobe = shutil.which("ffmpeg"), shutil.which("ffprobe")
    if not ffmpeg or not ffprobe:
        parser.error("ffmpeg and ffprobe are required")
    folder = args.output_dir
    folder.mkdir(parents=True, exist_ok=True)
    if args.overlays_only:
        overlays(folder)
        return
    levels = [0, .004, .01, .02, .04, .06, .1, .18, .25, .35, .5, .65, .75, .85, .95, 1]
    colors = [(c, c, c) for c in levels] + [
        (.7,.5,.4), (.5,.35,.3), (.3,.5,.7), (.3,.6,.4), (.7,.4,.5), (.6,.6,.3), (.4,.4,.7), (.65,.5,.4),
        (.4,.6,.6), (.6,.4,.6), (.55,.6,.5), (.5,.55,.6), (.6,.5,.55), (.8,.7,.65), (.4,.3,.25), (.25,.3,.4)
    ]
    manifest = {"version": 1, "width": WIDTH, "height": HEIGHT,
                "reference": "BT.2390 zero black / 203 nit / D65 sRGB; PQ 10000 nit, HLG 1000 nit OOTF",
                "toleranceLSB": 4, "displayToleranceLSB": 6, "samples": []}
    variants = [("sdr-limited", "bt709", True, "bt709"), ("sdr-full", "bt709", False, "bt709"),
                ("sdr-2020", "bt2020nc", True, "bt709"), ("pq", "bt2020nc", True, "smpte2084"),
                ("hlg", "bt2020nc", True, "arib-std-b67")]
    for name, matrix, limited, transfer in variants:
        output = folder/(name+".mkv")
        codes = [yuv(rgb, matrix, limited) for rgb in colors]
        frame = array("H")
        for channel in range(3):
            for row in range(HEIGHT):
                for column in range(WIDTH):
                    frame.append(codes[(row//90)*COLUMNS + column//80][channel])
        if sys.byteorder != "little":
            frame.byteswap()
        tags = ["-color_range", "tv" if limited else "pc", "-colorspace", matrix,
                "-color_primaries", "bt709" if matrix == "bt709" else "bt2020", "-color_trc", transfer]
        command = [ffmpeg, "-hide_banner", "-loglevel", "error", "-f", "rawvideo", "-pix_fmt", "yuv444p10le",
                   "-s", f"{WIDTH}x{HEIGHT}", "-r", "1", *tags, "-i", "pipe:0", "-vf", "loop=loop=11:size=1:start=0",
                   "-frames:v", "12", "-c:v", "libx265", "-x265-params",
                   "log-level=error:pools=2:lossless=1:keyint=1:colorprim=" + ("1" if matrix == "bt709" else "9")
                   + ":transfer=" + {"bt709": "1", "smpte2084": "16", "arib-std-b67": "18"}[transfer]
                   + ":colormatrix=" + ("1" if matrix == "bt709" else "9") + ":range=" + ("limited" if limited else "full"),
                   *tags, "-n", str(output)]
        subprocess.run(command, input=frame.tobytes(), check=True)
        probe = json.loads(subprocess.check_output([ffprobe, "-v", "error", "-show_streams", "-of", "json", str(output)], text=True))
        first_frame = json.loads(subprocess.check_output([ffprobe, "-v", "error", "-read_intervals", "%+#1", "-show_frames", "-of", "json", str(output)], text=True))["frames"][0]
        assert first_frame["color_space"] == matrix
        assert first_frame["color_transfer"] == transfer
        assert first_frame["color_primaries"] == ("bt709" if matrix == "bt709" else "bt2020")
        decoded = subprocess.check_output([ffmpeg, "-v", "error", "-i", str(output), "-frames:v", "1", "-f", "rawvideo", "-pix_fmt", "yuv444p10le", "pipe:1"])
        assert decoded == frame.tobytes(), "Decoded YUV must match the fixed reference exactly"
        patches = [{"x": (i%8)*80+40, "y": (i//8)*90+45, "yuv": c,
                    "srgb": reference(c, matrix, limited, transfer),
                    "linearSRGB": reference(c, matrix, limited, transfer, output_linear=True)} for i, c in enumerate(codes)]
        manifest["samples"].append({"file": output.name, "sha256": hashlib.sha256(output.read_bytes()).hexdigest(),
                                    "matrix": matrix, "limited": limited, "transfer": transfer,
                                    "patches": patches, "probe": probe, "firstFrame": first_frame,
                                    "decodedYUVMatchesReference": True})
        pixels = bytearray()
        for row in range(HEIGHT):
            for col in range(WIDTH):
                pixels.extend(round(v*255) for v in patches[(row//90)*8+col//80]["srgb"])
        ppm = folder/(name+"-reference.ppm")
        ppm.write_bytes(f"P6\n{WIDTH} {HEIGHT}\n255\n".encode()+pixels)
        subprocess.run([ffmpeg, "-hide_banner", "-loglevel", "error", "-i", str(ppm), "-frames:v", "1", "-n", str(folder/(name+"-reference.png"))], check=True)
        ppm.unlink()
    (folder/"manifest.json").write_text(json.dumps(manifest, indent=2)+"\n")
    overlays(folder)
    print(f"Generated {len(variants)} lossless charts and fixed references in {folder}")


if __name__ == "__main__":
    main()
