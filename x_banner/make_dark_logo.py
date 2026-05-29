"""Build the dark-mode RAVEN logo tile: the line-art raven on a deep
navy field with a soft violet glow — the dark counterpart of the
pale-mint light logo. Output 1024x1024 to match RavenLogo.png."""
import math
from PIL import Image, ImageFilter, ImageEnhance

W = 1024
raven = Image.open("raven_logo_clean.png").convert("RGBA")   # transparent line-art raven
rw, rh = raven.size
POS = (max(0, (W - rw) // 2), W - rh)                        # bottom-aligned, matches light tile

# --- deep navy base ---
base = Image.new("RGBA", (W, W), (12, 15, 26, 255))

# --- soft radial violet glow (small gradient, upscaled = smooth + fast) ---
g = 168
small = Image.new("L", (g, g), 0)
sp = small.load()
for y in range(g):
    for x in range(g):
        d = math.hypot(x - g / 2, y - g / 2) / (g / 2)
        t = max(0.0, 1.0 - d)
        sp[x, y] = int((t ** 1.7) * 255)
glow_l = small.resize((W, W))
glow = Image.new("RGBA", (W, W), (108, 94, 222, 0))
glow.putalpha(glow_l.point(lambda v: int(v * 0.42)))
base.alpha_composite(glow)

# --- soft halo hugging the raven strokes ---
alpha = raven.getchannel("A")
halo_mask = alpha.filter(ImageFilter.GaussianBlur(22))
halo = Image.new("RGBA", raven.size, (138, 168, 255, 0))
halo.putalpha(halo_mask.point(lambda v: int(v * 0.5)))
halo_canvas = Image.new("RGBA", (W, W), (0, 0, 0, 0))
halo_canvas.alpha_composite(halo, POS)
base.alpha_composite(halo_canvas)

# --- the raven, mildly lifted so it pops on dark ---
r, g_, b, a = raven.split()
rgb = ImageEnhance.Brightness(Image.merge("RGB", (r, g_, b))).enhance(1.16)
raven_lift = Image.merge("RGBA", (*rgb.split(), a))
raven_canvas = Image.new("RGBA", (W, W), (0, 0, 0, 0))
raven_canvas.alpha_composite(raven_lift, POS)
base.alpha_composite(raven_canvas)

base.convert("RGB").save("RavenLogo-Dark.png")
# dark-on-dark preview is itself, just confirm
print("saved RavenLogo-Dark.png", base.size)
