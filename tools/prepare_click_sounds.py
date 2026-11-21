#!/usr/bin/env python3
"""Cuts recorded mouse clicks into the click sounds in Resources/Cursors.bundle/sounds/<set>/.

    python3 tools/prepare_click_sounds.py soft=<file> crisp=<file> classic=<file>

Each source is one recorded click: the press, then the release. Any format ffmpeg reads works, but WAV or FLAC is better
than MP3 or AAC (no encoder delay, no smeared transient). Sources and licenses are in sounds/NOTICE.txt.

For each set it writes down.wav (the press), up.wav (the release) and click.wav (both, with the gap as recorded), 16-bit
mono 44.1 kHz. The app plays click.wav. Steps: decode with ffmpeg, high-pass at 60 Hz to drop rumble, find the two
clicks from a 2 ms loudness envelope, cut each from 2 ms before it starts to where it falls 50 dB under the peak, fade
the edges, and scale every set to the same loudness so switching sets does not jump in volume.
"""

import math
import struct
import subprocess
import sys
import wave
from pathlib import Path

RATE = 44100
ROOT = Path(__file__).resolve().parent.parent / "macos" / "NativeScreen" / "Resources" / "Cursors.bundle" / "sounds"
WINDOW = int(RATE * 0.002)
TARGET_RMS = 0.12  # loudness of the clicks themselves (2 ms windows within 30 dB of the peak)
PEAK_LIMIT = 0.95


def decode(path):
    raw = subprocess.run(
        ["ffmpeg", "-loglevel", "error", "-i", str(path), "-ac", "1", "-ar", str(RATE), "-af", "highpass=f=60",
         "-f", "s16le", "-"],
        check=True, capture_output=True).stdout
    return [v / 32768 for v in struct.unpack(f"<{len(raw) // 2}h", raw)]


def envelope(samples):
    peak = max(abs(v) for v in samples) or 1.0
    out = []
    for i in range(0, len(samples), WINDOW):
        chunk = samples[i:i + WINDOW]
        rms = math.sqrt(sum(v * v for v in chunk) / len(chunk))
        out.append(20 * math.log10(rms / peak + 1e-9))
    return out


def find_clicks(samples):
    """Start and end sample of the press and of the release: runs above -30 dB, joined across gaps under 20 ms."""
    env = envelope(samples)
    runs = []
    for i, db in enumerate(env):
        if db > -30:
            if runs and i - runs[-1][1] <= 10:
                runs[-1][1] = i
            else:
                runs.append([i, i])
    if len(runs) < 2:
        raise SystemExit(f"expected a press and a release, found {len(runs)} click(s)")
    press, release = runs[0], runs[-1]

    def bounds(run, limit):
        start = max(0, run[0] - 1)
        end = run[1]
        while end + 1 < limit and env[end + 1] > -50:
            end += 1
        return start * WINDOW, min(len(samples), (end + 1) * WINDOW)

    press_bounds = bounds(press, release[0] - 1)
    return press_bounds, bounds(release, len(env))


def faded(samples, fade_in_ms=1.0, fade_out_ms=4.0):
    out = list(samples)
    fin, fout = int(RATE * fade_in_ms / 1000), int(RATE * fade_out_ms / 1000)
    for i in range(min(fin, len(out))):
        out[i] *= i / fin
    for i in range(min(fout, len(out))):
        out[-1 - i] *= i / fout
    return out


def loudness_gain(samples):
    peak = max(abs(v) for v in samples) or 1.0
    loud = []
    for i in range(0, len(samples), WINDOW):
        chunk = samples[i:i + WINDOW]
        rms = math.sqrt(sum(v * v for v in chunk) / len(chunk))
        if rms > peak * 10 ** (-30 / 20):
            loud.append(rms)
    rms = math.sqrt(sum(r * r for r in loud) / len(loud))
    return min(TARGET_RMS / rms, PEAK_LIMIT / peak)


def write_wav(path, samples):
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(b"".join(struct.pack("<h", int(max(-1.0, min(1.0, v)) * 32767)) for v in samples))


def prepare(name, source):
    samples = decode(source)
    (ps, pe), (rs, re) = find_clicks(samples)
    click = faded(samples[ps:re])
    gain = loudness_gain(click)
    folder = ROOT / name
    folder.mkdir(parents=True, exist_ok=True)
    write_wav(folder / "down.wav", [v * gain for v in faded(samples[ps:pe])])
    write_wav(folder / "up.wav", [v * gain for v in faded(samples[rs:re])])
    write_wav(folder / "click.wav", [v * gain for v in click])
    print(f"{name}: press {ps / RATE * 1000:.0f}-{pe / RATE * 1000:.0f} ms, release {rs / RATE * 1000:.0f}-"
          f"{re / RATE * 1000:.0f} ms, gain {20 * math.log10(gain):+.1f} dB")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    for arg in sys.argv[1:]:
        name, _, source = arg.partition("=")
        prepare(name, Path(source).expanduser())
