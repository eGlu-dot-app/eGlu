#!/usr/bin/env python3
"""Offline shallow-cylinder glass using NumPy, SciPy and Pillow.

    python3 fluted.py --all
    python3 fluted.py --version graded --rib-contrast 0.35
    python3 fluted.py --version reeded --strength -2 --appearance Dark

Positive strength magnifies each flute's view; negative strength compresses it.
Finite circular-segment normals supply Snell refraction. The left view shift
and weak vertical bulge are explicit slice-view approximations, rather than
optical power attributed to an infinitely long cylindrical surface.
"""

# Scene and rods, in pixels in the supplied 1024 px assets.
CENTER_X = 552.9  # Horizontal scene centre.
CENTER_Y = 462.3  # Vertical scene centre and equator.
AXIS_A = 365.7  # Horizontal globe semi-axis, locating the rim.
PERIOD = 40.0  # Spacing between adjacent vertical rod axes.
PHASE = 14.0  # Absolute x coordinate of a rod axis, modulo the period.
SAG = 4.0  # Height of the shallow circular segment above its valleys.
DEPTH = 100.0  # Scene distance behind the glass valleys.
WEIGHT = 8.0  # Euclidean growth radius of the globe strokes.
CORE_ALPHA = 0.5  # Alpha threshold separating the solid globe from its baked shadow.
COLOUR_SMOOTH = 12.0  # Vertical smoothing of the globe's original white/blue colour.
IOR = 1.5  # Green-channel refractive index.
DISPERSION = 0.003  # Blue/red refractive-index offset around green.
LENTICULAR_STRENGTH = 1.0  # Signed ray strength of magnifying local views.
REEDED_STRENGTH = -2.0  # Signed ray strength of compressing local views.
VIEW_OFFSET = 85.0  # Maximum rightward shift of a compressing flute's view axis.
VIEW_START = 20.0  # Start of the decline in the left-side view shift.
VIEW_END = 260.0  # End of the left-side view shift.
FOCUS_SCALE = 0.08  # Spacing ratio of the three exterior magnifying views.
FOCUS_AXIS = 134.0  # Rod axis of the innermost magnifying exterior view.
FOCUS_BIAS = 1.9  # Position of that view inside the newly thickened source rim.
FOCUS_START = 155.0  # Start of the transition from focused waves to ordinary views.
FOCUS_END = 280.0  # End of the transition to ordinary magnifying views.
FOCUS_VERTICAL = 1.65  # Vertical magnification of the focused exterior crescents.
LENTICULAR_BULGE = 0.055  # Vertical view magnification at a lenticular rod's centre.
REEDED_BULGE = 0.025  # Vertical view magnification at a reeded rod's centre.
GRADED_START = 240.0  # Beginning of the optical fade towards the cursor.
GRADED_END = 820.0  # End of the optical fade towards nearly clear glass.
GRADED_MIN = 0.055  # Remaining optical strength at the clear end.
ECHO_FADE = 0.65  # Contrast attenuation of the exterior optical echoes.
EDGE_HOLD = 2.0  # Untouched pixels inside the silhouette boundary.
EDGE_FADE = 10.0  # Additional glass fade width near the silhouette.

