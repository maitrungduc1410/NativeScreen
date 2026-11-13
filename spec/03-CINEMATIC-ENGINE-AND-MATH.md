# NativeScreen: Cinematic Engine, Physics & GPU Shaders

NativeScreen's signature cinematic feel is driven by deterministic mathematical solvers and real-time GPU shaders. This specification defines the complete cross-platform algorithms to implement identically on both **macOS** (`Swift` + `Metal`) and **Windows** (`C#` + `Direct3D 11` / `HLSL`).

---

## 1. 120Hz Spring Physics Solver (`SpringTrajectorySolver`)

Both smooth cursor gliding and virtual camera pan/zoom are modeled by a second-order damped harmonic oscillator (Newtonian spring differential equation):

$$\frac{d^2x}{dt^2} = -\frac{k}{m}(x - x_{\text{target}}) - \frac{c}{m}\frac{dx}{dt}$$

Where:
- $k$ = `stiffness`
- $c$ = `damping`
- $m$ = `mass`
- $\omega_0 = \sqrt{k / m}$ (natural frequency)
- $c_{\text{crit}} = 2\sqrt{k \cdot m}$ (critical damping)
- $\zeta = c / c_{\text{crit}}$ (damping ratio)

### 1.1. Canonical Spring Presets

#### A. Cursor Spring Presets
| Preset | `stiffness` ($k$) | `damping` ($c$) | `mass` ($m$) | Damping Ratio ($\zeta$) | Steady-State Lag ($c / k \times 1000$) |
| :--- | :---: | :---: | :---: | :---: | :---: |
| **Smooth** *(Default)* | `470.0` | `70.0` | `3.0` | `0.93` | `148.9 ms` |
| **Medium** | `340.0` | `60.0` | `3.0` | `0.94` | `176.5 ms` |
| **Rapid** | `530.0` | `40.0` | `1.0` | `0.87` | `75.5 ms` |
| **None** | n/a | n/a | n/a | Instant (`1:1`) | `0.0 ms` |

#### B. Camera Zoom / Pan Spring Presets
| Preset | `stiffness` ($k$) | `damping` ($c$) | `mass` ($m$) | Damping Ratio ($\zeta$) | Behavior |
| :--- | :---: | :---: | :---: | :---: | :--- |
| **Smooth** *(Default)* | `170.0` | `50.0` | `3.0` | `1.11` | Overdamped, fluid cinematic settle |
| **Focused** | `250.0` | `40.0` | `2.25` | `0.84` | Fast stabilization for reading code/text |

---

### 1.2. 1ms Substep Integrator with Dynamic Critical Damping Clamp (`stepClampedSpring`)

Because timeline scrubbing must support random access without replaying the simulation, `PlaybackTrajectorySolver` projects retained telemetry and zoom intervals into edited time, then pre-solves at **120Hz** ($\Delta t = 1000 / 120 \approx 8.333\text{ ms}$). Source-contiguous slices share a trajectory even when speed changes; a source discontinuity starts a new one, with the incoming cursor and active camera targets initialized at the cut. Lookup never interpolates across cuts. Preview, video/GIF export and still frames pass explicit timeline time (required when a source range is reused). Crop and slice edits invalidate derived camera/motion state. Source media and persisted coordinates do not change.
- For a 10-minute video at 120Hz, the pre-solved trajectory array has only `72,000` samples (`~1.1 MB` in RAM) and takes **`< 2 ms`** to compute on a single CPU core.
- Within each `8.333 ms` step, the integrator advances in **8 substeps** ($\delta t = \Delta t / 8 \approx 1.04\text{ ms}$).
- **Dynamic Overshoot Clamp:** At every `1 ms` substep, if the velocity $v$ is approaching the target ($v \cdot (x_{\text{target}} - x) > 0$) faster than the natural settling rate $|x_{\text{target}} - x| \cdot \omega_0$, the effective damping for that substep is boosted to at least critical damping:
  $$c_{\text{step}} = \max\left(c,\; 2\sqrt{k \cdot m}\right)$$
  Additionally, if a substep crosses $x_{\text{target}}$ ($(x - x_{\text{target}})(x_{\text{next}} - x_{\text{target}}) < 0$), the state is snapped cleanly to $(x = x_{\text{target}}, v = 0)$. This guarantees **zero bounce and zero oscillation** under all presets.

