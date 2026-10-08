#!/usr/bin/env python3
"""Draw RareNet's map and minimap pin layers as 64x64 TGA textures.

pin_disc.tga  dark disc behind the pin (contrast on any terrain)
pin_ring.tga  white ring, tinted in game by the kind of pin
pin_skull.tga white skull with dark features
pin_dot.tga   white filled dot, tinted in game (secondary spawn points)
pin_wave.tga  thin white ring, the radar waves of a live sighting
"""
import os

from PIL import Image, ImageDraw, ImageFilter

S = 64
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "RareNet", "Media")


def canvas():
    return Image.new("RGBA", (S * 4, S * 4), (0, 0, 0, 0))   # draw at 4x, scale down for smooth edges


def save(img, name):
    img = img.resize((S, S), Image.LANCZOS)
    img.save(os.path.join(OUT, name), "TGA", compression=None)
    print(name)


def disc():
    img = canvas()
    d = ImageDraw.Draw(img)
    d.ellipse((8, 8, S * 4 - 8, S * 4 - 8), fill=(10, 10, 14, 235))
    return img


def ring():
    img = canvas()
    d = ImageDraw.Draw(img)
    d.ellipse((8, 8, S * 4 - 8, S * 4 - 8), outline=(255, 255, 255, 255), width=26)
    return img


def wave():
    # 128 px: shown up to ~100 px wide on the map, so it is drawn big.
    # White core tinted in game, dark edges so it reads on bright maps.
    n = 128 * 4
    img = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.ellipse((8, 8, n - 8, n - 8), outline=(0, 0, 0, 200), width=30)
    d.ellipse((16, 16, n - 16, n - 16), outline=(255, 255, 255, 255), width=14)
    img = img.resize((128, 128), Image.LANCZOS)
    img.save(os.path.join(OUT, "pin_wave.tga"), "TGA", compression=None)
    print("pin_wave.tga")


def dot():
    img = canvas()
    d = ImageDraw.Draw(img)
    d.ellipse((52, 52, S * 4 - 52, S * 4 - 52), fill=(255, 255, 255, 255))
    return img


def skull():
    img = canvas()
    d = ImageDraw.Draw(img)
    c, r = S * 2, S * 4
    bone, ink = (250, 248, 240, 255), (0, 0, 0, 0)
    d.ellipse((c - 62, 52, c + 62, 160), fill=bone)                     # cranium
    d.rounded_rectangle((c - 40, 130, c + 40, 196), radius=10, fill=bone)  # jaw
    for k in (-1, 1):                                                     # eye sockets
        d.ellipse((c + k * 28 - 20, 92, c + k * 28 + 20, 132), fill=ink)
    d.polygon([(c, 130), (c - 9, 150), (c + 9, 150)], fill=ink)            # nose
    for k in (-1, 0, 1):                                                  # teeth gaps
        d.rectangle((c + k * 22 - 3, 168, c + k * 22 + 3, 196), fill=ink)
    # thin dark outline so the skull reads on light rings too
    alpha = img.getchannel("A")
    outline = alpha.filter(ImageFilter.MaxFilter(9))
    base = Image.new("RGBA", img.size, (12, 10, 10, 255))
    base.putalpha(outline)
    return Image.alpha_composite(base, img)


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    save(disc(), "pin_disc.tga")
    save(ring(), "pin_ring.tga")
    save(skull(), "pin_skull.tga")
    save(dot(), "pin_dot.tga")
    wave()
