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
14. [ADR-14: Recording Integrity, Decoder-Clocked Playback & Export/Preview Parity](#14-adr-14-recording-integrity-decoder-clocked-playback--exportpreview-parity)
15. [ADR-15: Menu Bar Command Routing](#15-adr-15-menu-bar-command-routing)
16. [ADR-16: Light / Dark Appearance & Settings Window](#16-adr-16-light--dark-appearance--settings-window)

---

## 1. ADR-01: Hybrid Parallel Video Encoding (Hardware ASIC + Multi-Core CPU)

### Problem
When exporting a 22.5-second 4K (`3226×2160` @ 60fps = `1,350` frames) project to `H.264` MP4 on Apple Silicon:
- The **Metal GPU Compositor** renders all 6 visual passes in just `~2.7 ms/frame` (`~3.6 seconds` total for 1,350 frames, or **~375 fps**).
- However, a single hardware `AVAssetWriter` / `VTCompressionSession` (`H.264` Hardware Media Engine) takes **`18.2 seconds`** to finish because the physical H.264 ASIC block on Apple Silicon has a fixed hardware throughput ceiling of **~74 fps at 4K**.
- Spawning 2 or 4 hardware `H.264` sessions in parallel yields the exact same `18.3s` runtime because they all queue into the same physical H.264 Media Engine silicon block, while the multi-core CPU sits at `< 5%` utilization.

### Decision & Architecture
For `H.264` MP4 exports, NativeScreen uses a **Hybrid Parallel GOP Encoder** (`exportMP4VideoFileHybrid`):
1. The timeline is partitioned into **2-second closed GOPs** (`fps * 2` frames) with a forced keyframe at the start of each GOP.
2. Two **encoder lanes** run at the same time, each on a *different* GOP, each with its own decoder (`ExportFrameSource`) and `VTCompressionSession` (`VTParallelCompressionWorker`):
   - **Hardware lane**: `RequireHardwareAcceleratedVideoEncoder = true`, constant quality (`kVTCompressionPropertyKey_Quality`).
   - **Software lane**: `EnableHardwareAcceleratedVideoEncoder = false`. Apple's software H.264 encoder rejects `kVTCompressionPropertyKey_Quality` (`-12900`), so it runs average-bitrate and is **re-targeted to the hardware lane's measured bitrate** before each GOP (matched quality). It does not start until the hardware lane has produced 30 frames, so its first GOP is already calibrated.
   - Whichever lane is free takes the next GOP, so the split adapts to the machine (no fixed 60/40 ratio).
   - Submitting GOPs to the lanes one after the other does NOT run them in parallel (each lane only overlaps by its in-flight queue). Two GOPs must be in flight at once.
3. GPU rendering is asynchronous: the main actor builds the `CIImage` graph and starts a `CIRenderTask` into the encoder's pool buffer; the lane's serial `workQueue` waits for the GPU and encodes, which also keeps presentation order intact. Decoding runs on each `ExportFrameSource`'s own queue and is prefetched one frame ahead.
4. Encoded samples go to `OrderedEncodedSampleQueue`, which re-orders them and **streams them into the passthrough muxer while encoding** (interleaved with audio). A lane may start at most 3 GOPs ahead of the muxer, so memory is bounded to a few GOPs instead of the whole video.
5. Muxer rules learned the hard way:
   - The two lanes produce different SPS/PPS (`max_num_ref_frames`, VUI, `bottom_field_pic_order_in_frame_present_flag`). `AVAssetWriter` stores them as two `avc1` sample descriptions in one track; AVFoundation and FFmpeg decode it without errors.
   - Hold audio back (to ~1s past the muxed video) only while the video input is ready. If the writer refuses video it is waiting for audio, so audio must keep flowing or the export deadlocks.
   - When a lane finishes a GOP and has to idle (muxer lead limit), call `VTCompressionSessionCompleteFrames` on it, so frames parked in the software encoder's lookahead are emitted and the ordered muxer never waits on them.

### Result
Measured on an M4 Pro with a 43-second 3456×2170 recording exported at 4K/60fps H.264:
- The H.264 Media Engine alone tops out at ~70 fps at this size (`kVTCompressionPropertyKey_RealTime` and `PrioritizeEncodingSpeedOverQuality` make no difference).
- Previous sequential-chunk hybrid: ~35s, peak RSS ~267 MB (grows with video length), worst GOP SSIM 0.9846 vs a ProRes reference (software chunks were encoded at 65% of the target bitrate).
- Parallel lanes: ~25s, peak RSS ~170 MB (bounded), worst GOP SSIM 0.9910, overall SSIM 0.9944 (was 0.9937). Files are ~15% larger because the software GOPs no longer get a lower bitrate.
- Progress is reported from frames encoded by either lane, not frames muxed in order (the in-order count only moves when the slower lane finishes its GOP, which made the bar jump).
- Main thread: no stall over 40ms while encoding (only ~0.8s of setup at export start).
- `HEVC` uses only the hardware lane. `ProRes` and `GIF` use the same background decoder and main-actor pacing (yield every ~8ms, progress at ~30 Hz).

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
2. **Retained-Layer `.hover-magnet` Button Physics (`HoverMagnetTrackingNSView`) & 1:1 Hitbox-to-Highlight Parity**:
   - Every toolbar, quick-dock, header (`Presets`, `Command Menu`, `Undo`, `Redo`, `Show in Finder`, `Remove`), sub-toolbar, transport, and rail button uses an AppKit `NSTrackingArea` + `CALayer` driven by a 120Hz 1D spring solver (`stiffness = 1500, damping = 100, mass = 2`, magnetic pull `±2pt`, escape multiplier `10x`, entry scale `0.8 -> 1.0`, `masksToBounds = false`).
   - When the cursor enters a button from any angle (e.g. top-right), the highlight layer starts `22pt` outside in that exact direction and flies into the button, tracks the cursor magnetically while inside, and flies out along the exit vector when leaving—all with **zero SwiftUI `@State` mutations**.
   - **Strict 1:1 Hitbox-to-Highlight Rule (`.contentShape(...)`)**: In SwiftUI on macOS, `Button`s styled with `.buttonStyle(.plain)` only hit-test opaque text/icon glyphs unless `.contentShape(RoundedRectangle(cornerRadius: ...))` (or `.contentShape(Rectangle())`) is explicitly applied **after** `.padding(...)`, `.frame(...)`, `.background(...)`, and `.overlay(...)` inside the button's `label`. Every interactive button and row across the app must attach `.contentShape(...)` matching its outer visual background/highlight geometry so 100% of the visible highlight area is clickable.
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
2. **12 GPU Filmic Camera Looks, Custom Color Preset Studio, Standalone Camera Crop Window, Vision Face Tracking & Person Cutout (`LocalOnDeviceMediaIntelligence`)**:
   - Implement the 12 filmic camera looks (`Studio`, `Cinema`, `Film`, `Golden`, `Cream`, `Terra`, `Moody`, `Arctic`, `Neon`, `Punch`, `Fade`, `Mono`), user-created `CustomCameraColorPreset` (`Warmth`, `Background pop`, `Contrast`, `Color intensity`), and `CISharpenLuminance` via cached GPU CoreImage pipelines, using real recorded webcam frame thumbnails in the 7×2 `Color grading` grid.
   - Present standalone movable `NSWindow`s (`presentCameraCropWindow` and `presentColorPresetStudioWindow` in `ProjectWorkspaceStore`) with a brighter studio slate backdrop (`rgb(0.19, 0.19, 0.23)`) and soft ambient frame bleed when cropping the camera or creating a custom color preset.
   - In `Camera cutout` layout mode, render a horizontal 3-dot `Camera Position` bar (`CameraCutoutPositionDotBarPicker` for Left / Center / Right), `Camera Size`, collapsible `Camera size during zoom`, `Edge softness` (`CIGaussianBlur` on person segmentation mask), `Edge inset` (`CIMorphologyMinimum`), and `Avoid empty area`.
   - In `Split screen` layout mode (`MetalFrameCompositor.computeSplitScreenGeometry`), partition the stage into `zoomArea` (screen slot) and `cameraRect` (camera slot) with 3 ratio cards (`Auto`, `½ | ½`, and `⅔ | ⅓` or `⅓ | ⅔` when `Flip` is enabled), `Flip` toggle, and `Fill` (`Fullscreen` edge-to-edge with `padPx = 0` and `cornerRadius = 0` unzoomed vs `Padded` with shared project `paddingRatio` around and between screen and camera).
   - Dynamically scale the webcam PiP during active zoom segments (`1.0 - (1.0 - scaleWhenZoomed) * zoomProgress01`) so the webcam shrinks smoothly when the main screen zooms in.
3. **On-Device Speech Recognition (`SFSpeechRecognizer`), On-Demand Open-Source Whisper Model Downloader & Non-Destructive Transcript Slice Cutting**:
   - Support both Apple's built-in on-device speech engine (`SFSpeechRecognizer` with `requiresOnDeviceRecognition = true`) and on-demand open-source OpenAI Whisper GGML models (`Base` 142MB, `Small` 466MB, `Medium` 1.5GB via `WhisperModelDownloadManager`).
   - Before downloading any Whisper model, present an explicit user confirmation dialog (`NSAlert`), display a live MB/percentage progress bar with a `Cancel` button during download, and render a green checkmark badge (`checkmark.circle.fill`) with an instant tooltip showing which Whisper model is downloaded locally.
   - Cutting words or tightening pauses (`>= 800ms` trimmed down to a `200ms` natural breath) in `Edit by transcript` splits or trims `document.timeline.slices` non-destructively inside a single `mutate` block, keeping cut words visible as strikethrough tokens that can be restored in one click (`Restore` or `⌘Z`).
4. **Persistent `WarmCameraCaptureController` (Zero ISP Auto-Exposure Black Flash on Record Start), Zero-Copy `IOSurface` Preview & Safe-Area Window Sizing**:
   - **Persistent Warm Camera Session Across HUD $\to$ Countdown $\to$ Recording**: Stopping a pre-recording preview `AVCaptureSession` and starting a second `AVCaptureSession` when clicking Record powers down the camera sensor ISP and resets Auto-Exposure (AE) to black (`0 EV`), causing both the live preview bubble and the first ~15–25 frames of `webcam.mp4` to turn black and slowly ramp brightness back up. Instead, `WarmCameraCaptureController.shared` maintains a **single continuous `AVCaptureSession`** from the moment a camera is selected in the Recording HUD right through active recording, feeding `LiveCameraPreviewHostNSView` via zero-copy `CVPixelBufferGetIOSurface(sampleBuffer)` (`recordedFrameLayer.contents = ioSurface`, `< 0.01 ms`, zero `AVCaptureVideoPreviewLayer` mutation) and attaching `ScreenCaptureEngine`'s `webcamWriter` to the already-warmed-up stream without restarting the hardware sensor.
   - **Auto-Exposure Safe Format Selection (`configureHighestFrameRateFormat`)**: Configure `AVCaptureDevice` **after** `session.commitConfiguration()`, only assign `device.activeFormat = chosenFormat` when it differs from the current format (avoiding unnecessary ISP resets), set `activeVideoMinFrameDuration` (`1/60s` or `minFrameDuration`), and keep `activeVideoMaxFrameDuration = .invalid` (hardware default) so the camera ISP can lengthen shutter exposure in indoor/evening light instead of underexposing to black.
   - **Bulletproof `webcam.mp4` Encoding (`AVAssetWriterInputPixelBufferAdaptor` + Monotonic `CMTime` + Retained Writer in `finishWriting`)**: Append camera frames via `AVAssetWriterInputPixelBufferAdaptor` with strictly monotonic `CMTime` (`lastAppendedWebcamPTS`) so cold-start `CMFormatDescription` changes or clock jitter never transition `AVAssetWriter` to `.failed`, and retain `wWriter` / `wInput` / `wAdaptor` (and `mWriter` / `mInput`) inside the `finishWriting` completion closure so ARC never deallocates the writer before the `moov` atom is flushed to disk.
   - **Real-Time Device Discovery, Dual-Bar Microphone Metering (`WarmMicrophoneCaptureController`), Dual-Color Clip Waveforms & Multi-Monitor HUD Stability**:
     - Exclude `.deskViewCamera` from camera discovery and observe `AVCaptureDeviceWasConnected` / `AVCaptureDeviceWasDisconnected` to update `connectedCameras` and `connectedMicrophones` live.
     - Compute real-time PCM RMS/peak audio levels in `WarmMicrophoneCaptureController.shared` to drive a 2-bar meter in the HUD (`liveMicrophoneLevel01` bright instantaneous bar + `liveMicrophonePeakHold01` dimmer slow-decay trailing bar).
     - Extract and render two distinct waveforms on timeline Clip segments: purple (`#4D2FF5`) for system/app audio (`audioWaveformSamples` from `display.mp4`) and translucent white (`Color.white.opacity(0.44 -> 0.20)`) for recorded microphone audio (`microphoneWaveformSamples` from `microphone.m4a`), while synchronizing `micPlayer` (`AVPlayer`) with `player` in `MetalPreviewView`.
     - Keep `hudPanel.sharingType = .readOnly` when idle (so system screenshots can capture the HUD) and switch `hudPanel.sharingType = .none` during active recording; round `hudPanel` widths to even integers (`ceil(w / 2.0) * 2.0`) with `floor(midX - width * 0.5 + 0.5)` and avoid 1Hz resize calls during recording so negative-coordinate secondary monitors (`x < 0`) never drift left.
   - Open every project Editor `NSWindow` maximized to `screen.visibleFrame` by default with `window.collectionBehavior = [.fullScreenNone]` (so the green traffic light button displays `+` Zoom / `Move & Resize` instead of entering a separate full-screen space), and strictly enforce a minimum window size of `1280 × 780 pt` via `.frame(minWidth: 1280, minHeight: 780)`, `hostingController.sizingOptions = [.minSize]`, `window.minSize`, and `windowWillResize(_:to:)`.
   - Never call `hosting.layoutSubtreeIfNeeded()` inside `RecordingCoordinator.currentDesiredPanelSize` (`fittingSize` queries layout automatically without triggering `_NSDetectedLayoutRecursion`).
5. **Camera Motion Blur Compute Shader & Discontinuity-Free Camera Unzoom Settling (`EffectKernels.swift`, `MetalFrameCompositor.swift`, `SpringTrajectorySolver.swift`)**:
   - **Root Cause of End-of-Clip / Post-Zoom Stuck Blur**:
     1. In `AutoZoomClusterGenerator.generateZooms`, auto-generated zoom blocks were previously capped at `durationMs - 500.0` (500ms before the end of the recording). However, the default camera spring (`stiffness: 170, damping: 50, mass: 3.0`, $\omega_0 \approx 7.53\text{ rad/s}$) takes **`~750ms`** to settle within `< 1.0px/frame` (`< 0.002` normalized units). With only 500ms of tail margin, at `t = durationMs` the camera was still actively zooming out (`scale = 1.028`, edge velocity `~3.8px/frame`).
     2. In `SpringTrajectorySolver.init`, when `solvedScale` (`rectW`) settled to `1.0` slightly before `rectX` and `rectY` finished settling to `0.0`, the branch `else if solvedScale > 1.0001 { ... } else { solvedCenter01 = .center }` abruptly snapped `solvedCenter01` from `(0.5 - rectX, 0.5 - rectY)` to `(0.5, 0.5)` in a single 8.33 ms step.
   - **Solution**:
     1. Enforce a **`durationMs - 800.0` ms** tail margin on all auto-generated zoom blocks in `AutoZoomClusterGenerator.generateZooms` (including `extendForTyping` and `minZoomDurationMs` extensions) and use spring settling `precision = 0.002` in `stepClampedSpring`, guaranteeing that every default auto-zoom has 100% settled to rest (`1.0x`, `0.0px/frame`) before the end of the recording.
     2. Always compute `solvedCenter01 = ((0.5 - rectX) / solvedScale, (0.5 - rectY) / solvedScale)` smoothly for all `solvedScale >= 1.0` in `SpringTrajectorySolver` so `center01` never snaps when `rectW` reaches `1.0`.
     3. Replace CoreImage's `CIMotionBlur` and 3-tap ghosting approximation with a runtime-compiled Metal compute kernel (`cameraMotionBlur` in `EffectKernels`) that averages, per pixel, what passed under it while the shutter was open between `rectPrev` and `rectNow` (see `spec/03` Pass 5A), and suppress shutter motion blur when paused at the final settled frame of the timeline (`playheadTimelineMs >= totalTimelineDurationMs - 16.7`).
     4. When playback reaches `totalTimelineDurationMs` in `MetalPreviewView`, explicitly seek the video decoder (`seekDecoderCoalesced(toSourceMs: finalSourceMs, fastSkim: false)`) so the final frame settles crystal-clear.
6. **Frozen Ruler Duration During Clip Resize (`frozenPlaybackDurationMs`), Safe Trim/Cut Teardrop Badges (`computeClipTrimAndCutBadges`), Flicker-Free Split Mode Cursor, Bottom-Center Toast Pill & `⌘S` Save**:
   - **Frozen Timeline Scale During Clip Resize**: Capture `session.frozenPlaybackDurationMs = max(1000.0, timeMapper.totalTimelineDurationMs)` in `beginInteractiveEdit()` and clear it in `endInteractiveEdit()`, so dragging a clip resize handle never rescales or shifts the ruler ticks mid-drag.
   - **Safe Trim & Cut Teardrop Badges (`CutBoundaryTeardropBadgeView`)**: Replace the unsafe `ForEach(Array(mappedSlices.dropLast().enumerated()), id: \.element.slice.id)` (which crashed with `Index out of range` at `mappedSlices[idx + 1]` when SwiftUI reconciled stale `idx` closures during slice splitting/merging) with `computeClipTrimAndCutBadges()`. Render golden teardrop badges with trimmed duration labels (`0.6s`, `4s`, `2m`) and `Undo trim` / `Join clips` actions for leading trims, inter-slice trimmed gaps / cuts, and trailing trims.
   - **Flicker-Free Split Mode Cursor**: Remove the 60Hz `TimelineView` vertical wiggle (`baseWiggleY`) and per-pixel `@State private var lastHoverLocalX` mutation (which previously forced `NSHostingView` to invalidate cursor rects on every frame and reset the cursor to `NSCursor.arrow`), set `enclosingScrollView.documentCursor = isSplitMode ? .crosshair : nil` in `HorizontalScrollViewIntrospector`, and register native AppKit cursor rects in `RightClickCatcherNSView.resetCursorRects()`.
   - **Bottom-Center Toast Banner, `⌘S` Save & `"Native Screen"` Menu Bar Title (`PRODUCT_NAME = "Native Screen"`)**: Present a dark purple pill toast (`Copied to clipboard`, `Project saved`, `Zoom range copied`, `The part you want to cut is too short`, etc.) at the bottom center of the Editor window (`activeToastMessage`), support `⌘S` to save immediately with `"Project saved"`, store projects in `~/Native Screen Projects`, and set `PRODUCT_NAME = "Native Screen"` + `INFOPLIST_KEY_CFBundleName = "Native Screen"` so the macOS menu bar title next to `` displays `"Native Screen"`.
7. **On-Device Sensitive Data OCR (`VNRecognizeTextRequest`), Face Blur (`VNDetectFaceRectanglesRequest`), Presets Store, Camera Layouts Track, Voiceovers Track & Multi-Track Audio Mixdown**:
   - **On-Device Sensitive Data OCR & Face Blur**: Scan sampled video frames with `VNRecognizeTextRequest` (matching emails, phone numbers, credit card numbers, API keys/tokens, and user-entered `sensitiveDataCustomPhrases`) and `VNDetectFaceRectanglesRequest` (`Hide faces`), merging spatially and temporally adjacent bounding boxes into tracked `MaskItem`s (`isAutoSensitiveMask` / `isAutoFaceMask`) on the timeline.
   - **Presets Store (`ProjectPresetsStore`)**: Persist reusable project presets as JSON files in `~/Library/Application Support/NativeScreen/Presets/`, exposing `✨ Presets ⌄` in the top header bar with `"Matches project"` and `"Default"` badges, inline rename, `"Update to match currently edited project"`, and `"Use as default for new projects"` (applied automatically in `RecordingCoordinator` when creating new recordings).
   - **Camera Layouts Track & Dedicated Layout Segment Editor (`CameraLayoutSegment`)**: Support per-segment layout overrides (`Camera overlay`, `Split screen`, `Camera cutout`, `Fullscreen camera`, `Only screen`) with per-segment `overlayPosition01` and `cutoutPositionX01`, evaluated in both `PreviewCameraAndCaptionsOverlayView` and `MetalFrameCompositor`.
   - **Voiceovers Track, Translucent White Waveforms, On-Demand Background Music Synthesis & Multi-Track Audio Mixdown (`HardwareVideoExporter.buildMultiTrackAudioReaderAndOutput`)**: Record live microphone voiceovers (`AVAudioRecorder`) or import audio files onto the `Voiceovers` track with `Independent` / `Synchronized` attach modes, `Hide & Mute original recording`, and translucent white Catmull-Rom waveforms (`voiceoverWaveformSamplesByID`) matching the Clip microphone waveform. Synthesize built-in 16-second stereo 44.1kHz PCM `.wav` backing tracks strictly **on demand** in a background task (`Task.detached`) only when the user clicks a track (`selectBuiltInBackgroundTrack`), displaying a smooth fade-in loading spinner (`loadingBackgroundAudioTrackName`) right inside the selected track pill button with `0.0 ms` main-thread blocking and zero startup overhead when background music is unused.
   - **Deadlock-Free `AVAssetWriter` Video + Audio Interleaving During MP4/ProRes Export**: When an `AVAssetWriter` is configured with both a video `AVAssetWriterInput` (`muxInput`) and an audio `AVAssetWriterInput` (`muxAudioInput`), Apple's MP4/MOV muxer requires media samples across tracks to be appended in roughly interleaved presentation-time order. Appending all video frames in a blocking `while !muxInput.isReadyForMoreMediaData` loop before feeding any audio samples causes `AVAssetWriter`'s internal interleave buffer to fill up after ~1.5s and set `muxInput.isReadyForMoreMediaData = false` indefinitely (hanging export at 96%). Instead, drain ready video samples (`while !isVideoDone && muxInput.isReadyForMoreMediaData`) and ready audio samples (`while !isAudioDone && aInput.isReadyForMoreMediaData`) inside a single combined loop until both streams reach EOF.
   - **Contextual Sidebar Tab Disabling with Hover-When-Disabled Tooltips (`inspectorTabAvailability` & `allowHoverWhenDisabled`)**: Disable sidebar navigation tabs whose underlying recording data is absent (`Cursor` when `cursorEvents.isEmpty` $\to$ `"There is no mouse cursor recorded"`, `Camera Layout` when `!hasRecordedCamera` $\to$ `"No camera recorded"`, `Camera Style` when `!hasRecordedCamera` or `!camera.enabled` $\to$ `"Camera is hidden (see Camera Layout)"`, `Captions` / `Edit by transcript` when `!hasRecordedMicrophone` $\to$ `"No microphone recorded"`, and `Keyboard Shortcuts` when no shortcuts exist $\to$ `"No keyboard shortcuts during recording"`), while keeping `allowHoverWhenDisabled = true` on `HoverMagnetTrackingNSView` so hovering a disabled tab still animates a subtle directional `.hover-magnet` highlight (`0.48x` opacity) and displays the explanatory tooltip.
   - **GPU-Cached Metallic Device Mockup Bezels (`renderDeviceMockupBezel`)**: Rasterize high-DPI vector anodized aluminum/titanium device frames (`MacBook Pro 16"`, `MacBook Air 15"`, `iPhone 16 Pro`, `iPad Pro 13"`) with even-odd screen cutouts and camera notch / Dynamic Island, materializing the bezel into a VRAM `MTLTexture` (`cachedDeviceBezelImage`) so Pass 3 composites it in `< 0.05 ms/frame`.

---

## 14. ADR-14: Recording Integrity, Decoder-Clocked Playback & Export/Preview Parity

### Problem
- Recordings were plain MP4s: a crash, force-quit or power loss mid-recording left files with no `moov` atom (several real projects were lost this way).
- Pause/resume subtracted the gap between the first frame *after* pausing and the first frame *after* resuming. The capture stream only delivers frames when the screen changes, so on a still screen that gap differs from the wall-clock pause the telemetry recorder subtracts, shifting cursor and clicks against the video after every pause. Audio read the pause state from another queue without synchronization.
- The preview playhead advanced on the wall clock with a 50ms clamp, so any main-thread hitch lost timeline time while the decoder kept playing (up to 180ms cursor/video drift, then a hard seek).
- Export composited a still 240px webcam image and a single caption word instead of what the preview shows.
- Views that read the playhead in their body (Inspector transcript/masks/cursor sections) were re-evaluated 120 times a second during playback.
- Any `CursorConfig` change, including draw-only fields like size, re-solved the whole cursor trajectory, and the solver scanned every click and drag at every 120Hz step.

### Solution
1. **Fragmented recording**: every capture writer (screen, webcam, microphone) sets `movieFragmentInterval = 2s`. A killed recorder leaves a playable file up to the last fragment (verified with `kill -9`); `finishWriting` defragments as before.
2. **One pause timeline**: `RecordingCoordinator` passes the same `systemUptime` to `ScreenCaptureEngine.setPaused(_:atUptime:)` and `TelemetryRecorder.setPaused(_:atUptime:)`. The engine stores pause intervals on the host clock behind a lock, drops any sample whose host PTS falls inside a pause, and subtracts the total pause time before it, for screen, system audio, webcam and microphone alike.
3. **Decoder-clocked playback with an anchored start**: on Play (and on a cut-boundary re-sync) the preview calls `AVPlayer.setRate(_:time:atHostTime:)` with the current source time and *now* (`automaticallyWaitsToMinimizeStalling = false`) instead of `seek` + `rate`. The player's timebase is anchored immediately, so the playhead, cursor and zoom move from the very first frame and decoded frames catch up with the timebase 1-6 frames later. The mic, voiceover and webcam-bubble players are anchored the same way, so they start on the same frame. The playhead follows the anchored clock (`itemMs + (now - hostSec) * rate`) mapped through `NLETimeMapper.timelineTime(forSourceMs:withinSliceAtTimelineMs:)`, never stepping backwards; the wall clock remains the fallback for cut boundaries and audio-only projects. Measured on the Play path before this: seek-then-play froze the preview ~165ms (exact seek from the previous keyframe plus stall-avoidance buffering), and a variant that held the playhead during the seek still froze it the same amount. Do not call `AVPlayer.currentTime()` on the 120Hz path: right after a timebase change it blocks the main thread ~30ms. `itemTime(forHostTime:)` is invalid until the first decoded frame, which is why the anchor is the clock.
4. **Export parity**: `MetalFrameCompositor.composeFrame(webcamVideoFrame:)` takes the real `webcam.mp4` frame (decoded side by side with the screen, honoring `delayAdjustmentMs`) and applies crop, mirror, Vision person cutout (one reused `VNGeneratePersonSegmentationRequest`), color grade and face-tracking punch-in. Captions use `CaptionLineLayout`, shared with the preview, rasterized with CoreGraphics (no TIFF round-trip) and cached until the visible words change.
5. **Change-only mirrors for SwiftUI**: `ProjectSession` exposes `spokenTranscriptSegmentIds`, `activeMaskIdAtPreviewTime` and `isCursorHiddenAtPreviewTime`, recomputed in `didSet` of the playhead/skim/isPlaying properties and assigned only when they change. Views must read these instead of `currentSourceTimeMs`.
6. **Cheaper solver rebuilds**: `scale`, `themeId`, `variantId` and `clickEffect` are excluded from the trajectory rebuild key; drags, clicks and ripple clicks are walked with sliding windows over sorted arrays (O(steps + events)).
7. **One render path for preview and export**: the editor no longer draws the camera bubble, captions or keycaps as SwiftUI overlays. `MetalPreviewView` decodes `webcam.mp4` itself (anchored to the same host time as the screen player, seeked with the playhead while paused) and calls `composeFrame(includeShortcutOverlay: true, webcamVideoFrame:, isRealtimePreview: true)`, the same pass the exporter runs, so layout, styling and timing match the export frame for frame. Differences that remain are only resolution (drawable size vs export size). `isRealtimePreview` changes two things: person cutout uses `AsyncPersonSegmenter` (Vision on a background queue, newest finished mask, at most one in flight, redraw on completion) instead of segmenting synchronously, and hovered / selected keycaps are drawn brighter. Keycap interaction uses invisible SwiftUI hit targets placed from `MetalFrameCompositor.lastShortcutHitRects01`. Measured during playback: about 2 ms of main-thread compose work per frame (2.6 ms with cutout), no frame over 21 ms at 60 Hz.
8. **Layout motion without SwiftUI**: screen and camera placement is a `StageLayout` (continuous rects, corner radius, opacity, shadow and border strength) resolved per frame in `resolvedStageLayout`. Timeline changes (camera layout segment boundaries, hide during silence, voiceover hide, screen-only) blend from the previous layout over 380 ms with smoothstep easing; the change point is found by binary-searching the discrete `StageLayout.Key` inside the window, so the result depends only on the project and the time and the export is identical to the preview (the screen also glides into and out of split screen). In the live preview only, edits made while paused spring toward the new layout (`SpringVector`, response 0.25 s, damping 0.82, like SwiftUI), and keycap groups spring their center and key height; a frame counts as an edit when the source time did not move, so playback and scrubbing follow the timeline exactly. `MetalPreviewView` keeps its render loop running while `isAnimatingPreviewOverlays` is true, then pauses again. `isCameraHiddenDuringSilence` uses a cached sorted transcript because the transition search calls it about ten times per frame.

---

## 15. ADR-15: Menu Bar Command Routing

### Problem
Menu bar items are app-wide, but almost every action belongs to one project window, and some of them (export modal, command menu, delete-project alert) live in that window's SwiftUI state. The editor also handles many shortcuts in its own `keyDown` monitor, which runs before menu key equivalents.

### Solution
1. `ProjectWorkspaceStore.activeSessionID` follows `windowDidBecomeKey` of editor windows (and falls back to another open editor when the active one closes). Menu items act on `activeSession` and are disabled without one.
2. Window-local actions go through `ProjectSession.pendingEditorCommand` (`showExportSheet`, `quickExport(target)`, `showCommandMenu`, `removeProject`). `ProjectEditorWindowView` performs and clears it in `onChange` and also in `onAppear`, so a command set before the window exists (the recorder's `After Recording > Export…`) still runs.
3. The key monitor must match modifiers exactly (`flags == .command`, never `flags.contains(.command)`) for keys that have an `⌥⌘` / `⇧⌘` variant in the menu, otherwise it swallows the menu shortcut (for example `⌥⌘C` Quick export to clipboard used to be eaten as `⌘C` Copy).
4. `Edit` items first send the standard selector (`copy:`, `paste:`, `undo:`…) when an `NSText` is first responder, and only otherwise act on the timeline selection.
5. SwiftUI appends `CommandMenu`s after `View`; `MainMenuOrder` re-orders the top-level items (`File, Edit, Record, Export, View, Window, Help`) and re-applies it on `NSMenu.didAddItemNotification` when SwiftUI rebuilds the menu bar.
6. View preferences (`EditorViewPreferences`) are app-wide and persisted, shared by every open editor window.
7. Menu icons: macOS 27 hides `NSMenuItem.image` by default (`preferredImageVisibility = .automatic`) and SwiftUI has no modifier for it, so `Button(_:systemImage:)` icons never show. `MainMenuOrder` sets `.visible` on the app's own items when the menu bar starts tracking (SwiftUI may have rebuilt them); the application menu, `Help` and system `Window` items keep AppKit's default.

---

## 16. ADR-16: Light / Dark Appearance & Settings Window

### Decision
- **Appearance** (`Settings > General`, also `⌘K > Switch to light/dark appearance`) sets `NSApp.appearance` (System / Light / Dark). The editor chrome was designed dark with white-at-opacity foregrounds over near-black surfaces, so it was converted to two adaptive tokens (`Views/Theme.swift`) instead of hand-picked light colors:
  - `Color.ink`: white in dark mode, near-black in light mode. Replaces chrome `.white` / `Color.white`.
  - `Color.surface(red:green:blue:)`: takes the existing dark surface color; light mode mirrors its lightness (`1 - L * 0.7`) and keeps the channel offsets, so a cool dark gray becomes a cool light gray. Dark mode renders exactly as before.
- Plain `.white` stays where content sits on a fixed colored background in both appearances: text on the solid accent purple (primary buttons), timeline segment labels, controls drawn over the video preview, the recording bar and tooltips. When adding a new purple button, use `.white`, not `.ink`.
- The window background (`NSWindow.backgroundColor`) uses `NSColor.surface`, so it follows the appearance too.
- **Settings window** (SwiftUI `Settings` scene, native toolbar tabs): General (launch at login via `SMAppService`, appearance, reset), Recording (projects folder, countdown, highlight area, hide desktop/Dock icons while recording, auto zooms, after-recording action, max camera resolution), Editing (start new projects from the last project's style, autosave on/off with a save prompt on close, presets folder), Quick export (format, fps, resolution, compression/codec, used by ⌥⌘C / ⌥⌘S and after-recording export), Shortcuts (read-only reference). `AppSettings` stores these; projects and presets folders are read straight from `UserDefaults` so non-main-actor code can resolve them.
- **Document icon**: `CFBundleTypeIconSystemGenerated` plus `UTTypeIcons` (`UTTypeIconBadgeName = AppIcon`, `UTTypeIconText`) let macOS draw `.nativescreen` packages as a page with the app icon.
- **Verification**: the editor, Settings tabs, Export modal and command menu were rendered offscreen in both appearances (`NSView.cacheDisplay`) and checked visually.


---

## 17. ADR-17: Windows Port Strategy

### Context
The macOS app is complete and tuned. Windows code is written on macOS (where it cannot run) and verified on a Windows
machine by a second agent.

### Decision
- **Separate C# implementation**, no shared native core. The Swift code is the reference; C# ports keep its names,
  constants and formulas (`spec/08` §1). Rust or C++ only with a measured reason and its own ADR.
- **Correctness by fixtures, not by eye:** the macOS app generates `conformance/` (numbers and frames from synthetic
  projects); Windows tests must match them within fixed tolerances (`spec/08` §2).
- **Implicit CoreImage behavior is written down** (`spec/07`): compositing happens in gamma-encoded sRGB with
  premultiplied alpha (the macOS `CIContext` working space), so Windows uses `B8G8R8A8_UNORM` targets and never `_SRGB`.
  Built-in camera looks travel as LUTs exported from macOS instead of re-deriving undocumented filters.
- **Writer / verifier workflow** (`windows/AGENTS.md`): the writer compiles everything that compiles on macOS
  (`EnableWindowsTargeting`) and marks unverified Windows API details with `// VERIFY:`; the verifier runs
  `verify.ps1`, measures the phase acceptance checks and records `PASS` / `FAIL` in `windows/HANDOFF.md`.
- **Hybrid encoding is not ported by default.** It solved a VideoToolbox throughput limit; Windows hardware encoders are
  measured first (`spec/platforms/windows-d3d11-mediafoundation.md` §6).

---

## 18. ADR-18: Attaching a Swap Chain to a WinUI `SwapChainPanel`

### Context
A managed cast from `SwapChainPanel` to a `[ComImport]` `ISwapChainPanelNative` compiles but always throws
`InvalidCastException`: C#/WinRT projected objects are not COM wrappers. Once attached, a swap chain that has not
presented opaque pixels leaves the panel see-through, so the window behind shows inside the preview. Presenting alpha 0
does not change that.

### Decision
- `SwapChainPanelInterop` calls `QueryInterface` on `IWinRTObject.NativeObject.ThisPtr` and invokes `SetSwapChain`
  (vtable slot 3) through a function pointer, checking the `HRESULT`. No extra package is needed for one call.
- The first frame presented after attaching is the opaque stage from `PreviewRenderer`, so the panel never shows through.
- The editor window stops the render thread, detaches the swap chain (`SetSwapChain(0)`) and disposes it and the
  compositor when it closes.

---

## 19. ADR-19: Windows Editor Chrome Rebuilt Against the macOS Views

### Context
The first WinUI shell used default controls and looked nothing like the macOS editor. Default caption buttons follow the
OS theme rather than the app theme, so their glyphs disappeared on the dark title bar.

### Decision
- **Same tokens and metrics as the Swift views:** surfaces, ink opacities, the `#4D2FF5` accent, the 52 / 245 header and
  timeline heights, the 344 inspector and the track row heights are copied, with the light theme from the same mirrored
  lightness formula as `Theme.swift`.
- **Caption buttons are colored explicitly** on `AppWindowTitleBar` whenever the app theme changes. The title bar is a
  drag region with `InputNonClientPointerSource` passthrough rects over its controls.
- **`AppWindow` sizes are physical pixels.** `Ui.SizeWindow` takes DIPs and fits the work area; passing DIPs directly made
  windows two thirds of the intended size at 150% scale, and the title bar controls overlapped.
- **Timeline blocks are retained XAML elements, not Win2D.** A project has few blocks and they change only on edits. The
  playhead moves by transform with no layout pass. Revisit with a measured stall (`spec/08` phase 6 allows 8 ms) or when
  waveforms need a drawn surface.
- **A timeline drag never rebuilds the tree.** Selecting a block rebuilds every block, and a rebuild during a press
  cancels the drag, so selection waits for release and a drag moves its one element in place.
  `BeginInteractiveEdit` / `EndInteractiveEdit` make the whole drag one undo step, like `ProjectSession`.
- **A feature with no Windows backend is disabled with a tooltip, never a control that silently does nothing.**
- **The preview draws the real stage** on one render thread that blocks on an event while idle: the mesh, gradient or
  solid background, shadow, screen rect, inset and camera placement from the ported layout engine. Video, cursor, masks,
  captions and keycaps are not composited yet, and the shadow is a feathered rounded rect rather than the baked Gaussian
  of `spec/07`, so these frames are not expected to pass the conformance fixtures.

---

## 20. ADR-20: macOS Behaviors the Fixtures Exposed

### Context
Measuring the Windows compositor against `conformance/` found two things the code and `spec/07` did not state.

### Findings
- **Baked layers were flipped vertically (fixed, ADR-32).** `materializeToGPUTexture` rendered into a Metal texture and
  flipped the result with an extra transform, mirroring the background, screen shadow and device bezel. Windows reproduced
  this until the macOS fix.
- **The fixtures used to leak backgrounds between cases.** The generator shared one `MetalFrameCompositor` across all
  cases, and its background crossfade runs on wall-clock time for 320 ms, including during export, so frames rendered right
  after a background change contained the previous case's background and depended on machine speed. The generator now
  creates a compositor per case, and two runs produce identical frames (ADR-29). Full-frame enforcement can now be turned on.

### Decision
`Rendering.Tests` enforces the `spec/08` §2.4 tolerances (SSIM 0.985, 99.5% of pixels within 6/255) on the screen region
of the cases whose passes exist, leaving out frames that show keycaps until that pass lands. Acceptance still needs the
full frame, which the regenerated fixtures now allow.

---

## 21. ADR-21: Windows Decode and Export Start in System Memory

### Context
`spec/platforms/windows-d3d11-mediafoundation.md` describes zero-copy decode (`IMFDXGIBuffer` on the compositor's device) and
`ID3D11VideoProcessor` for BGRA to NV12. Both need a device shared across threads and make failures depend on the driver.

### Decision
- Decode with hardware transforms (they need a D3D device, see ADR-26) but receive NV12 in system memory, upload to a dynamic NV12 texture on the render thread,
  and convert with `Nv12ToRgb.hlsl`. No device is shared with the decode thread, and the render thread never waits on it.
- Export converts each composed frame with `GpuNv12Converter` and reads NV12 back, then encodes through `IMFSinkWriter` with
  hardware transforms. GIF reads BGRA back. `Nv12Converter` stays as the reference for the matrix.
- Export lives in `NativeScreen.Export`, the one library allowed to depend on both `Media` and `Rendering`, so it runs in
  tests without the WinUI app.
- This costs copies at high resolution. Move to the zero-copy path when a measurement at 4K misses the `spec/08` phase 3 or
  phase 4 targets. Neither has been measured yet.

### Notes
- NV12 chroma starts two thirds into the decoder's buffer, not at `stride * height`: decoders pad rows to the macroblock
  height and the media type does not report it.
- WIC's metadata API rejects the byte vectors of the GIF `NETSCAPE2.0` extension, so the loop block is added to the finished file.
- A fragmented clip reading back late was first seen here as a test host oddity. ADR-22 has the real cause.

---

## 22. ADR-22: Windows Reads Fragment Times From the MP4 Boxes

### Context
A recording's frames came back up to 280 ms away from the times they were written with, in blocks of tens of frames, sometimes going backwards. On a screen that stays still and then changes, the picture would lag the cursor by that much.

### Root cause
The Media Foundation fragmented MP4 sink writes about 300 ms fragments with exact sample durations but no `tfdt`. Its reader then estimates each fragment's start, and only comes right at a keyframe, whose time is in `mfra`. The file is correct; the reported times are not. It looked like a test host problem earlier because constant-rate clips are often estimated correctly.

### Decision
`Mp4FragmentIndex` parses `moov` and `moof` into a table of true times and keyframes, and `VideoFileReader` numbers frames against it instead of using `SampleTime`. A seek targets the keyframe's true time and then re-synchronizes on the nearest keyframe. Plain MP4 files keep the reported times. Recordings use H.264 baseline, so decode order is presentation order.

### Status
`FragmentedTimingTests` covers variable-rate reads and seeks on generated clips. Not checked: how the macOS app reads these files.

---

## 23. ADR-23: Recording on Windows: Silence, and an Unexplained Machine Reset

### Decisions
- WASAPI loopback delivers nothing while nothing plays, and the MP4 sink holds video back waiting for audio to interleave. Measured: 142 of about 240 frames written and 3.5 s to stop. `AudioTrackRecorder` now writes silence from a timer, and live writers set `MF_SINK_WRITER_DISABLE_THROTTLING`.
- BGRA to NV12 runs in two pixel shaders (GpuNv12Converter) with the same matrix as Nv12Converter, because the CPU path measured 23 ms per frame at 3072×1840 on 4 threads, about 40 fps. Exports keep the CPU path (ADR-21).

### Open problem
On one Intel MacBook Pro running Boot Camp (i9-9880H, Radeon Pro 5500M, Windows 10 19045), the machine froze and reset within about a minute in all 3 runs that recorded the microphone through `WasapiCapture`. The fans rose first, and Event 41 shows no bugcheck and no dump. In the last run, disposing the recorder took 5 s against about 40 ms without a microphone. The 4 runs without a microphone completed and the machine stayed up. Two of the 3 resets also had the camera on; the camera alone has not been run. This points at the microphone path on this audio driver, but it is not proven and no other machine has been tried. Until it is resolved, keep the microphone off by default and do not run the microphone test without accepting a possible reset.

---

## 24. ADR-24: Windows Measurements, Packaging and What Stays Open

### Measurements (one machine: i9-9880H, Radeon Pro 5500M, Windows 10 19045)
`NS_TEST_PERF=1` runs `PerformanceMeasurements`. These clips are synthetic, the runs are short, and compose has no decoded screen video, so they are lower bounds on real work.
- Compose: 1.0 ms median and 2.2 ms p95 at 1080p, 3.0 and 5.6 ms at 4K, wall clock including the GPU wait.
- Playback of a 1080p30 clip at 60 Hz, offscreen: 0 late of 600 draws over 10 s, first frame 45 ms. No WASAPI or swap chain in that loop.
- Preview audio: the device position was 44 ms behind wall clock after 2 s, which includes start latency.
- Export: reading BGRA back and converting on the CPU gave 0.64x at 1080p and 0.21x at 4K. `GpuNv12Converter` gave 1.85x and 0.86x, and with ADR-26 about 1.7x and 1.17x. 4K is still below the 1.5x in the platform guide for considering hybrid encoding, and whether the sink writer picked a hardware encoder has not been checked.

### Packaging
`scripts/package-msix.ps1` builds an unsigned, self-contained package of 97 MB. It has not been installed. A `.nativescreen` package is a folder on Windows, and file type associations do not apply to folders, so double-clicking a package opens it in File Explorer. The declared association only covers a file with that extension. Opening by folder picker and by command line argument works. A real fix needs a decision: a shell extension for folders, or a single-file package format, which would break the shared layout.

### Not ported, on purpose
- The macOS fallback that invents a transcript when speech recognition fails. On Windows the failure is reported instead.
- Generated background music tracks. Custom audio files work.
- Person cutout. It needs a segmentation model whose license allows redistribution (`spec/07` 7.3). None was chosen, so cutout mode draws the plain camera rectangle.
- Voiceover recording, until the microphone problem in ADR-23 is understood. Uploading audio files works.

---

## 25. ADR-25: Transcribe Speech Regions, Not the Whole Track

### Root cause
Given speech that starts 2 s into a track, Whisper reported the first word at 0 ms and the rest about 1.6 s early. Edit by transcript cuts by these times, so it would cut the wrong audio. Screen recordings often have long silences.

### Decision
`SpeechRegions.Find` locates speech by energy in 30 ms windows: above 5% of the loudest window, gaps under 700 ms merged, 200 ms padding. Each region goes to Whisper separately and its words are shifted by the region's start. Silence is not sent at all, which also prevents invented text in it.

### Measured
Windows voice, base model, 8 of 16 threads: 9.7 s of speech in 1.7 to 3.6 s, words correct. `AudioFileReader` on a fragmented file matched the sample count exactly (0.0 ms), so ADR-22's problem does not reach audio. Real microphone speech has not been tried, and noisy tracks may need a different threshold.

---

## 26. ADR-26: Windows Playback: a Device per Reader, Swap Chain Pacing, Pooled Frames

Measured playing a 3072x1920 recording in the real editor window, with `NS_PREVIEW_STATS=<file>` writing present intervals on close.

| Step | CPU, of one core | Median interval | Over 1.5x median |
| :--- | :--- | :--- | :--- |
| Start | 215% | 33.9 ms | 1.64% over 10 s |
| After 1 and 2 below | 85 to 97% | 16.67 ms | 0.48% over 10 s, 3.20% over 60 s |
| After 3 below | 90% | 16.67 ms | 0.28% over 60 s, worst 165 ms |

### Root causes
1. `MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS` alone does not give a source reader a hardware decoder. Without `MF_SOURCE_READER_D3D_MANAGER` it decodes in software. Each reader now owns a device and device manager, and frames still reach the render thread in system memory, so no device is shared across threads. Writers got one too; export at 4K went from 0.88x to about 1.0x.
2. Preview time was driven by a `DispatcherTimer`, which ticked at about 30 Hz here. The render thread now draws in a loop paced by the swap chain's latency waitable and reads the clock itself, for each frame, while playing. The timer only moves the playhead and the clock label.
3. Each frame allocated a 9 MB array on the Large Object Heap, over 500 MB/s, and the resulting collections missed frames. It did not show in a 10 s run, which is why the acceptance check is 60 s. `VideoPlaybackSource` and `SequentialVideoSource` now reuse buffers. A frame handed to the render thread is only reused once that thread asks for another.

### Still open
- The recording bitrate came out at 47 Mbit/s against a requested 23.6, in every run. The encoder may be ignoring `MF_MT_AVG_BITRATE`; rate control through `ICodecAPI` has not been tried.
- A/V offset is limited to the 15 ms correction tolerance against the device position; it was not measured acoustically, so output latency is not included.

### Scrubbing
Dragging on the timeline moved the playhead without updating the clock label or the preview, because only a press raised a selection change. `TimelineView.PlayheadScrubbed` now does both.

---

## 27. ADR-27: Keycaps Follow the Platform a Project Was Recorded On

### Context
Keycaps drew macOS symbols and names everywhere, so a Windows recording showed Ctrl as "control" and the Windows key as "command".

### Decision
Decided by the project owner. When `recording/metadata.json` says `platform = "windows"`, and for a project with no recording on Windows, keycaps read `Ctrl`, `Alt`, `Shift`, `Win`, in the Windows order `Ctrl+Shift+P`, with no symbol line. Projects recorded on macOS keep macOS keycaps when opened on Windows, which also keeps the conformance fixtures valid. `ShortcutEngine` stays an exact port; `WindowsKeycaps` rewrites only the drawn labels and widths of its result.

### Consequences
- Telemetry and `project.json` do not change, so projects still round-trip.
- This is an intended difference from `spec/07`: frames of Windows projects are not comparable with macOS fixtures in the keycap area.
- The macOS app has no such branch, so it still draws macOS keycaps for a Windows project. Changing that needs a macOS code change.

## 28. ADR-28: Pointer Rules for Timeline Drags and Menus (Windows)

### Context
Three WinUI behaviors broke timeline editing. A right press bubbled to the canvas, which scrubbed and captured the pointer, and the capture cancelled `RightTapped`, so segment menus never opened. `ReleasePointerCapture` raises `PointerCaptureLost` synchronously, so a handler that released first ended the drag before the drop row was read. `Flyout` has no slider or card rows, and `MenuFlyout` cannot hold them.

### Decision
- Only a left press starts a scrub or a drag.
- `CanvasReleased` ends the drag with its drop position first, then releases the capture.
- Segment menus are a `Flyout` with rows built to look like a menu.
- A mask keeps its row until the drop. It follows the pointer visually, and the drop computes `round(deltaY / rowStep)`.

### Consequences
- Moving the only mask of a track to a new row looks like nothing happened: the emptied track is removed, so the layout is the same. A test of mask dragging needs a track with two masks.
- Icon glyphs must exist in Segoe MDL2 Assets as well as Segoe Fluent Icons, because Windows 10 has only the first. `ED1A` and `F19F` do not.

---

## 29. ADR-29: Cursor Themes Are Self-Drawn and Identical on Every Platform

### Context
A project must look the same on macOS and Windows, whichever one it was made on. Cursors of the operating systems cannot
meet that and stay clean: showing the macOS cursor on Windows means redistributing it, and reading each machine's own
cursor at runtime makes the same project differ per machine. Copying the system cursor into the project was also rejected,
because the app would still be making and carrying a copy of an operating system asset.

### Decision
- Every theme is drawn in code by `tools/generate_cursor_assets.py`. Do not bundle, trace or take coordinates from cursors
  of an operating system or another app, and do not add a theme that reads the system cursor. A later "import my own
  cursor" feature is fine, since the user then picks the file.
- Theme ids, in inspector order: `classic-dark` (default), `classic-light`, `rounded`, `dart`, `dart-color`, `outline`,
  `ring`, `pixel`, `touch`. Names are neutral; none uses an operating system's name.
- Both platforms render the same SVG files, so sprites use only what CoreSVG and Direct2D both draw: outlines are a
  separate layer under the fill (no `paint-order`), opacity uses `fill-opacity` / `stroke-opacity` (no `rgba()`), and every
  file has the same shadow (black 50%, stdDeviation 3, dy 2.4) because Direct2D ignores SVG filters and adds that shadow
  itself.
- Hands, I-beam and cross are drawn per pointer variant where the theme has colors. For a non-pointer kind, pick the sprite
  with the selected pointer's variant number, then the first sprite of that kind, then the selected pointer. `ring` and
  `touch` have pointer sprites only, so they stay the same shape for every cursor kind.

### Migration
`arrow` no longer exists. When a saved `CursorConfig` is decoded (`CursorThemePreset.migrateLegacyTheme`), `arrow` with
variant `pointer-2` becomes `classic-light`, any other `arrow` becomes `classic-dark`, and the variant is cleared.
Other unknown ids still normalize to the default, and ids starting with `touch` to `touch`. `rounded` and `touch` keep their ids and
variant ids.

### Fixtures
Changing a sprite changes frames, so rerun `--generate-conformance` in the same change. The generator now creates one
`MetalFrameCompositor` per case, which also removed the background leak in ADR-20.

---

## 30. ADR-30: Click Ripple Bends the Screen, Voiceovers Use Tracks

### Click ripple
The ripple used to be a hard white ring. It is now a refraction wave that draws nothing on top; the formula is in `spec/07`
Pass 4. It needs each click's own position and age, so the solver keeps `clickWaves` (at most 3, 900 ms) for every style,
because `clickEffect` is not part of the trajectory rebuild key. `activeClickProgress` still covers only the circle, so
`trajectory.json` does not change.

The kernel must run on the whole canvas. Running it on the screen rect alone smeared the screen's edge pixels across the
background. It also runs before the camera zoom, so CoreImage asks it for just the visible part of the canvas: its textures
are smaller than the canvas, and it works in canvas pixels using each texture's origin. Treating the output texture as the
whole canvas squeezed the full screen into it, which looked like the zoom snapping to 1x on every click.

### Voiceover tracks
- `VoiceoverSegment.trackIndex` (default 0) is the track. Segments on one track never overlap; segments on different tracks
  may, and both playback and export mix them.
- `TimelineConfig.hiddenVoiceoverTracks` holds the hidden track indices, so each track has its own eye. A hidden track is left
  out of playback and export, and its `hideRecording` segments stop muting the recording. Adding a voiceover shows its track.
  The old `isVoiceoversTrackHidden` flag is read once: when set, the project loads with every track hidden and the flag cleared.
- `normalizeVoiceoverTracks()` enforces the rules and remaps hidden indices when tracks close up. It runs on load, after adding and deleting, and after moving between tracks.
  Old projects with overlaps load with the later segment moved to the first free track, and empty tracks are closed up.
- An imported file goes to the first track with room. A recording goes to the first track with nothing after its start, so
  it fits at any length. Dragging along a track stops at its neighbors; dragging to a full track snaps the segment back.

---

## 31. ADR-31: Camera LUT Files Live in the Package and Grade sRGB Values

### Context
`Load your LUT file` stored only the file's name and switched to the Cinema look. No renderer read `customLUTRelativePath`, so the chosen LUT had no effect, and the file stayed outside the project.

### Decision
- The `.cube` file is checked, then copied to `assets/lut-<file name>`. `customLUTRelativePath` is that package-relative path. `recording/` is untouched.
- Order of precedence: selected custom preset, then LUT file, then built-in look. Picking a built-in look or a custom preset clears the LUT path, and loading a LUT clears the custom preset. `colorGradePreset` is left alone.
- A missing or unreadable file falls back to the built-in look, which covers projects saved by the old code with a bare file name and presets applied to another project.
- The table applies to sRGB-encoded values on both platforms: `CIColorCubeWithColorSpace` with sRGB on macOS, the `Lut3D` pass on Windows. `Color grading intensity` fades it as it does a look. Sizes from 2 to 128 are accepted; 1D LUTs are refused.

### Consequences
- Export and preview both pick it up, since both go through the compositor. Look thumbnails in the inspector do not show it.
- There is no fixture for a LUT file yet, so nothing compares the two platforms' output.

---

## 32. ADR-32: Self-Drawn Wallpapers, Baked Layers Stay Upright

### Built-in wallpapers
The built-in set is 108 JPGs in `Resources/Wallpapers.bundle/<Category>/`, with 192x120 previews in `thumbs/`. They are drawn by
`tools/generate_wallpapers.py` from seeded math and self-chosen colors, so the set carries no third-party rights. Never add
images from other apps or wallpaper packs to this bundle.

- **Files, not shaders.** The look depends on layered shading, grain and glass highlights. Shipping the same bytes gives
  identical wallpapers on every platform with no new compositor code. Cost: about 20 MB of app size.
- **2560x1600**, the compositor's decode limit. Grain breaks up 8-bit banding in the long gradients.
- **Colors mix in OKLCH along the short hue arc.** Mixing in OKLab turns complementary colors grey. Dark layers reject arcs
  through the yellow-green band, where those hues turn olive and brown.
- **Picking one copies the file byte for byte** to `assets/background-<id>.jpg` and sets `systemWallpaperName` to the id (for
  example `spring-01`). No re-encode, so a project stores the same file whichever platform picked the wallpaper.
- **Category pills only browse.** They no longer change `background.type`; picking an item does. The `Wallpaper` mode pill returns
  to the last picked wallpaper, or to the mesh when there is none. Mesh presets stay for existing projects, under `Mesh` and `★`.

### Baked layers stay upright
`materializeToGPUTexture` flipped every baked layer vertically, so the background was upside down in preview and export, shadows
fell the wrong way and the device notch sat at the bottom. The 320 ms background crossfade is not baked, so a newly picked
wallpaper appeared upright and then jumped upside down when the fade ended. `render(_:to:)` and `CIImage(mtlTexture:)` already
use the same row order, so the bake now only restores the extent's origin. Rounded masks are symmetric and did not change.
All frame fixtures were regenerated. Existing projects keep their settings and now render the intended direction.

---

## 33. ADR-33: Windows Recording Bar Frame and Sideways Rows in a Rebuilt Inspector

### Recording bar
On Windows the bar is a plain rectangle; rounded corners stay a macOS look. A WinUI window without a title bar still paints a white frame around its content, measured at 3 pixels at 200% scale. A window region only hides part of it and, being aliased, leaves broken black and white edges. The frame goes away only by removing `WS_CAPTION` and `WS_THICKFRAME` and adding `WS_POPUP`, followed by `SWP_FRAMECHANGED`. The bar is excluded from capture, so a screenshot of it needs that exclusion turned off for the test.

### Sideways rows
The inspector rebuilds its controls on every edit, so a new `ScrollViewer` would start at offset 0 and a selected item could never glide into view. `InspectorPanel.Strip` keeps offset, pending target and selected id by row key. A rebuild restores the offset without animation. When the selected id changed it then animates to center the item, and a row opening for the first time centers without animating. Every other rebuild leaves the row where the user scrolled it. On a row that overflows, a plain mouse wheel scrolls sideways.

### Inspector tabs
A disabled tab keeps its button enabled and ignores clicks, because a disabled WinUI button shows no tooltip and the tooltip gives the reason. The rail rebuilds only when availability changes, so a slider drag does not recreate it.
