"""Key the light background out of the official RAVEN logo and preview it on dark."""
from PIL import Image

SRC = "/Users/ahmd/hybrid_messenger/assets/raven_mark.png"
im = Image.open(SRC).convert("RGBA")
w, h = im.size
px = im.load()

# diagnostics: min(r,g,b) across a grid
print("min(r,g,b) grid:")
for fy in (0.02, 0.10, 0.25, 0.5, 0.75, 0.90, 0.98):
    row = []
    for fx in (0.02, 0.10, 0.25, 0.5, 0.75, 0.90, 0.98):
        r, g, b, _ = px[int(fx * (w - 1)), int(fy * (h - 1))]
        row.append(min(r, g, b))
    print(" ", row)

LO_MIN, HI_MIN = 140, 203
out = Image.new("RGBA", (w, h))
op = out.load()
for y in range(h):
    for x in range(w):
        r, g, b, a = px[x, y]
        m = min(r, g, b)
        if m <= LO_MIN:
            na = 255
        elif m >= HI_MIN:
            na = 0
        else:
            na = int(255 * (HI_MIN - m) / (HI_MIN - LO_MIN))
        op[x, y] = (r, g, b, min(a, na))

mask = out.getchannel("A").point(lambda v: 255 if v > 14 else 0)  # ignore fringe
bbox = mask.getbbox()
out = out.crop(bbox)
out.save("raven_logo_clean.png")
print("bbox", bbox, "final", out.size)

# preview on dark
bg = Image.new("RGBA", out.size, (10, 11, 20, 255))
bg.alpha_composite(out)
bg.convert("RGB").save("logo_preview.png")
print("preview saved")
