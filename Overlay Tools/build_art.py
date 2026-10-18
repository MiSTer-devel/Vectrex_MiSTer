#!/usr/bin/env python3
"""Build Vectrex overlay .art packages from 846x1080 source artwork.

Run from the Overlay Tools folder. Normal mode takes a supplied PNG and produces
all three orientation packages in an external output directory:

    python build_art.py build INPUT.png -o ../Vectrex_Artwork_Output

Build and build-all default to the current directory when -o is omitted.
One -o directory receives all orientations. Repeat -o to split Normal and Tate:

    python build_art.py build INPUT.png -o NORMAL_DIR -o TATE_DIR

Individual mode packs four authored exact-raster PNGs into one package:

    python build_art.py pack INPUT_DIR ../Vectrex_Artwork_Output/out.art

Extract defaults to 1080p artwork, centered 846x1080 for normal orientation:

    python build_art.py extract Mine_Storm.art -o OUTPUT_DIR

Use --resolution to select another plane, --all-resolutions for every plane,
and --full-plane to retain the complete raster instead of cropping artwork.
Standard _90CW/_90CCW filename suffixes select the quarter-turn crop; use
--orientation to override the filename hint for renamed packages.

In vfb_overlay.sv, alpha 255 blocks CRT energy and uses Opaque Brightness;
lower alpha uses Translucent Blend. Resampling and quantization keep these
alpha classes separate to prevent unintended transparency.

Use --preserve-alpha to retain the PNG's embedded alpha values instead of
normalizing them. This bypasses the source cutoff and exterior correction.
"""

from __future__ import annotations

import argparse
from collections import deque
import concurrent.futures
from fractions import Fraction
import heapq
import json
import math
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np
from PIL import Image

import vart_encoder as vart


# Canonical source raster. Nearby widths at native height are padded or cropped.
SOURCE_SIZE = (846, 1080)
SOURCE_WIDTH_RANGE = (840, 854)

# Display pixel aspect of each mode relative to the 1080p square-pixel frame.
# The HD modes are presented at their own raster aspect (1360:1080, 916:720)
# and so have square pixels. The CRT modes present a 720-wide raster on a 4:3
# screen, giving 8/9 at 480p and 4/9 at 240p.
PIXEL_ASPECT = {"1080p": 1.0, "720p": 1.0, "480p": 8 / 9, "240p": 4 / 9}

# label: (raster, normal art rect, quarter-turn art rect) as (x, y, w, h).
#
# Normal keeps the source aspect and fills the raster height. Quarter-turn
# fits the rotated source inside the raster, which binds on width at 1080p and
# 720p (leaving a 7px and 1px top/bottom border) and on height at 480p and
# 240p (leaving a 15px left/right border). Every rect is symmetric about the
# raster centre except the CRT normal rects, which sit half a pixel left
# because 423 is odd; that keeps the horizontal scale at exactly 1/2.
PLANES = {
    "1080p": ((1360, 1080), (257, 0, 846, 1080), (0, 7, 1360, 1066)),
    "720p": ((916, 720), (176, 0, 564, 720), (0, 1, 916, 718)),
    "480p": ((720, 480), (148, 0, 423, 480), (15, 0, 690, 480)),
    "240p": ((720, 240), (148, 0, 423, 240), (15, 0, 690, 240)),
}

MAX_COLOR_CHOICES = (16, 64, 256)
MAX_COLORS = 64
TRANSLUCENT_ALPHA = 51
# Initial interpretation of source alpha, not a substitute for a reviewed map.
# By default, 254 is opaque. A supplied alpha map is authoritative.
ALPHA_MIDPOINT = (TRANSLUCENT_ALPHA + 255) / 2
DEFAULT_ALPHA_CUTOFF = int(ALPHA_MIDPOINT)
# Baseline material selection, also retained when enlarging artwork.
OPAQUE_COVERAGE = 0.5
# Downscaling keeps the baseline and selective thin detail, then adds every
# pixel with at least this much exact opaque area coverage.
DOWNSCALE_OPAQUE_COVERAGE = Fraction(1, 4)

DEFAULT_SATURATION = 1.0


# --------------------------------------------------------------------------
# Colour
# --------------------------------------------------------------------------

def srgb_to_linear(value: np.ndarray) -> np.ndarray:
    return np.where(value <= 0.04045, value / 12.92, ((value + 0.055) / 1.055) ** 2.4)


def linear_to_srgb(value: np.ndarray) -> np.ndarray:
    value = np.clip(value, 0.0, 1.0)
    return np.where(
        value <= 0.0031308, value * 12.92, 1.055 * np.power(value, 1 / 2.4) - 0.055
    )


def _hue_to_channel(p: np.ndarray, q: np.ndarray, t: np.ndarray) -> np.ndarray:
    t = np.mod(t, 1.0)
    out = np.copy(p)
    m = t < 1 / 6
    out[m] = p[m] + (q[m] - p[m]) * 6.0 * t[m]
    m = (t >= 1 / 6) & (t < 1 / 2)
    out[m] = q[m]
    m = (t >= 1 / 2) & (t < 2 / 3)
    out[m] = p[m] + (q[m] - p[m]) * (2 / 3 - t[m]) * 6.0
    return out


def desaturate(rgb: np.ndarray, factor: float) -> np.ndarray:
    """Scale HSL saturation, leaving hue and lightness untouched.

    `rgb` is float64 in [0, 1] and stays float64 on the way out; the caller
    rounds to 8 bits once, at the end of the pipeline. Alpha is not touched
    here at all.
    """
    # Disabled means identity: no HSL conversion, arithmetic, copy or rounding.
    if factor == 1.0:
        return rgb

    r, g, b = rgb[..., 0], rgb[..., 1], rgb[..., 2]
    high = np.max(rgb, axis=-1)
    low = np.min(rgb, axis=-1)
    lightness = (high + low) / 2.0
    delta = high - low

    grey = delta < 1e-12
    denominator = np.where(lightness > 0.5, 2.0 - high - low, high + low)
    saturation = np.where(grey, 0.0, delta / np.where(denominator == 0, 1.0, denominator))

    safe_delta = np.where(grey, 1.0, delta)
    hue = np.where(
        high == r,
        (g - b) / safe_delta % 6.0,
        np.where(high == g, (b - r) / safe_delta + 2.0, (r - g) / safe_delta + 4.0),
    ) / 6.0
    hue = np.where(grey, 0.0, hue)

    saturation = saturation * factor

    q = np.where(
        lightness < 0.5,
        lightness * (1.0 + saturation),
        lightness + saturation - lightness * saturation,
    )
    p = 2.0 * lightness - q

    out = np.stack(
        [
            _hue_to_channel(p, q, hue + 1 / 3),
            _hue_to_channel(p, q, hue),
            _hue_to_channel(p, q, hue - 1 / 3),
        ],
        axis=-1,
    )
    out[grey] = lightness[grey][..., None]
    return np.clip(out, 0.0, 1.0)


