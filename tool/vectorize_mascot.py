#!/usr/bin/env python3
"""Traces a hand-drawn mascot PNG (assets/sticker_packs/default/*.png) into a
flat-color SVG that preserves the real linework, instead of approximating the
character with primitive shapes. Used for the .rlv vector sticker redesign.

Requires: potrace, librsvg (brew install potrace librsvg), scipy, numpy, PIL.

Usage: python3 tool/vectorize_mascot.py Happy.png [out_dir]

Pipeline (see chat history 2026-08-21 for the full rationale/debugging):
1. Downsample (LANCZOS) so the source's soft shading/AA noise doesn't survive
   as speckle noise after classification.
2. Seeded k-means classify opaque pixels into named colors (not blind
   quantization — blind clustering split real regions into noisy shading
   bands; seeding with the mascot's known palette keeps semantic regions
   together even where the art has soft internal gradient shading).
3. Per color, connected-component filter: keep only components >= a floor
   (drops AA/gradient noise speckles — verified to sit under ~0.16% of image
   area — while keeping every real design element, all >= ~1.2%).
4. Trace EACH surviving component with potrace SEPARATELY, not merged into
   one multi-island bitmap per color — potrace's nonzero winding rule
   produces broken (invisible) fills when a single traced path has many
   disconnected islands (confirmed: 2-island horns traced fine merged, but
   eyes+teeth+halo as one ~26-island white mask silently dropped most
   islands). One PGM+potrace call per component sidesteps this entirely.
5. A full-silhouette "base" layer (the whole opaque alpha mask, not the
   'body' color cluster) is traced and placed first/bottom in the body's own
   color, so gaps where shading pixels didn't classify as the body color
   never show through as background.
6. Combine every component's traced path into one <svg>, all sharing potrace's
   own transform (same-size inputs give identical transforms, so this is
   just string concatenation — no coordinate math needed).

Also note: PBM (1-bit) input made potrace invert polarity unpredictably per
mask (some traces came out ~35x too large — background instead of shape).
Switching to PGM (grayscale, 0=foreground/255=background, potrace's default
blacklevel=0.5) fixed it outright — always use PGM here, not PBM.
"""
import sys
import subprocess
import re
from pathlib import Path

from PIL import Image
import numpy as np
from scipy import ndimage

SEED_COLORS = {
    "black": (10, 8, 12),
    "white": (250, 250, 250),
    "purple": (122, 73, 190),  # body — also used as the gap-free base fill
    "green": (100, 170, 40),
    "maroon": (92, 12, 22),
    "pink": (232, 120, 140),
    "red": (200, 48, 56),
}
BODY_KEY = "purple"
MAX_DIM = 460
MIN_COMPONENT_PCT = 0.03  # drop connected components smaller than this
# ^ Deliberately low: genuine small details (individual teeth, per-claw
# marks) measured as small as 0.055%-0.14% of the image, well below what an
# earlier 0.25% floor let through — that floor was silently dropping them
# (teeth/claws rendering as the body color, not white). True AA/gradient
# noise speckles top out around 0.02%-0.06% per component, so 0.03% doesn't
# cleanly separate the two by size alone; the edge_band fraction test below
# is what actually rejects noise and fringe, this floor only needs to keep
# single-pixel dust out of the per-component potrace calls.


_CORE_SEEDS = {"black", "white", "purple", "green", "maroon"}


def _kmeans(pts, seeds):
    names = list(seeds.keys())
    centers = np.array([seeds[n] for n in names], dtype=float)
    assign = np.zeros(len(pts), dtype=int)
    for _ in range(15):
        d = ((pts[:, None, :] - centers[None, :, :]) ** 2).sum(axis=2)
        assign = d.argmin(axis=1)
        for k in range(len(names)):
            sel = pts[assign == k]
            if len(sel):
                centers[k] = sel.mean(axis=0)
    return names, centers, assign


def classify(png_path: Path, work_dir: Path, extra_seeds: dict[str, tuple[int, int, int]] | None = None):
    im = Image.open(png_path).convert("RGBA")
    w, h = im.size
    scale = MAX_DIM / max(w, h)
    nw, nh = max(1, round(w * scale)), max(1, round(h * scale))
    small = im.resize((nw, nh), Image.LANCZOS)
    arr = np.array(small).astype(float)
    alpha = arr[:, :, 3]
    rgb = arr[:, :, :3]
    opaque = alpha > 128

    seeds = dict(SEED_COLORS)
    if extra_seeds:
        seeds.update(extra_seeds)
    pts = rgb[opaque]
    names, centers, assign = _kmeans(pts, seeds)

    # A seed with no genuine target in this character (e.g. "red" when there
    # are no hearts) doesn't stay empty — it drifts to the mean of whatever
    # ambiguous shading/AA pixels are nearest, which is almost always a
    # muddy, low-saturation color (confirmed: MAX's unused "red" converged
    # to a flat gray and traced as a visible patch). A genuine design color
    # (heart red, tongue pink, sparkle yellow) stays saturated. Drop any
    # non-core seed that ends up desaturated and re-run k-means so its
    # pixels fall back to a real neighboring cluster instead of a fake one.
    def saturation(rgb_center):
        r, g, b = (v / 255.0 for v in rgb_center)
        mx, mn = max(r, g, b), min(r, g, b)
        return 0.0 if mx == 0 else (mx - mn) / mx

    orphans = [
        n for n, c in zip(names, centers)
        if n not in _CORE_SEEDS and saturation(c) < 0.18
    ]
    if orphans:
        seeds = {n: v for n, v in seeds.items() if n not in orphans}
        names, centers, assign = _kmeans(pts, seeds)

    full_assign = np.full((nh, nw), -1, dtype=int)
    full_assign[opaque] = assign
    return full_assign, centers, names, nw, nh