# Background light is part of the refracted scene, with no central hot spot.
LIGHT_CORNER = (0.99, 0.95, 0.84)  # The ivory at the edges, before the vignette: white plastic faded by the sun.
LIGHT_MID = (1.00, 0.97, 0.89)  # The ivory between.
LIGHT_GLOW = (1.00, 0.99, 0.94)  # The palest ivory, behind the globe.
GLOW_TOP = (0.36, 0.76, 1.00)  # Light mode: the blurred blue behind the globe, at its top (the dark globe's light blue).
GLOW_BOTTOM = (0.10, 0.48, 0.98)  # The blurred blue at its bottom (the dark globe's deep blue).
GLOW_STRENGTH = 1.0  # How strongly the blurred blue covers the ivory.
GLOW_SIZE = 1.25  # Size of the blurred blue against the globe's rim.
GLOW_BLUR = 135.0  # Blur radius (Gaussian sigma) of the blue.
MIX_LIFT = 2.5  # OKLab lightness added for each unit of chroma the blue and the ivory lose where they mix, so they meet in white, not grey.
AXIS_B = 304.75  # Vertical globe semi-axis.
SYSTEM_DARK_TOP = 0.133  # Dark mode: the grey (sRGB) of Icon Composer's own dark ground at its top, measured from ictool; the glass is drawn see-through over it.
SYSTEM_DARK_BOTTOM = 0.053  # The same grey at its foot.
BACKGROUND_HORIZONTAL = 0.32  # Left-to-right contribution to the light falloff.
BACKGROUND_VERTICAL = 0.68  # Top-to-bottom contribution to the light falloff.
BACKGROUND_RADIAL = 0.85  # Light mode: share of the light that gathers round a point, against the share that falls from the top left.
LIGHT_X = 440.0  # The x the gathered light is centred on.
LIGHT_Y = 400.0  # The y the gathered light is centred on.
VIGNETTE_LIGHT = 0.55  # How far the light background turns towards aged ivory at its corners.
VIGNETTE_IVORY = (0.98, 0.91, 0.74)  # The aged ivory, as an old CRT's case yellows: it reaches the corners through the blue.
VIGNETTE_INNER = 0.25  # Distance from the centre, as a share of the half-diagonal, where the light vignette begins.
VIGNETTE_OUTER = 1.0  # Distance where the vignette is full.

# The globe out of focus, more towards the left, where the waves are.
BLUR_RIGHT = 0.6  # Blur radius (Gaussian sigma) of the globe by the cursor.
BLUR_LEFT = 4.5  # Blur radius of the globe at its left.
BLUR_START = 180.0  # The x where the blur is strongest.
BLUR_END = 900.0  # The x where the blur is lightest.
BLUR_CURVE = 1.6  # How the blur grows towards the left: 1 evenly, more for a later, harder rise.

# Surface and transmission finishes, also individually overridable on the CLI.
LENTICULAR_FROST = 0.45  # Across-rod source blur of crisp lenticular glass.
REEDED_FROST = 2.0  # Across-rod source blur of frosted reeded glass.
FROST_RATIO = 5.0  # Across-rod to along-rod blur ratio.
LENTICULAR_SCATTER = 0.035  # Broad transmission scatter fraction for crisp glass.
REEDED_SCATTER = 0.18  # Broad transmission scatter fraction for frosted glass.
SCATTER_RADIUS = 11.0  # Across-rod radius of soft transmitted-light scatter.
LENTICULAR_MILK = 0.012  # Pale glass tint in lenticular transmission.
REEDED_MILK = 0.045  # Pale glass tint in reeded transmission.
LENTICULAR_SPECULAR = 0.045  # Thin edge reflection in lenticular glass.
REEDED_SPECULAR = 0.10  # Stronger thin edge reflection in reeded glass.
REFLECTION = 0.45  # Strength of Schlick-weighted environment reflections.
RIB_CONTRAST = 0.35  # Broad edge attenuation, with full transmission at the rod centre.
VALLEY = 0.19  # Strength of the fine dark line between rods.
VALLEY_WIDTH = 0.032  # Valley width as a fraction of the rod half-width.
HIGHLIGHT_POSITION = -0.73  # Position of the top-left highlight within a rod.
HIGHLIGHT_WIDTH = 0.065  # Highlight width as a fraction of the rod half-width.
DARK_HIGHLIGHTS = 0.42  # Dark appearance reflection and highlight multiplier.
DARK_MILK = 0.0  # Dark appearance milkiness multiplier: none, so the system's dark ground shows through true, not faded.
GRAIN = 0.0025  # Monochrome photographic grain standard deviation in sRGB.
SEED = 7319  # Fixed seed of the repeatable grain field.

# Output quality and contact sheets.
SUPERSAMPLE = 3  # Samples along each output-pixel axis.
PREVIEW_BACKGROUND = 128  # Grey channel of the opaque contact-sheet ground.
GRID_SIZE = 512  # Size of each icon in the side-by-side light/dark grid.
SMALL_SIZE = 180  # Size of each icon in the first row of the small preview.
TINY_SIZE = 60  # Size of each icon in the second row of the small preview.

import argparse
from pathlib import Path
import time

try:
    import numpy as np
    from PIL import Image
    from scipy.ndimage import distance_transform_edt, gaussian_filter, label, map_coordinates, minimum_filter
