#!/usr/bin/env python3
"""Draws Ribbon's pixel-art icon on a 32x32 grid and writes Resources/AppIcon.icns
(every size scaled with nearest-neighbor so pixels stay crisp) plus a preview PNG.
Run: python3 scripts/make_icon.py  (needs Pillow)"""
import math
import pathlib
from PIL import Image

N = 32
OUT = pathlib.Path(__file__).resolve().parent.parent / "Resources"

C = {k: tuple(int(v[i:i + 2], 16) for i in (1, 3, 5)) + (255,) for k, v in {
    "ink": "#0e0a1f",
    "bg0": "#43308a", "bg1": "#32246b", "bg2": "#231a50", "bg3": "#160f36",
    "rim": "#6a55c2",
    "ring": "#f5f0ff", "ringS": "#c4b8ea",
    "red": "#ff3355", "redD": "#c21d40", "redH": "#ff94a8",
    "tealL": "#5ff0de", "teal": "#2cc2b2", "tealD": "#17807a",
    "star": "#ffffff", "starD": "#a99cf0",
}.items()}

img = Image.new("RGBA", (N, N), (0, 0, 0, 0))
px = img.load()


def in_body(x, y, lo=3, hi=28, r=4.0):
    if not (lo <= x <= hi and lo <= y <= hi):
        return False
    cx = min(max(x, lo + r), hi - r)
    cy = min(max(y, lo + r), hi - r)
    return math.hypot(x - cx, y - cy) <= r + 0.01


# Background: 4-band vertical gradient with 2x2 Bayer dithering between bands.
bayer = [[0.125, 0.625], [0.875, 0.375]]
bands = ["bg0", "bg1", "bg2", "bg3"]
for y in range(N):
    for x in range(N):
        if not in_body(x, y):
            continue
        t = (y - 3) / 25 * (len(bands) - 1)
        i = int(t) + (1 if (t - int(t)) > bayer[y % 2][x % 2] else 0)
        px[x, y] = C[bands[min(i, len(bands) - 1)]]

# Outline and top rim light.
for y in range(N):
    for x in range(N):
        if in_body(x, y) and not all(in_body(x + dx, y + dy) for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1))):
            px[x, y] = C["ink"]
for y in range(N):
    for x in range(N):
        if in_body(x, y) and px[x, y] != C["ink"] and (
                (y < 9 and px[x, y - 1] == C["ink"]) or (y < 15 and px[x - 1, y] == C["ink"])):
            px[x, y] = C["rim"]

# Sparkles.
for (sx, sy) in ((7, 7), (25, 24)):
    px[sx, sy] = C["star"]
    for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
        px[sx + dx, sy + dy] = C["starD"]

# Ribbon tails (rosette), drawn behind the record button.
cx, cy = 15.5, 12.5
tails = {}
for y in range(15, 26):
    shift = (y - 15) // 3
    for x in range(11 - shift, 15 - shift):          # left tail
        tails[(x, y)] = x - (11 - shift)
    for x in range(17 + shift, 21 + shift):          # right tail (mirror)
        tails[(x, y)] = (20 + shift) - x
# V-notch at the bottom of each tail.
for (x, y) in list(tails):
    if y == 25 and tails[(x, y)] in (1, 2):
        del tails[(x, y)]

circle = {(x, y) for y in range(N) for x in range(N) if math.hypot(x - cx, y - cy) <= 6.8}
shape = set(tails) | circle
for (x, y) in shape:
    for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
        p = (x + dx, y + dy)
        if p not in shape and in_body(*p):
            px[p] = C["ink"]
for (x, y), col in tails.items():
    px[x, y] = C["tealL"] if col == 0 else C["tealD"] if col >= 3 else C["teal"]

# Record button: light ring, red core, shading and a highlight.
for (x, y) in circle:
    d = math.hypot(x - cx, y - cy)
    if d > 5.1:
        px[x, y] = C["ringS"] if (x - cx) + (y - cy) > 4 else C["ring"]
    elif d > 4.2 and (x - cx) + (y - cy) > 2.5:
        px[x, y] = C["redD"]
    else:
        px[x, y] = C["red"]
for (x, y) in ((13, 10), (14, 10), (13, 11)):
    px[x, y] = C["redH"]

OUT.mkdir(exist_ok=True)
big = img.resize((1024, 1024), Image.Resampling.NEAREST)
big.save(OUT / "AppIcon-preview.png")
sizes = [img.resize((s, s), Image.Resampling.NEAREST) for s in (512, 256, 128, 64, 32)]
sizes.append(img.resize((16, 16), Image.Resampling.BOX))
big.save(OUT / "AppIcon.icns", append_images=sizes)
print("wrote", OUT / "AppIcon.icns")
