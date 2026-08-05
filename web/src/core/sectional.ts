// Places lat/lon on the static sectional backdrop used by the route planner.
//
// The backdrop (../assets/sectional-bay.webp) is a crop of the FAA San Francisco
// Sectional — a US government work, public domain — covering Concord down to
// Monterey. Sectionals are drawn in Lambert Conformal Conic, so lat/lon -> pixel
// is not a plain linear scale: meridians converge going north and parallels bow.
// A straight affine fit lands 15 px off at the corners (at the 300 dpi source
// scale), which is visible once markers sit on top of airport symbols.
//
// The coefficients below were fitted against the chart's own printed graticule —
// the 36°30'/37°00'/37°30'/38°00' parallels and the 121°00'/121°30'/122°00'/
// 122°30' meridians, located to a tenth of a pixel in the 300 dpi render — and
// reproduce every one of the 16 grid intersections to under half a pixel. They
// map (lon, lat) to a fraction of the image, so they stay valid no matter what
// size the image is displayed at; only a re-crop of the backdrop invalidates them.

/** Aspect ratio (width / height) of the backdrop image. */
export const SECTIONAL_W = 940;
export const SECTIONAL_H = 1400;

// Basis is [1, u, v, u², uv, v²] with u = lon + 121.75, v = lat - 37.25 (the
// centre of the crop) — centring keeps the quadratic terms small and stable.
const FX = [0.67154273, 0.72709848, 0.00304932, -0.00022323, -0.00916523, -8.196e-5];
const FY = [0.51744051, 0.00169041, -0.61063809, -0.00252811, -2.146e-5, -0.00019499];

/** Where a coordinate falls on the backdrop, as 0–1 fractions of width/height.
 *  Returns null for anything outside the printed area. */
export function sectionalPos(lat: number, lon: number): { fx: number; fy: number } | null {
  const u = lon + 121.75;
  const v = lat - 37.25;
  const basis = [1, u, v, u * u, u * v, v * v];
  let fx = 0;
  let fy = 0;
  for (let i = 0; i < 6; i++) {
    fx += FX[i] * basis[i];
    fy += FY[i] * basis[i];
  }
  if (fx < 0 || fx > 1 || fy < 0 || fy > 1) return null;
  return { fx, fy };
}