except ImportError as exc:
    raise SystemExit(f"Missing {exc.name}. Use an offline environment with NumPy, SciPy and Pillow. "
                     "On this machine: /opt/anaconda3/bin/python3 fluted.py --all") from exc


def smoothstep(low, high, value):
    t = np.clip((value - low) / (high - low), 0, 1)
    return t * t * (3 - 2 * t)


def linear(rgb):
    return np.where(rgb <= 0.04045, rgb / 12.92, ((rgb + 0.055) / 1.055) ** 2.4)


def srgb(rgb):
    rgb = np.maximum(rgb, 0)
    return np.where(rgb <= 0.0031308, rgb * 12.92, 1.055 * rgb ** (1 / 2.4) - 0.055)


# Björn Ottosson's OKLab, from and to linear sRGB.
TO_LMS = np.array([[0.4122214708, 0.5363325363, 0.0514459929],
                   [0.2119034982, 0.6806995451, 0.1073969566],
                   [0.0883024619, 0.2817188376, 0.6299787005]])
LMS_TO_LAB = np.array([[0.2104542553, 0.7936177850, -0.0040720468],
                       [1.9779984951, -2.4285922050, 0.4505937099],
                       [0.0259040371, 0.7827717662, -0.8086757660]])


def oklab(rgb):
    return np.cbrt(np.asarray(rgb) @ TO_LMS.T) @ LMS_TO_LAB.T


def from_oklab(lab):
    return np.clip((lab @ np.linalg.inv(LMS_TO_LAB).T) ** 3 @ np.linalg.inv(TO_LMS).T, 0, 1)


def mix(a, b, t, p):
    """a to b by t, in OKLab, made lighter by the chroma the mix loses.

    Mixed as light, blue and ivory cancel to a dull grey where they meet.
    OKLCH keeps their chroma, but the shorter turn of hue from sky blue to
    ivory runs through mint green and the longer through lilac and pink. In
    OKLab the chroma still drops where the two cancel; giving it back as
    lightness fades the blue through white to ivory. Two creams lose none
    and are not lifted, so the ivory doesn't clip to lemon at the corners.
    """
    a, b, t = oklab(a), oklab(b), np.asarray(t, dtype=np.float32)
    lab = a + t[..., None] * (b - a)
    chroma = lambda lab: np.hypot(lab[..., 1], lab[..., 2])
    lost = chroma(a) + t * (chroma(b) - chroma(a)) - chroma(lab)
    lab[..., 0] += p.mix_lift * lost
    return from_oklab(lab)


def sample(plane, x, y):
    return map_coordinates(plane, (y, x), order=1, mode="nearest", prefilter=False)


def clean_layer(image):
    """Keep the main object and its shadow; remove the disconnected frame halo."""
    pixels = np.array(image.convert("RGBA"))
    components, count = label(pixels[..., 3] > 0)
    border = np.unique(np.concatenate((components[0], components[-1], components[:, 0], components[:, -1])))
    sizes = np.bincount(components.ravel(), minlength=count + 1)
    sizes[border] = 0
    if sizes.max() == 0:
        raise ValueError("No separate object component found in the input layer")
    pixels[components != sizes.argmax()] = 0
    return pixels


def grow_globe(pixels, weight, p):
    """Grow the solid globe by Euclidean distance, retaining its smooth colour gradient."""
    rgba = pixels.astype(np.float32) / 255
    if weight == 0:
        return rgba
    core = rgba[..., 3] >= p.core_alpha
    outside = distance_transform_edt(~core)
    alpha = np.clip(weight + 0.5 - outside, 0, 1)
    # The source's baked bevel/shadow contains narrow bands. Magnifying those
    # bands makes false fringes. Keep the stroke silhouette and its row colour,
    # rather than growing the baked lighting around each edge.
    rows = np.flatnonzero(np.any(core, axis=1))
    row_colour = np.array([np.median(rgba[row, core[row], :3], axis=0) for row in rows])
    profile = np.stack([np.interp(np.arange(len(rgba)), rows, row_colour[:, channel])
                        for channel in range(3)], axis=1)
    profile = gaussian_filter(profile, (p.colour_smooth, 0), mode="nearest")
    colour = np.broadcast_to(profile[:, None, :], rgba[..., :3].shape)
    return np.concatenate((colour, alpha[..., None]), axis=2)


