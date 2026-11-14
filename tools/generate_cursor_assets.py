#!/usr/bin/env python3
"""Generates the bundled cursor themes (SVG) and click sounds (WAV) in Resources/Cursors.bundle.

Everything is drawn or synthesized here from code, so the output is reproducible:

    python3 tools/generate_cursor_assets.py

File naming: sets/<theme>/<kind>-<variant>__<hotspotX>-<hotspotY>.svg, with the hotspot in percent of the
100x100 view box. Sounds: sounds/<set>/{down,up,click}.wav (16-bit mono, 44.1 kHz).

The same files are drawn by CoreSVG on macOS and Direct2D on Windows, so sprites stick to what both support: one shared
drop shadow (Direct2D ignores SVG filters and adds this exact shadow itself), and outlines drawn as a separate layer
under the fill rather than with paint-order.
"""

import math
import random
import shutil
import struct
import wave
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent / "macos" / "NativeScreen" / "Resources" / "Cursors.bundle"

# ---------------------------------------------------------------------------------------------------------------------
# Cursors
# ---------------------------------------------------------------------------------------------------------------------

BLACK, DARK, LIGHT, SOFT_DARK = "#000000", "#111114", "#ffffff", "#2a2a30"
PURPLE, BLUE, CORAL, GREEN = "#6f57fa", "#2f7cf6", "#f4574b", "#1fae6b"
OUTLINE = 8.0
SHADOW_BLUR, SHADOW_DY, SHADOW_OPACITY = 3.0, 2.4, 0.5  # windows/.../OverlayRasterizer.cs repeats these values

SHADOW = f"""<filter id="s" x="-30%" y="-30%" width="160%" height="160%">
<feGaussianBlur in="SourceAlpha" stdDeviation="{SHADOW_BLUR}"/><feOffset dx="0" dy="{SHADOW_DY}" result="blurred"/>
<feColorMatrix in="blurred" type="matrix" values="0 0 0 0 0  0 0 0 0 0  0 0 0 0 0  0 0 0 {SHADOW_OPACITY} 0" result="shadow"/>
<feBlend in="SourceGraphic" in2="shadow" mode="normal"/></filter>"""


def svg(body, defs=""):
    return (
        '<svg xmlns="http://www.w3.org/2000/svg" width="100" height="100" viewBox="0 0 100 100">'
        f'<defs>{SHADOW}{defs}</defs><g filter="url(#s)">{body}</g></svg>\n'
    )


def rounded_corners(pts, radii):
    """Closed polygon with each corner rounded by its own radius, using quadratic curves."""
    n = len(pts)
    out = []
    for i in range(n):
        prev, cur, nxt = pts[i - 1], pts[i], pts[(i + 1) % n]

        def toward(a, b, d):
            length = math.hypot(b[0] - a[0], b[1] - a[1]) or 1
            d = min(d, length / 2.1)
            return (a[0] + (b[0] - a[0]) * d / length, a[1] + (b[1] - a[1]) * d / length)

        start = toward(cur, prev, radii[i])
        end = toward(cur, nxt, radii[i])
        out.append(f"{'M' if i == 0 else 'L'}{start[0]:.2f},{start[1]:.2f} Q{cur[0]:.2f},{cur[1]:.2f} {end[0]:.2f},{end[1]:.2f}")
    return " ".join(out) + " Z"


def rounded_path(pts, radius, tip_factor=0.35):
    """Same radius everywhere, except the first point (the tip), which stays sharper."""
    return rounded_corners(pts, [radius * tip_factor, *[radius] * (len(pts) - 1)])


def solid(d, fill, stroke, width=OUTLINE, details=""):
    """A filled shape with an outline around it, drawn as two layers."""
    return (
        f'<path d="{d}" fill="{stroke}" stroke="{stroke}" stroke-width="{width}" stroke-linejoin="round"/>'
        f'<path d="{d}" fill="{fill}"/>{details}'
    )


