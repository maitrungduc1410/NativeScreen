# NativeScreen — Cinematic Engine, Physics & GPU Shaders

To match and surpass the signature "cinematic feel", NativeScreen relies on deterministic mathematical solvers and real-time GPU shaders. This document specifies the exact algorithms to implement on both macOS (Swift + Metal) and Windows (C# + HLSL).

---

## 1. Spring Physics Solver (Cursor & Camera Movement)

Both smooth cursor gliding and virtual camera pan/zoom are driven by a damped harmonic oscillator (spring differential equation):

$$\frac{d^2x}{dt^2} = -\frac{k}{m}(x - x_{\text{target}}) - \frac{c}{m}\frac{dx}{dt}$$

Where:
- $k$ = `stiffness` (Default: `125.0`)
- $c$ = `damping` (Default: `12.0` for cursor, `14.0` for camera)
- $m$ = `mass` (Default: `1.5`)

### 1.1. Deterministic Evaluation at Any Timestamp $t$
Because timeline scrubbing must be instant (random access to any frame $t$ without simulating from $t = 0$ every frame), we pre-solve or step the spring state at fixed 120Hz (`dt = 1.0 / 120.0` sec = `8.333 ms`) into a cached lookup array in memory whenever telemetry or zoom blocks change:
- For a 10-minute video at 120Hz, the pre-solved trajectory array has only `72,000` points (`~1.1 MB` in RAM) and takes **`< 2 ms`** to compute on a single CPU core!
- At render time (60fps/120fps preview or export), looking up the exact smoothed cursor position $(x, y)$, cursor velocity $(v_x, v_y)$, camera center $(c_x, c_y)$, and camera zoom $z$ at timestamp $t$ is an **$O(1)$ array interpolation**.

---

## 2. Cursor Processing Pipeline

1. **Micro-Shake Filtering (Pre-Filter):**
   - Raw mouse telemetry often contains 1–3px hand jitter during clicks or reading.
   - Apply a dead-zone / hysteresis filter (`removeShakeThresholdPx`): ignore movements within radius $r_{\text{shake}}$ unless sustained towards a new direction.
2. **Spring Smoothing:**
   - Feed filtered target coordinates into the 2D Spring Solver (`stiffness: 125, damping: 12, mass: 1.5`).
3. **Velocity-Based Cursor Tilt (Rotation):**
   - From instantaneous spring velocity $(v_x, v_y)$, compute dynamic tilt angle:
     $$\theta = \text{clamp}\left(-v_x \cdot \text{rotateOnXRatio}, -\theta_{\max}, +\theta_{\max}\right)$$
   - Gives the cursor a subtle physical banking feel when swiping across the screen.
4. **Auto-Hide on Idle & Loop-Back:**
   - If cursor velocity remains near zero for `> hideWhenIdleAfterMs` (e.g. `3000 ms`), smoothly fade cursor alpha `1.0 -> 0.0` over `250 ms`.
   - If `loopBackToStartMs` is enabled (e.g. last `800 ms` of clip), smoothly interpolate the target cursor position back to the initial position at `t = 0` for seamless looping GIFs/Reels.

---

## 3. Auto-Zoom Clustering & Typing-Aware Camera Solver

When a recording finishes (or when the user clicks "Regenerate Auto-Zooms"):

1. **Event Extraction:**
   - Gather all mouse clicks from `clicks.jsonl` and key presses from `keys.jsonl`.
2. **Spatio-Temporal Clustering (`follow-click-groups`):**
   - Group consecutive clicks that occur within $\Delta t \le 3500\text{ ms}$ of each other.
   - **Lead-in (Anticipation):** Start each zoom block `350 ms` *before* the first click in the cluster so the camera is already zooming in as the user clicks.
   - **Typing Hold:** If `keys.jsonl` shows active typing inside the cluster window, extend `sourceEndMs` until `1200 ms` after the last keystroke, keeping the camera steady on the text field without drifting.
   - **Minimum Duration & Merge:** Enforce a minimum zoom duration of `2000 ms`. Merge adjacent zoom blocks separated by `< 1000 ms`.
3. **Boundary Clamping (`avoidEmptyBoundsWhenZooming`):**
   - For zoom scale $Z \ge 1.0$, clamp the target camera center $(c_x, c_y) \in [0, 1]^2$ so the zoomed viewport never exposes outside the recorded screen edges:
     $$c_x \in \left[\frac{1}{2Z},\; 1 - \frac{1}{2Z}\right], \quad c_y \in \left[\frac{1}{2Z},\; 1 - \frac{1}{2Z}\right]$$

---

## 4. GPU Render Pass Pipeline (Metal on macOS / Direct3D 11 on Windows)

Every video frame at timestamp $t$ is composited on the GPU in a single command buffer:

### Pass 1: Background Layer
- Render selected background onto output canvas texture:
  - **System / Custom Wallpaper Image:** Sampled with aspect-fill UV + optional Gaussian blur (`background.blurRadius`).
  - **Linear / Radial / Mesh Gradient:** Evaluated directly in fragment shader.
  - **Subtle Film/White Noise:** Blend `noiseIntensity` (`~0.02`) procedural hash noise to eliminate 8-bit gradient banding.

### Pass 2: Multi-Track Sensitive Data Masks & Spotlights (Pre-Screen Pass)
- On the raw screen texture (in `source` normalized space, **before** camera zoom/pan transform so masks stick 100% to the underlying UI elements even while zooming!):
  - **For each active `blur` / `pixelate` mask across all `maskTracks`:**
    - Interpolate `rect01` from the mask's `keyframes` at `sourceMs`.
    - Apply separable Dual-Kawase / Gaussian blur or Pixelate shader inside the rounded rectangle `rect01` with smooth 2px anti-aliased SDF edge feathering.
  - **For active `spotlight` (highlight) masks:**
    - Dim the surrounding screen area by `highlightMaskOpacity` outside the union of active spotlight rounded rectangles.

### Pass 3: Screen Frame, Drop Shadow, Inset & Camera Zoom Transform
- Apply the Virtual Camera transform matrix $M_{\text{camera}}(c_x, c_y, Z)$ to the screen quad.
- **Signed Distance Field (SDF) Rounded Rectangle:**
  - Clip screen corners to `frameStyle.borderRadius` with sub-pixel anti-aliasing.
  - Render inner border (`frameStyle.inset`) and directional soft drop shadow (`frameStyle.shadow` using analytical SDF box shadow in the fragment shader — requires zero extra blur passes!).
  - Optional: Composite inside `deviceMockup` bezel texture (iPhone / MacBook frame).

### Pass 4: Cursor, Click Ripples & Optical Glass Loupe
- **Click Ripples:** For any click in $[t - 450\text{ ms}, t]$, render an expanding, fading ring/pulse at the click's normalized position transformed by $M_{\text{camera}}$.
- **Optical Loupe (if `zoom.presentation == "loupe"`):**
  - Render circular magnifying lens around cursor with barrel refraction, edge bevel specular highlight (`bevelRatio`), and RGB channel offset (`chromaticAberration`).
- **Vector / High-Res Cursor Sprite:**
  - Render cursor texture at smoothed $(x, y)$ with scale `cursor.scale`, rotation $\theta$, and directional motion blur trail if cursor speed is high.

### Pass 5: Camera Motion Blur (Shutter Integration)
- When camera velocity $(\dot{c}_x, \dot{c}_y, \dot{Z})$ exceeds a small threshold and `motionBlurIntensity > 0`:
  - Apply directional velocity blur along the instantaneous screen-space velocity vector (8–12 taps along shutter angle $180^\circ \cdot \text{motionBlurIntensity}$) so fast zoom-ins and pans look buttery smooth at 60fps.

### Pass 6: Webcam Overlay / AI Person Cutout & Captions/Keystrokes
- Composite Webcam PiP (with squircle/circle SDF mask + shadow, or CoreML/Vision person segmentation alpha matte).
- Notice: Webcam PiP scales by `scaleWhenZoomed` (e.g. `0.8x`) when the main screen is zoomed in so it doesn't obstruct content.
- Render active Keystroke HUD pill (e.g., `⌘ + C`) and Subtitle/Caption text overlay on top.
