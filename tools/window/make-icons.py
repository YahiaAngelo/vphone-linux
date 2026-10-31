#!/usr/bin/env python3
"""Draw the VM window's button bar icons into one RGBA atlas (tools/window/toolbar-<px>.rgba).

    tools/window/make-icons.py [PX]      # default 48

Row i is button i (ICONS order); left half its normal image, right half its hover image. Raw RGBA8,
non-premultiplied, no header: the format reims-vgpu's window reads (`toolbar` control message).
Needs Pillow; the generated atlas is committed, so running the VM does not."""
import math
import os
import sys

from PIL import Image, ImageDraw

PX = int(sys.argv[1]) if len(sys.argv) > 1 else 48
SS = 8                       # supersampling factor
S = PX * SS                  # drawing canvas
ICONS = ["home", "lock", "volume-up", "volume-down", "screenshot", "fold"]
WHITE = (245, 245, 247, 255)
HOVER_BG = (72, 72, 76, 255)
PRESS_RING = (10, 132, 255, 255)


def stroke(d, pts, w, fill=WHITE):
    d.line(pts, fill=fill, width=w, joint="curve")
    r = w / 2
    for x, y in (pts[0], pts[-1]):
        d.ellipse((x - r, y - r, x + r, y + r), fill=fill)


def u(v):
    """Canvas units: the icon is drawn on a 24-unit grid, like system symbol sets."""
    return v * S / 24


def glyph(name):
    im = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    w = int(u(1.9))
    if name == "home":
        # A house: roof and walls, a door gap.
        stroke(d, [(u(4), u(11.5)), (u(12), u(4.5)), (u(20), u(11.5))], w)
        stroke(d, [(u(6.5), u(9.5)), (u(6.5), u(19.5)), (u(10), u(19.5))], w)
        stroke(d, [(u(14), u(19.5)), (u(17.5), u(19.5)), (u(17.5), u(9.5))], w)
        stroke(d, [(u(10), u(19.5)), (u(10), u(14.5)), (u(14), u(14.5)), (u(14), u(19.5))], w)
    elif name == "lock":
        # The power symbol: an open ring and a bar.
        box = (u(5), u(5.5), u(19), u(19.5))
        d.arc(box, start=-50, end=230, fill=WHITE, width=w)
        for a in (-50, 230):
            x = u(12) + u(7) * math.cos(math.radians(a)) - 0
            y = u(12.5) + u(7) * math.sin(math.radians(a))
            r = w / 2
            d.ellipse((x - r, y - r, x + r, y + r), fill=WHITE)
        stroke(d, [(u(12), u(3.5)), (u(12), u(11))], w)
    elif name in ("volume-up", "volume-down"):
        # A speaker; waves for up, one short wave and a minus feel for down.
        d.polygon([(u(3.5), u(9.5)), (u(7), u(9.5)), (u(11.5), u(5.5)), (u(11.5), u(18.5)),
                   (u(7), u(14.5)), (u(3.5), u(14.5))], fill=WHITE)
        d.arc((u(9.5), u(8.5), u(16.5), u(15.5)), start=-50, end=50, fill=WHITE, width=w)
        if name == "volume-up":
            d.arc((u(9), u(5), u(20.5), u(19)), start=-50, end=50, fill=WHITE, width=w)
    elif name == "screenshot":
        # A camera body with a lens.
        d.rounded_rectangle((u(3), u(7), u(21), u(19)), radius=u(2.5), outline=WHITE, width=w)
        d.rounded_rectangle((u(8.5), u(4.5), u(15.5), u(7.6)), radius=u(1), fill=WHITE)
        d.ellipse((u(8.2), u(9.2), u(15.8), u(16.8)), outline=WHITE, width=w)
    elif name == "fold":
        # An open book-style foldable: two panels meeting at a hinge.
        stroke(d, [(u(12), u(6)), (u(12), u(19))], w)
        d.polygon([(u(12), u(6)), (u(4), u(4)), (u(4), u(17)), (u(12), u(19))], outline=WHITE,
                  width=w)
        d.polygon([(u(12), u(6)), (u(20), u(4)), (u(20), u(17)), (u(12), u(19))], outline=WHITE,
                  width=w)
    return im


def button(name, hover):
    canvas = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    if hover:
        ImageDraw.Draw(canvas).rounded_rectangle((u(0.5), u(0.5), u(23.5), u(23.5)),
                                                 radius=u(6.5), fill=HOVER_BG)
    g = glyph(name)
    # The glyph at 62% of the button, centred.
    k = int(S * 0.62)
    g = g.resize((k, k), Image.LANCZOS)
    canvas.alpha_composite(g, ((S - k) // 2, (S - k) // 2))
    out = canvas.resize((PX, PX), Image.LANCZOS)
    if not hover:
        # The normal glyph a touch dimmer, so the hover reads as lighting it up.
        r, gg, b, a = out.split()
        out = Image.merge("RGBA", (r, gg, b, a.point(lambda v: v * 82 // 100)))
    return out


atlas = Image.new("RGBA", (2 * PX, PX * len(ICONS)), (0, 0, 0, 0))
for i, name in enumerate(ICONS):
    atlas.paste(button(name, False), (0, i * PX))
    atlas.paste(button(name, True), (PX, i * PX))
here = os.path.dirname(os.path.abspath(__file__))
path = os.path.join(here, f"toolbar-{PX}.rgba")
with open(path, "wb") as f:
    f.write(atlas.tobytes())
preview = Image.new("RGBA", atlas.size, (28, 28, 30, 255))
preview.alpha_composite(atlas)
preview.save(os.path.join(here, f"toolbar-{PX}-preview.png"))
print(path, atlas.size, ",".join(ICONS))