# --------------------------------------------------------------------------
# Resampling
# --------------------------------------------------------------------------

def _resize_plane(plane: np.ndarray, size: tuple[int, int], filt) -> np.ndarray:
    image = Image.fromarray(np.ascontiguousarray(plane, dtype=np.float32), mode="F")
    return np.asarray(image.resize(size, filt), dtype=np.float64)


def _area_axis(values: np.ndarray, count: int, axis: int) -> np.ndarray:
    """Integrate source pixel cells over exact destination footprints."""
    values = np.moveaxis(values, axis, 0)
    length = values.shape[0]
    if length == count:
        return np.moveaxis(values.copy(), 0, axis)
    cumulative = np.concatenate(
        (np.zeros_like(values[:1]), np.cumsum(values, axis=0, dtype=np.float64)), axis=0
    )
    edges = np.linspace(0, length, count + 1)
    whole = np.floor(edges).astype(int)
    fraction = (edges - whole).reshape((-1,) + (1,) * (values.ndim - 1))
    integral = cumulative[whole] + values[np.minimum(whole, length - 1)] * fraction
    return np.moveaxis(np.diff(integral, axis=0) / (length / count), 0, axis)


def _area(values: np.ndarray, size: tuple[int, int]) -> np.ndarray:
    return _area_axis(_area_axis(values, size[0], 1), size[1], 0)


def _mask_area_axis(values: np.ndarray, count: int, axis: int) -> np.ndarray:
    """Sum exact overlaps in integer 1/count source-pixel units."""
    values = np.moveaxis(values, axis, 0).astype(np.int64, copy=False)
    length = values.shape[0]
    cumulative = np.concatenate(
        (np.zeros_like(values[:1]), np.cumsum(values, axis=0, dtype=np.int64)), axis=0
    )
    edges = np.arange(count + 1, dtype=np.int64) * length
    whole, remainder = edges // count, edges % count
    remainder = remainder.reshape((-1,) + (1,) * (values.ndim - 1))
    integral = cumulative[whole] * count + values[np.minimum(whole, length - 1)] * remainder
    return np.moveaxis(np.diff(integral, axis=0), 0, axis)


def _mask_area(mask: np.ndarray, size: tuple[int, int]) -> np.ndarray:
    """Exact coverage numerator; the denominator is mask.size.

    Keep mask arithmetic integral through both axes and compare by cross
    multiplication. Float cumulative sums can straddle an exact threshold
    along a uniform edge and create periodic opaque/transmitting teeth.
    RGB retains the separate floating-point linear-light area filter.
    """
    return _mask_area_axis(_mask_area_axis(mask, size[0], 1), size[1], 0)


def _morph_axis(mask: np.ndarray, radius: int, axis: int, erode: bool) -> np.ndarray:
    padding = [(0, 0), (0, 0)]
    padding[axis] = (radius, radius)
    windows = np.lib.stride_tricks.sliding_window_view(
        np.pad(mask, padding, mode="edge"), 2 * radius + 1, axis=axis
    )
    return windows.all(axis=-1) if erode else windows.any(axis=-1)


def _combined_opaque(
    opaque: np.ndarray,
    size: tuple[int, int],
    baseline_opaque: np.ndarray,
    baseline_transmitting: np.ndarray,
) -> np.ndarray:
    """Union of baseline, selective thin-detail and global 25% opaque sets."""
    coverage = _mask_area(opaque, size)
    denominator = opaque.size
    threshold = DOWNSCALE_OPAQUE_COVERAGE
    selected = baseline_opaque | (
        coverage * threshold.denominator >= denominator * threshold.numerator
    )
    scale_x = Fraction(opaque.shape[1], size[0])
    scale_y = Fraction(opaque.shape[0], size[1])
    scale = max(scale_x, scale_y)
    if scale > Fraction(3, 2):
        # An opening removes ink narrower than about one destination pixel.
        # Only promote transmitting cells dominated by that narrow source ink.
        rx, ry = max(1, math.ceil(scale_x / 2)), max(1, math.ceil(scale_y / 2))
        eroded = _morph_axis(_morph_axis(opaque, rx, 1, True), ry, 0, True)
        opened = _morph_axis(_morph_axis(eroded, rx, 1, False), ry, 0, False)
        thin_coverage = _mask_area(opaque & ~opened, size)
        cutoff = max(Fraction(1, 5), min(Fraction(1, 2), Fraction(3, 4) / scale))
        selected |= (
            baseline_transmitting
            & (coverage * cutoff.denominator >= denominator * cutoff.numerator)
            & (coverage * 2 < denominator)
            & (thin_coverage * 4 >= coverage * 3)
        )
    return selected


def _preserved_alpha(
    alpha: np.ndarray,
    size: tuple[int, int],
    opaque: np.ndarray,
    clear: np.ndarray,
) -> np.ndarray:
    """Select authored translucent levels by positive coverage, without mixing.

    Opaque detail and clear-region selection remain separate. Equal coverage
    between translucent levels selects the lower alpha value.
    """
    source = np.rint(alpha * 255.0).astype(np.uint8)
    shrinking = size[0] <= source.shape[1] and size[1] <= source.shape[0]
    selected = np.zeros((size[1], size[0]), dtype=np.uint8)
    best = np.zeros(selected.shape, dtype=np.float64)
    for value in np.unique(source):
        if value == 0 or value == 255:
            continue
        mask = source == value
        coverage = (_mask_area(mask, size) if shrinking else
                    _resize_plane(mask, size, Image.Resampling.BILINEAR))
        replace = coverage > best
        selected[replace] = value
        best[replace] = coverage[replace]
    selected[clear] = 0
    selected[opaque] = 255
    return selected.astype(np.float64) / 255.0


