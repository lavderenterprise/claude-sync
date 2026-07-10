#!/usr/bin/env python3
"""Compose AppIcon.icns from the "Claude Sync.icon" source bundle.

The .icon bundle (Apple Icon Composer format) stores only the raw white logo layer plus a
JSON recipe. This script reproduces that recipe as a flat, self-contained macOS icon:

    dark rounded-square tile  +  white logo centered at 40% scale

then emits every size an .iconset needs and runs iconutil to produce AppIcon.icns.

Run from the repo root:  python3 Icon/make_icon.py
"""

import json
import os
import subprocess
import sys
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
SOURCE = os.path.join(HERE, "Claude Sync.icon")
OUT_ICNS = os.path.join(HERE, "AppIcon.icns")

MASTER = 1024              # master canvas; every size is downscaled from this
TILE_MARGIN = 0.045        # transparent margin around the tile, as a fraction of the canvas
CORNER_RATIO = 0.2237      # Apple's rounded-rect corner radius, relative to the tile size
LOGO_SCALE = 0.40          # logo bounding box as a fraction of the canvas (from icon.json)


def p3_to_rgb8(triplet):
    """The recipe stores the fill in display-p3. For a near-black tile the gamut difference is
    imperceptible, so a straight 0–1 → 0–255 mapping is faithful enough."""
    return tuple(round(c * 255) for c in triplet)


def read_recipe():
    with open(os.path.join(SOURCE, "icon.json")) as fh:
        spec = json.load(fh)
    layer = spec["groups"][0]["layers"][0]
    fill = layer["fill"]["solid"]                      # e.g. "display-p3:0.067,0.068,0.075,1.0"
    comps = [float(x) for x in fill.split(":")[1].split(",")]
    bg = p3_to_rgb8(comps[:3])
    logo_name = layer["image-name"]
    scale = layer.get("position", {}).get("scale", LOGO_SCALE)
    return bg, os.path.join(SOURCE, "Assets", logo_name), scale


def compose(bg, logo_path, scale):
    canvas = Image.new("RGBA", (MASTER, MASTER), (0, 0, 0, 0))

    # Rounded-square tile.
    margin = round(MASTER * TILE_MARGIN)
    tile_size = MASTER - 2 * margin
    radius = round(tile_size * CORNER_RATIO)
    tile = Image.new("RGBA", (tile_size, tile_size), (0, 0, 0, 0))
    ImageDraw.Draw(tile).rounded_rectangle(
        [0, 0, tile_size - 1, tile_size - 1], radius=radius, fill=(*bg, 255)
    )
    canvas.alpha_composite(tile, (margin, margin))

    # White logo, centered, at the recipe's scale.
    logo = Image.open(logo_path).convert("RGBA")
    target = round(MASTER * scale)
    logo.thumbnail((target, target), Image.LANCZOS)
    pos = ((MASTER - logo.width) // 2, (MASTER - logo.height) // 2)
    canvas.alpha_composite(logo, pos)
    return canvas


def build_iconset(master_img):
    iconset = os.path.join(HERE, "AppIcon.iconset")
    os.makedirs(iconset, exist_ok=True)
    # (point size, scale) -> filename, per Apple's iconset naming.
    specs = [
        (16, 1), (16, 2), (32, 1), (32, 2), (128, 1),
        (128, 2), (256, 1), (256, 2), (512, 1), (512, 2),
    ]
    for pt, sc in specs:
        px = pt * sc
        name = f"icon_{pt}x{pt}{'@2x' if sc == 2 else ''}.png"
        master_img.resize((px, px), Image.LANCZOS).save(os.path.join(iconset, name))
    return iconset


def main():
    if not os.path.isdir(SOURCE):
        sys.exit(f"Source icon bundle not found: {SOURCE}")
    bg, logo_path, scale = read_recipe()
    master = compose(bg, logo_path, scale)
    iconset = build_iconset(master)
    subprocess.run(["iconutil", "-c", "icns", iconset, "-o", OUT_ICNS], check=True)
    print(f"Wrote {OUT_ICNS}")


if __name__ == "__main__":
    main()