---

## 2. Cursor Trajectory, Phase-Lag Compensation & Drag Synchronization

### 2.1. First-Frame Telemetry Epoch Synchronization
During recording, the mouse/keyboard telemetry clock (`t = 0.0 ms`) MUST be anchored to the exact presentation timestamp (`firstSampleTime`) of the first captured video frame from the OS screen capture stream, and a cursor sample is written at exactly `t = 0`. This prevents any startup offset between the recorded video frames and the cursor trajectory.

Recordings made before this (until 2026-10-26) started the clock when telemetry started, before capture, so every event is late by the startup delay `D`. They are recognized by a first cursor sample after `t = 0.5 ms`. Telemetry and capture stopped together, so `D = min(firstCursor.t, max(0, lastEvent.t - durationMs))` over cursor, click and key events, ignored below `20 ms` (ADR-88). On load, cursor, clicks and keys are moved by `-D` in memory; events before `0` are dropped. Files are never rewritten.

### 2.2. Planned Lead and Spring Speed (ADR-87, `CursorPathPlanner`)
A spring $(k, c, m)$ chasing a target at constant velocity lags it by $\text{lagMs} = c / k \times 1000$ (about `149 ms` for the default cursor `470/70/3`). The cursor is not given a fixed lookahead. It is a plain spring fed the recorded path at $t + \text{lead}(t)$, with $k_{\text{eff}} = k\,s(t)^2$ and $c_{\text{eff}} = c\,s(t)$. Lead is `0` and speed `1` except where an interaction needs them. All distances are in capture points (`logicalBounds`), all times in playback ms of one continuous run.

1. **Integration:** semi-implicit Euler in `1 ms` steps (fractional at the ends), the path sampled at every step, $s$ re-read every `4 ms`. Overshoot clamp as in §1. An axis snaps to its target below `0.01 pt` and `0.01 pt/s`. The result is stored per ms; evaluation interpolates it, so clicks between 120 Hz steps stay exact.
2. **Anchors:** mouse down/up (tolerance `2 pt`), every cursor sample while a button is held (`2 pt`), cursor-shape changes (`4 pt` with *Keep in sync with hovers*, otherwise `6 pt`; no hover telemetry is recorded, shape changes stand in for hovered UI). Anchors within `100 ms` form a group. Nothing after the ending options start (stop moving, loop back) is anchored.
3. **Per group**, simulate from the committed trajectory and measure $\max(\text{error} / \text{tolerance})$ at its anchors. Choose the smallest speed level in `[1, 1.25, 1.6, 2, 2.5, 3.2, 4, 5, 6.4, 8, 10, 13, 16, 20, 25, 32]` (binary search) and, for it, the smallest lead in `[0, 600] ms` (doubling candidates from `lagMs / s / 8`, then bisection or golden-section) whose ratio is at most `0.75`. If no level passes, keep the smallest error.
4. **Speed bump:** $s$ ramps in log space from `1` over `250 ms` before the group, holds through it and ramps out over `300 ms`. Overlapping bumps take the maximum.
5. **Lead shape:** after a group, lead drops to `0` at once if the recorded cursor rests for the whole lead, otherwise linearly at `0.35 ms/ms`. A raise toward the next group is placed in a rest where the target does not move (a jump), else compressed over the last `400 ms`. Target time must advance at `0.65x` to `1.4x` real time, or the raise is rejected. The approach window is `1500 ms` before the group.
6. **Merging:** a group whose ratio exceeds `1` is merged with the previous one and solved again when the gap is at most `400 ms`, or when the previous lead is still decaying at the group's start and the merged span stays within `4000 ms`.

Pauses: two samples more than `48 ms` apart in recording time hold the first position until `16 ms` before the second. The playback wrapper expands these holds before projecting samples into playback time; the planner then interpolates linearly. Down/up positions are inserted as path samples, since the click log owns the tip at the interaction, unless the click is more than `16 pt` from the interpolated cursor and from both bracketing samples (inconsistent or synthetic data; the bracketing samples cover a click just before a cursor warp). Click waves and circles stay at the down coordinate. A button held through a trim is a `held` event: it anchors the drag but makes no ripple. Clock offsets of older recordings are corrected on load (section 2.1).