def resample(
    rgb: np.ndarray,
    alpha: np.ndarray,
    opaque: np.ndarray,
    size: tuple[int, int],
    sharp: bool = True,
    preserve_alpha: bool = False,
) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """Resample to `size`, returning (rgb01, alpha01, selected opaque bool).

    Colour is resampled premultiplied and in linear light, independently for
    opaque and non-opaque material. Each output takes RGB only from the
    selected material, preventing cross-material fringes. Reductions combine
    selective thin-detail preservation with global 25% opaque area coverage,
    and use exact positive-area RGB integration. Enlargements retain Lanczos
    RGB (BOX with sharp=False) and a monotone 50% material decision.

    Material coverage uses positive filters. Numeric alpha is never interpolated:
    Lanczos ringing must not manufacture clear holes in transmitting material.
    """
    height, width = alpha.shape
    if (width, height) == size:
        return rgb.copy(), alpha.copy(), opaque.copy()

    shrinking = size[0] <= width and size[1] <= height
    colour_filter = Image.Resampling.LANCZOS if sharp else Image.Resampling.BOX
    # Area coverage when shrinking; a monotone filter when growing, so the
    # class mask never rings and never speckles.
    mask_filter = Image.Resampling.BOX if shrinking else Image.Resampling.BILINEAR

    coverage = np.clip(
        _resize_plane(opaque.astype(np.float64), size, mask_filter), 0.0, 1.0
    )
    selected_opaque = coverage >= OPAQUE_COVERAGE
    clear_coverage = np.clip(_resize_plane((alpha == 0).astype(np.float64),size,mask_filter),0.0,1.0)
    transmitting_coverage = np.clip(_resize_plane(((alpha > 0) & ~opaque).astype(np.float64),size,mask_filter),0.0,1.0)
    if shrinking:
        selected_opaque = _combined_opaque(
            opaque, size, selected_opaque,
            ~selected_opaque & (clear_coverage <= transmitting_coverage),
        )
    selected_clear = ~selected_opaque & (clear_coverage > transmitting_coverage)
    if preserve_alpha:
        out_alpha = _preserved_alpha(alpha, size, selected_opaque, selected_clear)
    else:
        out_alpha = np.where(selected_opaque,1.0,np.where(selected_clear,0.0,TRANSLUCENT_ALPHA/255.0))
    linear_rgb = srgb_to_linear(rgb)
    out_rgb = np.zeros((*out_alpha.shape, 3), dtype=np.float64)
    for material in (False, True):
        selected = selected_opaque == material
        if not np.any(selected):
            continue
        material_alpha = alpha * (opaque == material)
        premultiplied = linear_rgb * material_alpha[..., None]
        if shrinking:
            weight = _area(material_alpha, size)
            numerator = _area(premultiplied, size)
            colour = linear_to_srgb(np.clip(
                numerator / np.maximum(weight, 1e-8)[..., None], 0.0, 1.0
            ))
            colour[weight <= 1e-8] = 0.0
            out_rgb[selected] = colour[selected]
            continue
        out_linear = np.stack(
            [_resize_plane(premultiplied[..., c], size, colour_filter) for c in range(3)],
            axis=-1,
        )
        weight = np.clip(_resize_plane(material_alpha, size, colour_filter), 0.0, 1.0)
        visible = weight > 1e-6
        divisor = np.where(visible, weight, 1.0)[..., None]
        colour = linear_to_srgb(np.clip(out_linear / divisor, 0.0, 1.0))
        # A material with no visible source support contributes black, including
        # clear playfield windows. Never borrow RGB from the other material.
        colour = np.where(visible[..., None], colour, 0.0)
        out_rgb[selected] = colour[selected]
    return out_rgb, out_alpha, selected_opaque


def compose_plane(
    rgb: np.ndarray,
    alpha: np.ndarray,
    opaque: np.ndarray,
    raster: tuple[int, int],
    rect: tuple[int, int, int, int],
    preserve_alpha: bool = False,
) -> np.ndarray:
    """Place resampled art on the transparent raster and resolve alpha classes.

    Retain authored levels in preserve mode; otherwise resolve material to
    0/51/255. No intermediate coverage alpha enters the palette.
    """
    x, y, width, height = rect
    out = np.zeros((raster[1], raster[0], 4), dtype=np.uint8)

    # The resampler has already selected material. Re-thresholding fractional
    # coverage here would erase the supported detail retained during reduction.
    if preserve_alpha:
        resolved = np.rint(alpha * 255.0).astype(np.uint8)
    else:
        resolved = np.where(
            opaque, 255, np.where(alpha * 255 >= TRANSLUCENT_ALPHA / 2, TRANSLUCENT_ALPHA, 0)
        )

    tile = np.empty((height, width, 4), dtype=np.uint8)
    tile[..., :3] = np.round(rgb * 255.0).astype(np.uint8)
    tile[..., 3] = resolved.astype(np.uint8)
    tile[resolved == 0,:3] = 0
    out[y : y + height, x : x + width] = tile
    return out


# --------------------------------------------------------------------------
# Palette
# --------------------------------------------------------------------------

def _pack_rgba(pixels: np.ndarray) -> np.ndarray:
    """Pack uint8 RGBA in numeric RGBA order using native-endian uint32."""
    return np.ascontiguousarray(pixels).view('>u4').reshape(-1).astype(np.uint32, copy=False)


def normalize_material_alpha(alpha: np.ndarray,
                             alpha_cutoff: int = DEFAULT_ALPHA_CUTOFF) -> np.ndarray:
    """Initial 51/255 interpretation of source alpha; retain explicit clear 0.

    Source-specific optical defects require a reviewed --alpha-map. This numeric
    fallback does not claim to infer physical materials or repair isolated lines
    whose source alpha is already a plausible transmitting level.
    """
    return np.where(alpha == 0, 0,
                    np.where(alpha >= alpha_cutoff, 255, TRANSLUCENT_ALPHA)).astype(np.uint8)


def _rgb_to_oklab(rgb: np.ndarray) -> np.ndarray:
    linear = srgb_to_linear(rgb / 255.0)
    lms = linear @ np.array([[.4122214708,.2119034982,.0883024619],
                            [.5363325363,.6806995451,.2817188376],
                            [.0514459929,.1073969566,.6299787005]])
    return np.cbrt(lms) @ np.array([[.2104542553,1.9779984951,.0259040371],
                                   [.7936177850,-2.4285922050,.7827717662],
                                   [-.0040720468,.4505937099,-.8086757660]])


def _oklab_to_rgb(lab: np.ndarray) -> np.ndarray:
    roots = lab @ np.array([[1,1,1],[.3963377774,-.1055613458,-.0894841775],
                            [.2158037573,-.0638541728,-1.2914855480]])
    linear = roots**3 @ np.array([[4.0767416621,-1.2684380046,-.0041960863],
                                  [-3.3077115913,2.6097574011,-.7034186147],
                                  [.2309699292,-.3413193965,1.7076147010]])
    return np.rint(linear_to_srgb(linear) * 255).astype(np.uint8)


