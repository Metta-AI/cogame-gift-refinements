#!/usr/bin/env python3
"""Key, split and pad the nano-banana cog sheet into the six board sprites.

`scripts/art/source/cogs_sheet.png` is one nano-banana (gemini-2.5-flash-image)
render of SIX Softmax cogs on a flat chroma-green backdrop, one kit per slot so
the six read apart at board scale with no label:

    slot 0  Aro  red     — a lumpy raw ore rock held at chest height
    slot 1  Bex  orange  — a wide grey funnel hopper worn as a hat
    slot 2  Cyr  yellow  — a bronze refining crucible held in both hands
    slot 3  Dov  lime    — a tall spiral coil antenna off the back
    slot 4  Eno  blue    — a glowing white-gold super ingot star
    slot 5  Fay  pink    — a short fat gift-beam emitter raised in one hand

Gemini returns no alpha and the "pure green" it draws is *some* green with a
tinted edge, so the key is a flood fill from the image border against the
MEDIAN border colour (corners sometimes carry a smudge) — that way a green
accent inside a cog survives. The row is then split on empty columns, each part
cropped to its ink, padded to a square and resized.

Outputs (committed; CI never regenerates art):

    data/cog_<colour>_front.png   96x96  the board body
    data/cog_<colour>_beam.png    96x96  firing pose (leaning, brightened)
    data/cog_<colour>_bank.png    96x96  cash-out pose (crouched, warm flash)
    client/art/lockerroom/<lk>_<pose>.webp
                                  the pre-load curtain's four bot carousels
                                  (the inherited buildLockerRoom names exactly
                                  red/green/blue/yellow x poses 1,2,3,5,6)
    client/art/lockerroom/bg.jpg  the curtain's empty-room plate, from the
                                  second nano-banana render
                                  (scripts/art/source/lockerroom_bg.png — a
                                  refinery floor at shift change)

`scripts/art/gen_gift_art.py` owns every OTHER asset in `data/` — floor,
pillars, the wall ring, seep pads, tokens, beams, bursts, the badge frame and
the trust-graph art. It does NOT own the six `cog_*.png` files above; those come
from here.

    python3 scripts/art/split_cog_sheet.py
"""

from __future__ import annotations

import os
from collections import deque

from PIL import Image, ImageEnhance

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SOURCE = os.path.join(ROOT, "scripts", "art", "source", "cogs_sheet.png")
BG_SOURCE = os.path.join(ROOT, "scripts", "art", "source", "lockerroom_bg.png")
DATA = os.path.join(ROOT, "data")
LOCKER = os.path.join(ROOT, "client", "art", "lockerroom")

# Slot order on the sheet, left to right. These are the design note's body
# colours (`## The game` §Seats) and they are the sprite file names the
# renderer asks for.
COLOURS = ["red", "orange", "yellow", "lime", "blue", "pink"]
SPRITE_PX = 96

# The inherited pre-load curtain (client/replay_broadcast.html, buildLockerRoom)
# declares four bots by colour and five poses each. It ships verbatim, so the
# art is named to fit it rather than the other way round: these four cogs stand
# in the refinery at shift change.
LOCKER_BOTS = {"red": "red", "green": "lime", "blue": "blue", "yellow": "yellow"}
LOCKER_POSES = [1, 2, 3, 5, 6]
LOCKER_PX = 320
# The inherited curtain lays its bots out in percentages of a 992x926 plate.
LOCKER_BG = (992, 926)


def median_border(image: Image.Image) -> tuple[int, int, int]:
    """The backdrop colour: the median of every pixel on the image border."""
    width, height = image.size
    reds, greens, blues = [], [], []
    for x in range(width):
        for y in (0, height - 1):
            r, g, b = image.getpixel((x, y))[:3]
            reds.append(r)
            greens.append(g)
            blues.append(b)
    for y in range(height):
        for x in (0, width - 1):
            r, g, b = image.getpixel((x, y))[:3]
            reds.append(r)
            greens.append(g)
            blues.append(b)
    reds.sort()
    greens.sort()
    blues.sort()
    mid = len(reds) // 2
    return reds[mid], greens[mid], blues[mid]


def key_backdrop(image: Image.Image, tolerance: int = 60) -> Image.Image:
    """Flood-fill the chroma backdrop from the border and cut it to alpha."""
    image = image.convert("RGBA")
    width, height = image.size
    pixels = image.load()
    kr, kg, kb = median_border(image)

    def is_backdrop(x: int, y: int) -> bool:
        r, g, b, _ = pixels[x, y]
        return abs(r - kr) + abs(g - kg) + abs(b - kb) <= tolerance * 3

    seen = bytearray(width * height)
    queue: deque[tuple[int, int]] = deque()
    for x in range(width):
        for y in (0, height - 1):
            if not seen[y * width + x] and is_backdrop(x, y):
                seen[y * width + x] = 1
                queue.append((x, y))
    for y in range(height):
        for x in (0, width - 1):
            if not seen[y * width + x] and is_backdrop(x, y):
                seen[y * width + x] = 1
                queue.append((x, y))
    while queue:
        x, y = queue.popleft()
        pixels[x, y] = (0, 0, 0, 0)
        for nx, ny in ((x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)):
            if 0 <= nx < width and 0 <= ny < height and not seen[ny * width + nx]:
                if is_backdrop(nx, ny):
                    seen[ny * width + nx] = 1
                    queue.append((nx, ny))
    return image


