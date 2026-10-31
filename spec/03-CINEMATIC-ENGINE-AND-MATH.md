# NativeScreen — Cinematic Engine, Physics & GPU Shaders

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
| **None** | — | — | — | Instant (`1:1`) | `0.0 ms` |

#### B. Camera Zoom / Pan Spring Presets
| Preset | `stiffness` ($k$) | `damping` ($c$) | `mass` ($m$) | Damping Ratio ($\zeta$) | Behavior |
| :--- | :---: | :---: | :---: | :---: | :--- |
| **Smooth** *(Default)* | `170.0` | `50.0` | `3.0` | `1.11` | Overdamped, fluid cinematic settle |
| **Focused** | `250.0` | `40.0` | `2.25` | `0.84` | Fast stabilization for reading code/text |

---

### 1.2. 1ms Substep Integrator with Dynamic Critical Damping Clamp (`stepClampedSpring`)

Becausetimeline scrubbing must support instant random access to any timestamp $t$ without simulating from $t = 0$ on every frame, the solver pre-computes the entire trajectory at **120Hz** ($\Delta t = 1000 / 120 \approx 8.333\text{ ms}$) into a contiguous lookup array whenever telemetry or zoom blocks change:
- For a 10-minute video at 120Hz, the pre-solved trajectory array has only `72,000` samples (`~1.1 MB` in RAM) and takes **`< 2 ms`** to compute on a single CPU core.
- Within each `8.333 ms` step, the integrator advances in **8 substeps** ($\delta t = \Delta t / 8 \approx 1.04\text{ ms}$).
- **Dynamic Overshoot Clamp:** At every `1 ms` substep, if the velocity $v$ is approaching the target ($v \cdot (x_{\text{target}} - x) > 0$) faster than the natural settling rate $|x_{\text{target}} - x| \cdot \omega_0$, the effective damping for that substep is boosted to at least critical damping:
  $$c_{\text{step}} = \max\left(c,\; 2\sqrt{k \cdot m}\right)$$
  Additionally, if a substep crosses $x_{\text{target}}$ ($(x - x_{\text{target}})(x_{\text{next}} - x_{\text{target}}) < 0$), the state is snapped cleanly to $(x = x_{\text{target}}, v = 0)$. This guarantees **zero bounce and zero oscillation** under all presets.

---

## 2. Cursor Trajectory, Phase-Lag Compensation & Drag Synchronization

### 2.1. First-Frame Telemetry Epoch Synchronization
During recording, the mouse/keyboard telemetry clock (`t = 0.0 ms`) MUST be anchored to the exact presentation timestamp (`firstSampleTime`) of the first captured video frame from the OS screen capture stream. This prevents any startup offset between the recorded video frames and the cursor trajectory.

### 2.2. Lookahead Phase-Lag Compensation (`leadMs`)
A physical spring with parameters $(k, c)$ chasing a moving target at velocity $v$ exhibits a steady-state temporal phase lag:
$$\text{lagMs} = \frac{c}{k} \times 1000\text{ ms}$$
If the spring at time $t$ is fed the raw cursor position at $t$, the rendered cursor will arrive at buttons, hover highlights, and text selections ~`150 ms` *after* the visual reaction has already appeared in the video frame.

To eliminate this lag:
1. **Lookahead Target Lookup:** At simulation time $t$, the spring is fed the recorded target position at:
   $$t_{\text{lookup}} = t + \frac{\text{effectiveLeadMs}}{\text{syncSpeedMultiplier}}$$
   where $\text{effectiveLeadMs} = \text{lagMs} \times (1.0 \text{ if } \text{keepInSyncWithHovers else } 0.72)$.
2. **Stationary Pause Hold (`> 48 ms` gap):** When two consecutive recorded cursor samples $e_0, e_1$ are separated by more than `48 ms` (indicating the physical mouse was stationary), the target lookup holds $(e_0.x, e_0.y)$ until $e_1.t - 16\text{ ms}$ rather than linearly interpolating across the pause. This prevents the cursor from drifting prematurely before the user actually moved their hand.

### 2.3. Active Drag & Click Speed Multiplier (`syncSpeedMultiplier`)
When the user performs a mouse-down drag (e.g., selecting/highlighting a line of text or dragging a UI slider) or clicks a button, the rendered cursor tip must stay locked 1:1 to the selection edge and stop at the exact millisecond `mouseUp` occurs:
1. Construct all `[mouseDown ... mouseUp]` drag intervals from `clicks.jsonl`.
2. Compute a dynamic speed multiplier $\text{speed} \ge 1.0$:
   - **220 ms ramp-in before `drag.startMs`:** $\text{speed}$ ramps linearly from $1.0 \rightarrow 4.2$.
   - **During `[drag.startMs, drag.endMs]`:** $\text{speed} = 4.2$, and the micro-shake filter threshold is set to `0.0` so every character selection step is tracked faithfully.
   - **260 ms ramp-out after `drag.endMs`:** $\text{speed}$ ramps linearly from $4.2 \rightarrow 1.0$.
   - **Within $\pm 180\text{ ms}$ of any click:** $\text{speed}$ is boosted up to $3.4\times$.
3. Scale the effective spring parameters quadratically/linearly by $\text{speed}$:
   $$k_{\text{eff}} = k \cdot \text{speed}^2, \quad c_{\text{eff}} = c \cdot \text{speed}$$
   Because $\text{lagMs}_{\text{eff}} = c_{\text{eff}} / k_{\text{eff}} = \text{lagMs} / \text{speed}$, dividing the lookahead time by $\text{speed}$ keeps phase alignment seamless.