def _merge_preserved_alpha(lab, weights, alpha, max_colors):
    """Merge RGB shades within each alpha level without a full cross-alpha matrix."""
    members = [[i] for i in range(len(alpha))]
    groups, candidates = {}, []

    def enqueue(value):
        ids, cost = groups[value]
        i, j = np.unravel_index(np.argmin(cost), cost.shape)
        if np.isfinite(cost[i, j]):
            heapq.heappush(candidates, (cost[i, j], int(ids[i]), int(ids[j]),
                                       value, i, j))

    for value in np.unique(alpha):
        ids = np.flatnonzero(alpha == value)
        shades, counts = lab[ids], weights[ids]
        distance = ((shades[:, None, :] - shades[None, :, :])**2).sum(axis=2)
        cost = distance * counts[:, None] * counts[None, :] / (counts[:, None] + counts[None, :])
        cost[np.tril_indices(len(ids))] = np.inf
        groups[value] = ids, cost
        enqueue(value)

    remaining = len(alpha)
    while remaining > max_colors:
        if not candidates:
            raise vart.ArtworkError('Alpha levels exceed the palette budget')
        _, i, j, value, gi, gj = heapq.heappop(candidates)
        lab[i] = (lab[i] * weights[i] + lab[j] * weights[j]) / (weights[i] + weights[j])
        weights[i] += weights[j]
        members[i].extend(members[j])
        members[j] = []
        ids, cost = groups[value]
        distance = ((lab[i] - lab[ids])**2).sum(axis=1)
        upper = distance * weights[i] * weights[ids] / (weights[i] + weights[ids])
        lower = distance * weights[ids] * weights[i] / (weights[ids] + weights[i])
        positions = np.arange(len(ids))
        cost[gi, :] = np.where(positions > gi, upper, np.inf)
        cost[:, gi] = np.where(positions < gi, lower, np.inf)
        inactive = np.array([not members[index] for index in ids])
        cost[inactive, :] = np.inf
        cost[:, inactive] = np.inf
        enqueue(value)
        remaining -= 1
    active = [i for i, group in enumerate(members) if group]
    return lab[active], alpha[active], [members[i] for i in active]


def _perceptual_fit(rgba: np.ndarray, max_colors: int, preserve_alpha: bool = False):
    """Fit duplicate RGB/alpha entries by merging nearest same-material shades.

    libimagequant selects the global RGB palette. Restoring exact material alpha
    can duplicate RGB entries. Merge the lowest weighted Oklab-error pair until
    the total RGBA budget fits; never merge across material classes.
    """
    packed, inverse, counts = np.unique(_pack_rgba(rgba.reshape(-1,4)),
                                       return_inverse=True, return_counts=True)
    unique = packed.astype('>u4', copy=False).view(np.uint8).reshape(-1, 4)
    if len(unique) <= max_colors:
        return inverse.reshape(rgba.shape[:2]).astype(np.uint8), [tuple(map(int,c)) for c in unique]
    lab = _rgb_to_oklab(unique[:,:3].astype(float))
    weights = counts.astype(float)
    members = [[i] for i in range(len(unique))]
    alpha = unique[:,3].copy()
    if preserve_alpha:
        lab, alpha, members = _merge_preserved_alpha(lab, weights, alpha, max_colors)
    while not preserve_alpha and len(members) > max_colors:
        distance = ((lab[:,None,:] - lab[None,:,:])**2).sum(axis=2)
        cost = distance * weights[:,None] * weights[None,:] / (weights[:,None] + weights[None,:])
        cost[np.tril_indices(len(members))] = np.inf
        cost[alpha[:,None] != alpha[None,:]] = np.inf
        i, j = np.unravel_index(np.argmin(cost), cost.shape)
        if not np.isfinite(cost[i,j]):
            raise vart.ArtworkError('Material classes exceed the palette budget')
        lab[i] = (lab[i]*weights[i] + lab[j]*weights[j]) / (weights[i]+weights[j])
        weights[i] += weights[j]
        members[i].extend(members[j])
        del members[j]
        lab, weights, alpha = np.delete(lab,j,0), np.delete(weights,j), np.delete(alpha,j)
    remap = np.zeros(len(unique), dtype=np.uint8)
    palette = []
    for index, original in enumerate(members):
        remap[original] = index
        rgb = unique[original[0],:3] if len(original) == 1 else _oklab_to_rgb(lab[index])
        palette.append((*map(int,rgb),int(alpha[index])))
    canonical, lookup, compact = [], {}, []
    for entry in palette:
        if entry not in lookup:
            lookup[entry] = len(canonical)
            canonical.append(entry)
        compact.append(lookup[entry])
    final_map = np.asarray(compact, dtype=np.uint8)[remap]
    return final_map[inverse].reshape(rgba.shape[:2]), canonical


def _libimagequant_rgb(rgba: np.ndarray, max_colors: int) -> np.ndarray:
    node = os.environ.get('NODE_EXECUTABLE') or shutil.which('node')
    if not node:
        raise vart.ArtworkError(
            'Palette reduction requires Node.js and Sharp/libimagequant. '
            'Install Node.js, set NODE_EXECUTABLE if it is not on PATH, and '
            'run npm install --no-package-lock in the tools folder. '
            'See Setup in README.md beside this script.')
    helper = Path(__file__).with_name('quantize_art.cjs')
    with tempfile.TemporaryDirectory(prefix='vart_palette_') as temporary:
        root = Path(temporary)
        source, output = root/'input.rgba', root/'output.rgb'
        source.write_bytes(np.ascontiguousarray(rgba).tobytes())
        try:
            result = subprocess.run([node,str(helper),str(source),str(output),
                str(rgba.shape[1]),str(rgba.shape[0]),str(max_colors)],
                check=True,capture_output=True,text=True,timeout=180)
        except (OSError,subprocess.CalledProcessError,subprocess.TimeoutExpired) as error:
            detail = getattr(error,'stderr',None) or str(error)
            raise vart.ArtworkError(
                f'libimagequant failed: {detail}\n'
                'For palette reduction setup, see Setup in README.md beside '
                'this script, including the link to Advanced setup for '
                'dependencies installed in a separate folder.') from error
        metadata = json.loads(result.stdout)
        if metadata['rgbColours'] > max_colors or metadata['dither'] != 0:
            raise vart.ArtworkError('Unexpected libimagequant palette result')
        raw = output.read_bytes()
        if len(raw) != rgba.shape[0]*rgba.shape[1]*3:
            raise vart.ArtworkError('libimagequant returned an invalid RGB raster')
        return np.frombuffer(raw,dtype=np.uint8).reshape(*rgba.shape[:2],3).copy()


