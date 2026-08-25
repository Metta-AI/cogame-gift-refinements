#!/usr/bin/env python3
"""Deterministic board art for Gift Refinements (Pillow, committed output).

    python3 scripts/art/gen_gift_art.py

Owns every asset in `data/` EXCEPT the six `cog_<colour>_{front,beam,bank}.png`
kits, which are nano-banana renders of the Softmax cog split out by
`scripts/art/split_cog_sheet.py` (see the checklist in
`coworld-builder/playbooks/art-nanobanana.md`). It also does not own
`client/art/lockerroom/*`, which the same script produces.

Everything here is drawn from a fixed seed and fixed geometry, so re-running it
reproduces the committed PNGs byte for byte. CI never regenerates art.

What it writes (all RGBA PNG, palette = the starter's Ink & Print world:
stage #16110d -> #241a12, paper #f2e8d8, ink #2a1f16, amber #e8a33d):

    floor.png            48x48  foundry deck plate, the passable tile
    floor_alt.png        48x48  the same plate, rotated grain (checker relief)
    pillar.png           48x48  poured-stone pillar block (2x2 of these)
    wall.png             48x48  the border wall ring
    pad_lit.png          48x48  a seep pad with a raw token growing on it
    pad_dark.png         48x48  a seep pad still regrowing
    token_raw.png        24x24  level 0: dull grey ore
    token_refined.png    24x24  level 1: polished bronze, rim highlight
    token_super.png      24x24  level 2: white-gold, four-point sparkle
    pip_raw.png          12x12  the badge-sized token at each sheen
    pip_refined.png      12x12
    pip_super.png        12x12
    beam_lane.png        48x16  one cell of the gift beam's lane
    beam_fizzle.png      48x16  a miss
    burst.png            64x64  the consume flash
    puff.png             48x48  the invCap spill
    badge.png            56x20  the three-slot inventory badge frame
    graph_node.png       28x28  a trust-graph hexagon node
    graph_arc.png        64x8   a trust-graph edge segment
"""

from __future__ import annotations

import math
import os
import random

from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DATA = os.path.join(ROOT, "data")

CELL = 48
# The deck has to READ. The starter's stage colours (#16110d -> #241a12) are
# the page BACKGROUND; a floor painted in them renders as a black rectangle in
# a 360 px iframe, which is what the first viewer-smoke screenshot showed. The
# plate is lifted well clear of the backdrop and keeps the warm hue.
STAGE_LO = (46, 35, 25)
STAGE_HI = (74, 57, 40)
INK = (42, 31, 22)
PAPER = (242, 232, 216)
AMBER = (232, 163, 61)
SEEP = (87, 201, 138)

RAW = (150, 148, 143)
RAW_DARK = (92, 90, 86)
BRONZE = (206, 142, 62)
BRONZE_DARK = (128, 82, 30)
GOLD = (255, 244, 214)
GOLD_DARK = (226, 178, 60)

LEVELS = {
    "raw": (RAW, RAW_DARK),
    "refined": (BRONZE, BRONZE_DARK),
    "super": (GOLD, GOLD_DARK),
}


def save(image: Image.Image, name: str) -> None:
    os.makedirs(DATA, exist_ok=True)
    image.save(os.path.join(DATA, name))
    print(f"data/{name}  {image.width}x{image.height}")


def grain(image: Image.Image, seed: int, amount: int = 10) -> Image.Image:
    """A fixed-seed warm-dark speckle so a flat fill never reads as plastic."""
    rng = random.Random(seed)
    pixels = image.load()
    for y in range(image.height):
        for x in range(image.width):
            r, g, b, a = pixels[x, y]
            if a == 0:
                continue
            n = rng.randint(-amount, amount)
            pixels[x, y] = (
                max(0, min(255, r + n)),
                max(0, min(255, g + n)),
                max(0, min(255, b + n)),
                a,
            )
    return image


def floor_tile(seed: int, flip: bool) -> Image.Image:
    """A riveted deck plate: warm dark ground, a lighter inset, four rivets."""
    tile = Image.new("RGBA", (CELL, CELL), STAGE_LO + (255,))
    draw = ImageDraw.Draw(tile)
    draw.rectangle([1, 1, CELL - 2, CELL - 2], fill=STAGE_HI + (255,))
    # Grain lines run one way on the plate and the other on its neighbour, so
    # the deck reads as laid plates rather than one flat sheet.
    for i in range(4, CELL - 4, 6):
        if flip:
            draw.line([(4, i), (CELL - 5, i)], fill=(88, 68, 48, 255))
        else:
            draw.line([(i, 4), (i, CELL - 5)], fill=(88, 68, 48, 255))
    for cx, cy in ((5, 5), (CELL - 6, 5), (5, CELL - 6), (CELL - 6, CELL - 6)):
        draw.ellipse([cx - 2, cy - 2, cx + 2, cy + 2], fill=(38, 29, 21, 255))
        draw.ellipse([cx - 1, cy - 1, cx + 1, cy + 1], fill=(112, 88, 62, 255))
    return grain(tile, seed, 7)