### 2.4. Micro-Shake Filter, Cursor Rotation & Idle Auto-Hide
1. **Micro-Shake Filtering (`removeShakeThresholdPx`):**
   - Convert pixel threshold to normalized coordinates: $r_{\text{shake}} = \text{removeShakeThresholdPx} / 1600.0$.
   - Ignore target displacements smaller than $r_{\text{shake}}$ when not actively dragging.
2. **Cursor Rotation (`Tilt` vs `Follow`):**
   - **Tilt mode (`velocity`):** Banks horizontally with horizontal velocity $v_x$:
     $$\theta_{\text{dynamic}} = \text{clamp}\left(-v_x \cdot 0.14 \cdot \text{intensity},\; -0.35\text{ rad},\; +0.35\text{ rad}\right)$$
   - **Follow mode (`directional`):** Smoothly aligns cursor heading along the 2D velocity vector $\text{atan2}(-v_y, v_x) - \frac{3\pi}{4}$ when speed exceeds `0.04`.
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

### 3.2. Stationary Dead-Zone Focus Groups (`CursorMovesGroup`)
If a zoomed-in camera chased every minor mouse movement continuously, the viewport would swim constantly and cause motion sickness. Instead, inside each `followCursor` zoom block:
1. Decimate cursor samples inside `[zoom.sourceStartMs, zoom.sourceEndMs]` by a minimum step of `0.006` normalized units (plus all click-down anchors).
2. Partition consecutive samples into bounding-box clusters (`CursorMovesGroup`) whose horizontal and vertical spans $(\max X - \min X)$ and $(\max Y - \min Y)$ do not exceed the **50% zoomed-viewport dead-zone**:
   $$\text{maxDistance}_{01} = \frac{0.5}{\text{zoomScale}}$$
3. For each group, compute its **time-weighted centroid**:
   $$\mathbf{c}_{\text{group}} = \frac{\sum_i \mathbf{p}_i \cdot \Delta t_i}{\sum_i \Delta t_i}$$
   where $\Delta t_i = t_{i+1} - t_i$ is the duration the cursor dwelt at sample $i$.
4. As long as the cursor stays within the current `CursorMovesGroup`'s bounding box, the camera target remains **100% stationary** at $\mathbf{c}_{\text{group}}$, only panning when the user moves the cursor into the next group!

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
  - When not in Loupe mode, apply the affine camera transform (`scale: Z`, centered on `cameraState.center01`).
  - Evaluate where the zoomed screen rect sits now ($R_1$) and one frame earlier ($R_0$, at $t - 16.67\text{ ms}$). The shutter is open for the last `motionBlurIntensity` fraction of that interval.
  - For a pixel $p$, the screen point under it at time $s$ is $u(s) = (p - R(s)_{xy}) / R(s)_{wh}$ with $R(s) = \text{lerp}(R_0, R_1, s)$, drawn in the current frame at $q(s) = R_{1,xy} + u(s) \cdot R_{1,wh}$. The output averages the current frame at $q(s)$ for $s \in [1 - \text{shutter}, 1]$. For pans the path is a straight line; for zooms it curves toward the focus point.
  - Samples are taken in linear light (gamma 2.2 decode, premultiplied), with a per-pixel jitter (interleaved gradient noise) so a small sample count reads as fine grain. Sample count = `travel / pixelsPerSample`, capped at 8 in playback and 24 in export.
  - If no edge moves at least `0.5 px`, the pass is skipped, so the image is sharp the moment the camera settles. Also skipped during instant zoom snaps and on the paused last frame.
- **5B. Magnifier Lens (`EffectKernels.applyMagnifierLens`):**
  - When `cameraState.loupePresence01 > 0.005`, run the lens kernel over the composited scene (screen + background):
    1. **Magnification:** inside radius $R$, sample at `center + offset / zoom`.
    2. **Rim refraction:** in the rim band (`rimRatio` of the radius), scale the sample offset by $1 + 0.55\,e^2$ with $e = \text{smoothstep}(1 - \text{rimRatio}, 1, r/R)$, so the edge shows content from further out like a thick convex lens.
    3. **Color fringing:** red and blue are sampled at offsets scaled by $1 \mp 0.045 \cdot \text{colorFringe} \cdot e$ (3 taps).
    4. **Lighting:** soft gloss over the upper half, slight rim darkening away from the light, and an exponential rim highlight that is strongest on the top-left (light side) with a faint counter highlight opposite.
    5. **Shadow:** a Gaussian-falloff disc offset slightly downward, visible only outside the glass. `presence` fades the whole lens and its shadow.

### Pass 6: 3D Keyboard Shortcut Keycaps Overlay (`WYSIWYG` Preview & Export)
- Render active `ShortcutPressCluster` 3D bevel keycaps (`renderShortcutKeycapsOverlay` with cached `keycapSpriteCache`) across all visible shortcut tracks.
- Supports `Bottom` (horizontal), `Top` (horizontal), `Left` (vertical stack), and `Right` (vertical stack) dock positions, `offsetX`/`offsetY` shifts, `Default Dark` / `Solid` / `Gradient` keycap themes, and a deterministic cubic smoothstep transition envelope (`150 ms` fade/scale/slide-in, `180 ms` fade/scale/slide-out) shared identically between live Preview and video/GIF export.