### 2.3. Smoothing Off
With smoothing off the cursor is the shake-filtered recorded position at $t$, with no lead and no spring.

### 2.4. Micro-Shake Filter, Cursor Rotation & Idle Auto-Hide
1. **Micro-Shake Filtering (`removeShakeThresholdPx`):**
   - Measure displacement in capture points, `hypot(dx01 * pointWidth, dy01 * pointHeight)`, and drop moves within `removeShakeThresholdPx` of the last kept sample, except while a button is held and at clicks. A kept move after dropped ones holds until the last dropped sample's time. The planner runs on the filtered path.
2. **Cursor Rotation (`Tilt` vs `Follow`):**
   - **Tilt mode (`velocity`):** Banks horizontally with horizontal velocity in points, expressed as `vx01 * pointWidth / 1600`:
     $$\theta_{\text{dynamic}} = \text{clamp}\left(-v_x \cdot 0.14 \cdot \text{intensity},\; -0.35\text{ rad},\; +0.35\text{ rad}\right)$$
   - **Follow mode (`directional`):** Uses `atan2(-vy01 * pointHeight, vx01 * pointWidth) - 3pi/4`; the speed gate is measured in points divided by 1600. A non-square capture must not distort the heading. Velocity is the planned path's central difference over `+-1 ms`.
3. **Auto-Hide on Idle & Loop-Back:**
   - If cursor movement ceases for `> hideWhenIdleAfterMs`, smoothly fade opacity toward `0.0`.
   - If `loopBackToStartMs` is set, linearly blend the target position back to `firstPos` over the final `loopBackToStartMs` milliseconds of the recording.

---

## 3. Cinematic Virtual Camera & Auto-Zoom Architecture

### 3.1. Automatic Click-Clustering & Typing Hold (`AutoZoomClusterGenerator`)
When a recording finishes, mouse clicks (`clicks.jsonl`) and keystrokes (`keys.jsonl`) are grouped into non-overlapping `ZoomBlock` segments:
- **Lead-in (Anticipation):** Start each zoom block `300 ms` *before* the first click in a cluster so the camera is already zooming in as the click happens.
- **Click Merge Window:** Consecutive clicks within `2500 ms` of each other are merged into the same zoom block, holding for `2500 ms` after the last click.
- **Typing Hold:** If active keystrokes occur during the zoom window, extend `sourceEndMs` until `1500 ms` after the last keystroke.
- **Minimum Duration:** Enforce a minimum duration of `2200 ms` per zoom block.
- **Merge Close Zooms:** After the blocks are built, neighbours less than `2500 ms` apart (`mergeGapMs`, strict inequality) become one block spanning both, centered on the duration-weighted mean of their centers. Keep the typing hold and tail margin. This avoids a brief full-frame detour between related interactions.

### 3.2. Stationary Dead-Zone Focus Groups (`CursorMovesGroup`)
If a zoomed-in camera chased every minor mouse movement continuously, the viewport would swim constantly and cause motion sickness. Instead, inside each `followCursor` zoom block:
1. Decimate cursor samples inside `[zoom.sourceStartMs, zoom.sourceEndMs]` by a minimum step of `0.006` normalized units (plus all click-down anchors).
2. Partition consecutive samples into bounding-box clusters (`CursorMovesGroup`) whose horizontal and vertical spans $(\max X - \min X)$ and $(\max Y - \min Y)$ do not exceed the **50% zoomed-viewport dead-zone**:
   $$\text{maxDistance}_{01} = \frac{0.5}{\text{zoomScale}}$$
3. For each group, compute its **time-weighted centroid**:
   $$\mathbf{c}_{\text{group}} = \frac{\sum_i \mathbf{p}_i \cdot \Delta t_i}{\sum_i \Delta t_i}$$
   where $\Delta t_i = t_{i+1} - t_i$ is the duration the cursor dwelt at sample $i$.