def hollow(d, line, halo, details=""):
    """Only the contour: a line with a contrasting halo so it reads on any background."""
    return (
        f'<path d="{d}" fill="none" stroke="{halo}" stroke-width="9.5" stroke-linejoin="round"/>'
        f'<path d="{d}" fill="none" stroke="{line}" stroke-width="4.8" stroke-linejoin="round"/>{details}'
    )


# Arrow: a symmetric head around an axis 25 degrees off vertical, with a long slim tail set into a swept-back base.
def arrow_points(tip=(16, 8), head=58.0, tail=29.0, tail_width=9.5, sweep=9.0, half_angle=25.0):
    a = math.radians(half_angle)
    axis, normal = (math.sin(a), math.cos(a)), (math.cos(a), -math.sin(a))

    def along(distance, offset):
        return (tip[0] + axis[0] * distance + normal[0] * offset, tip[1] + axis[1] * distance + normal[1] * offset)

    base = head * math.cos(a) - sweep
    return [
        tip,
        (tip[0], tip[1] + head),
        along(base, -tail_width / 2),
        along(base + tail, -tail_width / 2),
        along(base + tail, tail_width / 2),
        along(base, tail_width / 2),
        (tip[0] + head * math.sin(2 * a), tip[1] + head * math.cos(2 * a)),
    ]


ARROW_HOTSPOT = (16, 8)


def arrow_corners(tip, wing, notch, tail_end):
    """Corner radii in arrow_points order: tip, left wing, notch, tail end, tail end, notch, right wing."""
    return [tip, wing, notch, tail_end, tail_end, notch, wing]


CLASSIC_ARROW = rounded_corners(arrow_points(), arrow_corners(1.2, 8.5, 1.0, 4.6))
ROUNDED_ARROW = rounded_corners(arrow_points(tail_width=12.0), arrow_corners(3.0, 11.0, 2.5, 5.8))
OUTLINE_ARROW = rounded_corners(arrow_points(tail_width=14.0), arrow_corners(2.5, 8.5, 2.0, 6.5))

# Dart: a tailless paper-plane pointer.
DART_HOTSPOT = (14, 6)
DART = rounded_path([(14, 6), (31, 86), (45, 58), (77, 45)], 7.0)

# Hand, one contour: index finger up, three knuckles, thumb on the left. Above y = 30 (outline included) there must be
# nothing but the index finger: the app folds that part on a click (CursorSpriteProvider.handFingerSeam01).
HAND_HOTSPOT = (43, 8)
HAND = (
    "M37,14 a6,6 0 0 1 12,0 V42 a5.5,5.5 0 0 1 11,0 V45 a5.5,5.5 0 0 1 11,1 V48 a5,5 0 0 1 10,1 V66 "
    "C81,80 72,90 59,90 H51 C43,90 38,86 33,79 L19,60 a6,6 0 0 1 9,-8 L37,62 Z"
)
HAND_LINES = "M49,58 V70 M60,58 V70 M71,59 V70"
FIST_HOTSPOT = (50, 50)
FIST = (
    "M27,46 a5.5,5.5 0 0 1 11,-1 a5.5,5.5 0 0 1 11,-2 a5.5,5.5 0 0 1 11,1 a5.5,5.5 0 0 1 11,2 a5,5 0 0 1 8,4 V64 "
    "C79,76 71,84 59,84 H49 C39,84 33,79 29,71 L21,57 a5.5,5.5 0 0 1 8,-7 Z"
)
FIST_LINES = "M38,46 V58 M49,44 V58 M60,45 V58"

IBEAM = (
    "M38,18 C44,18 48,19 50,22 C52,19 56,18 62,18 V24 C56,24 53,25 53,29 V71 C53,75 56,76 62,76 V82 "
    "C56,82 52,81 50,78 C48,81 44,82 38,82 V76 C44,76 47,75 47,71 V29 C47,25 44,24 38,24 Z"
)
CROSS = "M47,24 H53 V47 H76 V53 H53 V76 H47 V53 H24 V47 H47 Z"


def lines(d, color):
    return f'<path d="{d}" fill="none" stroke="{color}" stroke-width="2.6" stroke-linecap="round"/>'