def pillar_tile() -> Image.Image:
    """Poured stone: a pale block with a hard shadow on two sides."""
    tile = Image.new("RGBA", (CELL, CELL), (0, 0, 0, 0))
    draw = ImageDraw.Draw(tile)
    draw.rectangle([0, 0, CELL - 1, CELL - 1], fill=(140, 122, 100, 255))
    draw.rectangle([0, 0, CELL - 1, 3], fill=(178, 158, 130, 255))
    draw.rectangle([0, 0, 3, CELL - 1], fill=(166, 146, 120, 255))
    draw.rectangle([CELL - 5, 0, CELL - 1, CELL - 1], fill=(84, 70, 55, 255))
    draw.rectangle([0, CELL - 5, CELL - 1, CELL - 1], fill=(70, 57, 44, 255))
    for y in range(10, CELL - 6, 12):
        draw.line([(5, y), (CELL - 7, y)], fill=(108, 92, 74, 255))
    return grain(tile, 4242, 9)


def wall_tile() -> Image.Image:
    """The border ring: darker, banded, unmistakably not floor."""
    tile = Image.new("RGBA", (CELL, CELL), (0, 0, 0, 0))
    draw = ImageDraw.Draw(tile)
    draw.rectangle([0, 0, CELL - 1, CELL - 1], fill=(26, 20, 15, 255))
    for y in range(0, CELL, 8):
        draw.rectangle([2, y + 1, CELL - 3, y + 4], fill=(58, 45, 33, 255))
    draw.rectangle([0, 0, CELL - 1, 1], fill=(96, 76, 55, 255))
    return grain(tile, 77, 6)


def pad_tile(lit: bool) -> Image.Image:
    """A floor vent. Dark while it regrows; a bright seam once a token sits."""
    tile = floor_tile(9001, False)
    draw = ImageDraw.Draw(tile)
    inner = (SEEP if lit else (60, 96, 76))
    glow = Image.new("RGBA", (CELL, CELL), (0, 0, 0, 0))
    gdraw = ImageDraw.Draw(glow)
    gdraw.ellipse([8, 12, CELL - 9, CELL - 13],
                  fill=inner + (150 if lit else 70,))
    glow = glow.filter(ImageFilter.GaussianBlur(4 if lit else 2))
    tile.alpha_composite(glow)
    for i, y in enumerate(range(15, CELL - 14, 5)):
        shade = 210 if lit else 120
        draw.line([(11 + (i % 2), y), (CELL - 12 - (i % 2), y)],
                  fill=inner + (shade,), width=2)
    draw.rectangle([7, 11, CELL - 8, CELL - 12], outline=(20, 15, 11, 220))
    return tile