def progressive_blur(rgba, p):
    """The globe blurred more towards the left, as if further out of focus there."""
    width = rgba.shape[1]
    left = 1 - smoothstep(p.blur_start, p.blur_end, np.arange(width, dtype=np.float32))
    sigma = p.blur_right + (p.blur_left - p.blur_right) * left ** p.blur_curve
    levels = np.linspace(sigma.min(), sigma.max(), 8)
    premultiplied = np.concatenate((rgba[..., :3] * rgba[..., 3:], rgba[..., 3:]), axis=2)
    # Each column a blend of the two blurs nearest its own radius.
    position = np.interp(sigma, levels, np.arange(len(levels)))
    blurred = np.zeros_like(premultiplied)
    for index, level in enumerate(levels):
        weight = np.clip(1 - np.abs(position - index), 0, 1)[None, :, None]
        if np.any(weight > 0):
            layer = gaussian_filter(premultiplied, (level, level, 0), mode="constant") if level > 0 else premultiplied
            blurred += layer * weight
    alpha = blurred[..., 3:]
    return np.concatenate((blurred[..., :3] / np.maximum(alpha, 1e-6), alpha), axis=2)


def vignette(rgb, x, y, p):
    """Light: turned towards aged ivory at the corners.

    The blue covers nearly the whole square, so the ivory ground alone shows
    only at its foot; drawn over the blue here, it reaches every corner. A
    darker corner, as before, would turn ivory and blue together to grey.
    """
    centre = 511.5
    distance = np.sqrt(((x - centre) / centre) ** 2 + ((y - centre) / centre) ** 2) / np.sqrt(2)
    edge = smoothstep(p.vignette_inner, p.vignette_outer, distance)
    return mix(rgb, linear(np.array(p.vignette_ivory)), p.vignette_light * edge, p)


def background(x, y, appearance, p, grey=None):
    """The ground behind the globe. Dark: a flat grey (sRGB), one of the two the see-through plate is separated from."""
    if appearance == "Dark":
        return np.full(x.shape + (3,), linear(np.float32(grey)), dtype=np.float32)
    direction = (p.background_horizontal * x + p.background_vertical * y)
    direction /= 1023 * (p.background_horizontal + p.background_vertical)
    gathered = np.clip(np.hypot(x - p.light_x, y - p.light_y) / (512 * np.sqrt(2)), 0, 1)
    direction = direction * (1 - p.background_radial) + gathered * p.background_radial
    glow = 1 - smoothstep(0, 1, direction)
    colour = np.array(p.light_corner) + np.minimum(2 * glow, 1)[..., None] * (np.array(p.light_mid) - p.light_corner)
    colour += np.maximum(2 * glow - 1, 0)[..., None] * (np.array(p.light_glow) - p.light_mid)
    rgb = linear(colour)
    # The blue, blurred behind the globe, deeper towards its bottom.
    inside = (((x - p.center_x) / (p.axis_a * p.glow_size)) ** 2 + ((y - p.center_y) / (p.axis_b * p.glow_size)) ** 2) <= 1
    cover = gaussian_filter(inside.astype(np.float32), p.glow_blur) * p.glow_strength
    t = np.clip((y - (p.center_y - p.axis_b)) / (2 * p.axis_b), 0, 1)[..., None]
    blue = linear(np.array(p.glow_top)) * (1 - t) + linear(np.array(p.glow_bottom)) * t
    rgb = mix(rgb, blue, cover, p)
    return vignette(rgb, x, y, p).astype(np.float32)


def system_dark(shape, p):
    """Icon Composer's dark ground, top to foot, in sRGB: what the dark previews show behind the see-through plate."""
    t = np.linspace(0, 1, shape[0], dtype=np.float32)[:, None, None]
    return np.broadcast_to(p.system_dark_top + (p.system_dark_bottom - p.system_dark_top) * t, shape + (3,))


def safe_coordinates(x, y, safe):
    valid, nearest = safe
    x, y = np.clip(x, 0, valid.shape[1] - 1), np.clip(y, 0, valid.shape[0] - 1)
    invalid = sample(valid, x, y) < 0.9999
    if np.any(invalid):
        ix, iy = np.rint(x[invalid]).astype(int), np.rint(y[invalid]).astype(int)
        x, y = x.copy(), y.copy()
        x[invalid], y[invalid] = nearest[1, iy, ix], nearest[0, iy, ix]
    return x, y


