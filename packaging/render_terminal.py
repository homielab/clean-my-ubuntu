#!/usr/bin/env python3
"""Render the terminal app to a PNG, for docs and app stores.

    render_terminal.py ENGINE OUT.png [--keys "1|n"] [--cols 110 --rows 34] [--wait 6]

Runs ENGINE (clean-my-ubuntu.sh --dry-run) in a virtual terminal (pyte), sends the
keys (separated by |, with a pause after each), and draws the final screen with
Pillow inside a dark window frame. HOME etc. come from the environment.
Needs: pyte, Pillow, the Ubuntu Mono font (fonts-ubuntu).
"""
import argparse, fcntl, os, pty, select, struct, subprocess, termios, time

import pyte
from PIL import Image, ImageDraw, ImageFilter, ImageFont

PALETTE = {  # GNOME/Tango, tuned for a dark background
    "default": "#d6d6d6", "black": "#2e3436", "red": "#ef2929", "green": "#8ae234", "brown": "#fce94f",
    "yellow": "#fce94f", "blue": "#729fcf", "magenta": "#ad7fa8", "cyan": "#34e2e2", "white": "#eeeeec",
}
BG = "#1e1e1e"


def font_file(pattern):
    return subprocess.run(["fc-match", "-f", "%{file}", pattern], capture_output=True, text=True).stdout


class DimScreen(pyte.Screen):
    """pyte ignores SGR 2 (dim); map it onto italics, which the app never uses."""

    def select_graphic_rendition(self, *attrs, **kwargs):
        super().select_graphic_rendition(*[3 if a == 2 else a for a in attrs], **kwargs)


def color(c, default):
    c = default if c == "default" else PALETTE.get(c, c)
    c = c.lstrip("#")
    return "#" + (c if len(c) == 6 else default.lstrip("#"))


def mix(a, b):
    a, b = int(a[1:], 16), int(b[1:], 16)
    return "#%02x%02x%02x" % tuple(((a >> s & 255) + (b >> s & 255)) // 2 for s in (16, 8, 0))


def drive(engine, keys, cols, rows, wait, live=False):
    screen = DimScreen(cols, rows)
    stream = pyte.ByteStream(screen)
    pid, fd = pty.fork()
    if pid == 0:
        os.environ.update(TERM="xterm-256color", CMU_NO_UPDATE_CHECK="1")
        # scan-only key sequences are read-only; --live just hides the DRY-RUN badge
        os.execvp("bash", ["bash", engine, "--no-mouse"] + ([] if live else ["--dry-run"]))
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))

    def pump(t):
        end = time.time() + t
        while time.time() < end:
            if select.select([fd], [], [], 0.05)[0]:
                try:
                    stream.feed(os.read(fd, 65536))
                except OSError:
                    return
    pump(2)
    for k in [k for k in keys.split("|") if k]:
        os.write(fd, k.encode().decode("unicode_escape").encode("latin-1"))
        pump(wait)
    snapshot = [[screen.buffer[y][x] for x in range(cols)] for y in range(rows)]
    os.write(fd, b"qqqq")
    pump(0.5)
    return snapshot, cols, rows