def companions(fill, stroke, variant, width=OUTLINE):
    """The non-arrow sprites of a theme, matching one pointer variant."""
    return [
        ("pointinghand", variant, HAND_HOTSPOT, svg(solid(HAND, fill, stroke, width, lines(HAND_LINES, stroke)))),
        ("closedhand", variant, FIST_HOTSPOT, svg(solid(FIST, fill, stroke, width, lines(FIST_LINES, stroke)))),
        ("ibeamstroke", variant, (50, 50), svg(solid(IBEAM, fill, stroke, 4.0))),
        ("cross", variant, (50, 50), svg(solid(CROSS, fill, stroke, 4.0))),
    ]


def outline_companions(line, halo, variant):
    def draw(d, _fill, _stroke, details=""):
        return hollow(d, line, halo, details)

    return [
        ("pointinghand", variant, HAND_HOTSPOT, svg(draw(HAND, None, None, details=lines(HAND_LINES, line)))),
        ("closedhand", variant, FIST_HOTSPOT, svg(draw(FIST, None, None, details=lines(FIST_LINES, line)))),
        ("ibeamstroke", variant, (50, 50), svg(solid(IBEAM, line, halo, 4.0))),
        ("cross", variant, (50, 50), svg(solid(CROSS, line, halo, 4.0))),
    ]


def gradient(stops):
    first, second = stops
    return (
        f'<linearGradient id="g" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="{first}"/>'
        f'<stop offset="1" stop-color="{second}"/></linearGradient>'
    )


def gradient_sprite(d, stops, stroke=LIGHT, details=""):
    return svg(solid(d, "url(#g)", stroke, details=details), defs=gradient(stops))


def ring(color, halo):
    return svg(
        f'<circle cx="50" cy="50" r="23" fill="none" stroke="{halo}" stroke-width="9.5"/>'
        f'<circle cx="50" cy="50" r="23" fill="none" stroke="{color}" stroke-width="5"/>'
        f'<circle cx="50" cy="50" r="5" fill="{halo}"/><circle cx="50" cy="50" r="3.2" fill="{color}"/>'
    )


def touch(fill, fill_opacity, ring_color, ring_opacity):
    return svg(
        f'<circle cx="50" cy="50" r="22" fill="{fill}" fill-opacity="{fill_opacity}" '
        f'stroke="{ring_color}" stroke-opacity="{ring_opacity}" stroke-width="3"/>'
    )


# Pixel theme: bitmaps with X = outline, . = fill, on a 5-unit grid.
PIXEL_ARROW = [
    "X         ",
    "XX        ",
    "X.X       ",
    "X..X      ",
    "X...X     ",
    "X....X    ",
    "X.....X   ",
    "X......X  ",
    "X.......X ",
    "X....XXXXX",
    "X.X..X    ",
    "XX X..X   ",
    "X  X..X   ",
    "    X..X  ",
    "    XXXX  ",
]
PIXEL_HAND = [
    "   XX       ",
    "  X..X      ",
    "  X..X      ",
    "  X..X      ",
    "  X..XXX    ",
    "  X..X..XX  ",
    "XXX..X..X.X ",
    "X.X.......X ",
    "X.........X ",
    " X........X ",
    "  X.......X ",
    "  X......X  ",
    "   X.....X  ",
    "   XXXXXXX  ",
]
PIXEL_FIST = [
    "  XX XX XX  ",
    " X..X..X..X ",
    "XX........X ",
    "X.........X ",
    "X.........X ",
    " X........X ",
    "  X.......X ",
    "  XXXXXXXXX ",
]
PIXEL_IBEAM = ["XX XX", "X.X.X", "XX.XX", *[" X.X "] * 10, "XX.XX", "X.X.X", "XX XX"]
PIXEL_CROSS = [
    *["    XXX    "], *["    X.X    "] * 3, "XXXXX.XXXXX", "X.........X", "XXXXX.XXXXX", *["    X.X    "] * 3, "    XXX    ",
]


