#!/usr/bin/env python3
"""Render the DMG Finder-window background (dmg/background.png and dmg/background@2x.png).

The window is WIDTH x HEIGHT points (see scripts/build-dmg.sh, which positions the app icon and the
Applications link on either side of the arrow drawn here). Dark ASCII field (same look as the share card
and launch video) with a translucent white card behind each icon: Finder always draws icon labels in black, so the
cards are what keep "Local Flow" / "Applications" readable; a white arrow sits between them.
"""
import os
import random
from PIL import Image, ImageDraw, ImageFont

WIDTH, HEIGHT = 660, 400
ARROW_Y = 180          # vertical centre of the icons (build-dmg.sh uses the same value)
ARROW_LEN, HEAD, STROKE = 56, 12, 2
BG = (13, 13, 13)
# Two translucent white cards, one per icon (128pt icon + Finder label inside); the arrow sits between them.
CARDS = [(75, 100, 255, 288), (405, 100, 585, 288)]
CARD_RADIUS = 14
CARD_ALPHA = 224
ARROW_COLOR = "white"
CW, CH = 9, 14         # glyph cell (points)
RAMP = ". . . : : - = + * # % @ 8 0 B M".split()
OUT = os.path.join(os.path.dirname(__file__), "..", "dmg")
FONT = "/System/Library/Fonts/Menlo.ttc"


def value_noise(cols, rows, seed, cell=6):
    """Smooth 0..1 noise: random lattice, bicubic-upsampled."""
    rnd = random.Random(seed)
    gw, gh = cols // cell + 2, rows // cell + 2
    lat = Image.new("F", (gw, gh))
    lat.putdata([rnd.random() for _ in range(gw * gh)])
    return lat.resize((cols, rows), Image.BICUBIC)


def render(scale):
    img = Image.new("RGB", (WIDTH * scale, HEIGHT * scale), BG)
    d = ImageDraw.Draw(img)
    font = ImageFont.truetype(FONT, int(10 * scale), index=1)  # Menlo Bold
    cols, rows = WIDTH // CW + 1, HEIGHT // CH + 1
    n1, n2 = value_noise(cols, rows, 7), value_noise(cols, rows, 11, cell=3)
    jitter = random.Random(3)
    for r in range(rows):
        for c in range(cols):
            n = 0.65 * n1.getpixel((c, r)) + 0.35 * n2.getpixel((c, r))
            n = max(0.0, min(1.0, (n - 0.5) * 1.6 + 0.5))
            dens = n * 0.5 if n < 0.5 else 0.25 + (n - 0.5) * 1.5
            if jitter.random() > min(1.0, dens) * 0.55 + 0.02:
                continue
            ch = RAMP[min(len(RAMP) - 1, int(n * len(RAMP)))]
            x, y = c * CW, r * CH
            a = 0.10 + 0.32 * n
            v = int(13 + a * 150)
            d.text((x * scale, y * scale), ch, font=font, fill=(v, v, v))
    overlay = Image.new("RGBA", img.size, (0, 0, 0, 0))
    od = ImageDraw.Draw(overlay)
    for card in CARDS:
        od.rounded_rectangle([v * scale for v in card], radius=CARD_RADIUS * scale, fill=(255, 255, 255, CARD_ALPHA))
    img = Image.alpha_composite(img.convert("RGBA"), overlay).convert("RGB")
    d = ImageDraw.Draw(img)
    cx, cy = WIDTH / 2, ARROW_Y
    x0, x1 = (cx - ARROW_LEN / 2) * scale, (cx + ARROW_LEN / 2) * scale
    y, w = cy * scale, STROKE * scale
    for pts in ([(x0, y), (x1, y)], [(x1 - HEAD * scale, y - HEAD * scale), (x1, y)], [(x1 - HEAD * scale, y + HEAD * scale), (x1, y)]):
        d.line(pts, fill=ARROW_COLOR, width=w, joint="curve")
    d.ellipse([x1 - w / 2, y - w / 2, x1 + w / 2, y + w / 2], fill=ARROW_COLOR)
    return img


os.makedirs(OUT, exist_ok=True)
render(1).save(os.path.join(OUT, "background.png"))
render(2).save(os.path.join(OUT, "background@2x.png"))
print(f"wrote dmg/background.png ({WIDTH}x{HEIGHT}) and dmg/background@2x.png")