4. As long as the cursor stays within the current `CursorMovesGroup`'s bounding box, the camera target remains **100% stationary** at $\mathbf{c}_{\text{group}}$, only panning when the user moves the cursor into the next group!

Group spans in recording coordinates are `(crop.width, crop.height) * 0.5 / zoomScale`. Camera and Loupe targets then enter crop space as `((x - crop.x) / crop.width, (y - crop.y) / crop.height)`. Cursor states and click waves remain recording-space until drawn. Loupe uses these same grouped targets, plus its existing slow decorative drift (manual focus has no drift). `CameraFrameState.center01` always belongs to the screen camera; `loupeCenter01` is independent. A fading lens never suppresses the screen transform. Effect exits start at the item end, not before it (ADR-84).

### 3.3. Screen-Rect Space Interpolation (Zero Curvilinear Swimming)
If camera center $(c_x, c_y)$ and zoom scale $Z$ were animated by independent springs, differences in relative displacement would cause the viewport to travel along a curved arc ("curvilinear swimming") when zooming in on a corner.

Instead, NativeScreen solves the camera trajectory in **Normalized Screen-Rectangle Space** $(x_{\text{rect}}, y_{\text{rect}}, w_{\text{rect}})$:
1. In normalized unzoomed screen coordinates where the full screen is $[0, 0, 1, 1]$:
   - Unzoomed state ($Z = 1$): $w_{\text{target}} = 1.0,\; x_{\text{target}} = 0.0,\; y_{\text{target}} = 0.0$.
   - Zoomed state at scale $Z > 1$ focused on $(f_x, f_y)$ with boundary clamping (`avoidEmptyBoundsWhenZooming`):
     $$w_{\text{target}} = Z$$
     $$x_{\text{target}} = \text{clamp}(0.5 - f_x \cdot Z,\; 1.0 - Z,\; 0.0)$$
     $$y_{\text{target}} = \text{clamp}(0.5 - f_y \cdot Z,\; 1.0 - Z,\; 0.0)$$
2. Advance $x_{\text{rect}}$, $y_{\text{rect}}$, and $w_{\text{rect}}$ using the **exact same camera spring** (`stepClampedSpring`).
3. Recover the instantaneous camera scale and focus center from the interpolated rectangle:
   $$Z_{\text{solved}} = \max(1.0, w_{\text{rect}}), \quad c_x = \frac{0.5 - x_{\text{rect}}}{Z_{\text{solved}}}, \quad c_y = \frac{0.5 - y_{\text{rect}}}{Z_{\text{solved}}}$$
Because all three components share identical spring dynamics, zoom scale and pan translation remain **100% locked in linear phase**.

---

## 4. 6-Pass GPU Compositor Pipeline (`MetalFrameCompositor`)

Every video frame at source timestamp $t$ is composited on the GPU in a deterministic 6-pass pipeline:

### Pass 1: Background Layer
- Render the selected background onto the output canvas texture:
  - **System / Custom Wallpaper Image:** Aspect-fill UV mapping + optional Gaussian blur (`background.blurRadius`) + smooth `320 ms` cubic crossfade when switching wallpapers.
  - **Mesh / Linear / Radial Gradient or Solid Color:** Evaluated and cached at target canvas resolution.

### Pass 2: Multi-Track Sensitive Data Masks & Spotlights (Pre-Screen Space)
- Applied directly in unzoomed source screen space **before** camera zoom/pan or cursor rendering, so masks remain 100% locked to the underlying screen content even while the camera zooms and pans:
  - **Blur / Pixelate / Solid Masks:** Interpolate `rect01` from `keyframes` at `sourceTimeMs` and apply Gaussian blur, pixelation, or solid fill clipped to an anti-aliased rounded rectangle (`cornerRadius`).
  - **Spotlight (Highlight) Masks:** Dim the surrounding screen area by `intensity`% while keeping the spotlight rounded rectangle at full brightness.

### Pass 3: Screen Frame, Rounded Corners, Inset Border & Drop Shadow
- Fit the cropped source screen into the padded canvas (`canvas.paddingRatio`).
- Clip corners to `frameStyle.borderRadius`, composite inner border (`frameStyle.inset`), and render Classic or Directional soft drop shadow (`frameStyle.shadow`).