def pixels(bitmap, origin, fill, stroke, cell=5.0, overlap=0.25):
    """Rows of same-colored runs. The overlap keeps antialiasing from showing seams between cells."""
    out = []
    for y, row in enumerate(bitmap):
        x = 0
        while x < len(row):
            ch = row[x]
            end = x
            while end < len(row) and row[end] == ch:
                end += 1
            if ch in "X.":
                color = stroke if ch == "X" else fill
                out.append(
                    f'<rect x="{origin[0] + x * cell:g}" y="{origin[1] + y * cell:g}" '
                    f'width="{(end - x) * cell + overlap:g}" height="{cell + overlap:g}" fill="{color}"/>'
                )
            x = end
    return svg("".join(out))


def pixel_set(fill, stroke, variant):
    return [
        ("pointer", variant, (15, 7), pixels(PIXEL_ARROW, (14, 6), fill, stroke)),
        ("pointinghand", variant, (37, 11), pixels(PIXEL_HAND, (20, 10), fill, stroke)),
        ("closedhand", variant, (50, 50), pixels(PIXEL_FIST, (20, 30), fill, stroke)),
        ("ibeamstroke", variant, (50, 50), pixels(PIXEL_IBEAM, (38, 10), fill, stroke)),
        ("cross", variant, (50, 50), pixels(PIXEL_CROSS, (22, 22), fill, stroke)),
    ]


def write_theme(theme, sprites):
    folder = ROOT / "sets" / theme
    folder.mkdir(parents=True, exist_ok=True)
    for kind, variant, hotspot, content in sprites:
        (folder / f"{kind}-{variant}__{hotspot[0]}-{hotspot[1]}.svg").write_text(content)


def generate_cursors():
    write_theme("classic-dark", [
        ("pointer", 1, ARROW_HOTSPOT, svg(solid(CLASSIC_ARROW, BLACK, LIGHT, 9.5))),
        *companions(BLACK, LIGHT, 1),
    ])
    write_theme("classic-light", [
        ("pointer", 1, ARROW_HOTSPOT, svg(solid(CLASSIC_ARROW, LIGHT, BLACK, 3.4))),
        *companions(LIGHT, BLACK, 1, 5.0),
    ])

    # Every pointer variant gets hands and bars in its own colors.
    rounded = [(1, DARK, LIGHT), (2, LIGHT, SOFT_DARK), (3, PURPLE, LIGHT), (4, BLUE, LIGHT)]
    write_theme("rounded", [
        sprite
        for variant, fill, stroke in rounded
        for sprite in [("pointer", variant, ARROW_HOTSPOT, svg(solid(ROUNDED_ARROW, fill, stroke))), *companions(fill, stroke, variant)]
    ])

    darts = [(1, DARK, LIGHT), (2, LIGHT, SOFT_DARK)]
    write_theme("dart", [
        sprite
        for variant, fill, stroke in darts
        for sprite in [("pointer", variant, DART_HOTSPOT, svg(solid(DART, fill, stroke))), *companions(fill, stroke, variant)]
    ])

    def color_dart(variant, stops):
        return [
            ("pointer", variant, DART_HOTSPOT, gradient_sprite(DART, stops)),
            ("pointinghand", variant, HAND_HOTSPOT, gradient_sprite(HAND, stops, details=lines(HAND_LINES, LIGHT))),
            ("closedhand", variant, FIST_HOTSPOT, gradient_sprite(FIST, stops, details=lines(FIST_LINES, LIGHT))),
            ("ibeamstroke", variant, (50, 50), svg(solid(IBEAM, stops[1], LIGHT, 4.0))),
            ("cross", variant, (50, 50), svg(solid(CROSS, stops[1], LIGHT, 4.0))),
        ]

    write_theme("dart-color", [
        *color_dart(1, ("#8b7bff", "#4f5ff5")),
        *color_dart(2, ("#45a6ff", "#1f66e8")),
        *color_dart(3, ("#ff8a5c", "#ee3f6d")),
        *color_dart(4, ("#3fd08f", "#0f9a78")),
    ])

    write_theme("outline", [
        ("pointer", 1, ARROW_HOTSPOT, svg(hollow(OUTLINE_ARROW, DARK, LIGHT))),
        *outline_companions(DARK, LIGHT, 1),
        ("pointer", 2, ARROW_HOTSPOT, svg(hollow(OUTLINE_ARROW, LIGHT, DARK))),
        *outline_companions(LIGHT, DARK, 2),
    ])

    # Ring and Touch stand in for every cursor shape, so they have pointer sprites only.
    write_theme("ring", [
        ("pointer", 1, (50, 50), ring(PURPLE, LIGHT)),
        ("pointer", 2, (50, 50), ring(BLUE, LIGHT)),
        ("pointer", 3, (50, 50), ring(CORAL, LIGHT)),
        ("pointer", 4, (50, 50), ring(GREEN, LIGHT)),
    ])

    write_theme("pixel", [*pixel_set(DARK, LIGHT, 1), *pixel_set(LIGHT, DARK, 2)])

    write_theme("touch", [
        ("pointer", 1, (50, 50), touch("#28282e", 0.55, LIGHT, 0.9)),
        ("pointer", 2, (50, 50), touch(LIGHT, 0.65, "#141418", 0.55)),
    ])


