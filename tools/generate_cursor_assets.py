#!/usr/bin/env python3
"""Generates the bundled cursor themes (SVG) and click sounds (WAV) in Resources/Cursors.bundle.

Everything is drawn or synthesized here from code, so the output is reproducible:

    python3 tools/generate_cursor_assets.py

File naming: sets/<theme>/<kind>-<variant>__<hotspotX>-<hotspotY>.svg, with the hotspot in percent of the
100x100 view box. Sounds: sounds/<set>/{down,up,click}.wav (16-bit mono, 44.1 kHz).
The "macOS" theme is not generated: the app draws the system cursors (NSCursor) at runtime.
"""

import math
import random
import shutil
import struct
import wave
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent / "NativeScreen" / "NativeScreen" / "Resources" / "Cursors.bundle"

# ---------------------------------------------------------------------------------------------------------------------
# Cursors
# ---------------------------------------------------------------------------------------------------------------------

# Arrow outline in a 100x100 box, tip at (12, 6). Drawn by hand on graph paper: a slim arrow head with a short tail.
ARROW = [(12, 6), (12, 76), (29, 61), (40, 86), (51, 81), (40, 57), (63, 57)]
ARROW_HOTSPOT = (12, 6)

# Soft drop shadow. CoreSVG (NSImage) does not support feMerge, so the shadow is blended under the shape with feBlend.
SHADOW = """<filter id="s" x="-20%" y="-20%" width="140%" height="140%">
<feGaussianBlur in="SourceAlpha" stdDeviation="{blur}"/><feOffset dx="0" dy="{dy}" result="blurred"/>
<feColorMatrix in="blurred" type="matrix" values="0 0 0 0 0  0 0 0 0 0  0 0 0 0 0  0 0 0 {opacity} 0" result="shadow"/>
<feBlend in="SourceGraphic" in2="shadow" mode="normal"/></filter>"""


def svg(body, shadow=True, blur=2.2, dy=1.6, opacity=0.35):
    defs = f"<defs>{SHADOW.format(blur=blur, dy=dy, opacity=opacity)}</defs>" if shadow else ""
    group = f'<g filter="url(#s)">{body}</g>' if shadow else body
    return f'<svg xmlns="http://www.w3.org/2000/svg" width="100" height="100" viewBox="0 0 100 100">{defs}{group}</svg>\n'


def points(pts):
    return " ".join(f"{x:g},{y:g}" for x, y in pts)


def rounded_path(pts, radius):
    """Closed polygon with every corner rounded by a quadratic curve."""
    n = len(pts)
    out = []
    for i in range(n):
        prev, cur, nxt = pts[i - 1], pts[i], pts[(i + 1) % n]

        def toward(a, b, d):
            length = math.hypot(b[0] - a[0], b[1] - a[1]) or 1
            d = min(d, length / 2.2)
            return (a[0] + (b[0] - a[0]) * d / length, a[1] + (b[1] - a[1]) * d / length)

        r = radius * (0.35 if i == 0 else 1.0)  # keep the tip fairly sharp so the hotspot reads clearly
        start = toward(cur, prev, r)
        end = toward(cur, nxt, r)
        out.append(f"{'M' if i == 0 else 'L'}{start[0]:.2f},{start[1]:.2f} Q{cur[0]:g},{cur[1]:g} {end[0]:.2f},{end[1]:.2f}")
    return " ".join(out) + " Z"


def arrow(fill, stroke, stroke_width=5.0):
    return svg(
        f'<polygon points="{points(ARROW)}" fill="{fill}" stroke="{stroke}" '
        f'stroke-width="{stroke_width}" stroke-linejoin="miter" stroke-miterlimit="10" paint-order="stroke"/>'
    )


def rounded_arrow(fill, stroke, stroke_width=6.0):
    return svg(
        f'<path d="{rounded_path(ARROW, 6)}" fill="{fill}" stroke="{stroke}" '
        f'stroke-width="{stroke_width}" stroke-linejoin="round" paint-order="stroke"/>',
        blur=2.6, dy=2.0, opacity=0.3,
    )