### Pass 4: Vector Cursor Sprite & Click Ripples
- Render active click effects (`Circle` or `Ripple` expanding over `450 ms`) at the click coordinate.
- Composite the high-DPI vector cursor sprite (`CursorSpriteProvider`) at smoothed `cursorState.position01` with hotspot alignment, `cursor.scale`, and rotation `cursorState.rotationRadians`.

### Pass 5: Virtual Camera Transform, Camera Motion Blur & Magnifier Lens
- **5A. Camera Zoom & Motion Blur (`EffectKernels.applyCameraMotionBlur`):**
  - Apply the affine screen camera transform (`scale: Z`, centered on `cameraState.center01`), including its settling during Loupe transitions.
  - Evaluate where the zoomed screen rect sits now ($R_1$) and one frame earlier ($R_0$, at $t - 16.67\text{ ms}$). The shutter is open for the last `motionBlurIntensity` fraction of that interval.
  - For a pixel $p$, the screen point under it at time $s$ is $u(s) = (p - R(s)_{xy}) / R(s)_{wh}$ with $R(s) = \text{lerp}(R_0, R_1, s)$, drawn in the current frame at $q(s) = R_{1,xy} + u(s) \cdot R_{1,wh}$. The output averages the current frame at $q(s)$ for $s \in [1 - \text{shutter}, 1]$. For pans the path is a straight line; for zooms it curves toward the focus point.
  - Samples are taken in linear light (gamma 2.2 decode, premultiplied), with a per-pixel jitter (interleaved gradient noise) so a small sample count reads as fine grain. Sample count = `travel / pixelsPerSample`, capped at 8 in playback and 24 in export.
  - Compare camera states 16.67 playback milliseconds apart. If no edge moves at least `0.5 px`, skip so the image is sharp once the camera settles. Also skip across a real cut, during instant zoom snaps and on the paused last frame.
- **5B. Magnifier Lens (`EffectKernels.applyMagnifierLens`):**
  - When `cameraState.loupePresence01 > 0.005`, run the lens kernel with two inputs: the base scene and a sharp, pre-magnified scene patch (screen, masks, screen annotations, cursor, frame and background). Rebuild the screen directly from source pixels at lens scale. The patch bounds are integral, centered on the transformed `loupeCenter01`, with half-side `1.7 * R + 2`; allocation does not grow with magnification. Canvas annotations, webcam, captions and keycaps remain outside the glass.
    1. **Magnification:** the patch already applies `translate(center) * scale(zoom) * translate(-center)`, so the kernel samples it at `center + offset`.
    2. **Rim refraction:** in the rim band (`rimRatio` of the radius), scale the sample offset by $1 + 0.55\,e^2$ with $e = \text{smoothstep}(1 - \text{rimRatio}, 1, r/R)$, so the edge shows content from further out like a thick convex lens.
    3. **Color fringing:** red and blue are sampled at offsets scaled by $1 \mp 0.045 \cdot \text{colorFringe} \cdot e$ (3 taps).
    4. **Lighting:** soft gloss over the upper half, slight rim darkening away from the light, and an exponential rim highlight that is strongest on the top-left (light side) with a faint counter highlight opposite.
    5. **Shadow:** a Gaussian-falloff disc offset slightly downward, visible only outside the glass. `presence` fades the whole lens and its shadow.

### Pass 6: 3D Keyboard Shortcut Keycaps Overlay (`WYSIWYG` Preview & Export)
- Render active `ShortcutPressCluster` 3D bevel keycaps (`renderShortcutKeycapsOverlay` with cached `keycapSpriteCache`) across all visible shortcut tracks.
- Supports `Bottom` (horizontal), `Top` (horizontal), `Left` (vertical stack), and `Right` (vertical stack) dock positions, `offsetX`/`offsetY` shifts, `Default Dark` / `Solid` / `Gradient` keycap themes, and a deterministic cubic smoothstep transition envelope (`150 ms` fade/scale/slide-in, `180 ms` fade/scale/slide-out) shared identically between live Preview and video/GIF export.
