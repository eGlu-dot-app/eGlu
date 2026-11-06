#!/usr/bin/env python3
"""The Engineer app icon: a terminal window in satin chrome, its screen a green dot-matrix display.

    python3 engineer.py --plates App/Engineer.icon/Assets
    python3 engineer.py --preview /tmp/engineer

--plates writes the icon's two pictures, metal-light.png and metal-dark.png:
the whole square, which Icon Composer cuts to the tile. It also writes the
window's three lights, close.svg, minimise.svg and zoom.svg: Liquid Glass
layers that sit on the chrome, coloured in icon.json. --preview
writes the pictures cut to the tile, light and dark side by side, at 512, 180
and 60 px, without the lights, which only Icon Composer draws.

What it draws from, in this folder: frame.svg, the window's frame (its hole is
the screen); e-pixels.svg, the e globe and its crescents on the window's
19.5-point grid, each cell of which becomes four dots; beam-body.svg, the
I-beam's cells on the same grid; and
../fluted-glass/squircle-mask.png, the tile's outline. Every measure is in
points of the 1024-point icon.
"""

# Drawing.
SUPERSAMPLE = 2  # Samples along each output-pixel axis.
E_SHIFT = (0.0, -39.0)  # Where the e globe sits: the old pixel layer's translation.
DOT_PITCH = 9.75  # Spacing of the dots: half a cell of the window's grid.
DOT_SMALL = 0.15  # Radius of a dot off the e, as a share of the pitch.
DOT_LARGE = 0.44  # Radius of a dot on the e.
COVER_BLUR = 5.0  # Blur (Gaussian sigma) of the e before it is sampled, so its dots shrink towards its edges.
COVER_LOW = 0.10  # Coverage below which a dot is the small one.
COVER_HIGH = 0.80  # Coverage above which a dot is the large one.

# The beam: the old pixel I-beam's cells in raised chrome.
BEAM_SHIFT = (19.5, -19.5)  # Where the beam sits: the old pixel layers' translation.
BEAM_BEVEL = 6.0  # Width of the beam's bevel.
BEAM_SHEEN = (0.12, 0.92)  # The span of the chrome's reflection, light to steel, that runs across the beam's width.

# The window's lights: glass layers on the chrome.
LAMPS = (("close", 215.0, 85.0), ("minimise", 303.7, 85.0), ("zoom", 392.4, 85.0))
LAMP_RADIUS = 26.6  # Radius of each light.

# The chrome: lit from the top left; the reflection runs across, light on the left, steel blue on the right.
LIGHT_X = -0.6  # Direction the light comes from, across.
LIGHT_Y = -0.8  # And down.
BEVEL = 13.0  # Width of the frame's bevels.
BEVEL_CURVE = 1.6  # How fast a bevel flattens towards its top: 1 evenly, more for a rounder edge.
HIGHLIGHT = 0.85  # How far a bevel facing the light turns to its highlight.
SHADOW = 0.85  # How far a bevel facing away turns to its shadow.
RIM = 1.1  # Width of the bright line along every edge.
RIM_STRENGTH = 0.55  # Its strength.
BRUSH = 0.010  # Strength of the faint horizontal brushing.
TOP_LIFT = 0.04  # How much lighter the chrome is at the top than at the foot.
LIGHT_METAL = (  # Across the icon, from left to right: (share of the width, sRGB).
    (0.00, (0.94, 0.96, 0.99)), (0.26, (0.99, 1.00, 1.00)), (0.48, (0.89, 0.92, 0.96)), (0.64, (0.73, 0.79, 0.87)),
    (0.73, (0.63, 0.70, 0.80)), (0.86, (0.72, 0.78, 0.87)), (1.00, (0.66, 0.73, 0.83)))
LIGHT_HIGHLIGHT = (1.00, 1.00, 1.00)
LIGHT_SHADOW = (0.42, 0.50, 0.62)
LIGHT_RIM = (1.00, 1.00, 1.00)
DARK_METAL = (  # Graphite, for the dark appearance.
    (0.00, (0.44, 0.47, 0.52)), (0.26, (0.50, 0.53, 0.58)), (0.48, (0.38, 0.41, 0.46)), (0.64, (0.26, 0.29, 0.34)),
    (0.73, (0.21, 0.24, 0.28)), (0.86, (0.27, 0.30, 0.35)), (1.00, (0.23, 0.26, 0.30)))