def masked_blur(rgb, across, along, alpha):
    weight = gaussian_filter(alpha, (along, across), mode="constant")
    colour = gaussian_filter(rgb * alpha[..., None], (along, across, 0), mode="constant")
    return colour / np.maximum(weight[..., None], 1e-8)


def finish(version, p):
    crisp = version == "lenticular"
    values = {
        "strength": p.lenticular_strength if crisp else p.reeded_strength,
        "frosting": p.lenticular_frost if crisp else p.reeded_frost,
        "scatter": p.lenticular_scatter if crisp else p.reeded_scatter,
        "milkiness": p.lenticular_milk if crisp else p.reeded_milk,
        "specular": p.lenticular_specular if crisp else p.reeded_specular,
        "bulge": p.lenticular_bulge if crisp else p.reeded_bulge,
    }
    return {name: getattr(p, name) if getattr(p, name) is not None else value for name, value in values.items()}


def prepare_scene(folder, appearance, settings, p, grey=None):
    silhouette = Image.open(folder / "squircle-mask.png").convert("L")
    layer = Image.open(folder / f"globe-layer-{appearance}.png")
    cursor_image = Image.open(folder / f"cursor-{appearance}.png")
    if silhouette.size != (1024, 1024) or layer.size != silhouette.size or cursor_image.size != silhouette.size:
        raise ValueError("The globe, cursor and mask must all be 1024 x 1024")
    globe = progressive_blur(grow_globe(clean_layer(layer), p.weight, p), p)
    cursor = Image.fromarray(clean_layer(cursor_image), "RGBA")
    alpha = np.asarray(silhouette, dtype=np.float32) / 255
    y, x = np.indices(alpha.shape, dtype=np.float32)
    ground = background(x, y, appearance, p, grey)
    original = linear(globe[..., :3]) * globe[..., 3:] + ground * (1 - globe[..., 3:])
    valid = minimum_filter(alpha, size=3, mode="constant", cval=0) == 1
    nearest = distance_transform_edt(~valid, return_distances=False, return_indices=True)
    edge_distance = distance_transform_edt(alpha == 1)
    boundary = smoothstep(p.edge_hold, p.edge_hold + p.edge_fade, edge_distance).astype(np.float32)
    frost = masked_blur(original, settings["frosting"], settings["frosting"] / p.frost_ratio, alpha)
    haze = masked_blur(original, p.scatter_radius, p.scatter_radius / p.frost_ratio, alpha)
    scene = frost * (1 - settings["scatter"]) + haze * settings["scatter"]
    return original, scene, ground, silhouette, cursor, (valid.astype(np.float32), nearest), boundary


def rod_geometry(x, p):
    axis = p.phase + p.period * np.floor((x - p.phase) / p.period + 0.5)
    local = x - axis
    half = p.period / 2
    radius = (half * half + p.sag * p.sag) / (2 * p.sag)
    circle_z = np.sqrt(np.maximum(radius * radius - local * local, 1e-8))
    height = circle_z - np.sqrt(radius * radius - half * half)
    slope = -local / circle_z
    nz = 1 / np.sqrt(1 + slope * slope)
    return axis, local, local / half, height, -slope * nz, nz


def coordinates(x, y, geometry, settings, version, ior, p):
    axis, local, u, height, nx, nz = geometry
    eta = 1 / ior
    coefficient = eta * nz - np.sqrt(1 - eta * eta * (1 - nz * nz))
    tx, tz = coefficient * nx, -eta + coefficient * nz
    displacement = (p.depth + height) * tx / (-tz)
    activity = min(abs(settings["strength"]), 1)
    wave = np.zeros_like(x)
    if settings["strength"] > 0:
        wave = 1 - smoothstep(p.focus_start, p.focus_end, axis)
        rim = p.center_x - p.axis_a - p.weight + p.focus_bias
        focused_axis = rim + p.focus_scale * (axis - p.focus_axis)
        view_shift = (focused_axis - axis) * wave
    else:
        view_shift = p.view_offset * (1 - smoothstep(p.view_start, p.view_end, axis))
    qx = axis + activity * view_shift + local + settings["strength"] * displacement
    # A weak vertical view bulge gives each slice its own curved end.
    vertical_scale = (1 + settings["bulge"] * activity * (1 - u * u))
    vertical_scale *= 1 + (p.focus_vertical - 1) * wave * activity
    qy = p.center_y + (y - p.center_y) / vertical_scale
    grade = np.ones_like(x)
    if version == "graded":
        grade = 1 - (1 - p.graded_min) * smoothstep(p.graded_start, p.graded_end, axis)
    return x + (qx - x) * grade, y + (qy - y) * grade, grade


