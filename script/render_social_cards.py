#!/usr/bin/env python3
"""Compose social cards from reviewed screenshots; Pillow is required.

The layout belongs to the publication, while this renderer contains no account,
source, or release-specific data. Without --raw-dir it reuses sanitized assets.
"""

import argparse
import hashlib
import io
import json
from pathlib import Path

from PIL import Image, ImageCms, ImageDraw, ImageFilter, ImageFont, ImageOps


SIZE = (1242, 1656)
INK, MUTED, ACCENT = "#FAF7FF", "#C0B7D1", "#BCEEDC"
FONT = "/System/Library/Fonts/STHeiti Medium.ttc"
LATIN = "/System/Library/Fonts/Supplemental/Arial Bold.ttf"


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def basename(value):
    if not value or Path(value).name != value or value in {".", ".."}:
        raise ValueError(f"Expected a simple filename: {value!r}")
    return value


def checked_box(value, size):
    left, top, right, bottom = value
    if not (0 <= left < right <= size[0] and 0 <= top < bottom <= size[1]):
        raise ValueError(f"Box {value} exceeds {size}")
    return left, top, right, bottom


def sanitize(source, item):
    if digest(source) != item["source_sha256"]:
        raise ValueError(f"Capture changed: {source.name}")
    image = ImageOps.exif_transpose(Image.open(source)).convert("RGB")
    if profile := image.info.get("icc_profile"):
        image = ImageCms.profileToProfile(
            image, ImageCms.ImageCmsProfile(io.BytesIO(profile)),
            ImageCms.createProfile("sRGB"), outputMode="RGB")
    for region in item.get("redactions", []):
        box = checked_box(region["box"], image.size)
        if region["mode"] == "blur":
            patch = image.crop(box).filter(ImageFilter.GaussianBlur(region["radius"]))
            image.paste(patch, box[:2])
        elif region["mode"] == "solid":
            ImageDraw.Draw(image).rectangle(box, fill=region["color"])
        else:
            raise ValueError("Unknown redaction mode")
    result = image.crop(checked_box(item["crop"], image.size))
    result.info.clear()
    return result


def font(size, latin=False):
    return ImageFont.truetype(LATIN if latin else FONT, size)


def text(draw, xy, value, size, color=INK, latin=False):
    x, y = xy
    for line in value.split("\n"):
        if draw.textlength(line, font=font(size, latin)) > SIZE[0] - x - 64:
            raise ValueError(f"Text overflows card: {line}")
        draw.text((x, y), line, font=font(size, latin), fill=color)
        y += int(size * 1.25)
    return y


def screenshot(card, image, frame):
    left, top, right, bottom = frame
    fitted = ImageOps.contain(image, (right-left, bottom-top), Image.Resampling.LANCZOS)
    x, y = left+(right-left-fitted.width)//2, top+(bottom-top-fitted.height)//2
    mask = Image.new("L", fitted.size)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, fitted.width-1, fitted.height-1), 22, fill=255)
    card.paste(fitted, (x, y), mask)


def compose(spec, entry, assets, index):
    card = Image.new("RGB", SIZE)
    draw = ImageDraw.Draw(card)
    for y in range(SIZE[1]):
        t = y / SIZE[1]
        draw.line((0, y, SIZE[0], y), fill=(int(28+15*t), int(23+8*t), int(48+19*t)))
    draw.ellipse((870, -180, 1450, 400), fill="#352B52")
    text(draw, (64, 60), spec["brand"], 29, ACCENT, True)
    draw.text((930, 65), spec["version_label"], font=font(26), fill=MUTED)
    text(draw, (66, 161), entry["eyebrow"], 30, ACCENT)
    text(draw, (60, 233), entry["title"], entry.get("title_size", 88))
    text(draw, (65, 477), entry["subtitle"], 33, MUTED)
    frames = entry.get("frames", [[48, 573, 1194, 1195]] if entry.get("assets") else [])
    for name, frame in zip(entry.get("assets", []), frames, strict=True):
        with Image.open(assets/name) as image:
            screenshot(card, image.convert("RGB"), frame)
    draw = ImageDraw.Draw(card)
    if entry.get("caption"):
        text(draw, (66, 1214), entry["caption"], 23, MUTED)
    for row, item in enumerate(entry["notes"]):
        y = entry.get("notes_y", 1276)+row*entry.get("note_gap", 83)
        draw.rounded_rectangle((65, y+8, 75, y+42), 4, fill=ACCENT)
        text(draw, (95, y), item, entry.get("note_size", 34))
    text(draw, (66, 1500), entry["condition"], 24, MUTED)
    draw.line((65, 1560, 1176, 1560), fill="#5A4C6B", width=2)
    text(draw, (65, 1590), "macOS 14+ · Apple Silicon", 25, MUTED)
    draw.text((1050, 1588), f"{index:02d} / {len(spec['cards']):02d}", font=font(25, True), fill=ACCENT)
    return card


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("layout", type=Path)
    parser.add_argument("--raw-dir", type=Path)
    args = parser.parse_args()
    root = args.layout.resolve().parent
    spec = json.loads(args.layout.read_text())
    assets, cards = root/"assets", root/"cards"
    assets.mkdir(exist_ok=True)
    cards.mkdir(exist_ok=True)
    if args.raw_dir:
        for item in spec["captures"]:
            sanitize(args.raw_dir/basename(item["source"]), item).save(assets/basename(item["file"]))
    records = []
    for index, entry in enumerate(spec["cards"], 1):
        entry["assets"] = [basename(name) for name in entry.get("assets", [])]
        card = compose(spec, entry, assets, index)
        path = cards/basename(entry["file"])
        card.save(path)
        records.append({"path": str(path.relative_to(root)), "sha256": digest(path), "size": list(card.size)})
    preview = Image.new("RGB", (1240, 414*((len(records)+3)//4)), "#1C1730")
    for index, record in enumerate(records):
        with Image.open(root/record["path"]) as image:
            preview.paste(image.resize((310, 414), Image.Resampling.LANCZOS), ((index%4)*310, (index//4)*414))
    preview.save(root/"preview.jpg", quality=93)
    manifest = {"version": spec["version_label"], "cards": records,
                "assets": [{"path": str(p.relative_to(root)), "sha256": digest(p)} for p in sorted(assets.glob("*.png"))],
                "preview_sha256": digest(root/"preview.jpg")}
    (root/"images.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2)+"\n")
    print(f"Rendered {len(records)} cards, {SIZE[0]} × {SIZE[1]} pixels")


if __name__ == "__main__":
    main()
