#!/usr/bin/env python3
"""Builds app/Council/AppIcon.xcassets from app/Icons/opencouncil-icon.png.

The source is a full-bleed 1024 square. macOS does not draw app icons full-bleed: the artwork sits on the
system icon grid — an 824x824 rounded body centred on a 1024 canvas — so a square source would stand in the
Dock as a hard-edged tile noticeably larger than everything beside it. This applies that grid and writes the
ten sizes an .appiconset needs.

It lives in its own catalog on purpose: make-icon-assets.py rebuilds Icons.xcassets with shutil.rmtree, which
would take the app icon with it.

    python3 app/Tools/make-app-icon.py
"""
import json
import pathlib
import sys

import numpy as np
from PIL import Image

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / "Icons" / "opencouncil-icon.png"
DST = ROOT / "Council" / "AppIcon.xcassets" / "AppIcon.appiconset"

# Apple's macOS icon grid, as ratios of the 1024 canvas: the body is 824 wide with a 185.4 corner radius.
BODY = 824 / 1024
RADIUS = 185.4 / 1024
SUPERSAMPLE = 4

# (points, scale) -> pixel size. Xcode wants every one of these for a macOS app icon.
SIZES = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]


def rounded_mask(size: int, radius: float) -> Image.Image:
    """An antialiased rounded-rectangle mask, rendered large and reduced so the corners stay smooth."""
    n = size * SUPERSAMPLE
    r = radius * SUPERSAMPLE
    ys, xs = np.mgrid[0:n, 0:n]
    # Distance from the rounded rectangle, measured only inside the corner quadrants.
    dx = np.maximum(np.maximum(r - 0.5 - xs, xs - (n - r - 0.5)), 0)
    dy = np.maximum(np.maximum(r - 0.5 - ys, ys - (n - r - 0.5)), 0)
    inside = np.hypot(dx, dy) <= r
    mask = Image.fromarray((inside * 255).astype(np.uint8))
    return mask.resize((size, size), Image.LANCZOS)


def master(source: Image.Image, canvas: int) -> Image.Image:
    """The artwork inset onto the icon grid at `canvas` pixels, corners rounded, everything else transparent."""
    body = max(1, round(canvas * BODY))
    art = source.resize((body, body), Image.LANCZOS)
    art.putalpha(rounded_mask(body, canvas * RADIUS))
    out = Image.new("RGBA", (canvas, canvas), (0, 0, 0, 0))
    out.paste(art, ((canvas - body) // 2, (canvas - body) // 2), art)
    return out


def main() -> int:
    if not SRC.exists():
        sys.exit(f"no source icon at {SRC}")
    source = Image.open(SRC).convert("RGBA")
    if source.width != source.height:
        sys.exit(f"{SRC.name} is {source.width}x{source.height}; the source must be square")

    DST.mkdir(parents=True, exist_ok=True)
    for stale in DST.glob("*.png"):
        stale.unlink()

    # Every size comes off one well-antialiased 1024 master, so the corner geometry cannot drift between them.
    top = master(source, 1024)
    images = []
    for points, scale in SIZES:
        pixels = points * scale
        name = f"icon_{points}x{points}{'@2x' if scale == 2 else ''}.png"
        img = top if pixels == 1024 else top.resize((pixels, pixels), Image.LANCZOS)
        img.save(DST / name)
        images.append({"filename": name, "idiom": "mac", "scale": f"{scale}x", "size": f"{points}x{points}"})
        print(f"{name:24} {pixels:>4}px")

    (DST / "Contents.json").write_text(
        json.dumps({"images": images, "info": {"author": "xcode", "version": 1}}, indent=2) + "\n")
    (DST.parent / "Contents.json").write_text(
        json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2) + "\n")
    print(f"\nwrote {DST.relative_to(ROOT.parent)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