def shade(transmitted, geometry, _grade, settings, appearance, p):
    _, _, u, height, nx, nz = geometry
    quiet = p.dark_highlights if appearance == "Dark" else 1
    f0 = ((p.ior - 1) / (p.ior + 1)) ** 2
    fresnel = f0 + (1 - f0) * (1 - nz) ** 5
    reflected_x = 2 * nx * nz
    softbox = 0.2 + np.exp(-((reflected_x + 0.48) / 0.42) ** 2)
    # The grade changes ray bending only. The same rib material continues over
    # the entire icon, including its nearly clear cursor side.
    reflected = (fresnel * p.reflection * quiet)[..., None]
    colour = transmitted * (1 - reflected) + softbox[..., None] * np.array((0.70, 0.80, 0.86)) * reflected
    transmission = 1 - p.rib_contrast * (1 - height / p.sag)
    valley = np.exp(-0.5 * ((1 - np.abs(u)) / p.valley_width) ** 2)
    highlight = np.exp(-0.5 * ((u - p.highlight_position) / p.highlight_width) ** 2)
    colour *= (transmission * (1 - p.valley * valley))[..., None]
    colour += (settings["specular"] * quiet * highlight)[..., None] * (0.72, 0.85, 0.93)
    milk = settings["milkiness"] * (p.dark_milk if appearance == "Dark" else 1)
    return colour * (1 - milk) + np.array((0.65, 0.77, 0.83)) * milk


def composite_cursor(colour, silhouette, cursor):
    result = Image.fromarray(np.uint8(np.clip(colour, 0, 1) * 255 + 0.5), "RGB").convert("RGBA")
    result.putalpha(silhouette)
    result = Image.alpha_composite(result, cursor)
    result.putalpha(silhouette)
    pixels = np.array(result)
    pixels[pixels[..., 3] == 0, :3] = 0
    return Image.fromarray(pixels, "RGBA")


def render(folder, version, appearance, p):
    started = time.perf_counter()
    settings = finish(version, p)
    if appearance == "Dark":
        # See-through: drawn over the darkest and the lightest grey of Icon
        # Composer's dark ground, the difference says how much of the ground
        # shows through each pixel, and the rest is the glass's own colour.
        low, high = p.system_dark_bottom, p.system_dark_top
        under_low, silhouette, cursor, boundary = optics(folder, version, appearance, settings, p, low)
        under_high = optics(folder, version, appearance, settings, p, high)[0]
        alpha = np.clip(1 - (under_high - under_low).mean(axis=2) / (high - low), 0, 1)
        colour = (under_low - (1 - alpha[..., None]) * low) / np.maximum(alpha[..., None], 1e-4)
    else:
        colour, silhouette, cursor, boundary = optics(folder, version, appearance, settings, p)
        alpha = None
    grain = np.random.default_rng(p.seed).normal(size=boundary.shape).astype(np.float32) * boundary
    colour = np.clip(colour + grain[..., None] * p.grain, 0, 1)
    if p.plates:
        # The app icon's own layer: the whole square, no cursor (Icon Composer
        # draws it on top) and no outline (Icon Composer cuts its own). The
        # dark one is see-through, over Icon Composer's own dark ground.
        name = "glass-dark.png" if appearance == "Dark" else "glass-light.png"
        Path(p.plates).mkdir(parents=True, exist_ok=True)
        pixels = colour if alpha is None else np.concatenate((colour, alpha[..., None]), axis=2)
        Image.fromarray(np.uint8(pixels * 255 + 0.5), "RGB" if alpha is None else "RGBA").save(Path(p.plates) / name, optimize=True)
        print(f"{name}: {time.perf_counter() - started:.2f} s", flush=True)
        return None
    if alpha is not None:
        colour = colour * alpha[..., None] + system_dark(alpha.shape, p) * (1 - alpha[..., None])
    result = composite_cursor(colour, silhouette, cursor)
    output_folder = folder if version == "graded" else folder / "others"
    output_folder.mkdir(exist_ok=True)
    destination = output_folder / f"vertical-{version}-{appearance}.png"
    result.save(destination)
    print(f"{destination.name}: {time.perf_counter() - started:.2f} s, strength {settings['strength']:g}, "
          f"frosting {settings['frosting']:g} px", flush=True)
    return result


