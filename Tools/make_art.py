"""Bugsy's art from the owner's master: Media/Hat.tga and Media/Icon.tga (#28).

    python -I Tools/make_art.py MASTER.png [--out Media] [--preview DIR]

MASTER is "BUGSY liquid glass fedora logo.png" (1254x1254, the glass fedora over a dark
navy ground, the word BUGSY under it). Masters stay out of git.

- Hat.tga (128x128): the hat alone, the navy ground keyed out to transparency (a matte
  against the ground colour, so the glass stays see-through), for the window's header
  and the empty state.
- Icon.tga (64x64): the hat on its navy ground, corners rounded, for the addon list
  (TOC IconTexture) and the minimap button: it must read at 16-20 pixels.

WoW loads TGA (uncompressed, 32-bit, power-of-two), never PNG.
"""

import argparse
import os

import numpy as np
from PIL import Image

HAT_BOX = (110, 95, 1165, 865)        # the hat, without the word under it (source pixels)


def write_tga(img, path):
    img = img.convert("RGBA")
    w, h = img.size
    data = np.asarray(img, dtype=np.uint8)[::-1, :, [2, 1, 0, 3]]   # bottom-up, BGRA
    header = bytes([0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                    w & 255, w >> 8, h & 255, h >> 8, 32, 8])
    with open(path, "wb") as f:
        f.write(header)
        f.write(data.tobytes())


def ground_colour(rgb):
    corners = np.concatenate([rgb[:40, :40].reshape(-1, 3), rgb[:40, -40:].reshape(-1, 3)])
    return corners.mean(axis=0)


def keyed_hat(master):
    rgb = np.asarray(master.convert("RGB"), dtype=np.float64)
    bg = ground_colour(rgb)
    box = rgb[HAT_BOX[1]:HAT_BOX[3], HAT_BOX[0]:HAT_BOX[2]]
    dist = np.sqrt(((box - bg) ** 2).sum(axis=2))
    alpha = np.clip((dist - 6.0) / 70.0, 0.0, 1.0)
    a = alpha[..., None]
    colour = np.where(a > 0.004, (box - bg * (1 - a)) / np.maximum(a, 0.004), 0)
    colour = np.clip(colour, 0, 255)
    out = np.dstack([colour, alpha * 255]).astype(np.uint8)
    hat = Image.fromarray(out, "RGBA")
    w, h = hat.size
    side = max(w, h)
    square = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    square.paste(hat, ((side - w) // 2, (side - h) // 2))
    return square


def resize_premultiplied(img, size):
    arr = np.asarray(img, dtype=np.float64)
    a = arr[..., 3:4] / 255.0
    pre = np.dstack([arr[..., :3] * a, arr[..., 3:4]])
    small = Image.fromarray(np.clip(pre, 0, 255).astype(np.uint8), "RGBA").resize((size, size), Image.LANCZOS)
    s = np.asarray(small, dtype=np.float64)
    sa = s[..., 3:4] / 255.0
    rgb = np.where(sa > 0.004, s[..., :3] / np.maximum(sa, 0.004), 0)
    return Image.fromarray(np.clip(np.dstack([rgb, s[..., 3:4]]), 0, 255).astype(np.uint8), "RGBA")


def icon(master, size=64, round_frac=0.2, fill=0.92):
    rgb = np.asarray(master.convert("RGB"), dtype=np.float64)
    bg = tuple(int(c) for c in ground_colour(rgb))
    inner = int(size * fill)
    hat = resize_premultiplied(keyed_hat(master), inner)
    img = Image.new("RGBA", (size, size), bg + (255,))
    img.alpha_composite(hat, ((size - inner) // 2, (size - inner) // 2))
    arr = np.asarray(img).copy()
    r = round_frac * size
    yy, xx = np.mgrid[0:size, 0:size] + 0.5
    cx = np.clip(xx, r, size - r)
    cyy = np.clip(yy, r, size - r)
    d = np.sqrt((xx - cx) ** 2 + (yy - cyy) ** 2)
    arr[..., 3] = (np.clip(r - d + 0.5, 0, 1) * 255).astype(np.uint8)
    return Image.fromarray(arr, "RGBA")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("master")
    ap.add_argument("--out", default="Media")
    ap.add_argument("--preview")
    args = ap.parse_args()
    master = Image.open(args.master)
    os.makedirs(args.out, exist_ok=True)
    hat = resize_premultiplied(keyed_hat(master), 128)
    ico = icon(master)
    write_tga(hat, os.path.join(args.out, "Hat.tga"))
    write_tga(ico, os.path.join(args.out, "Icon.tga"))
    if args.preview:
        os.makedirs(args.preview, exist_ok=True)
        for name, im in (("hat", hat), ("icon", ico)):
            for bgname, bgc in (("dark", (30, 24, 18, 255)), ("light", (200, 200, 205, 255))):
                bg = Image.new("RGBA", im.size, bgc)
                bg.alpha_composite(im)
                bg.resize((im.size[0] * 3, im.size[1] * 3), Image.NEAREST).save(
                    os.path.join(args.preview, f"{name}-{bgname}.png"))


if __name__ == "__main__":
    main()
