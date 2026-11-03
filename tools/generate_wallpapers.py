#!/usr/bin/env python3
"""Generates the built-in wallpapers in Resources/Wallpapers.bundle.

Every image is drawn from scratch with seeded math and self-chosen colors, so the
set carries no third-party rights. Output is deterministic for a given numpy version,
and the JPGs are committed so macOS and Windows ship the same bytes.

Needs numpy and Pillow:
    python3 tools/generate_wallpapers.py                     # writes the bundle
    python3 tools/generate_wallpapers.py --preview DIR       # small contact sheets only
    python3 tools/generate_wallpapers.py --only Spring ...
"""
import argparse
import math
import multiprocessing
import shutil
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent / "NativeScreen" / "NativeScreen" / "Resources" / "Wallpapers.bundle"
FULL_SIZE = (2560, 1600)  # Matches the compositor's 2560 px decode limit.
THUMB_SIZE = (192, 120)
JPEG_QUALITY = 86


# ---- color -----------------------------------------------------------------
def hex_rgb(h):
    h = h.lstrip("#")
    return np.array([int(h[i:i + 2], 16) / 255 for i in (0, 2, 4)])


def srgb_to_linear(c):
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


def linear_to_srgb(c):
    c = np.clip(c, 0, 1)
    return np.where(c <= 0.0031308, c * 12.92, 1.055 * c ** (1 / 2.4) - 0.055)


def lch(L, C, H):
    """OKLCH to OKLab. Hue in degrees."""
    a = math.radians(H)
    return np.array([L, C * math.cos(a), C * math.sin(a)])


def oklab(h):
    if not isinstance(h, str):
        return h
    r, g, b = srgb_to_linear(hex_rgb(h))
    l = 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b
    m = 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b
    s = 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b
    l, m, s = np.cbrt(l), np.cbrt(m), np.cbrt(s)
    return np.array([
        0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
        1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
        0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s,
    ])


def lab_to_srgb(lab):
    L, a, b = lab[..., 0], lab[..., 1], lab[..., 2]
    l = (L + 0.3963377774 * a + 0.2158037573 * b) ** 3
    m = (L - 0.1055613458 * a - 0.0638541728 * b) ** 3
    s = (L - 0.0894841775 * a - 1.2914855480 * b) ** 3
    rgb = np.stack([
        4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
        -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
        -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s,
    ], axis=-1)
    return linear_to_srgb(rgb)


# ---- fields ----------------------------------------------------------------
def smoothstep(a, b, x):
    t = np.clip((x - a) / (b - a), 0, 1)
    return t * t * (3 - 2 * t)


def wave(u, rng, amp=1.0, f0=0.5, f1=2.2, n=4):
    out = np.zeros_like(u)
    for _ in range(n):
        f = rng.uniform(f0, f1)
        out += np.sin(2 * np.pi * f * u + rng.uniform(0, 6.283)) / f
    return amp * out / n


def blobs(X, Y, cols, rng, sigma=0.55):
    """Soft color field from gaussian blobs, smoother than a corner mesh."""
    w_sum, acc = 0, 0
    for c in cols:
        cx, cy = rng.uniform(-0.1, X.max() + 0.1), rng.uniform(-0.1, 1.1)
        s = sigma * rng.uniform(0.7, 1.3)
        w = np.exp(-((X - cx) ** 2 + (Y - cy) ** 2) / (2 * s * s)) + 1e-4
        w_sum = w_sum + w
        acc = acc + w[..., None] * oklab(c)
    return acc / w_sum[..., None]


def lch_mix(c0, c1, t):
    c0, c1 = oklab(c0), oklab(c1)
    h0, h1 = np.arctan2(c0[2], c0[1]), np.arctan2(c1[2], c1[1])
    dh = (h1 - h0 + np.pi) % (2 * np.pi) - np.pi
    C = np.hypot(c0[1], c0[2]) * (1 - t) + np.hypot(c1[1], c1[2]) * t
    H = h0 + dh * t
    return np.stack([c0[0] * (1 - t) + c1[0] * t, C * np.cos(H), C * np.sin(H)], -1)


def grid(w, h):
    ax = w / h
    x, y = np.meshgrid(np.linspace(0, ax, w), np.linspace(0, 1, h))
    return x, y, ax


