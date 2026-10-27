# NativeScreen — Engineering Decisions, Performance Optimizations & Architecture Notes

This document records the core engineering decisions, mathematical calibrations, and performance breakthroughs discovered while building **NativeScreen**. It serves both as an Architecture Decision Record (ADR) for open-source contributors and as a blueprint for keeping the **macOS** (`SwiftUI` + `AppKit` + `Metal` + `VideoToolbox`) and **Windows** (`WinUI 3` + `Direct3D 11` + `Media Foundation`) implementations fast, deterministic, and visually identical.

---

## Table of Contents

1. [ADR-01: Hybrid Parallel Video Encoding (Hardware ASIC + Multi-Core CPU)](#1-adr-01-hybrid-parallel-video-encoding-hardware-asic--multi-core-cpu)
2. [ADR-02: Constant-Quality Keyframe Budgeting & Color Space (`ITU_R_709_2`)](#2-adr-02-constant-quality-keyframe-budgeting--color-space-itu_r_709_2)
3. [ADR-03: Sequential Zero-Copy Frame Decoding vs. Random Seek Generators](#3-adr-03-sequential-zero-copy-frame-decoding-vs-random-seek-generators)
4. [ADR-04: Baking Static 4K GPU Stencils & Drop Shadows into VRAM Textures](#4-adr-04-baking-static-4k-gpu-stencils--drop-shadows-into-vram-textures)
5. [ADR-05: Uniform Shortest-Side Padding (`padByRatio`) for `Auto` Aspect Ratio](#5-adr-05-uniform-shortest-side-padding-padbyratio-for-auto-aspect-ratio)
6. [ADR-06: Telemetry Clock Synchronization (`t = 0`), Spring Phase-Lag Lookahead & Drag Acceleration](#6-adr-06-telemetry-clock-synchronization-t--0-spring-phase-lag-lookahead--drag-acceleration)
7. [ADR-07: Zero-Overhead 120Hz Playback, Pure AppKit/Retained-Layer Tooltips & `.hover-magnet` Physics](#7-adr-07-zero-overhead-120hz-playback-pure-appkitretained-layer-tooltips--hover-magnet-physics)
8. [ADR-08: Floating Callout Tooltip Geometry (Boolean CSG Fillet Union & Window Sharing Inheritance)](#8-adr-08-floating-callout-tooltip-geometry-boolean-csg-fillet-union--window-sharing-inheritance)
9. [ADR-09: Value-Type Atomic Undo/Redo Snapshots & Non-Overlapping Track Clamping](#9-adr-09-value-type-atomic-undoredo-snapshots--non-overlapping-track-clamping)
10. [ADR-10: Mip-Pyramid + Catmull-Rom Spline Audio Waveforms & Dynamic Fixed-Interval Ruler](#10-adr-10-mip-pyramid--catmull-rom-spline-audio-waveforms--dynamic-fixed-interval-ruler)
11. [ADR-11: WYSIWYG 3D Keycap Overlay & Non-Linear Export File Size / Live ETA Estimation](#11-adr-11-wysiwyg-3d-keycap-overlay--non-linear-export-file-size--live-eta-estimation)

---

## 1. ADR-01: Hybrid Parallel Video Encoding (Hardware ASIC + Multi-Core CPU)

### Problem
When exporting a 22.5-second 4K (`3226×2160` @ 60fps = `1,350` frames) project to `H.264` MP4 on Apple Silicon:
- The **Metal GPU Compositor** renders all 6 visual passes in just `~2.7 ms/frame` (`~3.6 seconds` total for 1,350 frames, or **~375 fps**).
- However, a single hardware `AVAssetWriter` / `VTCompressionSession` (`H.264` Hardware Media Engine) takes **`18.2 seconds`** to finish because the physical H.264 ASIC block on Apple Silicon has a fixed hardware throughput ceiling of **~74 fps at 4K**.
- Spawning 2 or 4 hardware `H.264` sessions in parallel yields the exact same `18.3s` runtime because they all queue into the same physical H.264 Media Engine silicon block, while the multi-core CPU sits at `< 5%` utilization.

### Decision & Architecture
For `H.264` MP4 exports, NativeScreen uses a **Hybrid Parallel GOP Encoder**:
1. The timeline is partitioned into **2-second closed GOP chunks** (`120` frames at 60fps), with an explicit keyframe (`forceKeyframe = true`) at the start of each chunk.
2. Two independent compression workers run simultaneously on background queues:
   - **Hardware Worker (`hwWorker`)**: Uses the dedicated Hardware Media Engine (`RequireHardwareAcceleratedVideoEncoder = true`) and processes **60% of the GOP chunks** (3 out of every 5 chunks).
   - **Software Worker (`swWorker`)**: Uses the multi-core CPU encoder (`EnableHardwareAcceleratedVideoEncoder = false`) and processes **40% of the GOP chunks** (2 out of every 5 chunks) in parallel.
3. Both encoders operate directly on native bi-planar YUV `4:2:0` buffers (`kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange` on macOS / `DXGI_FORMAT_NV12` on Windows), eliminating redundant RGB $\leftrightarrow$ YUV conversions.
4. Once all chunks finish encoding in parallel, the resulting compressed `CMSampleBuffer` packets are sorted by presentation timestamp (`PTS`) and written into the final `.mp4` container via a **zero-reencode passthrough muxer** (`AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: formatDesc)`), which takes `< 0.05 seconds`.

### Result
- 4K/60fps `H.264` export throughput jumps from `~74 fps` (`18.3s`) to **`~115–125 fps` (`11–13s`)**.
- Note: For `HEVC (H.265)` and `ProRes`, the dedicated Apple Silicon HEVC/ProRes Media Engines natively run at `~125 fps` at 4K, so they run 100% on the hardware engine.

---

## 2. ADR-02: Constant-Quality Keyframe Budgeting & Color Space (`ITU_R_709_2`)

### Problem
Screen recordings have a fundamentally different spatio-temporal profile from camera footage:
- **90%+ of pixels are completely static** across consecutive frames (desktop background, browser chrome, code editor sidebars), meaning P-frames require very few bits.
- However, **11–13pt UI typography on dark backgrounds** requires high-fidelity I-frames (keyframes). If an encoder applies a strict per-second byte ceiling (`DataRateLimits` / tight CBR), it starves the I-frame at the start of each 2-second GOP (compressing a 4K keyframe down to `105–350 KB` instead of `600–1,000 KB`). Because subsequent P-frames only copy blocks from that degraded I-frame, text looks blurry and dark areas exhibit macroblocking for the entire 2-second GOP.

### Decision & Calibration
1. **Constant-Quality Mode on Hardware Encoder (`kVTCompressionPropertyKey_Quality`)**:
   - Do **not** set `kVTCompressionPropertyKey_DataRateLimits` on the hardware encoder.
   - Instead, drive the hardware encoder using constant-quality quantization calibrated to the 4 compression tiers:
     | Compression Tier | Equivalent Software CRF | Hardware `Quality` (`0.0–1.0`) | Reference `bitsPerPixel` (1080p60) |
     | :--- | :---: | :---: | :---: |
     | **Studio** | `CRF 14` | `0.87` | `0.0816` |
     | **Social Media** | `CRF 24` | `0.72` | `0.0221` |
     | **Web** | `CRF 30` | `0.58` | `0.0110` |
     | **Web (Low)** | `CRF 42` | `0.42` | `0.0038` |
   - This allows every 4K keyframe in `Studio` mode to receive `~600–950 KB` for razor-sharp UI text, while static P-frames naturally compress to a few kilobytes, yielding a compact `~26–30 MB` file for a 22-second 4K/60fps clip.
2. **Lanczos Downscaling for Unzoomed Screen Frames**:
   - When the source screen recording (`3456×2170`) is scaled down to fit inside the padded 4K canvas (`~2772×1720`), standard bilinear sampling softens 1px font stems. Using **`CILanczosScaleTransform`** (macOS) / ** Lanczos / High-Quality Cubic Sampler** (Windows) preserves crisp sub-pixel text contrast.
3. **Explicit `ITU_R_709_2` (Rec. 709) Color Tags**:
   - Always embed explicit BT.709 color metadata (`ColorPrimaries = ITU_R_709_2`, `TransferFunction = ITU_R_709_2`, `YCbCrMatrix = ITU_R_709_2`) in the output MP4 stream. Without these tags, players may fall back to legacy `Rec. 601` matrix coefficients, shifting blues/purples and desaturating UI colors.

---

## 3. ADR-03: Sequential Zero-Copy Frame Decoding vs. Random Seek Generators

### Problem
In H.264/HEVC recordings with a 60-frame GOP (`keyFrameInterval = 60`), using a stateless frame extractor such as `AVAssetImageGenerator.image(at:)` with `.requestedTimeToleranceBefore = .zero` and `.requestedTimeToleranceAfter = .zero` is catastrophic for export performance:
- Because it is stateless, requesting frame `59` forces the decoder to seek back to frame `0` (the nearest keyframe) and decode all 60 frames (`0 -> 59`). Requesting frame `60`, `61`, etc. repeats this GOP walk on every single frame!
- For a `1,350`-frame clip, a stateless generator decodes $\approx 1{,}350 \times 30 = \mathbf{40{,}500\text{ 4K frames}}$ and copies each frame from GPU `CVPixelBuffer` $\to$ CPU `CGImage` $\to$ GPU `CIImage` (`~45–50 ms/frame`, or **70 seconds** total).

### Decision
- Use a stateful **Sequential Video Frame Reader** (`AVAssetReader` + `AVAssetReaderTrackOutput` on macOS; `IMFSourceReader` on Windows) that decodes the video stream forward in a single pass (`copyNextSampleBuffer()`).
- Retain only the previous and current decoded `CVPixelBuffer`-backed `CIImage` in memory so timeline speed changes (`0.25x–8.0x`) pick the nearest presentation timestamp without re-decoding.
- Only reset the sequential reader if a timeline cut (`ClipSlice`) jumps backward in source time or jumps forward by more than `3.5 seconds`.
- Sequential hardware decoding into `420v` Metal-compatible pixel buffers takes **`~1.2 ms/frame`** (over **35× faster**).

---

## 4. ADR-04: Baking Static 4K GPU Stencils & Drop Shadows into VRAM Textures

### Problem
In CoreImage (and similar deferred GPU filter graphs), a `CIImage` is **not** a rendered texture—it is a **lazy filter recipe**.
- Caching a `CIImage` variable (such as `shadowBox.applyingGaussianBlur(sigma: 35)` or `CIRoundedRectangleGenerator` for the screen's rounded-corner mask) and reusing that `CIImage` reference across `1,350` frames still forces the GPU to **re-execute the expensive 4K Gaussian Blur and rounded-rectangle generator on every single frame**!
- Furthermore, CoreImage's default intermediate working format is `RGBAh` (64-bit half-float = 8 bytes/pixel), which doubles VRAM bandwidth at 4K.

### Decision
1. Configure the compositor's `CIContext` with `.workingFormat: CIFormat.BGRA8` (32-bit = 4 bytes/pixel).
2. Whenever the **Background Layer**, **4K Gaussian Drop Shadow**, or **Rounded-Corner Stencil Mask** is computed for a given configuration, immediately **materialize (bake)** the `CIImage` recipe into a dedicated GPU-resident `MTLTexture` (`storageMode = .private`, `pixelFormat = .bgra8Unorm`).
3. **Critical Synchronization Rule (`waitUntilCompleted`)**: When baking a stencil or background into an offscreen `MTLTexture` on a separate `MTLCommandBuffer`, always call `cmdBuf.waitUntilCompleted()` (which takes `< 0.8 ms` once at the start of export) before returning the `CIImage(mtlTexture:)`. Otherwise, Frame 0 may sample the texture on another command queue before the blit/render pass finishes, causing the screen layer on Frame 0 to be masked out completely.

---

## 5. ADR-05: Uniform Shortest-Side Padding (`padByRatio`) for `Auto` Aspect Ratio

### Problem
When the user selects the **`Auto` (Recording + Padding)** aspect ratio with a padding ratio $p \in [0, 0.45]$ (default $p = 0.10$) on a `16:10` display (`3456×2170`):
- If `Auto` simply uses the raw source aspect ratio $W / H = 1.6$ and insets horizontal and vertical edges by $p \cdot W$ and $p \cdot H$ independently, the horizontal margin is $1.6\times$ wider than the vertical margin, and a 4K export renders at `3440×2160` (`7.43M` pixels).

### Mathematical Specification
To guarantee **visually uniform padding on all 4 sides** (top, bottom, left, right) in `Auto` mode:
1. Compute the uniform padding thickness $\text{pad}$ from the **shortest side** of the cropped source recording $(W, H)$:
   $$\text{pad} = \min(W, H) \times p$$
2. The effective `Auto` stage aspect ratio is:
   $$\text{aspect}_{\text{auto}} = \frac{W + 2 \cdot \text{pad}}{H + 2 \cdot \text{pad}}$$
   *(For a `16:10` recording with $p = 0.10$, $\text{aspect}_{\text{auto}} = \frac{1.6 + 0.2}{1.0 + 0.2} = 1.5$, producing an exact **`3226×2160`** 4K frame—7% fewer pixels to encode and identical margin thickness on all 4 edges).*
3. Inside the compositor, given any target canvas $(C_w, C_h)$ and shortest side $S = \min(C_w, C_h)$, the uniform inset margin on all 4 sides of the stage is:
   $$m = \frac{S - \frac{S}{1 + 2p}}{2}$$

---

## 6. ADR-06: Telemetry Clock Synchronization (`t = 0`), Spring Phase-Lag Lookahead & Drag Acceleration

### Problem
Two subtle timing issues can make a spring-smoothed cursor feel "floaty" or out-of-sync with the recorded screen video:
1. **Capture Startup Offset (`50–200 ms`)**: Global mouse/keyboard event taps (`CGEventTap` / `NSEvent`) start recording immediately at `t = 0`, whereas `ScreenCaptureKit` (`SCStream`) takes `50–200 ms` to deliver the very first video frame (`PTS = 0.0s`). Without synchronization, every cursor move and click in the video appears shifted relative to the UI reactions on screen.
2. **Spring Steady-State Phase Lag ($\tau = c / k$)**: A damped spring ODE $m \ddot{x} + c \dot{x} + k(x - x_{\text{target}}) = 0$ tracking a moving cursor at constant velocity $v_0$ trails behind the true cursor by a steady-state time lag of $\tau_{\text{lag}} = \frac{c}{k}$ seconds (e.g. `40–75 ms`). During fast text-selection drags or button clicks, the smoothed cursor visibly lags behind the highlighted text or button press on screen.

### Solution
1. **First-Frame Telemetry Anchor**: When `SCStream` delivers its first video `CMSampleBuffer`, record its system uptime $t_{\text{firstFrame}}$ and shift all telemetry timestamps by $\Delta t = t_{\text{firstFrame}} - t_{\text{tapStart}}$ so `t = 0.0 ms` in `cursor.jsonl`, `clicks.jsonl`, and `keys.jsonl` aligns 1:1 with video frame `0`.
2. **Lookahead Phase-Lag Compensation**: When sampling the raw cursor trajectory to feed the 120Hz spring solver at time $t$, sample the raw cursor position at lookahead time:
   $$t_{\text{sample}} = t + \min\left(75\text{ ms},\; \frac{c}{k} \times 1000\text{ ms}\right)$$
   This cancels out the steady-state phase lag of the spring filter so the smoothed cursor arrives at buttons and hover targets at the exact millisecond the underlying screen UI reacts.
3. **Active Mouse-Down / Drag Speed Multiplier ($s = 1.85$)**: While the mouse button is held down (e.g. dragging a window or selecting text), scale the spring constants by $k_{\text{eff}} = k \cdot s^2$ and $c_{\text{eff}} = c \cdot s$ ($s = 1.85$) to preserve the exact damping ratio $\zeta$ while locking the cursor tightly to the dragged element.

---

## 7. ADR-07: Zero-Overhead 120Hz Playback, Pure AppKit/Retained-Layer Tooltips & `.hover-magnet` Physics

### Problem
During 60/120Hz video preview playback, two UI interactions previously caused frame drops:
1. **Rapidly hovering across toolbar/timeline buttons**: Presenting a floating `NSPanel` containing a SwiftUI `NSHostingView` triggered cross-window SwiftUI `AttributeGraph` layout locks (`~8–15 ms`), causing playhead and video judder.
2. **Overlapping `AVPlayer.seek` calls & `CIZoomBlur`**: Calling `player.seek(to:)` at 120Hz before the previous seek completed stalled the hardware decoder; meanwhile CoreImage's built-in `CIZoomBlur` filter took `~35 ms/frame` at Retina resolution.

### Solution
1. **Pure AppKit / Direct2D Tooltip Rendering**: `SharedFloatingTooltipWindowController` uses a 100% pure AppKit `NSView` (`TooltipContentView`) with zero `NSHostingView`, rendering in `< 0.02 ms` without touching SwiftUI's `AttributeGraph`.
2. **Retained-Layer `.hover-magnet` Button Physics (`HoverMagnetTrackingNSView`)**:
   - Every toolbar, quick-dock, header, and rail button uses an AppKit `NSTrackingArea` + `CALayer` driven by a 120Hz 1D spring solver (`stiffness = 1500, damping = 100, mass = 2`, magnetic pull `±2pt`, escape multiplier `10x`, entry scale `0.8 -> 1.0`, `masksToBounds = false`).
   - When the cursor enters a button from any angle (e.g. top-right), the highlight layer starts `22pt` outside in that exact direction and flies into the button, tracks the cursor magnetically while inside, and flies out along the exit vector when leaving—all with **zero SwiftUI `@State` mutations**.
   - When a modal overlay (`Export Settings`, `Command Menu`, `Export Still Frames`) is open, `\.isTooltipAndHoverBlocked` suspends `NSTrackingArea`s on background views so hovering modal buttons never triggers tooltips from underlying editor controls.
3. **3-Tap Radial Shutter Blend & Seek Gating**:
   - Gate `AVPlayer.seek` with an `isDecoderSeeking` flag during scrubbing, and replace `CIZoomBlur` with a 3-tap radial scale/alpha blend (`< 0.4 ms/frame` on Metal).
   - Isolate 120Hz playhead observation into dedicated leaf views (`TimelinePlayheadsOverlayView`, `LivePlayheadTimecodeTextView`) so the main timeline body never re-evaluates during playback.

---

## 8. ADR-08: Floating Callout Tooltip Geometry (Boolean CSG Fillet Union & Window Sharing Inheritance)

### Problem
1. Drawing a rounded rectangle tooltip bubble and a pointer arrow (caret) as separate shapes or manual quadratic curves often produces a faint 1px seam or broken/dashed line artifact at the neck of left/right arrows.
2. If the tooltip panel has a fixed `sharingType = .none`, users cannot capture tooltips in screenshots of the Editor window; conversely, if `sharingType = .readOnly`, tooltips hovered on the `RecordingHUDPanel` during an active screen recording would leak into the recorded video!
3. If the tooltip panel uses `.popUpMenuWindow` level (`101`), it renders *behind* the `RecordingHUDPanel` (`.screenSaver` level = `1000`).

### Solution
1. **CSG Boolean Path Union with Stroke Filleting (`BubbleShape.outline`)**:
   - Construct `bodyPath` (`cornerRadius = min(w/6, h/6, 6.67pt)` inside a `7.0pt` margin) and `caretPath` (`reach = 5.8pt`, `tipRadius = 2.0pt`, overlapping deep into `bodyRect`).
   - Compute `clippedCaret.union(bodyPath, using: .winding)`, then apply rounded stroke-union/subtraction CSG (`strokeWidth = 9.0pt` outer fillet, `4.0pt` inner fillet) to produce a single mathematically seamless `CGPath` used both as `NSVisualEffectView.maskImage` and for the `1px` inner border stroke.
2. **Dynamic `sharingType` & Window Level Inheritance**:
   - Whenever a tooltip is shown for an `ownerView`, mirror its window's sharing policy:
     ```swift
     panel.sharingType = (ownerWindow.sharingType != .none) ? .readOnly : .none
     panel.level = NSWindow.Level(rawValue: max(baseLevel, ownerWindow.level.rawValue + 1))
     ```
   - Tooltips on the Project Editor (`sharingType != .none`) appear in macOS screenshots (`⇧⌘4`), whereas tooltips on the Recording HUD (`sharingType == .none`) remain 100% invisible to `ScreenCaptureKit`.

---

## 9. ADR-09: Value-Type Atomic Undo/Redo Snapshots & Non-Overlapping Track Clamping

### Problem
1. If deleting the last segment on a track (e.g. the last `Shortcut` keycap segment) calls `mutate { ... }` to delete the segment and then calls a second `mutate { ... }` to remove the now-empty track, pressing `⌘Z` once only restores an empty track, requiring a second `⌘Z` to restore the segment.
2. Overlapping segments on the same Zoom or Shortcut track cause ambiguous camera targets or overlapping keycap animations.

### Solution
1. **Single-Mutation Atomic Transactions**: Every user action must perform both segment deletion and empty-track cleanup inside a **single `mutate { doc in ... }` closure** so `undoStack` records exactly one atomic snapshot per user action.
2. **Strict Non-Overlapping Track Clamping**: Moving, resizing, duplicating, or inserting a Zoom or Shortcut segment clamps its `[startMs, endMs]` against the immediate left and right neighbors on the same track (`0 ms` overlap). Moving a segment body strictly preserves its duration (`endMs - startMs`).

---

## 10. ADR-10: Mip-Pyramid + Catmull-Rom Spline Audio Waveforms & Dynamic Fixed-Interval Ruler

### Problem
1. Drawing raw audio samples as vertical bars on a zoomed-out NLE timeline causes visual aliasing/flicker when resizing slices, and re-scanning thousands of audio samples per frame is slow.
2. Scaling timeline ruler tick intervals linearly with clip speed makes ruler labels crowded or uneven.

### Solution
1. **Multi-Level Mip-Pyramid + Catmull-Rom Cubic Spline Waveform**:
   - Precompute a power-of-two min/max envelope pyramid from the audio track once on load.
   - At render time, select the pyramid level matching `pxPerBin = 5.0 pt` and interpolate the envelope peaks with a **Catmull-Rom cubic spline** filled with a vertical gradient (`#4D2FF5`, top `0.50` $\to$ bottom `0.25` opacity).
2. **Fixed-Step Time Ruler**:
   - Select the first human-friendly time step from `[100ms, 250ms, 500ms, 1s, 2.5s, 5s, 10s, 15s, 30s, 1m, 2.5m, 5m, 10m, 15m, 30m, 1h]` whose spacing is $\ge 200\text{ px}$ at the current timeline zoom, with 3 minor sub-ticks between major labels.

---

## 11. ADR-11: WYSIWYG 3D Keycap Overlay & Non-Linear Export File Size / Live ETA Estimation

### Problem
1. If 3D keyboard shortcut badges are rendered only as a SwiftUI view over the preview player, exported MP4/ProRes/GIF files will either miss the keycaps or have mismatched fade/slide animations.
2. Estimating export file size linearly (`width * height * fps`) overestimates 4K file sizes by 2x, and updating export progress without yielding to the main RunLoop freezes the live `elapsed • time left` countdown.

### Solution
1. **Shared Deterministic Transition Envelope (`shortcutTransitionEnvelope`) + Pass 6 Sprite Cache**:
   - Both the SwiftUI Preview overlay and `MetalFrameCompositor` Pass 6 share the exact same cubic smoothstep (`3t^2 - 2t^3`) transition envelope (`150ms` fade-in, `180ms` fade-out, scale `0.95 -> 1.0`, and directional slide).
   - `MetalFrameCompositor` caches rasterized 3D keycap `CIImage` sprites by key/style identifier (`keycapSpriteCache`) so Pass 6 composites them on the GPU in `< 0.1 ms/frame`.
2. **Power-Law Bitrate Estimator & 80ms RunLoop Yield**:
   - Scale estimated MP4 bitrate sub-linearly with resolution and frame rate:
     $$\text{bitrate} = \text{bpp}_{\text{ref}} \cdot (1920 \times 1080) \cdot 60 \cdot \left(\frac{W \cdot H}{1920 \times 1080}\right)^{0.78} \cdot \left(\frac{\text{fps}}{60}\right)^{0.57}$$
   - During export, yield to the main RunLoop (`Task.sleep(for: .milliseconds(1))`) every `80 ms` so the live elapsed timer, remaining ETA countdown, Dock progress bar, and instant `Stop export` button stay silky-smooth at 60fps.

---

## 12. ADR-12: Incremental Camera-Only 120Hz Spring Rebuild & Zero-Blur Timeline Segment Dragging

### Problem
Moving or resizing a Zoom segment on the NLE timeline fires mouse drag updates at 60–120Hz. If every drag pixel:
1. Re-solves the entire 120Hz Cursor Trajectory (`cursorStates`) from scratch even when `document.cursor` has not changed,
2. Recomputes `CursorMovesGroup.timeWeightedCenter01` inside the 120Hz camera integration loop on every `8.33 ms` step instead of once per group,
3. Integrates 4 Loupe springs (`32` substeps/step) even when the project contains no Loupe zoom segments, and integrates settled springs (`current == target && velocity == 0`) without an early-out,
4. Re-scans `keyEvents` for typing suggestions and shortcut clusters on every SwiftUI view evaluation, and
5. Uses an offscreen Gaussian `.blur()` filter inside each timeline segment view or allows `.onContinuousHover` to scrub the ghost playhead during active drags,
then timeline segment dragging/resizing drops to ~20–30fps on the main thread.

### Solution
1. **Cursor Trajectory Reuse (`reusingCursorStates`)**:
   - When only `document.timeline.zooms` or `document.motion` changes (`document.cursor == lastSolverCursorConfig`), pass the existing solved `cursorStates` into `SpringTrajectorySolver` to skip 100% of cursor physics, binary searches, and click/drag interval scans.
2. **Up-Front `ResolvedFocusGroup` Centroids, Settled Spring Fast-Path & Conditional Loupe Integration**:
   - Compute each `CursorMovesGroup`'s time-weighted centroid once when partitioning groups (`buildMovesGroupsForZoom` using $O(\log N)$ binary search on `cursorEvents`).
   - Precompute $\omega_0 = \sqrt{k/m}$ and $c_{\text{crit}} = 2\sqrt{km}$ outside the 120Hz loop, early-exit `stepClampedSpring` in $O(1)$ whenever $|x_{\text{target}} - x| < 0.0004 \land |v| < 0.0004$, and skip the 4 Loupe springs entirely when `!hasAnyLoupeZoom`.
3. **Memoized Telemetry Derivations & Smooth Gaussian-CDF Inner Glow (`SegmentBodyCanvas`)**:
   - Cache `activeTypingSuggestions` and `detectedShortcutClusters` on `ProjectSession` (invalidated only when `slices`, `dismissedTypingSuggestionStarts`, or `captions` change).
   - Render timeline segment inner edge glows (`radiusPx = 10`, `GLOW_SPREAD_PX = 3`, `GLOW_SIGMA_PX = 7.5`) using 4-edge multi-stop Gaussian-CDF `LinearGradient`s (`SegmentBodyCanvas`), eliminating both offscreen Gaussian `.blur()` buffer allocations during resize and sharp concentric stroke step boundaries.
   - Show edge resize handle capsules (`3 pt` width, `9 pt` vertical inset, `6.5 pt` horizontal inset on standard segments; adaptively scaled down to `2.4 pt` width and `>= 2.2 pt` inset on minimum-width segments) **only on hover or active edge resize** (`isHovered || activeDragMode == .resizeLeft || activeDragMode == .resizeRight`) with no minimum segment width cutoff (`segWidth >= 10 pt` and adaptive `edgeHitWidth = min(13, max(5.5, segWidth * 0.34))` plus `-3 pt` hit slop), ensuring even a minimum-duration segment always exposes left-resize, center-move, and right-resize zones. Dim sibling segments on the same track (`opacity = 0.30`) when a segment editor is open, and clear any active segment selection (`clearTimelineSelection()`) when clicking empty timeline space or pressing `Escape`.
   - **Important SwiftUI `ZStack(alignment: .leading)` Coordinate Anchor Invariant**: Every timeline track lane `ZStack` whose children are positioned via `.offset(x:)` **MUST** include a full-width `Color.clear.frame(width: contentWidth, height: rowHeight).contentShape(Rectangle())` anchor child inside the `ZStack`. Without a full-width child inside the `ZStack`, SwiftUI sizes the inner `ZStack` to the widest non-offset child (a single segment's width) and centers that narrow `ZStack` inside the outer `.frame(width: contentWidth)`, shifting all `.offset(x:)` segment coordinates, `.onContinuousHover(coordinateSpace: .local)`, and `DragGesture` hit-testing by `(contentWidth - maxSegmentWidth) / 2`!

---

## 13. ADR-13: 100% On-Device Camera, Microphone, Filmic Color Grading, Captions & Transcript-Driven Video Cutting

### Problem
Users need studio-grade webcam layouts (`Camera overlay`, `Split screen`, `Camera cutout`), 12 filmic color-grading looks + sharpen + crop + face tracking, microphone audio presets (`Off`, `Standard`, `Loud`, `Noise reduction`, `Podcast`), animated word-timed captions, and text-based video editing (`Edit by transcript` with filler-word and pause removal) **without** sending any video or audio to external cloud servers.

### Solution
1. **Multi-Track Capture (`ScreenCaptureEngine`), Floating Live Camera Bubble & HUD Menu-Dismiss Drag Guard**:
   - Capture the display/window via `ScreenCaptureKit` (`display.mp4`) while simultaneously running an `AVCaptureSession` on a dedicated `avDeviceQueue` to record the selected webcam (`webcam.mp4`) and microphone (`microphone.m4a`) with pause-offset timestamp synchronization (`adjustSampleBufferTime`). Ensure `com.apple.security.device.camera` and `com.apple.security.device.audio-input` entitlements are present so `AVCaptureVideoPreviewLayer` and `AVCaptureDeviceInput` receive live camera frames.
   - Display a borderless, non-activating `DraggableHUDPanel` with `sharingType = .none` and `hasShadow = false` for `Show camera preview`, rendering the squircle-clipped `AVCaptureVideoPreviewLayer` and its rounded `shadowPath` inside `LiveCameraPreviewHostNSView` so macOS WindowServer never draws a rectangular black shadow outline outside the rounded corners.
   - Guard `DraggableHUDPanel.sendEvent` with `isTrackingLeftClick` and a `150 ms` post-`NSMenu` dismissal cooldown (`lastHUDMenuClosedUptime`), and set `isMovableByWindowBackground = false` so clicking from an open HUD context menu (e.g. Microphone) onto another HUD button (e.g. Camera) never computes a synthetic window drag delta `currentMouse - previousMouseDownScreenPoint` that jumps the HUD horizontally.
2. **12 GPU Filmic Camera Looks, Vision Face Tracking & Person Cutout (`LocalOnDeviceMediaIntelligence`)**:
   - Implement the 12 filmic camera looks (`Studio`, `Cinema`, `Film`, `Golden`, `Cream`, `Terra`, `Moody`, `Arctic`, `Neon`, `Punch`, `Fade`, `Mono`) + `CISharpenLuminance` via cached GPU CoreImage pipelines, and use macOS `Vision` (`VNDetectFaceRectanglesRequest` and `VNGeneratePersonSegmentationRequest`) 100% on-device.
   - Dynamically scale the webcam PiP during active zoom segments (`1.0 - (1.0 - scaleWhenZoomed) * zoomProgress01`) so the webcam shrinks smoothly when the main screen zooms in.
3. **On-Device Speech Recognition (`SFSpeechRecognizer`), On-Demand Open-Source Whisper Model Downloader & Non-Destructive Transcript Slice Cutting**:
   - Support both Apple's built-in on-device speech engine (`SFSpeechRecognizer` with `requiresOnDeviceRecognition = true`) and on-demand open-source OpenAI Whisper GGML models (`Base` 142MB, `Small` 466MB, `Medium` 1.5GB via `WhisperModelDownloadManager`).
   - Before downloading any Whisper model, present an explicit user confirmation dialog (`NSAlert`), display a live MB/percentage progress bar with a `Cancel` button during download, and render a green checkmark badge (`checkmark.circle.fill`) with an instant tooltip showing which Whisper model is downloaded locally.
   - Cutting words or tightening pauses (`>= 800ms` trimmed down to a `200ms` natural breath) in `Edit by transcript` splits or trims `document.timeline.slices` non-destructively inside a single `mutate` block, keeping cut words visible as strikethrough tokens that can be restored in one click (`Restore` or `⌘Z`).
4. **Thread-Safe `AVCaptureSession` Handoff (Zero `AVCaptureVideoPreviewLayer` Mutation During `startRunning`), Zero-Based `webcam.mp4` Timestamps & Safe-Area Window Sizing**:
   - **Critical `AVCaptureSession_Tundra` Concurrency Invariant**: Never attach or mutate an `AVCaptureVideoPreviewLayer(session:)` on the main thread while `session.startRunning()` is concurrently executing on a background queue—doing so mutates `AVCaptureSession`'s internal `connections`/`outputs` `NSMutableArray` while `-[AVCaptureSession_Tundra _setRunning:]` is enumerating it (`NSGenericException: Collection <__NSArrayM> was mutated while being enumerated`). Instead, await `stopSessionAndWait()` on the pre-recording preview session before starting `ScreenCaptureEngine`, and during active recording feed the floating camera preview window via `ScreenCaptureEngine.onWebcamFrameCaptured` (`recordedFrameLayer.contents = cgImage`) with zero concurrent `AVCaptureVideoPreviewLayer` attachment.
   - Normalize `webcam.mp4` / `microphone.m4a` sample buffer timestamps to start at `CMTime.zero` (`adjustSampleBufferTime(bySubtracting: webcamFirstPTS)`) so the Editor's `RealRecordedWebcamVideoView` (`AVPlayerLayer` + `AVVideoComposition`) seeks and plays in exact lockstep with `sourceTimeMs = 0 .. durationMs`.
   - Open every project Editor `NSWindow` maximized to `screen.visibleFrame` by default, keep `NSHostingController.safeAreaRegions` intact with `.ignoresSafeArea(.container, edges: .top)` and explicit `minHeight` on the center workspace so resizing the window to `minSize` never clips the top header bar, and hide `window.toolbar?.isVisible = false` in `windowWillEnterFullScreen` so green-button native full-screen mode never shows a top gray toolbar strip.
   - Never call `hosting.layoutSubtreeIfNeeded()` inside `RecordingCoordinator.currentDesiredPanelSize` (`fittingSize` queries layout automatically without triggering `_NSDetectedLayoutRecursion`).



