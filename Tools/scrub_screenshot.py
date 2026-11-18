"""Crop a screenshot to Bugsy's window and erase what shows through it.

The window is translucent, so other players' names behind it read faintly. Everything
that isn't Bugsy's own bright text or art is replaced by a median-filtered copy: the
median erases thin, low-contrast strokes (the names) and keeps the large flat panels.

usage: python -I Tools/scrub_screenshot.py SRC OUT LEFT TOP RIGHT BOTTOM [--keep L,T,R,B ...] [--width W]
"""
import sys
import numpy as np
from PIL import Image, ImageFilter

args = sys.argv[1:]
src, out = args[0], args[1]
box = tuple(int(v) for v in args[2:6])
keeps, width, threshold = [], None, 150
i = 6
while i < len(args):
    if args[i] == "--keep":
        keeps.append(tuple(int(v) for v in args[i + 1].split(",")))
        i += 2
    elif args[i] == "--width":
        width = int(args[i + 1])
        i += 2
    elif args[i] == "--threshold":
        threshold = int(args[i + 1])
        i += 2
    else:
        raise SystemExit("unknown argument " + args[i])

img = Image.open(src).convert("RGB").crop(box)
a = np.asarray(img).astype(np.float32)
lum = 0.299 * a[..., 0] + 0.587 * a[..., 1] + 0.114 * a[..., 2]
bright = Image.fromarray(((lum > threshold) * 255).astype(np.uint8))
keep = np.asarray(bright.filter(ImageFilter.MaxFilter(5))) > 0
for (l, t, r, b) in keeps:                       # in source coordinates
    keep[max(0, t - box[1]):max(0, b - box[1]), max(0, l - box[0]):max(0, r - box[0])] = True

# The background: a median over a small copy (fast), scaled back up and softened.
small = img.resize((img.width // 3, img.height // 3), Image.BILINEAR)
bg = small.filter(ImageFilter.MedianFilter(7)).resize(img.size, Image.BILINEAR)
bg = bg.filter(ImageFilter.GaussianBlur(2))
res = np.where(keep[..., None], a, np.asarray(bg).astype(np.float32))
outimg = Image.fromarray(res.clip(0, 255).astype(np.uint8))
if width:
    outimg = outimg.resize((width, round(outimg.height * width / outimg.width)), Image.LANCZOS)
outimg.save(out, optimize=True)
print(out, outimg.size)