DARK_HIGHLIGHT = (0.74, 0.78, 0.84)
DARK_SHADOW = (0.06, 0.07, 0.09)
DARK_RIM = (0.66, 0.70, 0.76)

# The screen, in linear light: black, with a green glow round its edge from a neon line just inside it.
SCREEN_BLACK = (0.000, 0.0012, 0.0008)
HALO = (0.006, 0.34, 0.15)  # The green round the edge.
HALO_WIDTH = 44.0  # How far in the green reaches (exponential fall).
HALO_LIP = 2.5  # How fast it darkens between the line and the chrome.
TUBE = (0.55, 1.00, 0.75)  # The neon line.
TUBE_INSET = 9.0  # Its distance in from the chrome.
TUBE_WIDTH = 2.0  # Its half-width (Gaussian sigma).
TUBE_GLOW = (0.05, 0.60, 0.30)  # The glow round the line.
TUBE_GLOW_WIDTH = 7.0  # Its sigma.
TUBE_FOOT = 0.75  # The glow at the screen's foot, against its top.
DOT_ON = (0.18, 1.00, 0.48)  # A dot on the e.
DOT_CORE = (0.55, 1.00, 0.76)  # The palest, in the e's thickest parts.
DOT_OFF = (0.02, 0.30, 0.14)  # A dot off the e, at full glow.
DOT_OFF_FLOOR = 0.06  # Its brightness away from the glow.
DOT_OFF_GLOW = 1.6  # How much brighter it is in the glow.
BLOOM = 0.35  # The dots' and the line's light spread on the glass.
BLOOM_WIDTH = 4.0  # Its sigma.
GRAIN = 0.002  # Grain against banding, in sRGB.
SEED = 4127

import argparse
import re
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw
from scipy.ndimage import distance_transform_edt, gaussian_filter, map_coordinates

HERE = Path(__file__).resolve().parent
SS = SUPERSAMPLE
N = 1024 * SS


def smoothstep(low, high, value):
    t = np.clip((value - low) / (high - low), 0, 1)
    return t * t * (3 - 2 * t)


def srgb(rgb):
    rgb = np.clip(rgb, 0, 1)
    return np.where(rgb <= 0.0031308, rgb * 12.92, 1.055 * rgb ** (1 / 2.4) - 0.055)


def grid():
    """Every sample's position in points."""
    y, x = np.indices((N, N), dtype=np.float32)
    return (x + 0.5) / SS, (y + 0.5) / SS


def tile():
    mask = Image.open(HERE.parent / "fluted-glass" / "squircle-mask.png").convert("L")
    return np.asarray(mask.resize((N, N), Image.Resampling.BICUBIC), np.float32) / 255


def screen():
    """The frame's hole, from frame.svg: its second subpath."""
    path = re.search(r'd="([^"]*)"', (HERE / "frame.svg").read_text()).group(1)
    numbers = [float(v) for v in re.findall(r"-?\d+\.?\d*", path.split("Z")[1])]
    points = [(x * SS * 2, y * SS * 2) for x, y in zip(numbers[0::2], numbers[1::2])]
    image = Image.new("L", (N * 2, N * 2), 0)
    ImageDraw.Draw(image).polygon(points, fill=255)
    return np.asarray(image, np.float32).reshape(N, 2, N, 2).mean(axis=(1, 3)) / 255


def dots(x, y):
    """The e as dots: coverage of each dot from the e's cells, blurred, and each sample's dot."""
    text = (HERE / "e-pixels.svg").read_text()
    rects = [tuple(map(float, r)) for r in re.findall(r'<rect x="([\d.]+)" y="([\d.]+)" width="([\d.]+)" height="([\d.]+)"', text)]
    cell = 2 * DOT_PITCH
    margin = (cell - rects[0][2]) / 2
    on = np.zeros((1024, 1024), np.float32)  # One sample a point is enough for the blurred coverage.
    for rx, ry, w, h in rects:
        left, top = rx - margin + E_SHIFT[0], ry - margin + E_SHIFT[1]
        on[int(round(top)):int(round(top + cell)), int(round(left)):int(round(left + cell))] = 1
    cover = gaussian_filter(on, COVER_BLUR)
    origin_x = (rects[0][0] - margin + E_SHIFT[0]) % DOT_PITCH
    origin_y = (rects[0][1] - margin + E_SHIFT[1]) % DOT_PITCH
    ix = np.floor((x - origin_x) / DOT_PITCH)
    iy = np.floor((y - origin_y) / DOT_PITCH)
    cx = origin_x + (ix + 0.5) * DOT_PITCH
    cy = origin_y + (iy + 0.5) * DOT_PITCH
    c = map_coordinates(cover, (cy - 0.5, cx - 0.5), order=1, mode="nearest")
    t = smoothstep(COVER_LOW, COVER_HIGH, c)
    radius = DOT_PITCH * (DOT_SMALL + (DOT_LARGE - DOT_SMALL) * t)
    alpha = np.clip((radius - np.hypot(x - cx, y - cy)) * SS + 0.5, 0, 1)
    return alpha, t, smoothstep(0.75, 1.0, c)