def optics(folder, version, appearance, settings, p, grey=None):
    """The glass over its scene, in sRGB without grain, with the outline, the cursor and the glass's fade at the edge."""
    original, scene, ground, silhouette, cursor, safe, boundary = prepare_scene(folder, appearance, settings, p, grey)
    y, x = np.indices(original.shape[:2], dtype=np.float32)
    accumulated = np.zeros_like(original)
    for sy in range(p.supersample):
        for sx in range(p.supersample):
            xx = x + (sx + 0.5) / p.supersample - 0.5
            yy = y + (sy + 0.5) / p.supersample - 0.5
            geometry = rod_geometry(xx, p)
            transmitted = np.empty_like(scene)
            exterior = np.clip((p.center_x - p.axis_a - xx) / (3 * p.period), 0, 1)
            echo_contrast = np.exp(-p.echo_fade * exterior)
            for channel, offset in enumerate((-p.dispersion, 0, p.dispersion)):
                qx, qy, grade = coordinates(xx, yy, geometry, settings, version, p.ior + offset, p)
                qx, qy = xx + (qx - xx) * boundary, yy + (qy - yy) * boundary
                qx, qy = safe_coordinates(qx, qy, safe)
                seen = sample(scene[..., channel], qx, qy)
                behind = sample(ground[..., channel], qx, qy)
                transmitted[..., channel] = behind + (seen - behind) * echo_contrast
            glass = shade(transmitted, geometry, grade, settings, appearance, p)
            accumulated += glass * boundary[..., None] + original * (1 - boundary[..., None])
    accumulated /= p.supersample ** 2
    accumulated[boundary == 0] = original[boundary == 0]
    return srgb(accumulated), silhouette, cursor, boundary


