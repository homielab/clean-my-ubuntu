#!/usr/bin/env python3
"""Render store images into dist/store/ (uploaded by hand, so not committed):

  icon-512.png            Snap Store / anywhere a PNG icon is required
  snap-banner-1218x406.png  Snap Store featured banner
  github-social-1280x640.png  GitHub → Settings → Social preview

Needs: python3-gi (GdkPixbuf, to render the SVG icon), Pillow, fonts-ubuntu.
"""
import os, subprocess, sys

import gi
gi.require_version("GdkPixbuf", "2.0")
from gi.repository import GdkPixbuf  # noqa: E402
from PIL import Image, ImageDraw, ImageFilter, ImageFont  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP_ID = "com.homielab.CleanMyUbuntu"
SVG = f"{ROOT}/data/icons/hicolor/scalable/apps/{APP_ID}.svg"
OUT = sys.argv[1] if len(sys.argv) > 1 else f"{ROOT}/dist/store"
SHOT = f"{ROOT}/docs/screenshots/desktop-1-results.png"


def font(pattern, size):
    path = subprocess.run(["fc-match", "-f", "%{file}", pattern], capture_output=True, text=True).stdout
    return ImageFont.truetype(path, size)


def icon(size):
    pb = GdkPixbuf.Pixbuf.new_from_file_at_size(SVG, size, size)
    return Image.frombytes("RGBA" if pb.get_has_alpha() else "RGB", (pb.get_width(), pb.get_height()),
                           pb.get_pixels(), "raw", "RGBA" if pb.get_has_alpha() else "RGB", pb.get_rowstride())


def gradient(w, h, top=(58, 58, 58), bottom=(20, 20, 20)):
    img = Image.new("RGB", (w, h))
    d = ImageDraw.Draw(img)
    for y in range(h):
        t = y / max(h - 1, 1)
        d.line([(0, y), (w, y)], fill=tuple(int(a + (b - a) * t) for a, b in zip(top, bottom)))
    return img.convert("RGBA")


def sparkles(d, pts):
    for x, y, r in pts:
        d.polygon([(x, y - r), (x + r * .28, y - r * .28), (x + r, y), (x + r * .28, y + r * .28),
                   (x, y + r), (x - r * .28, y + r * .28), (x - r, y), (x - r * .28, y - r * .28)],
                  fill=(255, 255, 255, 90))


def banner(w, h, path):
    """Wide banner: icon on the left, name and tagline beside it."""
    img = gradient(w, h)
    d = ImageDraw.Draw(img)
    sparkles(d, [(w * .93, h * .18, h * .05), (w * .86, h * .80, h * .03), (w * .05, h * .82, h * .025)])
    ic = icon(int(h * .52))
    x = int(h * .16)
    img.alpha_composite(ic, (x, (h - ic.height) // 2))
    tx = x + ic.width + int(h * .09)
    d.text((tx, h * .28), "Clean My Ubuntu", font=font("Ubuntu:bold", int(h * .14)), fill="white")
    sub = font("Ubuntu", int(h * .065))
    d.text((tx, h * .50), "Free up disk space and keep Ubuntu tidy — safely.", font=sub, fill=(235, 235, 235))
    d.text((tx, h * .62), "Desktop app + terminal app (cmu) · free & open source", font=sub, fill=(190, 190, 190))
    img.convert("RGB").save(path)
    print("wrote", os.path.relpath(path, ROOT))


def social(w, h, path):
    """Link preview: text column on the left, a real screenshot on the right."""
    img = gradient(w, h)
    d = ImageDraw.Draw(img)
    sparkles(d, [(w * .47, h * .14, 22), (w * .05, h * .9, 14)])
    ic = icon(150)
    img.alpha_composite(ic, (64, 70))
    d.text((64, 250), "Clean My Ubuntu", font=font("Ubuntu:bold", 60), fill="white")
    tag = font("Ubuntu", 30)
    d.text((64, 340), "Free up disk space and", font=tag, fill=(235, 235, 235))
    d.text((64, 380), "keep Ubuntu tidy — safely.", font=tag, fill=(235, 235, 235))
    d.text((64, 470), "Desktop app + terminal app · open source", font=font("Ubuntu", 22), fill=(190, 190, 190))
    d.text((64, 505), "github.com/homielab/clean-my-ubuntu", font=font("Ubuntu:bold", 22), fill="white")
    if os.path.exists(SHOT):
        shot = Image.open(SHOT).convert("RGBA")
        sw = int(w * .44)
        shot = shot.resize((sw, int(shot.height * sw / shot.width)), Image.LANCZOS)
        mask = Image.new("L", shot.size, 0)
        ImageDraw.Draw(mask).rounded_rectangle((0, 0, *shot.size), 14, fill=255)
        sx, sy = w - sw - 56, (h - shot.height) // 2
        shadow = Image.new("RGBA", img.size, (0, 0, 0, 0))
        ImageDraw.Draw(shadow).rounded_rectangle((sx, sy + 12, sx + sw, sy + shot.height + 12), 14, fill=(0, 0, 0, 95))
        img.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(14)))
        img.paste(shot, (sx, sy), mask)
    img.convert("RGB").save(path)
    print("wrote", os.path.relpath(path, ROOT))


os.makedirs(OUT, exist_ok=True)
icon(512).save(f"{OUT}/icon-512.png")
print("wrote", os.path.relpath(f"{OUT}/icon-512.png", ROOT))
banner(1218, 406, f"{OUT}/snap-banner-1218x406.png")
social(1280, 640, f"{OUT}/github-social-1280x640.png")