# ---------------------------------------------------------------------------------------------------------------------
# Click sounds
# ---------------------------------------------------------------------------------------------------------------------

RATE = 44100


def click_sample(rng, length_ms, body_hz, body_decay_ms, noise_decay_ms, noise_gain, tone_gain, brightness):
    """One mechanical tick: a filtered noise transient plus a short damped resonance of the switch body."""
    n = int(RATE * length_ms / 1000)
    out = []
    lowpassed = 0.0
    for i in range(n):
        t = i / RATE
        white = rng.uniform(-1.0, 1.0)
        lowpassed += brightness * (white - lowpassed)  # one-pole low-pass: lower brightness = duller tick
        noise = lowpassed * math.exp(-t * 1000 / noise_decay_ms) * noise_gain
        tone = math.sin(2 * math.pi * body_hz * t) * math.exp(-t * 1000 / body_decay_ms) * tone_gain
        attack = min(1.0, i / (RATE * 0.0004))  # 0.4 ms attack avoids a hard digital edge
        out.append((noise + tone) * attack)
    return out


def write_wav(path, samples, peak=0.7):
    top = max(abs(s) for s in samples) or 1.0
    frames = b"".join(struct.pack("<h", int(max(-1.0, min(1.0, s / top * peak)) * 32767)) for s in samples)
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(frames)


def generate_sounds():
    presets = {
        # Muted, low tick, like a quiet trackpad-style mouse.
        "soft": dict(body_hz=1450, body_decay_ms=7, noise_decay_ms=3.5, noise_gain=0.8, tone_gain=0.5, brightness=0.35),
        # Brighter, snappier switch.
        "crisp": dict(body_hz=2600, body_decay_ms=5, noise_decay_ms=2.2, noise_gain=1.0, tone_gain=0.35, brightness=0.7),
    }
    for name, p in presets.items():
        folder = ROOT / "sounds" / name
        folder.mkdir(parents=True, exist_ok=True)
        rng = random.Random(name)  # fixed seed per preset so reruns produce identical files
        down = click_sample(rng, 60, **p)
        up_params = dict(p, body_hz=p["body_hz"] * 1.18, tone_gain=p["tone_gain"] * 0.7)
        up = click_sample(rng, 50, **up_params)
        up = [s * 0.6 for s in up]
        gap = [0.0] * int(RATE * 0.07)
        write_wav(folder / "down.wav", down)
        write_wav(folder / "up.wav", up, peak=0.45)
        write_wav(folder / "click.wav", down + gap + up)


if __name__ == "__main__":
    if ROOT.exists():
        shutil.rmtree(ROOT)
    generate_cursors()
    generate_sounds()
    print(f"Wrote {sum(1 for _ in ROOT.rglob('*.*'))} files to {ROOT}")