def cells(name, shift):
    """Coverage of the cells drawn in one of this folder's pixel drawings, moved by `shift`."""
    text = (HERE / name).read_text()
    image = Image.new("L", (N * 2, N * 2), 0)
    draw = ImageDraw.Draw(image)
    for rx, ry, w, h in re.findall(r'<rect x="([\d.]+)" y="([\d.]+)" width="([\d.]+)" height="([\d.]+)"', text):
        left, top = (float(rx) + shift[0]) * SS * 2, (float(ry) + shift[1]) * SS * 2
        draw.rectangle((left, top, left + float(w) * SS * 2 - 1, top + float(h) * SS * 2 - 1), fill=255)
    return np.asarray(image, np.float32).reshape(N, 2, N, 2).mean(axis=(1, 3)) / 255


def beam():
    """The I-beam: signed distance in, in points, and coverage."""
    body = cells("beam-body.svg", BEAM_SHIFT)
    solid = body > 0.5
    inside = (distance_transform_edt(solid) - distance_transform_edt(~solid)) / SS
    return inside.astype(np.float32), body


def interpolate(stops, u):
    positions = [s for s, _ in stops]
    return np.stack([np.interp(u, positions, [c[channel] for _, c in stops]) for channel in range(3)], axis=-1)


def chrome(x, y, inside, appearance, bevel, rng, across=None):
    """Metal lit from the top left, raised by a bevel along the edge of `inside` (signed distance in, in points).

    `across` places each sample in the reflection, 0 at its light left end and 1 at its steel right end: by
    default its place across the icon.
    """
    dark = appearance == "Dark"
    colour = interpolate(DARK_METAL if dark else LIGHT_METAL, x / 1024 if across is None else across)
    colour = colour * (1 + TOP_LIFT * (0.5 - y / 1024))[..., None]
    brushing = gaussian_filter(rng.normal(size=x.shape).astype(np.float32), (0.6 * SS, 60 * SS))
    colour = colour * (1 + BRUSH * brushing / max(brushing.std(), 1e-6))[..., None]
    gy, gx = np.gradient(gaussian_filter(inside, 0.8 * SS))
    length = np.maximum(np.hypot(gx, gy), 1e-6)
    light = np.array((LIGHT_X, LIGHT_Y)) / np.hypot(LIGHT_X, LIGHT_Y)
    facing = -(gx * light[0] + gy * light[1]) / length  # The edge's outward direction against the light.
    slope = (1 - np.clip(inside / bevel, 0, 1)) ** BEVEL_CURVE * (inside > -1)
    shade = facing * slope
    highlight = np.array(DARK_HIGHLIGHT if dark else LIGHT_HIGHLIGHT)
    shadow = np.array(DARK_SHADOW if dark else LIGHT_SHADOW)
    lit = np.clip(shade, 0, 1)[..., None] * HIGHLIGHT
    unlit = np.clip(-shade, 0, 1)[..., None] * SHADOW
    colour = colour + lit * (highlight - colour)
    colour = colour + unlit * (shadow - colour)
    rim = RIM_STRENGTH * np.exp(-0.5 * (np.maximum(inside, 0) / RIM) ** 2) * (0.55 + 0.45 * np.clip(facing, 0, 1))
    colour = colour + rim[..., None] * (np.array(DARK_RIM if dark else LIGHT_RIM) - colour)
    return colour