def ibeam(fill, stroke):
    bar = "M44,22 h12 v4 h-4 v48 h4 v4 h-12 v-4 h4 v-48 h-4 Z"
    return svg(f'<path d="{bar}" fill="{fill}" stroke="{stroke}" stroke-width="3" stroke-linejoin="round" paint-order="stroke"/>')


def crosshair(fill, stroke):
    plus = "M47.5,26 h5 v21.5 h21.5 v5 h-21.5 v21.5 h-5 v-21.5 h-21.5 v-5 h21.5 Z"
    return svg(f'<path d="{plus}" fill="{fill}" stroke="{stroke}" stroke-width="3" stroke-linejoin="round" paint-order="stroke"/>')


def hand(fill, stroke, closed=False):
    """A simple mitten-style hand: palm plus one raised finger (pointing) or a fist (closed)."""
    if closed:
        shape = rounded_path([(30, 40), (70, 40), (74, 70), (62, 84), (38, 84), (26, 70)], 9)
        hotspot = (50, 50)
    else:
        shape = rounded_path([(40, 10), (50, 10), (50, 42), (72, 46), (74, 72), (62, 88), (38, 88), (26, 66), (30, 50), (40, 50)], 5)
        hotspot = (45, 10)
    return svg(f'<path d="{shape}" fill="{fill}" stroke="{stroke}" stroke-width="4.5" stroke-linejoin="round" paint-order="stroke"/>'), hotspot


def touch(fill, ring):
    return svg(
        f'<circle cx="50" cy="50" r="22" fill="{fill}" stroke="{ring}" stroke-width="3"/>',
        blur=3, dy=1.5, opacity=0.25,
    )


def write_theme(theme, sprites):
    folder = ROOT / "sets" / theme
    folder.mkdir(parents=True, exist_ok=True)
    for kind, variant, hotspot, content in sprites:
        (folder / f"{kind}-{variant}__{hotspot[0]}-{hotspot[1]}.svg").write_text(content)


def generate_cursors():
    dark, light, purple, blue = "#111114", "#ffffff", "#6f57fa", "#2f7cf6"

    def common(fill, stroke, variant):
        pointing, pointing_hotspot = hand(fill, stroke)
        closed, closed_hotspot = hand(fill, stroke, closed=True)
        return [
            ("ibeamstroke", variant, (50, 50), ibeam(fill, stroke)),
            ("cross", variant, (50, 50), crosshair(fill, stroke)),
            ("pointinghand", variant, pointing_hotspot, pointing),
            ("closedhand", variant, closed_hotspot, closed),
        ]

    # Sharp arrow: black and white.
    write_theme("arrow", [
        ("pointer", 1, ARROW_HOTSPOT, arrow(dark, light)),
        ("pointer", 2, ARROW_HOTSPOT, arrow(light, dark, 4.0)),
        *common(dark, light, 1),
    ])

    # Rounded arrow in four colors, each with a white outline.
    write_theme("rounded", [
        ("pointer", 1, ARROW_HOTSPOT, rounded_arrow(dark, light)),
        ("pointer", 2, ARROW_HOTSPOT, rounded_arrow(light, "#2a2a30", 4.5)),
        ("pointer", 3, ARROW_HOTSPOT, rounded_arrow(purple, light)),
        ("pointer", 4, ARROW_HOTSPOT, rounded_arrow(blue, light)),
        *common(dark, light, 1),
    ])

    # Touch: a translucent dot that stands in for a finger.
    write_theme("touch", [
        ("pointer", 1, (50, 50), touch("rgba(40,40,46,0.55)", "rgba(255,255,255,0.9)")),
        ("pointer", 2, (50, 50), touch("rgba(255,255,255,0.65)", "rgba(20,20,24,0.55)")),
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