def token(size: int, level: str) -> Image.Image:
    """A token at one refinement sheen, drawn to read at 24 px and at 12 px."""
    face, dark = LEVELS[level]
    scale = 4
    big = Image.new("RGBA", (size * scale, size * scale), (0, 0, 0, 0))
    draw = ImageDraw.Draw(big)
    span = size * scale
    pad = span * 0.10
    draw.ellipse([pad, pad, span - pad, span - pad], fill=dark + (255,))
    draw.ellipse([pad + span * 0.06, pad + span * 0.06,
                  span - pad - span * 0.10, span - pad - span * 0.10],
                 fill=face + (255,))
    if level == "raw":
        # Ore: a chipped, faceted lump rather than a coin.
        draw.polygon([(span * 0.32, span * 0.30), (span * 0.58, span * 0.24),
                      (span * 0.70, span * 0.52), (span * 0.50, span * 0.72),
                      (span * 0.28, span * 0.58)], fill=(178, 176, 170, 255))
        draw.line([(span * 0.36, span * 0.62), (span * 0.62, span * 0.36)],
                  fill=RAW_DARK + (255,), width=max(2, span // 24))
    elif level == "refined":
        # Polished: a bright rim and a struck bar across the face.
        draw.ellipse([pad + span * 0.04, pad + span * 0.04,
                      span - pad - span * 0.04, span - pad - span * 0.04],
                     outline=(255, 214, 150, 255), width=max(2, span // 20))
        draw.rectangle([span * 0.32, span * 0.44, span * 0.68, span * 0.56],
                       fill=(246, 205, 137, 255))
    else:
        # Super: white-gold with a four-point star sitting proud of the face.
        for a in range(4):
            ang = math.pi / 2 * a
            draw.polygon([
                (span / 2 + math.cos(ang) * span * 0.42,
                 span / 2 + math.sin(ang) * span * 0.42),
                (span / 2 + math.cos(ang + 0.5) * span * 0.13,
                 span / 2 + math.sin(ang + 0.5) * span * 0.13),
                (span / 2 + math.cos(ang - 0.5) * span * 0.13,
                 span / 2 + math.sin(ang - 0.5) * span * 0.13),
            ], fill=(255, 252, 236, 255))
        draw.ellipse([span * 0.36, span * 0.36, span * 0.64, span * 0.64],
                     fill=GOLD_DARK + (255,))
    return big.resize((size, size), Image.LANCZOS)


def beam_lane(hit: bool) -> Image.Image:
    """One cell of the gift beam. `hit` is the bright lane; else a grey fizzle."""
    lane = Image.new("RGBA", (CELL, 16), (0, 0, 0, 0))
    draw = ImageDraw.Draw(lane)
    core = PAPER if hit else (138, 127, 114)
    halo = AMBER if hit else (96, 88, 78)
    draw.rectangle([0, 4, CELL - 1, 11], fill=halo + (110 if hit else 60,))
    draw.rectangle([0, 6, CELL - 1, 9], fill=core + (235 if hit else 120,))
    if hit:
        for x in range(2, CELL, 12):
            draw.rectangle([x, 3, x + 3, 12], fill=core + (150,))
    return lane.filter(ImageFilter.GaussianBlur(0.6))


def burst() -> Image.Image:
    """The consume flash: an amber ring blowing out from the till."""
    size = 64
    image = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    for i, radius in enumerate((30, 22, 14)):
        alpha = 70 + i * 50
        draw.ellipse([size / 2 - radius, size / 2 - radius,
                      size / 2 + radius, size / 2 + radius],
                     outline=AMBER + (alpha,), width=3)
    for a in range(8):
        ang = math.pi / 4 * a
        draw.line([(size / 2 + math.cos(ang) * 10, size / 2 + math.sin(ang) * 10),
                   (size / 2 + math.cos(ang) * 28, size / 2 + math.sin(ang) * 28)],
                  fill=PAPER + (180,), width=2)
    return image.filter(ImageFilter.GaussianBlur(1.2))


def puff() -> Image.Image:
    """The invCap spill: tokens bouncing off a full hopper and fading."""
    image = Image.new("RGBA", (CELL, CELL), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    rng = random.Random(31337)
    for _ in range(9):
        x = rng.randint(6, CELL - 7)
        y = rng.randint(6, CELL - 7)
        r = rng.randint(2, 5)
        draw.ellipse([x - r, y - r, x + r, y + r], fill=(150, 148, 143, 130))
    return image.filter(ImageFilter.GaussianBlur(1.4))


def badge_frame() -> Image.Image:
    """The three-slot inventory plate that rides over a cog's head."""
    image = Image.new("RGBA", (56, 20), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    draw.rounded_rectangle([0, 0, 55, 19], radius=5, fill=(14, 10, 7, 205))
    draw.rounded_rectangle([0, 0, 55, 19], radius=5,
                           outline=(242, 232, 216, 44), width=1)
    for x in (18, 37):
        draw.line([(x, 4), (x, 15)], fill=(242, 232, 216, 34))
    return image


def graph_node() -> Image.Image:
    """A trust-graph hexagon node, tinted at draw time by the renderer."""
    scale = 4
    span = 28 * scale
    big = Image.new("RGBA", (span, span), (0, 0, 0, 0))
    draw = ImageDraw.Draw(big)
    points = [
        (span / 2 + math.cos(math.pi / 3 * i - math.pi / 6) * span * 0.42,
         span / 2 + math.sin(math.pi / 3 * i - math.pi / 6) * span * 0.42)
        for i in range(6)
    ]
    draw.polygon(points, fill=(30, 23, 17, 235), outline=PAPER + (200,))
    return big.resize((28, 28), Image.LANCZOS)


def graph_arc() -> Image.Image:
    """One straight segment of a trust-graph edge (the renderer tints + tiles)."""
    image = Image.new("RGBA", (64, 8), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    draw.rectangle([0, 3, 63, 4], fill=PAPER + (235,))
    draw.rectangle([0, 2, 63, 5], fill=PAPER + (90,))
    return image


def main() -> None:
    save(floor_tile(101, False), "floor.png")
    save(floor_tile(202, True), "floor_alt.png")
    save(pillar_tile(), "pillar.png")
    save(wall_tile(), "wall.png")
    save(pad_tile(True), "pad_lit.png")
    save(pad_tile(False), "pad_dark.png")
    for level in LEVELS:
        save(token(24, level), f"token_{level}.png")
        save(token(12, level), f"pip_{level}.png")
    save(beam_lane(True), "beam_lane.png")
    save(beam_lane(False), "beam_fizzle.png")
    save(burst(), "burst.png")
    save(puff(), "puff.png")
    save(badge_frame(), "badge.png")
    save(graph_node(), "graph_node.png")
    save(graph_arc(), "graph_arc.png")


if __name__ == "__main__":
    main()
