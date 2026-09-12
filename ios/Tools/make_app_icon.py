#!/usr/bin/env python3
"""
Generates ios/ListingForge/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png.

Design: a capture frame (the safe-area brackets from SPEC §4.2) around a check
mark — "photograph it, it passes the marketplace rules", which is the product's
whole pitch (SPEC §2).

App Store requirements this file satisfies:
  * exactly 1024x1024
  * opaque RGB, no alpha channel (Apple rejects icons with transparency)
  * square with no baked-in rounded corners — the system masks them
  * sRGB

Run:  python3 ios/Tools/make_app_icon.py
"""

from pathlib import Path
from PIL import Image, ImageDraw

CANVAS = 1024          # final size, in design units
SS = 4                 # supersample factor; drawn at 4096 then downsampled
OUT = Path(__file__).resolve().parents[1] / (
    "ListingForge/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"
)

GRADIENT_FROM = (109, 40, 217)   # violet
GRADIENT_TO = (244, 63, 94)      # rose

BRACKET_INSET = 232              # distance from each edge to the bracket square
BRACKET_ARM = 150                # length of each bracket arm
BRACKET_STROKE = 52
BRACKET_ALPHA = 210              # slightly recessed so the check reads first

CHECK = [(378, 524), (468, 614), (648, 410)]
CHECK_STROKE = 78


def diagonal_gradient(size: int) -> Image.Image:
    """Corner-to-corner gradient, built small and scaled up so it stays smooth."""
    small = Image.new("RGB", (256, 256))
    px = small.load()
    for y in range(256):
        for x in range(256):
            t = (x + y) / 510
            px[x, y] = tuple(
                round(a + (b - a) * t) for a, b in zip(GRADIENT_FROM, GRADIENT_TO)
            )
    return small.resize((size, size), Image.BICUBIC)


def stroke(draw: ImageDraw.ImageDraw, points, width: int, fill) -> None:
    """Polyline with round caps and joins (PIL has no round-cap option)."""
    draw.line(points, fill=fill, width=width, joint="curve")
    r = width / 2
    for x, y in points:
        draw.ellipse((x - r, y - r, x + r, y + r), fill=fill)


def main() -> None:
    size = CANVAS * SS
    icon = diagonal_gradient(size)
    layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)

    def s(v):
        return v * SS

    white = (255, 255, 255, 255)
    bracket = (255, 255, 255, BRACKET_ALPHA)

    lo, hi = BRACKET_INSET, CANVAS - BRACKET_INSET
    arm = BRACKET_ARM
    for x, y, dx, dy in (
        (lo, lo, 1, 1),     # top-left
        (hi, lo, -1, 1),    # top-right
        (lo, hi, 1, -1),    # bottom-left
        (hi, hi, -1, -1),   # bottom-right
    ):
        stroke(draw, [(s(x), s(y)), (s(x + dx * arm), s(y))], s(BRACKET_STROKE), bracket)
        stroke(draw, [(s(x), s(y)), (s(x), s(y + dy * arm))], s(BRACKET_STROKE), bracket)

    stroke(draw, [(s(x), s(y)) for x, y in CHECK], s(CHECK_STROKE), white)

    icon = Image.alpha_composite(icon.convert("RGBA"), layer)
    icon = icon.resize((CANVAS, CANVAS), Image.LANCZOS).convert("RGB")  # drops alpha
    OUT.parent.mkdir(parents=True, exist_ok=True)
    icon.save(OUT, "PNG", optimize=True)
    print(f"wrote {OUT} ({icon.size[0]}x{icon.size[1]}, mode={icon.mode})")


if __name__ == "__main__":
    main()