def build_indexed(rgba: np.ndarray, max_colors: int = MAX_COLORS,
                  preserve_alpha: bool = False):
    """Perceptually reduce RGB while preserving prepared material alpha exactly."""
    if max_colors not in MAX_COLOR_CHOICES:
        raise vart.ArtworkError('max_colors must be 16, 64 or 256')
    if rgba.dtype != np.uint8 or rgba.ndim != 3 or rgba.shape[2] != 4:
        raise vart.ArtworkError('Expected an 8-bit RGBA raster')
    if preserve_alpha:
        alpha_count = len(np.unique(rgba[...,3]))
        if alpha_count > max_colors:
            raise vart.ArtworkError(
                f'Plane uses {alpha_count} distinct alpha values, exceeding the '
                f'{max_colors}-entry palette. Increase --max-colors or simplify '
                'the input alpha map; --preserve-alpha cannot merge alpha levels.')
    elif not np.isin(rgba[...,3],(0,TRANSLUCENT_ALPHA,255)).all():
        raise vart.ArtworkError('Normalize source material alpha before palette reduction')
    if len(np.unique(_pack_rgba(rgba.reshape(-1,4)))) <= max_colors:
        return _perceptual_fit(rgba,max_colors,preserve_alpha=preserve_alpha)
    prepared = rgba.copy()
    prepared[...,:3] = _libimagequant_rgb(rgba,max_colors)
    indices, palette = _perceptual_fit(prepared,max_colors,preserve_alpha=preserve_alpha)
    if not np.array_equal(np.asarray(palette,dtype=np.uint8)[indices,3],rgba[...,3]):
        raise vart.ArtworkError('Palette reduction changed material alpha')
    return indices, palette


def write_indexed_png(path: Path, indices: np.ndarray, palette) -> None:
    image = Image.fromarray(indices, mode="P")
    image.putpalette([c for entry in palette for c in entry[:3]])
    image.save(
        path,
        format="PNG",
        optimize=False,
        transparency=bytes(entry[3] for entry in palette),
    )


# --------------------------------------------------------------------------
# Package assembly
# --------------------------------------------------------------------------

# Clear pixels can represent sheet cutouts or transparent playfields.
# Treat only small, edge-connected clear regions as exterior, so converting
# the exterior to opaque black does not hide gameplay. --exterior clear
# retains exterior transparency. --alpha-map and --preserve-alpha bypass detection.
EXTERIOR_MAX_SHARE = 0.05
EXTERIOR_CUTOFF = 26


def exterior_mask(clear: np.ndarray) -> np.ndarray:
    """The part of `clear` that is outside the sheet rather than cut out of it.

    Grown from the pixels on the frame edge, so an enclosed window is never
    reached, then dropped altogether if what it reaches is too large to be a
    notch and four corners.
    """
    if not clear.any():
        return clear
    seed = np.zeros_like(clear)
    seed[0, :] = seed[-1, :] = True
    seed[:, 0] = seed[:, -1] = True
    seed &= clear
    while True:
        grown = seed.copy()
        grown[1:, :] |= seed[:-1, :]
        grown[:-1, :] |= seed[1:, :]
        grown[:, 1:] |= seed[:, :-1]
        grown[:, :-1] |= seed[:, 1:]
        grown &= clear
        if grown.sum() == seed.sum():
            break
        seed = grown
    return seed if seed.mean() <= EXTERIOR_MAX_SHARE else np.zeros_like(clear)


def exterior_alpha_fringe(source_alpha, material_alpha, outside):
    """Find tiny noncanonical transmitting fragments beside verified exterior.

    This is deliberately local: at most four connected pixels, touching the
    exterior, with at least one noncanonical source alpha. Keep every larger
    region, every authored 51-valued window and all interior features. A supplied
    reviewed map bypasses this inference entirely.
    """
    adjacent = np.zeros_like(outside)
    padded = np.pad(outside,1)
    for dy in range(3):
        for dx in range(3):
            adjacent |= padded[dy:dy+outside.shape[0],dx:dx+outside.shape[1]]
    transmitting = (material_alpha == TRANSLUCENT_ALPHA) & ~outside
    fringe = np.zeros_like(outside)
    visited = set()
    height,width = outside.shape
    for y,x in np.argwhere(adjacent & transmitting):
        start = (int(y),int(x))
        if start in visited:
            continue
        queue = deque([start])
        component = {start}
        while queue and len(component) <= 4:
            cy,cx = queue.popleft()
            for ny,nx in ((cy-1,cx),(cy+1,cx),(cy,cx-1),(cy,cx+1)):
                if 0 <= ny < height and 0 <= nx < width and transmitting[ny,nx] and (ny,nx) not in component:
                    component.add((ny,nx))
                    queue.append((ny,nx))
        visited.update(component)
        if len(component) <= 4 and any(source_alpha[p] != TRANSLUCENT_ALPHA for p in component):
            for p in component:
                fringe[p] = True
    return fringe