def previews(folder, p):
    ground = (p.preview_background,) * 3 + (255,)
    grid = Image.new("RGBA", (2 * p.grid_size, p.grid_size), ground)
    small = Image.new("RGBA", (2 * p.small_size, p.small_size + p.tiny_size), ground)
    for column, appearance in enumerate(("Default", "Dark")):
        icon = Image.open(folder / f"vertical-graded-{appearance}.png").convert("RGBA")
        grid.alpha_composite(icon.resize((p.grid_size, p.grid_size), Image.Resampling.LANCZOS),
                             (column * p.grid_size, 0))
        small.alpha_composite(icon.resize((p.small_size, p.small_size), Image.Resampling.LANCZOS),
                              (column * p.small_size, 0))
        small.alpha_composite(icon.resize((p.tiny_size, p.tiny_size), Image.Resampling.LANCZOS),
                              (column * p.small_size + (p.small_size - p.tiny_size) // 2, p.small_size))
    grid.convert("RGB").save(folder / "grid.png")
    small.convert("RGB").save(folder / "small.png")
    print(f"grid.png: light left, dark right, {p.grid_size} px each")
    print(f"small.png: light left, dark right; {p.small_size} px above {p.tiny_size} px")


def arguments():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--all", action="store_true", help="Render both graded icons and both contact sheets.")
    parser.add_argument("--version", choices=("lenticular", "reeded", "graded"), default="graded",
                        help="Other versions are saved into others/.")
    parser.add_argument("--appearance", choices=("Default", "Dark"), default="Default")
    parser.add_argument("--flutes", choices=("vertical",), default="vertical", help="Full vertical glass.")
    parser.add_argument("--coverage", choices=("full",), default="full")
    parser.add_argument("--folder", default=None, help="Where the inputs are and the previews go. Default: this script's folder.")
    parser.add_argument("--plates", default=None,
                        help="Write the app icon's layers (glass-light.png, glass-dark.png: no cursor, no outline) into this folder instead.")
    for name in ("strength", "frosting", "scatter", "milkiness", "specular", "bulge"):
        parser.add_argument("--" + name, type=float, default=None, help="Override this version's preset value.")
    declarations = Path(__file__).read_text().split("import argparse", 1)[0]
    for line in declarations.splitlines():
        if " = " not in line or " # " not in line:
            continue
        declaration, help_text = line.split(" # ", 1)
        name = declaration.split(" = ", 1)[0]
        default = globals()[name]
        options = {"type": float, "nargs": 3} if isinstance(default, tuple) else {"type": type(default)}
        parser.add_argument("--" + name.lower().replace("_", "-"), **options,
                            default=default, help=f"{help_text} Default: {default}.")
    p = parser.parse_args()
    for name, value in vars(p).items():
        if isinstance(value, (int, float)) and not np.isfinite(value):
            parser.error(f"--{name.replace('_', '-')} must be finite")
    for name in ("period", "sag", "ior", "frost_ratio", "valley_width", "highlight_width", "supersample", "grid_size", "small_size", "tiny_size", "edge_fade", "focus_vertical"):
        if getattr(p, name) <= 0:
            parser.error(f"--{name.replace('_', '-')} must be positive")
    if p.sag >= p.period / 2:
        parser.error("--sag must be less than half --period for a finite shallow arc")
    if p.background_horizontal < 0 or p.background_vertical < 0 or p.background_horizontal + p.background_vertical == 0:
        parser.error("Background direction weights must be nonnegative, with a positive total")
    if p.tiny_size > p.small_size:
        parser.error("--tiny-size cannot exceed --small-size")
    if p.ior - p.dispersion <= 1 or p.dispersion < 0:
        parser.error("--ior minus --dispersion must exceed 1, and dispersion cannot be negative")
    if p.view_end <= p.view_start or p.graded_end <= p.graded_start or p.focus_end <= p.focus_start:
        parser.error("View and graded transition ends must exceed their starts")
    if not 0 < p.core_alpha <= 1:
        parser.error("--core-alpha must be greater than 0 and at most 1")
    if p.vignette_outer <= p.vignette_inner or p.blur_end <= p.blur_start:
        parser.error("Vignette and blur ends must exceed their starts")
    for name in ("weight", "depth", "edge_hold", "grain", "scatter_radius", "lenticular_frost", "reeded_frost", "colour_smooth",
                 "blur_right", "blur_left", "blur_curve", "vignette_light", "mix_lift"):
        if getattr(p, name) < 0:
            parser.error(f"--{name.replace('_', '-')} cannot be negative")
    for name in ("strength", "frosting", "scatter", "milkiness", "specular", "bulge"):
        value = getattr(p, name)
        if value is not None and name != "strength" and value < 0:
            parser.error(f"--{name} cannot be negative")
    for name in ("scatter", "milkiness", "lenticular_scatter", "reeded_scatter", "lenticular_milk", "reeded_milk", "dark_highlights", "graded_min", "rib_contrast", "vignette_light"):
        value = getattr(p, name)
        if value is not None and not 0 <= value <= 1:
            parser.error(f"--{name.replace('_', '-')} must be between 0 and 1")
    return p


def main():
    p = arguments()
    folder = Path(p.folder).resolve() if p.folder else Path(__file__).resolve().parent
    combinations = [("graded", appearance) for appearance in ("Default", "Dark")]
    for version, appearance in combinations if p.all or p.plates else [(p.version, p.appearance)]:
        render(folder, version, appearance, p)
    if p.all and not p.plates:
        previews(folder, p)
    half = p.period / 2
    radius = (half * half + p.sag * p.sag) / (2 * p.sag)
    max_slope = half / np.sqrt(radius * radius - half * half)
    print(f"{p.period:g} px rods, {p.sag:g} px sag, finite edge slope {max_slope:.3f}; "
          f"globe growth {p.weight:g} px. Soft top-left light; broad rib transmission "
          f"{1-p.rib_contrast:.0%} at the edges to 100% at the centre across the whole icon. "
          "Only bending fades towards the cursor. Fixed grain, unchanged cursor, exact mask alpha.")


if __name__ == "__main__":
    main()