def render(cells, cols, rows, out, title, scale=2):
    size = 15 * scale
    regular = ImageFont.truetype(font_file("Ubuntu Mono"), size)
    bold = ImageFont.truetype(font_file("Ubuntu Mono:bold"), size)
    # like a terminal: symbols and box drawing come from a fallback font, emoji in colour
    symbols = ImageFont.truetype(font_file("DejaVu Sans Mono"), int(size * 0.92))
    symbols_bold = ImageFont.truetype(font_file("DejaVu Sans Mono:bold"), int(size * 0.92))
    emoji = ImageFont.truetype(font_file("Noto Color Emoji"), 109)  # bitmap font: one size only
    wide = ImageFont.truetype(font_file("DejaVu Sans"), int(size * 0.9))  # symbols the mono font lacks
    NOT_IN_MONO = set("ℹ⏱⚿⬆↶")
    ui = ImageFont.truetype(font_file("Ubuntu:bold"), 12 * scale)
    cw = regular.getlength("M")
    ch = int(size * 1.22)
    pad, bar, margin, radius = 18 * scale, 38 * scale, 32 * scale, 14 * scale
    w = int(cols * cw + 2 * pad + 2 * margin)
    h = int(rows * ch + 2 * pad + bar + 2 * margin)

    img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    shadow = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle((margin, margin + 8 * scale, w - margin, h - margin + 8 * scale),
                                             radius, fill=(0, 0, 0, 110))
    img.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(14 * scale)))
    d = ImageDraw.Draw(img)
    d.rounded_rectangle((margin, margin, w - margin, h - margin), radius, fill=BG)
    d.rounded_rectangle((margin, margin, w - margin, margin + bar), radius, fill="#2b2b2b")
    d.rectangle((margin, margin + bar - radius, w - margin, margin + bar), fill="#2b2b2b")
    tw = d.textlength(title, font=ui)
    d.text(((w - tw) / 2, margin + (bar - 12 * scale) / 2 - 2 * scale), title, font=ui, fill="#d8d8d8")
    for i in range(3):
        cx, cy, r = w - margin - 24 * scale - i * 26 * scale, margin + bar / 2, 8 * scale
        d.ellipse((cx - r, cy - r, cx + r, cy + r), fill="#575757")

    x0, y0 = margin + pad, margin + bar + pad
    for y, row in enumerate(cells):
        for x, c in enumerate(row):
            fg, bg = c.fg, c.bg
            if c.reverse:
                fg, bg = (bg if bg != "default" else BG), (fg if fg != "default" else PALETTE["default"])
            if bg != "default":
                d.rectangle((x0 + x * cw, y0 + y * ch, x0 + (x + 1) * cw + 1, y0 + (y + 1) * ch), fill=color(bg, BG))
            if c.data.strip():
                ink = color(fg, PALETTE["default"])
                if c.italics:  # dim
                    ink = mix(ink, BG)
                cp = ord(c.data[0])
                if cp >= 0x1F000:  # emoji: draw big, scale to the cell height
                    glyph = Image.new("RGBA", (140, 140), (0, 0, 0, 0))
                    ImageDraw.Draw(glyph).text((0, 0), c.data, font=emoji, embedded_color=True)
                    glyph = glyph.crop(glyph.getbbox() or (0, 0, 1, 1)).resize((int(ch * 0.9), int(ch * 0.9)), Image.LANCZOS)
                    img.alpha_composite(glyph, (int(x0 + x * cw), int(y0 + y * ch + ch * 0.05)))
                    continue
                if cp < 0x2070:
                    face = bold if c.bold else regular
                elif c.data in NOT_IN_MONO:
                    face = wide
                else:
                    face = symbols_bold if c.bold else symbols
                d.text((x0 + x * cw, y0 + y * ch + (0 if cp < 0x2070 else size * 0.04)), c.data, font=face, fill=ink)
    img.save(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("engine")
    ap.add_argument("out")
    ap.add_argument("--keys", default="")
    ap.add_argument("--cols", type=int, default=110)
    ap.add_argument("--rows", type=int, default=34)
    ap.add_argument("--wait", type=float, default=6)
    ap.add_argument("--title", default="cmu")
    ap.add_argument("--live", action="store_true", help="no --dry-run (only for keys that never clean)")
    a = ap.parse_args()
    if a.live and "c" in a.keys.replace("\\", "").split("|"):
        ap.error("--live with a 'c' (clean) key is not allowed")
    render(*drive(os.path.abspath(a.engine), a.keys, a.cols, a.rows, a.wait, a.live), a.out, a.title)
    print("wrote", a.out)


if __name__ == "__main__":
    main()