def column_runs(image: Image.Image, floor: int = 8) -> list[tuple[int, int]]:
    """Runs of columns that carry ink, in left-to-right order."""
    width, height = image.size
    alpha = image.split()[3].load()
    runs: list[tuple[int, int]] = []
    start = None
    for x in range(width):
        ink = 0
        for y in range(height):
            if alpha[x, y] > 24:
                ink += 1
                if ink >= floor:
                    break
        if ink >= floor:
            if start is None:
                start = x
        elif start is not None:
            runs.append((start, x))
            start = None
    if start is not None:
        runs.append((start, width))
    return runs


def merge_to(runs: list[tuple[int, int]], want: int) -> list[tuple[int, int]]:
    """Merge the narrowest neighbouring runs until exactly `want` remain.

    A cog's held prop can float clear of its body (the pink emitter, the lime
    antenna), which the column scan sees as a second run. Merging the smallest
    gaps first re-joins a prop with the body it belongs to without ever
    merging two cogs, whose gap is by far the widest.
    """
    runs = list(runs)
    while len(runs) > want:
        gaps = [(runs[i + 1][0] - runs[i][1], i) for i in range(len(runs) - 1)]
        _, index = min(gaps)
        runs[index] = (runs[index][0], runs[index + 1][1])
        del runs[index + 1]
    if len(runs) != want:
        raise SystemExit(f"expected {want} cogs on the sheet, found {len(runs)}")
    return runs


def square(part: Image.Image, size: int) -> Image.Image:
    """Crop to ink, pad to a square, resize. Feet stay on the bottom edge."""
    box = part.getbbox()
    if box is None:
        raise SystemExit("a sheet column keyed out completely")
    part = part.crop(box)
    side = max(part.size)
    canvas = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    canvas.paste(part, ((side - part.width) // 2, side - part.height))
    return canvas.resize((size, size), Image.LANCZOS)


def tint(image: Image.Image, factor: float, warm: tuple[int, int, int] | None = None):
    out = ImageEnhance.Brightness(image).enhance(factor)
    if warm is not None:
        glow = Image.new("RGBA", out.size, warm + (56,))
        glow.putalpha(Image.eval(out.split()[3], lambda a: (a * 56) // 255))
        out = Image.alpha_composite(out, glow)
    return out


def beam_pose(front: Image.Image) -> Image.Image:
    """Firing: the body leans into the beam and the whole cog brightens."""
    out = Image.new("RGBA", front.size, (0, 0, 0, 0))
    lifted = tint(front, 1.22, (255, 236, 178))
    out.paste(lifted.resize((front.width, int(front.height * 0.97)), Image.LANCZOS),
              (int(front.width * 0.03), int(front.height * 0.03)))
    return out


def bank_pose(front: Image.Image) -> Image.Image:
    """Cashing out: the cog squats over the till in a warm flash."""
    out = Image.new("RGBA", front.size, (0, 0, 0, 0))
    squashed = tint(front, 1.1, (255, 196, 92)).resize(
        (int(front.width * 1.04), int(front.height * 0.92)), Image.LANCZOS)
    out.paste(squashed, (-int(front.width * 0.02), int(front.height * 0.08)))
    return out


def locker_pose(front: Image.Image, index: int, size: int) -> Image.Image:
    """One frame of a bot's ~4fps idle loop in the pre-load curtain."""
    bob = (0, -3, -5, -2, 1)[index % 5]
    lean = (0.0, 0.01, 0.0, -0.01, 0.0)[index % 5]
    body = tint(front, 1.0 + 0.04 * (index % 3))
    body = body.resize((size, size), Image.LANCZOS)
    if lean:
        body = body.rotate(lean * 180 / 3.14159, resample=Image.BICUBIC)
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    canvas.paste(body, (0, bob))
    return canvas


def main() -> None:
    os.makedirs(DATA, exist_ok=True)
    os.makedirs(LOCKER, exist_ok=True)
    sheet = key_backdrop(Image.open(SOURCE))
    runs = merge_to(column_runs(sheet), len(COLOURS))
    fronts: dict[str, Image.Image] = {}
    for colour, (x0, x1) in zip(COLOURS, runs):
        front = square(sheet.crop((x0, 0, x1, sheet.height)), SPRITE_PX)
        fronts[colour] = front
        front.save(os.path.join(DATA, f"cog_{colour}_front.png"))
        beam_pose(front).save(os.path.join(DATA, f"cog_{colour}_beam.png"))
        bank_pose(front).save(os.path.join(DATA, f"cog_{colour}_bank.png"))
        print(f"cog_{colour}_*.png  from sheet columns {x0}..{x1}")

    for locker_name, colour in LOCKER_BOTS.items():
        big = square(sheet.crop(
            (runs[COLOURS.index(colour)][0], 0,
             runs[COLOURS.index(colour)][1], sheet.height)), LOCKER_PX)
        for slot, pose in enumerate(LOCKER_POSES):
            locker_pose(big, slot, LOCKER_PX).save(
                os.path.join(LOCKER, f"{locker_name}_{pose}.webp"),
                format="WEBP", lossless=True)
        print(f"lockerroom/{locker_name}_*.webp  from the {colour} cog")

    plate = Image.open(BG_SOURCE).convert("RGB").resize(LOCKER_BG, Image.LANCZOS)
    plate.save(os.path.join(LOCKER, "bg.jpg"), format="JPEG", quality=88)
    print("lockerroom/bg.jpg  the refinery floor at shift change")


if __name__ == "__main__":
    main()