def rotated(X, Y, ax, deg):
    a = np.deg2rad(deg)
    cx, cy = ax / 2, 0.5
    U = (X - cx) * np.cos(a) + (Y - cy) * np.sin(a)
    V = -(X - cx) * np.sin(a) + (Y - cy) * np.cos(a)
    return U, V


def signed_dist(V, edge, h):
    # First-order distance to the curve, so ridges keep an even width on slopes.
    du = np.gradient(edge, axis=1) / (1.0 / h)
    dv = np.gradient(edge, axis=0) / (1.0 / h)
    return (V - edge) / np.sqrt(1 + np.minimum(du * du + dv * dv, 16))


def finish(lab, rng, grain=1.3):
    rgb = lab_to_srgb(lab)
    # Grain breaks up 8-bit banding in the long gradients.
    n = rng.normal(0, grain / 255, rgb.shape[:2])[..., None]
    n2 = rng.normal(0, 0.5 * grain / 255, rgb.shape)
    return Image.fromarray((np.clip(rgb + n + n2, 0, 1) * 255 + 0.5).astype(np.uint8))


# ---- styles ----------------------------------------------------------------
def dunes(w, h, seed, pal):
    """Colored layered hills with lit ridges (Spring)."""
    rng = np.random.default_rng(seed)
    X, Y, ax = grid(w, h)
    img = blobs(X, Y, pal["sky"], rng, 0.6)
    U, V = rotated(X, Y, ax, rng.uniform(-24, 24))
    n = len(pal["layers"])
    bases = np.linspace(-0.28, 0.46, n) + rng.uniform(-0.04, 0.04, n)
    for k, (a_hex, b_hex) in enumerate(pal["layers"]):
        edge = bases[k] + wave(U, rng, rng.uniform(0.11, 0.2), 0.25, 1.1)
        d = signed_dist(V, edge, h)
        # Cast shadow on what's behind.
        img[..., 0] -= 0.075 * np.exp(np.minimum(d, 0) / 0.075) * (d < 0)
        t = smoothstep(-0.9, 0.9, U + wave(V, rng, 0.25, 0.3, 1.0))
        col = lch_mix(a_hex, b_hex, t)
        pos = np.maximum(d, 0)
        # Ridge catches light, then the slope falls into shade.
        col[..., 0] += 0.085 * np.exp(-pos / 0.05) - 0.085 * smoothstep(0.0, 0.5, pos)
        col[..., 1:] *= (1 + 0.14 * smoothstep(0.0, 0.35, pos))[..., None]
        m = smoothstep(-1.2 / h, 1.2 / h, d)[..., None]
        img = img * (1 - m) + col * m
    img[..., 1:] *= pal.get("sat", 1.22)
    return finish(img, rng)


def midnight(w, h, seed, cfg):
    """Monochrome layers rising out of black, lit along the crest."""
    rng = np.random.default_rng(seed)
    X, Y, ax = grid(w, h)
    U, V = rotated(X, Y, ax, cfg.get("angle", rng.uniform(-14, 14)))
    L = np.zeros_like(X) + cfg.get("floor", 0.09)
    # Faint glow from behind.
    gx, gy = rng.uniform(0.2, ax - 0.2), rng.uniform(0.1, 0.5)
    L += cfg.get("glow", 0.08) * np.exp(-((X - gx) ** 2 + (Y - gy) ** 2) / 0.28)
    n = cfg["layers"]
    bases = np.linspace(cfg.get("top", -0.12), cfg.get("bottom", 0.42), n)
    for k in range(n):
        edge = bases[k] + wave(U, rng, rng.uniform(0.07, cfg.get("amp", 0.17)), 0.3, 1.5)
        d = signed_dist(V, edge, h)
        # Crest brightness wanders along its length, so some parts die off.
        light = 0.16 + 0.84 * smoothstep(-0.6, 0.6, wave(U, rng, 1.1, 0.25, 1.0, n=3)) ** 1.3
        depth = 0.55 + 0.45 * k / max(n - 1, 1)
        pos = np.maximum(d, 0)
        sheen = (0.42 * np.exp(-pos / 0.012) + 0.34 * np.exp(-pos / 0.09)
                 + 0.26 * np.exp(-pos / 0.34)) * light * depth * cfg.get("gain", 1.0)
        # Fine striations give the surface a brushed, silky look.
        stri = 1 + 0.018 * np.sin(pos * rng.uniform(160, 240) + wave(U, rng, 2.0, 0.5, 1.5, n=2))
        col = 0.085 + sheen * stri
        L -= 0.05 * np.exp(np.minimum(d, 0) / 0.05) * (d < 0)
        m = smoothstep(-1.2 / h, 1.2 / h, d)
        L = L * (1 - m) + col * m
    lab = np.stack([np.clip(L, 0.05, 0.99), L * cfg.get("tint", (0, 0))[0], L * cfg.get("tint", (0, 0))[1]], -1)
    return finish(lab, rng, 1.6)