def load_source(path: Path, exterior: str = "opaque", alpha_map: Path | None = None,
                alpha_cutoff: int = DEFAULT_ALPHA_CUTOFF,
                preserve_alpha: bool = False,
                ) -> tuple[np.ndarray, np.ndarray, np.ndarray, str]:
    """Load a source overlay, normalised to 846x1080, as float RGB + alpha."""
    if preserve_alpha and alpha_map is not None:
        raise vart.ArtworkError('--preserve-alpha uses embedded PNG alpha; '
                                'it cannot be combined with --alpha-map')
    with Image.open(path) as handle:
        image = handle.convert("RGBA")
        size = image.size
        data = np.asarray(image)

    note = ""
    rgb = data[..., :3].astype(np.float64) / 255.0
    source_alpha = data[...,3]
    if preserve_alpha:
        material_alpha = source_alpha.copy()
        note = 'embedded source alpha preserved; cutoff and exterior correction bypassed'
    elif alpha_map is not None:
        with Image.open(alpha_map) as mask:
            if mask.size != size:
                raise vart.ArtworkError('Alpha map must match the original source dimensions')
            material_alpha = np.asarray(mask.convert('L')).copy()
        if not np.isin(material_alpha,(TRANSLUCENT_ALPHA,255)).all():
            raise vart.ArtworkError('Reviewed alpha map must contain only grayscale 51 and 255')
        note = f'reviewed alpha map: {alpha_map.name}'
    else:
        # Classify at source geometry, before any colour filtering. The numeric
        # fallback is reviewable, and must be replaced by a material map when
        # the source contains misleading alpha within a coherent printed region.
        material_alpha = normalize_material_alpha(source_alpha, alpha_cutoff)
        outside = exterior_mask(source_alpha < EXTERIOR_CUTOFF)
        if exterior == 'opaque' and outside.any():
            fringe = exterior_alpha_fringe(source_alpha,material_alpha,outside)
            outside |= fringe
            rgb[outside] = 0.0
            material_alpha[outside] = 255
            note = f'exterior {100*outside.mean():.2f}% set opaque'
            if fringe.any():
                note += f'; {int(fringe.sum())} exterior alpha fringe pixels resolved'
        changed = int(np.count_nonzero(material_alpha != source_alpha))
        note += ('; ' if note else '') + (
            f'source alpha normalized before resizing ({changed} pixels, cutoff {alpha_cutoff})'
        )
    alpha = material_alpha.astype(np.float64) / 255.0
    opaque = material_alpha == 255
    preserve_pixels = (
        size[1] == SOURCE_SIZE[1]
        and SOURCE_WIDTH_RANGE[0] <= size[0] <= SOURCE_WIDTH_RANGE[1]
    )
    if not preserve_pixels:
        # Other dimensions use material-separated resampling. Keep its selected
        # material map intact when preparing the master.
        note += f"; normalised {size[0]}x{size[1]} to 846x1080, class-aware"
        rgb, alpha, opaque = resample(rgb, alpha, opaque, SOURCE_SIZE, sharp=True,
                                     preserve_alpha=preserve_alpha)
        if not preserve_alpha:
            alpha = np.where(opaque,1.0,np.where(
                alpha*255 >= TRANSLUCENT_ALPHA/2,TRANSLUCENT_ALPHA/255.0,0.0))

    if preserve_pixels and size != SOURCE_SIZE:
        difference = SOURCE_SIZE[0] - size[0]
        left = abs(difference) // 2
        right = abs(difference) - left  # Odd extra column is added/removed at right.
        if difference > 0:
            padding = ((0, 0), (left, right))
            rgb = np.pad(rgb, (*padding, (0, 0)), constant_values=0.0)
            alpha = np.pad(alpha, padding, constant_values=1.0)
            opaque = np.pad(opaque, padding, constant_values=True)
            action = "padded opaque black"
        else:
            columns = slice(left, left + SOURCE_SIZE[0])
            rgb = rgb[:, columns]
            alpha = alpha[:, columns]
            opaque = opaque[:, columns]
            action = "cropped"
        adjustment = (
            f"{action} {size[0]}x{size[1]} to 846x1080 "
            f"({left}px left, {right}px right), no resampling"
        )
        note = adjustment + ("; " + note if note else "")
    return rgb, alpha, opaque, note


def build_orientation(
    rgb: np.ndarray,
    alpha: np.ndarray,
    opaque: np.ndarray,
    turned: bool,
    sharp: bool,
    preserve_alpha: bool = False,
) -> dict[str, np.ndarray]:
    if turned:
        rgb = np.rot90(rgb, k=-1)
        alpha = np.rot90(alpha, k=-1)
        opaque = np.rot90(opaque, k=-1)

    planes = {}
    for label, (raster, normal_rect, turned_rect) in PLANES.items():
        rect = turned_rect if turned else normal_rect
        out_rgb, out_alpha, out_opaque = resample(
            rgb, alpha, opaque, (rect[2], rect[3]), sharp,
            preserve_alpha=preserve_alpha,
        )
        planes[label] = compose_plane(out_rgb, out_alpha, out_opaque, raster, rect,
                                      preserve_alpha=preserve_alpha)
    return planes


def encode_planes(planes: dict[str, np.ndarray], workdir: Path,
                  max_colors: int = MAX_COLORS, *,
                  encoded_output: list | None = None,
                  preserve_alpha: bool = False) -> tuple[bytes, list]:
    workdir.mkdir(parents=True, exist_ok=True)
    encoded = []
    stats = []
    for label in PLANES:
        rgba = planes[label]
        indices, palette = build_indexed(rgba, max_colors=max_colors,
                                         preserve_alpha=preserve_alpha)
        png = workdir / f"{label}.png"
        write_indexed_png(png, indices, palette)
        encoded.append(vart.encode_plane(png))
        stats.append((label, len(palette)))

    container = vart.build_container(encoded)
    decoded = vart.verify_container(container, encoded, return_decoded=True)
    verify_opaque(container, planes, decoded)
    if encoded_output is not None:
        encoded_output.extend(encoded)
    return container, stats


def encode_rotated_planes(planes: dict[str, np.ndarray], workdir: Path,
                          clockwise: list, stats: list) -> tuple[bytes, list]:
    """Rotate final CW indices for CCW, retaining exact RGBA palette bytes."""
    encoded = []
    for label, plane in zip(PLANES, clockwise, strict=True):
        width, height = plane['width'], plane['height']
        indices = np.frombuffer(plane['pixels'], dtype=np.uint8).reshape(height, width)
        pixels = np.rot90(indices, k=2).tobytes()
        encoded.append(vart._encode_indexed_plane(
            width, height, pixels, plane['palette'], plane['bits'], plane['has_alpha'],
            path=workdir / f'{label}.png'))
    container = vart.build_container(encoded)
    decoded = vart.verify_container(container, encoded, return_decoded=True)
    verify_opaque(container, planes, decoded)
    return container, stats


def verify_opaque(container: bytes, planes: dict[str, np.ndarray],
                  decoded_planes: list[dict[str, object]] | None = None) -> None:
    """Verify every decoded alpha value against the prepared plane."""
    if decoded_planes is None:
        decoded_planes = vart.decode_container(container)
    decoded = {
        (plane["width"], plane["height"]): np.asarray(
            plane["image"].convert("RGBA")
        )
        for plane in decoded_planes
    }
    for label, (raster, _, _) in PLANES.items():
        got = decoded.get(raster)
        if got is None:
            raise vart.ArtworkError(f"{label}: plane missing from container")
        want_mask = planes[label][..., 3] == 255
        got_mask = got[..., 3] == 255
        if not np.array_equal(want_mask, got_mask):
            lost = int((want_mask & ~got_mask).sum())
            gained = int((got_mask & ~want_mask).sum())
            raise vart.ArtworkError(
                f"{label}: opaque set changed through encoding "
                f"({lost} lost, {gained} spurious)"
            )
        if not np.array_equal(got[...,3],planes[label][...,3]):
            raise vart.ArtworkError(f'{label}: alpha changed through encoding')


