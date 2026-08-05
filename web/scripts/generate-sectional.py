#!/usr/bin/env python3
"""Re-cut the route planner's sectional backdrop from an FAA sectional PDF.

    pip install pymupdf pillow numpy
    python3 web/scripts/generate-sectional.py ~/Downloads/San_Francisco.pdf

Writes web/src/assets/sectional-bay.webp and prints the FX/FY coefficient rows
to paste into web/src/core/sectional.ts.

Why this is not just a crop: sectionals are Lambert Conformal Conic, so lat/lon
maps to pixels non-linearly — meridians converge going north and parallels bow.
Fitting a plain affine leaves markers ~15 px off at the corners of this frame,
which is obvious once they sit on top of the chart's own airport symbols. So we
calibrate against the chart's printed graticule: find the whole/half-degree
parallels and meridians, intersect them, and least-squares a quadratic through
the intersections. That reproduces every grid crossing to under half a pixel.

Get the chart from https://www.faa.gov/air_traffic/flight_info/aeronav/digital_products/vfr/
(Sectional, PDF). Charts expire every 56 days; the backdrop is decorative and
labelled "not for navigation", so it does not need to be current, but re-cutting
it occasionally keeps airspace on the picture roughly honest.
"""

import sys
from pathlib import Path

import fitz  # pymupdf
import numpy as np
from PIL import Image

Image.MAX_IMAGE_PIXELS = None

DPI = 300

# Graticule lines to calibrate against, and roughly where they land in the
# 300 dpi render. Identified once by scanning the render for the strongest
# horizontal/vertical dark features and reading the chart's own degree labels;
# the assertions below re-check them, since even spacing is a strong signal that
# the guesses landed on real graticule and not on a road or a coastline.
PARALLELS = {38.0: 665, 37.5: 1976, 37.0: 3285, 36.5: 4595}
MERIDIANS = {-122.5: 721, -122.0: 1781, -121.5: 2828, -121.0: 3865}

# Frame to keep, chosen to hold every routable airport with room for markers.
CROP = (370, 410, 3250, 4700)  # left, top, right, bottom in 300 dpi pixels
OUT_SIZE = (940, 1400)
WEBP_QUALITY = 76

# Basis is centred on the middle of the crop to keep the quadratic terms small.
LON0, LAT0 = -121.75, 37.25


def basis(lon, lat):
    u, v = lon - LON0, lat - LAT0
    return np.stack([np.ones_like(u), u, v, u * u, u * v, v * v], axis=-1)


def render(pdf: Path) -> np.ndarray:
    page = fitz.open(pdf)[0]
    pix = page.get_pixmap(dpi=DPI)
    img = np.frombuffer(pix.samples, dtype=np.uint8).reshape(pix.height, pix.width, pix.n)
    return img[:, :, :3]


def trace(dark, axis, guess, lo, hi, span=22):
    """Locate a graticule line near `guess`, using a short stretch of it.

    Returns (sub-pixel position, contrast) where contrast is the peak's excess
    dark-pixel density over the local median — the chart is busy, so stretches
    where the line runs under a city or an airspace ring get thrown out.
    """
    if axis == "row":
        sub = dark[guess - span : guess + span + 1, lo:hi]
    else:
        sub = dark[lo:hi, guess - span : guess + span + 1].T
    counts = sub.sum(axis=1).astype(float)
    k = int(np.argmax(counts))
    weights = np.clip(counts[max(0, k - 2) : k + 3] - np.median(counts), 0, None)
    idx = np.arange(max(0, k - 2), min(len(counts), k + 3))
    pos = (idx * weights).sum() / weights.sum() if weights.sum() else k
    return guess - span + pos, (counts[k] - np.median(counts)) / (hi - lo)


def fit_line(dark, axis, guess, limit, step=150, window=300, min_contrast=0.55):
    """Fit position as a quadratic along the line — parallels bow, meridians tilt."""
    pts = []
    for start in range(150, limit - window, step):
        pos, contrast = trace(dark, axis, guess, start, start + window)
        if contrast > min_contrast:
            pts.append((start + window / 2, pos, contrast))
    pts = np.array(pts)
    if len(pts) < 8:
        raise SystemExit(f"only {len(pts)} clean samples for the line near {guess}")
    design = np.stack([np.ones(len(pts)), pts[:, 0], pts[:, 0] ** 2], axis=1)
    w = pts[:, 2:3]
    coef, *_ = np.linalg.lstsq(design * w, pts[:, 1] * pts[:, 2], rcond=None)
    return coef


def main():
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    pdf = Path(sys.argv[1]).expanduser()
    root = Path(__file__).resolve().parents[1]

    rgb = render(pdf)
    dark = (rgb.max(axis=2) < 100).astype(np.int32)
    h, w = dark.shape
    print(f"rendered {w}x{h} at {DPI} dpi")

    par = {lat: fit_line(dark, "row", g, w) for lat, g in PARALLELS.items()}
    mer = {lon: fit_line(dark, "col", g, h) for lon, g in MERIDIANS.items()}

    def y_of(c, x):
        return c[0] + c[1] * x + c[2] * x * x

    # A sanity check that we tracked real graticule: degree spacing must be even.
    mid_y = [y_of(par[lat], w / 2) for lat in sorted(par, reverse=True)]
    gaps = np.diff(mid_y)
    assert gaps.std() < 2, f"uneven parallel spacing {gaps} — check PARALLELS"
    mid_x = [y_of(mer[lon], h / 2) for lon in sorted(mer)]
    gaps = np.diff(mid_x)
    assert gaps.std() < 2, f"uneven meridian spacing {gaps} — check MERIDIANS"

    control = []
    for lat, pc in par.items():
        for lon, mc in mer.items():
            x, y = w / 2, y_of(pc, w / 2)
            for _ in range(50):  # the two curves are near-perpendicular; this converges fast
                x = y_of(mc, y)
                y = y_of(pc, x)
            control.append((lon, lat, x, y))
    control = np.array(control)

    design = basis(control[:, 0], control[:, 1])
    cx, *_ = np.linalg.lstsq(design, control[:, 2], rcond=None)
    cy, *_ = np.linalg.lstsq(design, control[:, 3], rcond=None)
    err = np.hypot(design @ cx - control[:, 2], design @ cy - control[:, 3])
    print(f"graticule fit: {len(control)} intersections, max error {err.max():.2f} px")
    assert err.max() < 1.5, "fit is too loose to trust — check the traced lines"

    x0, y0, x1, y1 = CROP
    Image.fromarray(rgb).crop(CROP).resize(OUT_SIZE, Image.LANCZOS).save(
        root / "src/assets/sectional-bay.webp", "WEBP", quality=WEBP_QUALITY, method=6
    )

    # Restate the fit in fractions of the cropped image, which is what the app
    # uses — that way the numbers survive any change to the output resolution.
    fx, fy = cx / (x1 - x0), cy / (y1 - y0)
    fx[0] -= x0 / (x1 - x0)
    fy[0] -= y0 / (y1 - y0)
    print(f"\nSECTIONAL_W = {OUT_SIZE[0]}; SECTIONAL_H = {OUT_SIZE[1]}")
    print("const FX = [" + ", ".join(f"{v:.8g}" for v in fx) + "];")
    print("const FY = [" + ", ".join(f"{v:.8g}" for v in fy) + "];")


if __name__ == "__main__":
    main()
