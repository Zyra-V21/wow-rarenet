#!/usr/bin/env python3
"""Render the CurseForge thumbnail in a WoW UI style: a gold-rimmed minimap
with a radar sweep and rare skull markers, on dark leather, under a gold
title plate.

Usage: python3 tools/thumbnail.py OUT_DIR   (writes thumbnail-1200.png and thumbnail-400.png)
"""
import math
import os
import random
import sys

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

SIZE = 1200
HERE = os.path.dirname(os.path.abspath(__file__))
TITLE_FONT = os.path.join(HERE, "fonts", "Cinzel.ttf")   # SIL Open Font License
CX, CY, R = SIZE // 2, 478, 380                         # minimap centre and radius
GOLD_LIGHT, GOLD, GOLD_DARK = (255, 226, 140), (214, 166, 60), (110, 72, 20)
TEAL = (90, 230, 200)


def noise(size, scale, seed):
    """Smooth value noise in 0..255, made by blurring random pixels."""
    random.seed(seed)
    small = Image.new("L", (size // scale, size // scale))
    small.putdata([random.randint(0, 255) for _ in range(small.width * small.height)])
    return small.resize((size, size), Image.BICUBIC).filter(ImageFilter.GaussianBlur(scale / 2))


def leather():
    base = Image.new("RGB", (SIZE, SIZE), (34, 22, 14))
    grain = noise(SIZE, 6, 1).point(lambda v: int(v * 0.18))
    blotch = noise(SIZE, 60, 2).point(lambda v: int(v * 0.25))
    img = ImageChops.add(base, Image.merge("RGB", (grain, grain.point(lambda v: v * 2 // 3), grain.point(lambda v: v // 3))))
    img = ImageChops.add(img, Image.merge("RGB", (blotch, blotch.point(lambda v: v // 2), blotch.point(lambda v: v // 4))))
    # Vignette towards the edges.
    mask = Image.new("L", (SIZE, SIZE), 0)
    ImageDraw.Draw(mask).ellipse((-200, -150, SIZE + 200, SIZE + 250), fill=255)
    mask = mask.filter(ImageFilter.GaussianBlur(160))
    dark = Image.new("RGB", (SIZE, SIZE), (6, 4, 3))
    return Image.composite(img, dark, mask).convert("RGBA")


def gold_ring(img, cx, cy, r_out, r_in):
    """A bevelled gold ring: light on the top left, dark on the bottom right."""
    ring = Image.new("RGBA", img.size, (0, 0, 0, 0))
    px = ring.load()
    for y in range(int(cy - r_out) - 1, int(cy + r_out) + 2):
        for x in range(int(cx - r_out) - 1, int(cx + r_out) + 2):
            d = math.hypot(x - cx, y - cy)
            if r_in <= d <= r_out:
                t = (d - r_in) / (r_out - r_in)                    # 0 inner edge, 1 outer edge
                light = -((x - cx) + (y - cy)) / (d * 1.414 + 1e-6)  # +1 top left, -1 bottom right
                bevel = math.sin(t * math.pi)                       # raised in the middle
                k = 0.55 + 0.35 * light * (1 - 2 * abs(t - 0.5)) + 0.25 * bevel
                k = max(0.0, min(1.25, k))
                c = [int(min(255, GOLD[i] * k + (GOLD_LIGHT[i] - GOLD[i]) * max(0, k - 0.9))) for i in range(3)]
                edge = min(t, 1 - t) * (r_out - r_in)
                alpha = 255 if edge > 1.5 else int(255 * edge / 1.5)
                px[x, y] = tuple(c) + (alpha,)
    return Image.alpha_composite(img, ring)


def rivets(img, cx, cy, r, n):
    d = ImageDraw.Draw(img)
    for i in range(n):
        a = 2 * math.pi * i / n + math.pi / n
        x, y = cx + r * math.cos(a), cy + r * math.sin(a)
        d.ellipse((x - 11, y - 11, x + 11, y + 11), fill=GOLD_DARK + (255,))
        d.ellipse((x - 8, y - 8, x + 6, y + 6), fill=GOLD_LIGHT + (255,))
    return img


def minimap(img):
    # Map surface: dark teal land with soft relief, clipped to the circle.
    land = noise(SIZE, 40, 3)
    detail = noise(SIZE, 10, 4)
    surface = Image.merge("RGB", (
        land.point(lambda v: 14 + v // 9),
        land.point(lambda v: 40 + v // 5),
        land.point(lambda v: 42 + v // 6)))
    surface = ImageChops.add(surface, Image.merge("RGB", [detail.point(lambda v: v // 14)] * 3))
    mask = Image.new("L", img.size, 0)
    ImageDraw.Draw(mask).ellipse((CX - R, CY - R, CX + R, CY + R), fill=255)
    img.paste(surface, (0, 0), mask)

    layer = Image.new("RGBA", img.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    for i in range(1, 4):
        r = R * i / 4
        d.ellipse((CX - r, CY - r, CX + r, CY + r), outline=TEAL + (55,), width=3)
    d.line((CX - R, CY, CX + R, CY), fill=TEAL + (35,), width=2)
    d.line((CX, CY - R, CX, CY + R), fill=TEAL + (35,), width=2)
    sweep = Image.new("RGBA", img.size, (0, 0, 0, 0))
    s = ImageDraw.Draw(sweep)
    lead = -28
    for k in range(80):
        a = lead - k
        s.pieslice((CX - R, CY - R, CX + R, CY + R), a - 1, a, fill=TEAL + (int(120 * (1 - k / 80) ** 2),))
    a = math.radians(lead)
    d.line((CX, CY, CX + R * math.cos(a), CY + R * math.sin(a)), fill=TEAL + (200,), width=4)
    img = Image.alpha_composite(img, sweep.filter(ImageFilter.GaussianBlur(3)))
    img = Image.alpha_composite(img, layer)

    # Inner shadow under the rim.
    shade = Image.new("RGBA", img.size, (0, 0, 0, 0))
    ImageDraw.Draw(shade).ellipse((CX - R, CY - R, CX + R, CY + R), outline=(0, 0, 0, 200), width=34)
    shade = shade.filter(ImageFilter.GaussianBlur(14))
    shade.putalpha(ImageChops.multiply(shade.getchannel("A"), mask))
    return Image.alpha_composite(img, shade)


def skull(img, x, y, color, size):
    glow = Image.new("RGBA", img.size, (0, 0, 0, 0))
    ImageDraw.Draw(glow).ellipse((x - size * 2.4, y - size * 2.4, x + size * 2.4, y + size * 2.4), fill=color + (150,))
    img = Image.alpha_composite(img, glow.filter(ImageFilter.GaussianBlur(size * 0.9)))
    d = ImageDraw.Draw(img)
    d.ellipse((x - size * 1.5, y - size * 1.5, x + size * 1.5, y + size * 1.5), fill=GOLD_DARK + (255,))
    d.ellipse((x - size * 1.32, y - size * 1.32, x + size * 1.32, y + size * 1.32), fill=color + (255,))
    ink, bone = (20, 16, 14, 255), (250, 246, 232, 255)
    d.ellipse((x - size * 0.85, y - size * 0.95, x + size * 0.85, y + size * 0.6), fill=bone)
    d.rounded_rectangle((x - size * 0.55, y + size * 0.2, x + size * 0.55, y + size * 0.95), radius=size * 0.15, fill=bone)
    for k in (-1, 1):
        d.ellipse((x + k * size * 0.38 - size * 0.27, y - size * 0.35, x + k * size * 0.38 + size * 0.27, y + size * 0.15), fill=ink)
    d.polygon([(x, y + size * 0.12), (x - size * 0.12, y + size * 0.38), (x + size * 0.12, y + size * 0.38)], fill=ink)
    for k in (-1, 0, 1):
        tx = x + k * size * 0.3
        d.line((tx, y + size * 0.6, tx, y + size * 0.95), fill=ink, width=max(2, int(size * 0.1)))
    return img


def frame(img):
    """Gold double border with diamond corner studs, like a WoW panel."""
    d = ImageDraw.Draw(img)
    for inset, width, color in ((18, 10, GOLD_DARK), (22, 4, GOLD), (40, 3, GOLD_DARK)):
        d.rectangle((inset, inset, SIZE - inset, SIZE - inset), outline=color + (255,), width=width)
    for cx, cy in ((30, 30), (SIZE - 30, 30), (30, SIZE - 30), (SIZE - 30, SIZE - 30)):
        d.polygon([(cx, cy - 26), (cx + 26, cy), (cx, cy + 26), (cx - 26, cy)], fill=GOLD_DARK + (255,))
        d.polygon([(cx, cy - 18), (cx + 18, cy), (cx, cy + 18), (cx - 18, cy)], fill=GOLD + (255,))
        d.polygon([(cx - 6, cy - 12), (cx, cy - 18), (cx + 6, cy - 12), (cx, cy - 4)], fill=GOLD_LIGHT + (255,))
    return img


def title(img, text):
    font = ImageFont.truetype(TITLE_FONT, 190)
    font.set_variation_by_name("Black")
    d = ImageDraw.Draw(img)
    PLATE_TOP, PLATE_BOTTOM = 950, 1150
    left, top_px, right, bottom_px = d.textbbox((0, 0), text, font=font)
    x = (SIZE - (right - left)) / 2 - left
    y = (PLATE_TOP + PLATE_BOTTOM) / 2 - (top_px + bottom_px) / 2
    # Dark plate behind the title.
    plate = Image.new("RGBA", img.size, (0, 0, 0, 0))
    pd = ImageDraw.Draw(plate)
    pd.rounded_rectangle((100, PLATE_TOP, SIZE - 100, PLATE_BOTTOM), radius=28, fill=(16, 10, 6, 235), outline=GOLD_DARK + (255,), width=6)
    pd.rounded_rectangle((112, PLATE_TOP + 12, SIZE - 112, PLATE_BOTTOM - 12), radius=20, outline=GOLD + (200,), width=2)
    img = Image.alpha_composite(img, plate)
    # Shadow, then a vertical gold gradient clipped to the letters, then a dark outline.
    shadow = Image.new("RGBA", img.size, (0, 0, 0, 0))
    ImageDraw.Draw(shadow).text((x + 6, y + 8), text, font=font, fill=(0, 0, 0, 255))
    img = Image.alpha_composite(img, shadow.filter(ImageFilter.GaussianBlur(6)))
    mask = Image.new("L", img.size, 0)
    ImageDraw.Draw(mask).text((x, y), text, font=font, fill=255)
    top, bottom = int(y + top_px), int(y + bottom_px)
    grad = Image.new("RGBA", img.size, (0, 0, 0, 0))
    gd = ImageDraw.Draw(grad)
    for yy in range(top, bottom):
        t = (yy - top) / (bottom - top)
        if t < 0.45:
            c = [int(GOLD_LIGHT[i] + (255 - GOLD_LIGHT[i]) * (0.45 - t)) for i in range(3)]
        else:
            k = (t - 0.45) / 0.55
            c = [int(GOLD[i] + (GOLD_DARK[i] - GOLD[i]) * k * 0.8) for i in range(3)]
        gd.line((0, yy, SIZE, yy), fill=tuple(c) + (255,))
    outline = Image.new("RGBA", img.size, (0, 0, 0, 0))
    ImageDraw.Draw(outline).text((x, y), text, font=font, fill=(40, 22, 6, 255), stroke_width=5, stroke_fill=(40, 22, 6, 255))
    img = Image.alpha_composite(img, outline)
    grad.putalpha(mask)
    return Image.alpha_composite(img, grad)


def main(out):
    img = leather()
    # Soft drop shadow under the whole minimap.
    drop = Image.new("RGBA", img.size, (0, 0, 0, 0))
    ImageDraw.Draw(drop).ellipse((CX - R - 40, CY - R - 25, CX + R + 50, CY + R + 60), fill=(0, 0, 0, 200))
    img = Image.alpha_composite(img, drop.filter(ImageFilter.GaussianBlur(30)))
    img = minimap(img)
    img = gold_ring(img, CX, CY, R + 46, R)
    img = rivets(img, CX, CY, R + 23, 12)
    img = skull(img, CX + 185, CY - 150, (60, 200, 80), 34)     # live on your layer
    img = skull(img, CX - 215, CY + 95, (230, 120, 30), 28)     # live on another layer
    img = skull(img, CX - 55, CY - 270, (230, 180, 30), 24)     # tameable
    img = skull(img, CX + 125, CY + 235, (150, 90, 230), 24)    # discovered
    img = frame(img)
    img = title(img, "RareNet")
    img = img.convert("RGB")
    img.save(os.path.join(out, "thumbnail-1200.png"))
    img.resize((400, 400), Image.LANCZOS).save(os.path.join(out, "thumbnail-400.png"))


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else ".")