def glass(w, h, seed, pal):
    """Pale field, saturated liquid layers, each with a translucent glass crest."""
    rng = np.random.default_rng(seed)
    X, Y, ax = grid(w, h)
    img = blobs(X, Y, pal["bg"], rng, 0.6)
    U, V = rotated(X, Y, ax, rng.uniform(-12, 12))
    n = len(pal["liquid"])
    bases = np.linspace(-0.04, 0.3, n) + rng.uniform(-0.03, 0.03, n)
    phase = rng.uniform(0, 6.283)
    for k, (a_hex, b_hex) in enumerate(pal["liquid"]):
        edge = bases[k] + wave(U, rng, rng.uniform(0.09, 0.15), 0.3, 1.25)
        d = signed_dist(V, edge, h)
        pos = np.maximum(d, 0)

        # Glass crest: a band above the liquid that swells and pinches.
        tw = 0.5 + 0.5 * np.cos(2 * np.pi * rng.uniform(0.4, 0.8) * U + rng.uniform(0, 6.283))
        band = 0.012 + rng.uniform(0.05, 0.1) * tw ** 1.4
        s = np.clip(-d / band, 0, 1)
        inside = smoothstep(0, 1.5 / h, -d) * smoothstep(1.0, 0.97, -d / band)
        hue = 3.4 * s + 2.6 * U + phase + k
        tint = img.copy()
        tint[..., 0] += 0.035 + 0.05 * s ** 4
        tint[..., 1] += 0.05 * np.cos(hue)
        tint[..., 2] += 0.05 * np.sin(hue)
        img = img * (1 - 0.8 * inside[..., None]) + tint * (0.8 * inside[..., None])
        # Thin upper rim of the band.
        img[..., 0] += 0.09 * np.exp(-(((-d - band) / 0.0016) ** 2))

        # Liquid body.
        t = smoothstep(-0.9, 0.9, U + wave(V, rng, 0.2, 0.3, 0.9))
        col = lch_mix(a_hex, b_hex, t)
        col[..., 0] -= 0.1 * smoothstep(0, 0.42, pos)
        col[..., 1:] *= (1 + 0.2 * smoothstep(0, 0.3, pos))[..., None]
        # Gloss hugging the crest, comes and goes along its length.
        gloss = smoothstep(-0.3, 0.7, wave(U, rng, 1.2, 0.5, 1.6, n=3))
        col[..., 0] += 0.13 * np.exp(-pos / 0.022) * gloss + 0.05 * np.exp(-pos / 0.09)
        m = smoothstep(-1.2 / h, 1.2 / h, d)[..., None]
        img = img * (1 - m) + col * m
        # Sharp bright edge line, the part that reads as glass.
        img[..., 0] += (0.1 + 0.16 * gloss) * np.exp(-((d / 0.0017) ** 2))

        # Droplets along the crest.
        for _ in range(int(pal.get("drops", 26))):
            ix = int(rng.integers(0, 1600) * w / 1600)
            ux, vy = U[h // 2, ix], edge[h // 2, ix] - abs(rng.normal(0, 0.016))
            rad = rng.uniform(0.0008, 0.0026)
            img[..., 0] += 0.28 * np.exp(-((U - ux) ** 2 + (V - vy) ** 2) / (rad * rad))

    # Soft shoulder so highlights roll off instead of clipping flat white.
    L = img[..., 0]
    over = L > 0.88
    L[over] = 0.88 + 0.1 * np.tanh((L[over] - 0.88) / 0.1)
    return finish(img, rng, 1.2)


# ---- hand-picked sets
SPRING = [
    dict(sky=["#C9F2C7", "#FFE9A8", "#8FE3C8"], layers=[("#7ADFA5", "#F5D76E"), ("#2FB9A0", "#F08FA0"), ("#177E89", "#6A5ACD"), ("#0F5C63", "#D1477A")]),
    dict(sky=["#D6F7E8", "#BDE7FF", "#A8F0D0"], layers=[("#8EE6C2", "#BFD7FF"), ("#40C4B0", "#7FA7F5"), ("#2388A8", "#8D74E8")]),
    dict(sky=["#FFE3B8", "#FFC2A1", "#FBE8A6"], layers=[("#FFB48A", "#F9D66F"), ("#4FD1B5", "#FF8C8C"), ("#1B9AAA", "#E75A7C"), ("#23395B", "#0F7C8A")]),
    dict(sky=["#E5FBD9", "#C3F3D5", "#FFF3C4"], layers=[("#B6EFA0", "#FFD98A"), ("#6DD6A8", "#F6A5C0"), ("#2BA8A0", "#B57EDC")]),
    dict(sky=["#A5EEDB", "#7CD5F2", "#D5F5C8"], layers=[("#54D2B4", "#97C4FA"), ("#2AA3B5", "#5F8BF0"), ("#E86FA0", "#F7B267"), ("#144E75", "#3C2F8F")]),
    dict(sky=["#F7F3C9", "#CDEFC0", "#FFD6C2"], layers=[("#D8EE9A", "#FFC29A"), ("#7FD8A0", "#FF9CB0"), ("#E0638C", "#F49B62")]),
    dict(sky=["#BFF3E6", "#E8F9D2", "#BCD9FF"], layers=[("#8FE8CE", "#B3C8FF"), ("#3CC0A8", "#8C9BF0"), ("#106F7A", "#3D5AC8"), ("#0C3F52", "#1E7F6F")]),
    dict(sky=["#FFD8DE", "#D5F5E3", "#FFEFC2"], layers=[("#FFC0C8", "#BBF0CF"), ("#F58BA8", "#67D6B2"), ("#7E5BD0", "#23A8A0")]),
]
MIDNIGHT = [
    dict(layers=5, angle=-6),
    dict(layers=7, amp=0.12, angle=5),
    dict(layers=3, amp=0.24, angle=-20, top=-0.1, bottom=0.3, gain=1.5),
    dict(layers=6, angle=12, tint=(-0.012, -0.03)),
    dict(layers=4, top=-0.28, bottom=0.2, angle=-3, glow=0.14),
    dict(layers=7, amp=0.1, top=-0.2, bottom=0.42, angle=2, gain=1.1),
    dict(layers=2, amp=0.28, top=-0.3, bottom=0.2, angle=28, floor=0.1, gain=1.7),
    dict(layers=5, angle=-14, tint=(0.015, -0.02), glow=0.12),
]
GLASS = [
    dict(bg=["#E6EEFA", "#FBDCE8", "#D5E6FA"], liquid=[("#9CC2F2", "#F4A9CB"), ("#5F93E8", "#C783DE")]),
    dict(bg=["#D6F0FF", "#EEF8FF", "#BDE1FF"], liquid=[("#8FD0F7", "#7BA6F5"), ("#3F8EE6", "#3E63D8")]),
    dict(bg=["#CBDDF9", "#E2D4F7", "#BFE0F6"], liquid=[("#8DB1F0", "#B79AEC"), ("#4C74DE", "#7B5BD8"), ("#2A44AE", "#4D36B0")]),
    dict(bg=["#2C54B8", "#3A3CA8", "#1F6CC8"], liquid=[("#6A52E0", "#C85BD8"), ("#2A2F98", "#5A2AA8")]),
    dict(bg=["#FBD2E0", "#FDE6EE", "#E2D3F7"], liquid=[("#83C4EC", "#B39BEF"), ("#3B80CC", "#5E62D0")]),
    dict(bg=["#F7D0E6", "#E9D3F8", "#FBDDE8"], liquid=[("#F29CCB", "#BE8BEA"), ("#D466B4", "#8D5FD8")]),
    dict(bg=["#BDD2F5", "#D5C8F3", "#AECCF3"], liquid=[("#A08CE8", "#7FA3EE"), ("#6C62D8", "#4D74DA"), ("#3E3BA6", "#2B4DA8")]),
    dict(bg=["#1C3760", "#264F80", "#16284A"], liquid=[("#2E74AA", "#3AA0C8"), ("#143B6C", "#0E2A52")]),
]

# ---- generated palettes -----------------------------------------------------
def walk(rng, hues, jitter=10):
    return hues[rng.integers(0, len(hues))] + rng.uniform(-jitter, jitter)


def crosses(h0, h1, band):
    """True if the short arc from h0 to h1 touches the hue band."""
    d = (h1 - h0 + 180) % 360 - 180
    return any(band[0] <= (h0 + d * t / 16) % 360 <= band[1] for t in range(17))


def layered(rng, n, L_top, L_bottom, C, near, accents, muddy=(75, 125)):
    """Back-to-front layers: lighter at the back, each blending a base hue into an accent.
    Darker layers never pass through the muddy band, where those hues read as olive and brown."""
    layers = []
    for L in np.linspace(L_top, L_bottom, n):
        c = rng.uniform(*C)
        for _ in range(200):
            h0, h1 = walk(rng, near), walk(rng, accents)
            if L > 0.78 or not crosses(h0, h1, muddy):
                break
        layers.append((lch(L, c, h0), lch(max(L - 0.03, 0.2), c, h1)))
    return layers


def sky(rng, L, C, hues):
    # One hue family, so the soft blobs don't average out to grey.
    H = walk(rng, hues)
    return [lch(L + rng.uniform(-0.02, 0.02), C, H + rng.uniform(-18, 18)) for _ in range(3)]


def spring_palette(rng):
    return dict(sky=sky(rng, 0.93, 0.07, [100, 125, 160, 190, 60]),
                layers=layered(rng, rng.integers(3, 5), 0.88, 0.5, (0.11, 0.16), [125, 160, 180, 200], [200, 230, 260, 300, 150]))


def sunset_palette(rng):
    return dict(sky=sky(rng, 0.9, 0.08, [85, 70, 55, 40]),
                layers=layered(rng, rng.integers(3, 6), 0.86, 0.45, (0.13, 0.17), [65, 55, 40, 25], [45, 30, 15, 0, 345]))


def radiant_palette(rng):
    return dict(sky=sky(rng, 0.84, 0.09, [300, 330, 10, 60, 230]),
                layers=layered(rng, rng.integers(3, 6), 0.8, 0.36, (0.13, 0.17), [290, 320, 350, 20, 250], [50, 20, 340, 300, 230, 265], muddy=(75, 170)))


def energy_palette(rng):
    return dict(sat=1.1, sky=sky(rng, 0.72, 0.13, [350, 20, 300, 250, 50]),
                layers=layered(rng, rng.integers(3, 6), 0.78, 0.38, (0.15, 0.19), [350, 15, 50, 300, 265], [60, 200, 330, 280, 25], muddy=(75, 170)))


def iridescent_palette(rng):
    H = rng.uniform(0, 360)
    return dict(sat=1.1, sky=[lch(0.96, 0.025, H + d) for d in (0, 70, 140)],
                layers=[(lch(L, rng.uniform(0.04, 0.085), H + rng.uniform(-90, 90)),
                         lch(L - 0.02, rng.uniform(0.05, 0.1), H + rng.uniform(90, 270)))
                        for L in np.linspace(0.94, 0.8, rng.integers(3, 5))])


def midnight_config(rng):
    return dict(layers=int(rng.integers(2, 9)), amp=rng.uniform(0.1, 0.26), angle=rng.uniform(-26, 26),
                top=rng.uniform(-0.3, -0.05), bottom=rng.uniform(0.2, 0.44), gain=rng.uniform(1.0, 1.7),
                glow=rng.uniform(0.06, 0.14),
                tint=[(0, 0), (0, 0), (-0.012, -0.03), (0.015, -0.02)][rng.integers(0, 4)])


def glass_palette(rng):
    H = walk(rng, [190, 215, 250, 280, 305, 340], 8)
    if rng.random() < 0.2:
        return dict(bg=[lch(0.38 + rng.uniform(-0.04, 0.04), 0.12, H + d) for d in (0, 25, -25)],
                    liquid=[(lch(0.52, 0.16, H + 20), lch(0.5, 0.17, H + 60)), (lch(0.3, 0.12, H), lch(0.28, 0.13, H + 30))])
    n = rng.integers(2, 4)
    return dict(bg=[lch(0.93, 0.03, H + d) for d in (0, 40, -30)],
                liquid=[(lch(L, c, H + rng.uniform(-15, 15)), lch(L - 0.02, c, H + rng.uniform(25, 60)))
                        for L, c in zip(np.linspace(0.78, 0.4, n), np.linspace(0.09, 0.16, n))])


# ---- catalog ----------------------------------------------------------------
# name, style, hand-picked configs, generator for the rest, total, seed, rejected seed offsets
CATEGORIES = [
    ("Spring", dunes, SPRING, spring_palette, 16, 1100, ()),
    ("Sunset", dunes, [], sunset_palette, 16, 5100, ()),
    ("Radiant", dunes, [], radiant_palette, 16, 6100, ()),
    ("Energy", dunes, [], energy_palette, 16, 7100, ()),
    ("Iridescent", dunes, [], iridescent_palette, 16, 8100, ()),
    ("Midnight", midnight, MIDNIGHT, midnight_config, 16, 2200, (13,)),
    ("Glassmorphism", glass, GLASS, glass_palette, 12, 3300, ()),
]


def render(job):
    style, seed, make_cfg, cfg, size, path, thumb_path = job
    if cfg is None:
        cfg = make_cfg(np.random.default_rng(seed + 50000))
    im = style(size[0], size[1], seed, cfg)
    if path:
        im.save(path, quality=JPEG_QUALITY, optimize=True)
        im.resize(THUMB_SIZE, Image.LANCZOS).save(thumb_path, quality=82, optimize=True)
        return None
    return im


def jobs_for(cat, size, root):
    name, style, fixed, make_cfg, total, seed, rejected = cat
    offsets = [o for o in range(total + len(rejected)) if o not in rejected]
    jobs = []
    for i, offset in enumerate(offsets):
        path = thumb = None
        if root:
            path = root / name / f"{name.lower()}-{i + 1:02d}.jpg"
            thumb = root / "thumbs" / path.name
        jobs.append((style, seed + offset, make_cfg, fixed[i] if i < len(fixed) else None, size, path, thumb))
    return jobs


def contact_sheet(images, path):
    tw, th = 240, 150
    cols = 8
    rows = math.ceil(len(images) / cols)
    sheet = Image.new("RGB", (cols * (tw + 8) + 8, rows * (th + 8) + 8), (21, 22, 27))
    draw = ImageDraw.Draw(sheet)
    for i, im in enumerate(images):
        x, y = 8 + (i % cols) * (tw + 8), 8 + (i // cols) * (th + 8)
        sheet.paste(im.resize((tw, th), Image.LANCZOS), (x, y))
        draw.text((x + 5, y + 4), str(i + 1), fill=(255, 255, 255), stroke_width=1, stroke_fill=(0, 0, 0))
    sheet.save(path)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--preview", type=Path, help="write small contact sheets here instead of the bundle")
    parser.add_argument("--only", nargs="*", help="category names to process")
    args = parser.parse_args()
    cats = [c for c in CATEGORIES if not args.only or c[0] in args.only]
    with multiprocessing.Pool() as pool:
        if args.preview:
            args.preview.mkdir(parents=True, exist_ok=True)
            for cat in cats:
                contact_sheet(pool.map(render, jobs_for(cat, (960, 600), None)), args.preview / f"{cat[0].lower()}.png")
            return
        (ROOT / "thumbs").mkdir(parents=True, exist_ok=True)
        for cat in cats:
            shutil.rmtree(ROOT / cat[0], ignore_errors=True)
            (ROOT / cat[0]).mkdir()
            for stale in (ROOT / "thumbs").glob(f"{cat[0].lower()}-*.jpg"):
                stale.unlink()
            pool.map(render, jobs_for(cat, FULL_SIZE, ROOT))


if __name__ == "__main__":
    main()