def trace_component(mask: np.ndarray, out_pgm: Path, out_svg: Path) -> list[str]:
    # A single scipy-labeled (4-connected) region is guaranteed contiguous,
    # but potrace's own tracer can still split it into several disjoint
    # <path> elements (observed: a 4-connected "base" union of many pieces
    # split into 13). Capturing only the first one silently dropped most of
    # the shape — collect every path this call produced, not just one.
    gray = np.where(mask, 0, 255).astype(np.uint8)
    Image.fromarray(gray, mode="L").save(out_pgm)
    subprocess.run(
        ["potrace", "-s", "-t", "3", "-a", "1", "-o", str(out_svg), str(out_pgm)],
        check=True,
    )
    return re.findall(r'<path d="(.*?)"/>', out_svg.read_text(), re.S)


def vectorize(
    png_path: Path,
    work_dir: Path,
    keep_near: dict[str, list[tuple[float, float]]] | None = None,
    near_radius: float = 45.0,
    extra_seeds: dict[str, tuple[int, int, int]] | None = None,
) -> Path:
    """keep_near restricts a color to components near given (x,y) points in
    classification space — e.g. Love's floating hearts and its heart-eye
    fills are both traced as "red", but only the eye ones belong baked into
    the body; the floating ones are re-added later as their own independently
    animated layers, so they're excluded here rather than double-drawn.
    extra_seeds adds sticker-specific colors (a laptop's gray, a sparkle's
    yellow) on top of the shared mascot palette."""
    work_dir.mkdir(parents=True, exist_ok=True)
    stem = png_path.stem
    full_assign, centers, names, nw, nh = classify(png_path, work_dir, extra_seeds=extra_seeds)

    layers: list[tuple[str, str, list[str]]] = []

    body_k = names.index(BODY_KEY)
    black_k = names.index("black")
    white_k = names.index("white")
    body_hex = "#%02X%02X%02XFF" % tuple(int(v) for v in centers[body_k])

    # The source PNGs are imperfectly cropped: a background-removal pass that
    # flood-fills from the canvas edge leaves any white background pocket
    # that's fully ENCLOSED by the character's own silhouette untouched (e.g.
    # Love's horn+hearts+tail arrangement encloses a sizable untouched patch
    # behind the horn — not a thin fringe, a real leftover chunk). The tell
    # is topological, not size or shape: a genuine white detail (eye, tooth)
    # is surrounded by opaque character pixels; a missed background pocket is
    # surrounded by more background. Reclassify any such pocket as
    # background BEFORE computing anything else, so it can't leak into the
    # body fill via erosion survival or the outline union either.
    full_silhouette = full_assign >= 0
    background = ~full_silhouette
    white_mask = full_assign == white_k
    lbl, n = ndimage.label(white_mask)
    if n > 0:
        for i in range(1, n + 1):
            comp = lbl == i
            ring = ndimage.binary_dilation(comp, iterations=4) & ~comp
            ring_total = int(ring.sum())
            if ring_total == 0:
                continue
            frac_bg = (ring & background).sum() / ring_total
            if frac_bg >= 0.3:
                full_silhouette &= ~comp
                full_assign[comp] = -1

    # keep_near-excluded components (e.g. Love's floating hearts, which get
    # re-added as their own independently animated layers) must disappear
    # from the body entirely, fill AND outline — otherwise the body still
    # carries a hollow black heart-ring where the fill used to be, or the
    # base silhouette's erosion still picks up the fill as generic opaque
    # area. Dilating past the outline's own width before reclassifying to
    # background removes both in one step.
    if keep_near:
        for name, pts in keep_near.items():
            k = names.index(name)
            cmask = full_assign == k
            clbl, cn = ndimage.label(cmask)
            csizes = ndimage.sum(cmask, clbl, range(1, cn + 1))
            for i in range(1, cn + 1):
                comp = clbl == i
                # A big dilation is needed to also erase a real heart's own
                # outline stroke, but applying that to a handful of stray
                # noise pixels can eat into a genuine neighboring shape (seen
                # eating a hole in the held-heart tongue). Only components
                # sized like an actual drawn heart get the wipe; tiny noise
                # stays classified as-is — a fleck is far less visible than a
                # torn hole in something real.
                if csizes[i - 1] < 150:
                    continue
                ys, xs = np.where(comp)
                if len(xs) == 0:
                    continue
                ccx, ccy = xs.mean(), ys.mean()
                if any(((ccx - px) ** 2 + (ccy - py) ** 2) ** 0.5 <= near_radius for px, py in pts):
                    continue
                wiped = ndimage.binary_dilation(comp, iterations=10)
                full_silhouette &= ~wiped
                full_assign[wiped] = -1

    total = int(full_silhouette.sum())

    # The body fill must stop at the true ink boundary, not the source PNG's
    # full opaque region — that region still includes a few px of soft AA
    # fringe right at the edge. Eroding first and re-adding the black-ink
    # pixels (which legitimately reach the true edge) gives a silhouette
    # bounded exactly by the outline.
    core = ndimage.binary_erosion(full_silhouette, iterations=3)
    base_mask = core | (full_assign == black_k)
    base_ds = trace_component(
        base_mask, work_dir / f"{stem}_base.pgm", work_dir / f"{stem}_base.svg"
    )
    if base_ds:
        layers.append(("base", body_hex, base_ds))

    # Same AA-fringe logic as above, applied to each detail color: a
    # component mostly sitting in that ~3px edge band is fringe riding along
    # on this color by coincidence, not a real design element (validated
    # against Love's floating hearts: real hearts measured 0.00-0.20 here,
    # fringe measured 0.25-0.44).
    edge_band = full_silhouette & ~core
    EDGE_FRACTION_CUTOFF = 0.22

    for k, name in enumerate(names):
        if name == BODY_KEY:
            continue
        mask = full_assign == k
        lbl, n = ndimage.label(mask)
        ds = []
        if n > 0:
            sizes = ndimage.sum(mask, lbl, range(1, n + 1))
            floor = total * MIN_COMPONENT_PCT / 100.0
            for i, s in enumerate(sizes):
                if s < floor:
                    continue
                comp = lbl == (i + 1)
                if name != "black":
                    edge_frac = (comp & edge_band).sum() / s
                    if edge_frac >= EDGE_FRACTION_CUTOFF:
                        continue
                if keep_near and name in keep_near:
                    ys, xs = np.where(comp)
                    ccx, ccy = xs.mean(), ys.mean()
                    if not any(
                        ((ccx - px) ** 2 + (ccy - py) ** 2) ** 0.5 <= near_radius
                        for px, py in keep_near[name]
                    ):
                        continue
                ds.extend(trace_component(
                    comp,
                    work_dir / f"{stem}_{name}_{i}.pgm",
                    work_dir / f"{stem}_{name}_{i}.svg",
                ))
        if ds:
            hexcol = "#%02X%02X%02XFF" % tuple(int(v) for v in centers[k])
            layers.append((name, hexcol, ds))

    fills = [l for l in layers if l[0] not in ("black",)]
    outline = [l for l in layers if l[0] == "black"]
    ordered = fills + outline
    parts = [
        f'<path fill="{hexcol}" d="{d}"/>'
        for _name, hexcol, ds in ordered
        for d in ds
    ]
    svg = (
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {nw} {nh}" '
        f'width="{nw}" height="{nh}">\n'
        f'<g transform="translate(0,{nh}) scale(0.1,-0.1)">\n' + "\n".join(parts) + "\n</g>\n</svg>\n"
    )
    out_path = work_dir / f"{stem}_combined.svg"
    out_path.write_text(svg)
    print(f"{stem}: {len(parts)} path elements, {nw}x{nh}px source -> {out_path}")
    return out_path


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    png_name = sys.argv[1]
    out_dir = Path(sys.argv[2]) if len(sys.argv) > 2 else Path("/tmp/vectrace")
    src = Path("assets/sticker_packs/default") / png_name
    keep_near = None
    extra_seeds = None
    if png_name == "Love.png":
        # Only the two heart-eye fills stay baked into the body; the
        # floating hearts elsewhere in the "red" cluster are dropped here
        # and re-added as their own independently animated layers.
        keep_near = {"red": [(229, 185), (166, 194)]}
    elif png_name == "Best.png":
        extra_seeds = {"yellow": (240, 208, 64)}  # sparkle accent
    elif png_name == "LapTop.png":
        extra_seeds = {"gray": (145, 145, 148)}  # laptop body
    elif png_name == "MAX.png":
        extra_seeds = {"coral": (233, 122, 94)}  # tongue
    vectorize(src, out_dir, keep_near=keep_near, extra_seeds=extra_seeds)