def write_atomic(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(data)
        os.replace(temporary, path)
    except Exception:
        Path(temporary).unlink(missing_ok=True)
        raise


def build_title(
    source: Path,
    outdir: Path,
    name: str | None,
    saturation: float,
    sharp: bool,
    verbose: bool = True,
    exterior: str = "opaque",
    max_colors: int = MAX_COLORS,
    alpha_map: Path | None = None,
    tate_outdir: Path | None = None,
    alpha_cutoff: int = DEFAULT_ALPHA_CUTOFF,
    preserve_alpha: bool = False,
) -> dict[str, int]:
    rgb, alpha, opaque, note = load_source(source, exterior, alpha_map, alpha_cutoff,
                                         preserve_alpha=preserve_alpha)
    rgb = desaturate(rgb, saturation)

    normal = build_orientation(rgb, alpha, opaque, False, sharp, preserve_alpha)
    clockwise = build_orientation(rgb, alpha, opaque, True, sharp, preserve_alpha)
    # The rects are symmetric about the raster centre, so the counter-clockwise
    # planes are an exact 180-degree rotation with no further resampling.
    counter = {label: np.rot90(plane, k=2) for label, plane in clockwise.items()}

    sizes = {}
    stem = name or source.stem
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        clockwise_encoded = []
        clockwise_stats = []
        for suffix, planes in (
            ("", normal), ("_90CW", clockwise), ("_90CCW", counter)
        ):
            if suffix == '_90CCW':
                container, stats = encode_rotated_planes(
                    planes, root / suffix, clockwise_encoded, clockwise_stats)
            else:
                container, stats = encode_planes(
                    planes, root / (suffix or "normal"), max_colors=max_colors,
                    encoded_output=clockwise_encoded if suffix == '_90CW' else None,
                    preserve_alpha=preserve_alpha)
                if suffix == '_90CW':
                    clockwise_stats = stats
            destination = tate_outdir if suffix and tate_outdir is not None else outdir
            target = destination / f"{stem}{suffix}.art"
            write_atomic(target, container)
            sizes[target.name] = len(container)
            if verbose:
                palettes = " ".join(f"{label}:{count}" for label, count in stats)
                print(f"  {target.name:<44} {len(container):>9,} B   palette {palettes}")
    if verbose and note:
        print(f"  note: {note}")
    return sizes


# --------------------------------------------------------------------------
# Individual mode and extraction
# --------------------------------------------------------------------------

def pack_directory(directory: Path, output: Path,
                   max_colors: int = MAX_COLORS,
                   alpha_cutoff: int = DEFAULT_ALPHA_CUTOFF,
                   preserve_alpha: bool = False) -> None:
    planes = {}
    for label, (raster, _, _) in PLANES.items():
        source = directory / f"{label}.png"
        if not source.is_file():
            raise vart.ArtworkError(f"missing required input {source}")
        with Image.open(source) as handle:
            if handle.size != raster:
                raise vart.ArtworkError(
                    f"{source}: expected {raster[0]}x{raster[1]}, "
                    f"got {handle.width}x{handle.height}"
                )
            planes[label] = np.asarray(handle.convert("RGBA")).copy()
            if not preserve_alpha:
                planes[label][...,3] = normalize_material_alpha(planes[label][...,3], alpha_cutoff)

    with tempfile.TemporaryDirectory() as temporary:
        container, stats = encode_planes(planes, Path(temporary), max_colors=max_colors,
                                         preserve_alpha=preserve_alpha)
    write_atomic(output, container)
    palettes = " ".join(f"{label}:{count}" for label, count in stats)
    print(f"{output.name}: {len(container):,} bytes   palette {palettes}")


def extract_package(package: Path, outdir: Path,
                    resolution: str | None = "1080p",
                    full_plane: bool = False,
                    orientation: str = "auto") -> None:
    """Copy stored RGBA pixels; None selects every resolution, without filtering."""
    if resolution is not None and resolution not in PLANES:
        raise vart.ArtworkError(f"unknown resolution {resolution!r}")
    if orientation not in ("auto", "normal", "cw", "ccw"):
        raise vart.ArtworkError(f"unknown orientation {orientation!r}")
    if orientation == "auto":
        stem = package.stem.casefold()
        orientation = ("ccw" if stem.endswith("_90ccw") else
                       "cw" if stem.endswith("_90cw") else "normal")
    sizes = {raster: label for label, (raster, _, _) in PLANES.items()}
    selected = []
    available = []
    names = set()
    for plane in vart.decode_container(package.read_bytes()):
        raster = (plane["width"], plane["height"])
        label = sizes.get(raster, f"{raster[0]}x{raster[1]}")
        available.append(label)
        if resolution is not None and label != resolution:
            continue
        if label in names:
            raise vart.ArtworkError(f"multiple planes match {label}; extraction is ambiguous")
        names.add(label)
        image = plane["image"].convert("RGBA")
        if not full_plane:
            if label not in PLANES:
                raise vart.ArtworkError(
                    f"no artwork crop defined for {label}; use --all-resolutions --full-plane"
                )
            x, y, width, height = PLANES[label][1 if orientation == "normal" else 2]
            image = image.crop((x, y, x + width, y + height))
        selected.append((label, image))
    if not selected:
        raise vart.ArtworkError(
            f"{resolution or 'requested'} plane not found; available: "
            + ", ".join(available)
        )
    # Validate selection before creating output files, including unknown crops.
    outdir.mkdir(parents=True, exist_ok=True)
    for label, image in selected:
        target = outdir / f"{label}.png"
        image.save(target)
        print(f"{target}: {image.width}x{image.height}")


# --------------------------------------------------------------------------

def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument(
        "--max-colors", "--max_color", dest="max_colors", type=int,
        choices=MAX_COLOR_CHOICES, default=MAX_COLORS,
        help="maximum RGBA palette entries per plane for build/build-all/pack "
             f"(default {MAX_COLORS}); fewer used entries select fewer index bits automatically",
    )
    parser.add_argument(
        "--alpha-cutoff", type=int, default=DEFAULT_ALPHA_CUTOFF, metavar="N",
        help="source-alpha cutoff for build/build-all/pack (1-255, default "
             f"{DEFAULT_ALPHA_CUTOFF}): nonzero values below N become 51, values "
             "at or above N become 255; --alpha-map/--preserve-alpha bypass this cutoff",
    )
    parser.add_argument(
        "--preserve-alpha", action="store_true",
        help="retain embedded PNG alpha levels for build/build-all/pack; bypass "
             "cutoff and exterior correction; resizing retains authored levels, "
             "palette reduction leaves alpha unchanged",
    )
    parser.add_argument(
        "--saturation", type=float, default=DEFAULT_SATURATION,
        help="HSL saturation multiplier (default 1.0: retain source saturation)",
    )
    parser.add_argument(
        "--no-desaturate", action="store_const", const=1.0, dest="saturation",
        help="keep the source saturation (default; equivalent to --saturation 1.0)",
    )
    parser.add_argument(
        "--exterior", choices=("opaque", "clear"), default="opaque",
        help="alpha outside the sheet: opaque 255 (default) or clear 0; "
             "--alpha-map/--preserve-alpha bypass this correction",
    )
    parser.add_argument(
        "--box", action="store_true",
        help="use BOX RGB instead of Lanczos when enlarging; reductions always "
        "use combined opaque coverage and exact area RGB",
    )
    commands = parser.add_subparsers(dest="command", required=True)

    build = commands.add_parser("build", help="one source PNG to three packages")
    build.add_argument("source", type=Path)
    build.add_argument("--name", help="output basename; defaults to the source stem")
    build.add_argument('--alpha-map',type=Path,
                       help='reviewed grayscale 51/255 map at original source dimensions; '
                            'bypasses source-alpha cutoff and exterior correction')
    build.add_argument(
        "-o", "--outdir", type=Path, action="append", metavar="DIR",
        help="output directory (default current directory); repeat once to send "
             "CW/CCW to a second directory",
    )

    build_all = commands.add_parser("build-all", help="every PNG in a directory")
    build_all.add_argument("input", type=Path)
    build_all.add_argument(
        "-o", "--outdir", type=Path, action="append", metavar="DIR",
        help="output directory (default current directory); repeat once to send "
             "CW/CCW to a second directory",
    )
    build_all.add_argument(
        "-j", "--jobs", type=int, default=min(8, os.cpu_count() or 1),
        help="parallel workers (default: up to 8)",
    )

    pack = commands.add_parser("pack", help="four exact-raster PNGs to one package")
    pack.add_argument("input", type=Path, help="directory of 1080p/720p/480p/240p.png")
    pack.add_argument("output", type=Path)

    extract = commands.add_parser("extract", help="extract artwork PNGs (default: cropped 1080p)")
    extract.add_argument("input", type=Path)
    extract.add_argument("-o", "--outdir", type=Path, required=True)
    selection = extract.add_mutually_exclusive_group()
    selection.add_argument(
        "--resolution", choices=tuple(PLANES), default="1080p",
        help="single resolution to extract (default: 1080p)",
    )
    selection.add_argument(
        "--all-resolutions", action="store_const", const=None, dest="resolution",
        help="extract every stored resolution instead of one",
    )
    extract.add_argument(
        "--full-plane", action="store_true",
        help="keep full raster dimensions instead of the centered artwork crop",
    )
    extract.add_argument(
        "--orientation", type=str.lower, choices=("auto", "normal", "cw", "ccw"),
        default="auto",
        help="crop geometry (default auto: _90CW/_90CCW filename suffix, otherwise normal)",
    )

    args = parser.parse_args()
    if not 1 <= args.alpha_cutoff <= 255:
        parser.error("--alpha-cutoff must be an integer from 1 to 255")
    if args.preserve_alpha and getattr(args, 'alpha_map', None) is not None:
        parser.error('--preserve-alpha and --alpha-map cannot be combined')
    if args.command in ("build", "build-all"):
        output_dirs = args.outdir or [Path(".")]
        if len(output_dirs) > 2:
            parser.error(f"{args.command} accepts at most two output directories "
                         "(-o NORMAL_DIR -o TATE_DIR)")
        outdir = output_dirs[0]
        tate_outdir = output_dirs[1] if len(output_dirs) == 2 else None
    sharp = not args.box
    try:
        if args.command == "build":
            print(f"{args.source.name}  saturation {args.saturation:g}"
                  f"  exterior {args.exterior}  max colors {args.max_colors}")
            build_title(args.source, outdir, args.name, args.saturation, sharp,
                        exterior=args.exterior, max_colors=args.max_colors,
                        alpha_map=args.alpha_map, tate_outdir=tate_outdir,
                        alpha_cutoff=args.alpha_cutoff, preserve_alpha=args.preserve_alpha)
        elif args.command == "build-all":
            sources = sorted(args.input.glob("*.png"))
            if not sources:
                raise vart.ArtworkError(f"{args.input}: no PNG sources found")
            jobs = max(1, min(args.jobs, len(sources)))
            print(
                f"building {len(sources)} titles with {jobs} workers, "
                f"saturation {args.saturation:g}, exterior {args.exterior}, "
                f"max colors {args.max_colors}, "
                + ('embedded alpha preserved' if args.preserve_alpha else
                   f'alpha cutoff {args.alpha_cutoff}')
            )
            total = 0
            done = 0
            with concurrent.futures.ProcessPoolExecutor(max_workers=jobs) as pool:
                pending = {
                    pool.submit(
                        build_title, source, outdir, None,
                        args.saturation, sharp, False, args.exterior,
                        max_colors=args.max_colors, tate_outdir=tate_outdir,
                        alpha_cutoff=args.alpha_cutoff,
                        preserve_alpha=args.preserve_alpha,
                    ): source
                    for source in sources
                }
                for future in concurrent.futures.as_completed(pending):
                    source = pending[future]
                    sizes = future.result()
                    done += 1
                    total += sum(sizes.values())
                    print(
                        f"[{done}/{len(sources)}] {source.stem:<34} "
                        f"{sum(sizes.values()):>9,} B"
                    )
            print(f"{len(sources) * 3} packages, {total:,} bytes total")
        elif args.command == "pack":
            pack_directory(args.input, args.output, max_colors=args.max_colors,
                           alpha_cutoff=args.alpha_cutoff, preserve_alpha=args.preserve_alpha)
        else:
            extract_package(args.input, args.outdir, resolution=args.resolution,
                            full_plane=args.full_plane, orientation=args.orientation)
    except (OSError, vart.ArtworkError) as error:
        print(f"FAILED: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
