#!/usr/bin/env python3
"""Build Assets.xcassets/AppIcon.appiconset from one square source PNG.

Usage: scripts/make-appicon.py source.png
Applies the macOS Big Sur squircle (artwork on 824/1024 of the canvas, transparent margin).
"""
import json, os, sys
from PIL import Image, ImageChops, ImageDraw

SRC = sys.argv[1]
OUT = os.path.join(os.path.dirname(__file__), "..", "LocalFlow", "Resources", "Assets.xcassets", "AppIcon.appiconset")
SIZES = [16, 32, 128, 256, 512]
CANVAS, ART, RADIUS = 1024, 824, 185


def squircle(size, radius, supersample=4):
    s = size * supersample
    m = Image.new("L", (s, s), 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, s - 1, s - 1], radius=radius * supersample, fill=255)
    return m.resize((size, size), Image.LANCZOS)


art = Image.open(SRC).convert("RGBA").resize((ART, ART), Image.LANCZOS)
art.putalpha(ImageChops.multiply(art.getchannel("A"), squircle(ART, RADIUS)))
master = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
master.paste(art, ((CANVAS - ART) // 2, (CANVAS - ART) // 2), art)

os.makedirs(OUT, exist_ok=True)
images = []
for base in SIZES:
    for scale in (1, 2):
        px = base * scale
        name = f"icon_{base}x{base}@{scale}x.png"
        master.resize((px, px), Image.LANCZOS).save(os.path.join(OUT, name))
        images.append({"filename": name, "idiom": "mac", "scale": f"{scale}x", "size": f"{base}x{base}"})
json.dump({"images": images, "info": {"author": "xcode", "version": 1}}, open(os.path.join(OUT, "Contents.json"), "w"), indent=2)
json.dump({"info": {"author": "xcode", "version": 1}}, open(os.path.join(OUT, "..", "Contents.json"), "w"), indent=2)
print(f"wrote {len(images)} images to {os.path.relpath(OUT)}")
