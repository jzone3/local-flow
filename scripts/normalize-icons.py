#!/usr/bin/env python3
"""raw/*.png (black glyph on white) -> template imagesets in Assets.xcassets. Uniform optical size: glyph bbox fit into 76% of the box."""
import os, json, sys, glob
from PIL import Image, ImageOps
OUT = os.path.join(os.path.dirname(__file__), "..", "LocalFlow", "Resources", "Assets.xcassets", "Icons")
BOX = 128  # @2x pixel size of a 64pt asset
FIT = 0.76
os.makedirs(OUT, exist_ok=True)
json.dump({"info": {"author": "xcode", "version": 1}, "properties": {"provides-namespace": False}}, open(f"{OUT}/Contents.json", "w"), indent=2)
names = sys.argv[1:] or [os.path.basename(p)[:-4] for p in glob.glob("raw/*.png")]
for name in names:
    im = Image.open(f"raw/{name}.png").convert("L")
    alpha = ImageOps.invert(im).point(lambda v: 0 if v < 90 else (255 if v > 215 else int((v - 90) * 255 / 125)))
    bbox = alpha.getbbox()
    if not bbox: print("EMPTY", name); continue
    glyph = alpha.crop(bbox)
    w, h = glyph.size
    scale = (BOX * FIT) / max(w, h)
    glyph = glyph.resize((max(1, round(w * scale)), max(1, round(h * scale))), Image.LANCZOS)
    canvas = Image.new("L", (BOX, BOX), 0)
    canvas.paste(glyph, ((BOX - glyph.width) // 2, (BOX - glyph.height) // 2))
    rgba = Image.merge("RGBA", (Image.new("L", (BOX, BOX), 0),) * 3 + (canvas,))
    d = f"{OUT}/{name}.imageset"; os.makedirs(d, exist_ok=True)
    rgba.save(f"{d}/{name}@2x.png")
    rgba.resize((BOX // 2, BOX // 2), Image.LANCZOS).save(f"{d}/{name}@1x.png")
    json.dump({"images": [{"filename": f"{name}@1x.png", "idiom": "universal", "scale": "1x"}, {"filename": f"{name}@2x.png", "idiom": "universal", "scale": "2x"}],
               "info": {"author": "xcode", "version": 1}, "properties": {"template-rendering-intent": "template", "preserves-vector-representation": False}},
              open(f"{d}/Contents.json", "w"), indent=2)
    print("ok", name, bbox)