def display(x, y, inside):
    """The screen in linear light, `inside` its distance in from the chrome."""
    alpha, on, core = dots(x, y)
    foot = 1 - (1 - TUBE_FOOT) * np.clip((y - 170) / 806, 0, 1)
    off = inside - TUBE_INSET
    halo = np.exp(-np.maximum(off, 0) / HALO_WIDTH + np.minimum(off, 0) / HALO_LIP) * foot
    tube = np.exp(-0.5 * (off / TUBE_WIDTH) ** 2) * foot
    glow = np.exp(-0.5 * (off / TUBE_GLOW_WIDTH) ** 2) * foot
    ground = np.array(SCREEN_BLACK) + halo[..., None] * np.array(HALO)
    dim = np.array(DOT_OFF) * (DOT_OFF_FLOOR + DOT_OFF_GLOW * halo)[..., None]
    lit = np.array(DOT_ON) + core[..., None] * (np.array(DOT_CORE) - DOT_ON)
    colour = dim + on[..., None] * (lit - dim)
    picture = ground * (1 - alpha[..., None]) + colour * alpha[..., None]
    light = colour * alpha[..., None] + tube[..., None] * np.array(TUBE) + glow[..., None] * np.array(TUBE_GLOW)
    picture = picture + tube[..., None] * np.array(TUBE) + glow[..., None] * np.array(TUBE_GLOW)
    picture = picture + BLOOM * gaussian_filter(light, (BLOOM_WIDTH * SS, BLOOM_WIDTH * SS, 0))
    return picture


def plate(appearance, rng):
    x, y = grid()
    outline = tile()
    glass = screen()
    frame = (outline > 0.5) & (glass < 0.5)
    inside = (distance_transform_edt(frame) - distance_transform_edt(~frame)).astype(np.float32) / SS
    picture = chrome(x, y, inside, appearance, BEVEL, rng)
    seen = (distance_transform_edt(glass > 0.5) / SS).astype(np.float32)
    picture = picture * (1 - glass[..., None]) + srgb(display(x, y, seen)) * glass[..., None]
    inside, body = beam()
    picture = picture * (1 - body[..., None])
    # The beam stays silver in the dark, as a glyph keeps its colour there.
    columns = x[body > 0.5]
    across = BEAM_SHEEN[0] + (BEAM_SHEEN[1] - BEAM_SHEEN[0]) * (x - columns.min()) / (columns.max() - columns.min())
    picture = picture + body[..., None] * chrome(x, y, inside, "Default", BEAM_BEVEL, rng, across)
    picture = picture.reshape(1024, SS, 1024, SS, 3).mean(axis=(1, 3))
    picture = picture + rng.normal(size=picture.shape[:2])[..., None] * GRAIN
    return np.uint8(np.clip(picture, 0, 1) * 255 + 0.5)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--plates", help="Write metal-light.png and metal-dark.png into this folder.")
    parser.add_argument("--preview", help="Write preview.png into this folder: light and dark, cut to the tile.")
    arguments = parser.parse_args()
    if not arguments.plates and not arguments.preview:
        parser.error("Give --plates or --preview")
    pictures = {}
    for appearance in ("Default", "Dark"):
        pictures[appearance] = Image.fromarray(plate(appearance, np.random.default_rng(SEED)), "RGB")
    if arguments.plates:
        folder = Path(arguments.plates)
        folder.mkdir(parents=True, exist_ok=True)
        pictures["Default"].save(folder / "metal-light.png", optimize=True)
        pictures["Dark"].save(folder / "metal-dark.png", optimize=True)
        for name, cx, cy in LAMPS:
            (folder / f"{name}.svg").write_text(
                '<svg width="1024" height="1024" viewBox="0 0 1024 1024" xmlns="http://www.w3.org/2000/svg">\n'
                f'<circle cx="{cx}" cy="{cy}" r="{LAMP_RADIUS}" fill="white"/>\n</svg>\n')
    if arguments.preview:
        folder = Path(arguments.preview)
        folder.mkdir(parents=True, exist_ok=True)
        mask = Image.open(HERE.parent / "fluted-glass" / "squircle-mask.png").convert("L")
        sheet = Image.new("RGB", (1024, 512 + 180 + 60), (128, 128, 128))
        for column, appearance in enumerate(("Default", "Dark")):
            icon = pictures[appearance].convert("RGBA")
            icon.putalpha(mask)
            for size, top in ((512, 0), (180, 512), (60, 692)):
                small = icon.resize((size, size), Image.Resampling.LANCZOS)
                sheet.paste(small, (column * 512 + (512 - size) // 2, top), small)
        sheet.save(folder / "preview.png")


if __name__ == "__main__":
    main()
