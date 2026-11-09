# NativeScreen: Engineering Decisions, Performance Optimizations & Architecture Notes

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
   - The two lanes produce different SPS/PPS (`max_num_ref_frames`, VUI, `bottom_field_pic_order_in_frame_present_flag`). Muxed as they come, `AVAssetWriter` stores them as two `avc1` sample descriptions that switch at every GOP. AVFoundation and FFmpeg decode that, but Chrome stops with `PIPELINE_ERROR_DECODE` at the first switch (about 1.5 to 2 s in), so shared videos broke on the web. The muxer therefore writes every sample under the FIRST sample description and puts each keyframe's own SPS/PPS in-band, length-prefixed in front of the IDR (`H264InBandParameterSets`). Decoders take the in-band sets at each IDR. Checked: one sample description, AVFoundation decodes it bit-identical to the two-description file, Chrome plays 1080p30 and 4K60 to the end, export speed unchanged (4K60 21 s project: 9.4 s; a hardware-only encoder took 18.7 s). The cost is a few dozen bytes per keyframe.
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
In CoreImage (and similar deferred GPU filter graphs), a `CIImage` is **not** a rendered texture; it is a **lazy filter recipe**.
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
   *(For a `16:10` recording with $p = 0.10$, $\text{aspect}_{\text{auto}} = \frac{1.6 + 0.2}{1.0 + 0.2} = 1.5$, producing an exact **`3226×2160`** 4K frame, 7% fewer pixels to encode and identical margin thickness on all 4 edges).*
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
   - When the cursor enters a button from any angle (e.g. top-right), the highlight layer starts `22pt` outside in that exact direction and flies into the button, tracks the cursor magnetically while inside, and flies out along the exit vector when leaving, all with **zero SwiftUI `@State` mutations**.
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
   - At render time, select the pyramid level matching `pxPerBin = 5.0 pt` and interpolate the envelope peaks with a **Catmull-Rom cubic spline** filled per ADR-42 (colors, fade and the full-volume copy below 100%).
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
     - Extract and render two distinct waveforms on timeline Clip segments: purple (`#4D2FF5`) for system/app audio (`audioWaveformSamples` from `display.mp4`) and translucent white for recorded microphone audio (colors and opacities in ADR-42) (`microphoneWaveformSamples` from `microphone.m4a`), while synchronizing `micPlayer` (`AVPlayer`) with `player` in `MetalPreviewView`.
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
1. **Fragmented recording**: every capture writer (screen, webcam, microphone) sets `movieFragmentInterval = 2s`. A killed recorder leaves a playable file up to the last fragment (verified with `kill -9`); `finishWriting` defragments as before. The video writers must not use frame reordering (ADR-54).
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
2. Window-local actions go through `ProjectSession.pendingEditorCommand` (`showExportSheet`, `quickExport(target)`, `showCommandMenu`, `removeProject`). `ProjectEditorWindowView` performs and clears it in `onChange` and also in `onAppear`, so a command set before the window exists (the recorder's `After Recording > Export...`) still runs.
3. The key monitor must match modifiers exactly (`flags == .command`, never `flags.contains(.command)`) for keys that have an `⌥⌘` / `⇧⌘` variant in the menu, otherwise it swallows the menu shortcut (for example `⌥⌘C` Quick export to clipboard used to be eaten as `⌘C` Copy).
4. `Edit` items first send the standard selector (`copy:`, `paste:`, `undo:`...) when an `NSText` is first responder, and only otherwise act on the timeline selection.
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
- **Light mode pass (2026-11-08).** Things the token conversion missed:
  - `Color.adaptive(dark:light:)` for colors that cannot be derived. Timeline segments (clip, zoom, mask, caption, camera layout) have their own light palettes: brighter, more saturated fills and an edge glow in the fill's own hue at lower opacity. The dark palettes' darkened edge glow looked dirty on a light timeline. The typing-speed badge on the clip track follows.
  - `Color.inkInverse` for glyphs on an `ink` fill (Export section badges, camera layout icons). They were `.black`, which vanished into the near-black light `ink` and left a black block.
  - Tooltips follow the owner window's appearance, so their tint does too: dark tint in dark mode, light tint and a dark hairline in light mode. A dark tint with dark `labelColor` text was unreadable.
  - The crop window, camera crop window, color preset window and Export still frames sheet were forced dark (`preferredColorScheme(.dark)` and fixed backgrounds). They now use `ink`, `surface` and `adaptive` like the editor. What is drawn over the frame (dimmed outside, grid, handles) stays dark in both.
  - Cursor style and variant tiles use light gray (0.84) instead of mid gray (0.48) in light mode; still dark enough for white cursors, which have a dark outline.
  - The preview canvas shadow is much smaller and fainter in light mode (radius 6, 10%). The dark one (radius 20, 55%) was cut off by the toolbar and playback bar and looked like a smudge.
  - The hover highlight (`HoverMagnetTrackingNSView`) is white at 9.5% in dark mode and black at 6.5% in light mode, where white did not show. Windows that draw dark chrome in both appearances adopt `AlwaysDarkChromeWindow` (the recording bar) and keep the white one.
- **Settings window** (SwiftUI `Settings` scene, native toolbar tabs): General (launch at login via `SMAppService`, appearance, reset), Recording (projects folder, countdown, highlight area, hide desktop/Dock icons while recording, auto zooms, after-recording action, max camera resolution), Editing (start new projects from the last project's style, autosave on/off with a save prompt on close, presets folder), Quick export (format, fps, resolution, compression/codec, used by ⌥⌘C / ⌥⌘S and after-recording export), Shortcuts (read-only reference). `AppSettings` stores these; projects and presets folders are read straight from `UserDefaults` so non-main-actor code can resolve them.
  - **Tabs resize smoothly.** SwiftUI sets the window to each tab's height in one frame. Each tab (`SettingsPage`) measures its own natural height (`fixedSize` vertically, reported through `SettingsTabHeightKey`), and `SettingsView` sets the root frame to that height inside `withAnimation(.smooth(duration: 0.28))`. SwiftUI passes every animated height to the window, so it resizes over about 0.3 s with its top edge fixed (measured frame by frame: 353 to 572 pt over 27 steps). The first tab is applied without animation, and Reduce Motion skips it.
  - **Segmented choices slide.** Appearance, countdown, camera resolution, quick export format, resolution and compression, and the Shortcuts section use `SlidingSegmentedControl` instead of `Picker(.segmented)`, whose AppKit control jumps. The accent pill moves with `matchedGeometryEffect` (spring, 0.3 s), hairlines separate unselected neighbours, VoiceOver gets the standard segmented picker through `accessibilityRepresentation`, and Reduce Motion turns the slide off. Pop-up menus (language, frame rate, codec...) stay native.
  - **`SettingsNavigation.shared.tab`** holds the selected tab, so other code can open Settings on a given tab.
- **Document icon**: `CFBundleTypeIconSystemGenerated` plus `UTTypeIcons` (`UTTypeIconBadgeName = AppIcon`, `UTTypeIconText`) let macOS draw `.nativescreen` packages as a page with the app icon.
- **Verification**: the editor, Settings tabs, Export modal and command menu were rendered offscreen in both appearances (`NSView.cacheDisplay`) and checked visually.
- **Windows:** timeline segments use the same light palettes, the selected outline comes from the palette instead of white, and cursor tiles use the same light grays. Dialogs already followed the theme and the preview has no shadow to shrink. Settings has `SlidingSegmentedControl`: the segments are radio buttons, so Narrator announces options, and it reacts to `Checked` because automation raises no click. The window height eases over 280 ms with its top edge fixed (measured from 540 to 999 px over 16 steps); with animations off it jumps.


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
  playhead moves by transform with no layout pass. Revisit with a measured stall (`spec/08` phase 6 allows 8 ms). Waveforms did not
  need a drawn surface (ADR-39).
- **The ruler holds still while a clip is resized**, as on macOS. `BeginInteractiveEdit` freezes the duration the timeline's width stands for, so the clip gets shorter under the pointer and leaves empty room at the right, and the ruler updates on the drop. Later clips, other tracks and the trim badges still close up during the drag: they move in place, since the drag cannot rebuild the tree. A segment shows from the first kept part of its range to the last (`NLETimeMapper.TimelineSpan`), and hides when no clip keeps any of it. Its own times do not change, so it returns when the clip grows back over it. Hidden segments are still created, so a drag can bring them back, and they do not block adding a new segment in their place.
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
  to the last picked wallpaper, or to the mesh when there is none. Mesh presets stay for existing projects, under `Mesh`.
- **`★` is Favorites.** Right-clicking any thumbnail (mesh or wallpaper) offers `Add to Favorites` or `Remove from Favorites`.
  The list is app-wide, in add order, stored in `NativeScreen.Wallpaper.Favorites` as one id per line (`mesh:<id>` or
  `wallpaper:<id>`). A favorite whose wallpaper is missing on this machine (a system wallpaper from another macOS version) is
  skipped. With no favorites, the grid shows a hint about the right-click menu. Favorites never touch the project file.
  A favorite thumbnail shows a white outlined star in its middle, both under `★` and in its own category.
- **`Pick random wallpaper` draws from every category** (mesh, system and built-in), not just the one on screen, then switches to
  the pick's category and scrolls its pill into view.
- **Windows.** The favorites are `FavoriteBackgrounds` in `settings.json`, a list in add order with the same ids. The filtering is in `Core/Rendering/BackgroundFavorites.cs`. Each thumbnail gets a `ContextFlyout` to add or remove it, and a favorite shows a white outlined `\uE734` star over a faint shadow copy. The random pick sets the category first, and the pill strip centers a newly selected pill on its own.

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

---

## 34. ADR-34: Windows Preview Seeking Never Shows an Empty Frame

### The black flashes
`VideoPlaybackSource` emptied its frame ring when a seek began and only refilled it after the first decode, so `FrameAt` returned null in between and the compositor drew no screen. On a 3072x1840 recording, hovering the ruler got null from 83% of the calls and playing after a seek from 88%. Three loops kept it going:

- **Asking again for a frame just after the target.** A seek stopped on the first frame near its target. If that frame was slightly later, the request counted as outside the ring and seeked again, and every finished seek redrew the preview, so a parked pointer flashed for ever.
- **Restarting from the same keyframe.** While decoding forward, the frame in the ring was more than 500 ms behind the clock, which also counted as outside the ring. Seeking returned to the same keyframe, so the decoder never caught up.
- **A seek can land before the keyframe it asked for.** Fragmented recordings land up to about 750 ms before the target, for example at 2250 ms when asked for 3000 ms. So "is there a keyframe after this frame" stays true right after landing. `VideoFileReader.CanSkipAhead` therefore also compares against the last seek's own target.

### The rules now
- The frame already on screen stays until a newer one is ready. The render thread's held frame is only recycled once it is replaced.
- A running seek follows the newest request. It restarts only when the request moved behind what it can still reach, or when a later keyframe really is closer.
- A seek keeps the frame just before its target. A still screen can have seconds between frames, and that older frame is the correct one.
- A seek that takes longer than 100 ms shows a frame every 100 ms, because a pointer can move faster than decode (about 1.9x real time at this size). Short seeks show only their result.
- `coveredFromMs` records how far back the ring answers, including a landing just after the target, so a finished seek is never asked for again.

Measured on the same recording afterwards: no null frames while hovering or playing, one seek for a parked pointer, and a median of 16 ms between the clock and the shown frame while playing.

### Timeline
- **Ruler.** It sits in its own row above the tracks and follows them sideways by a transform. `TimelineRuler.StepSeconds` is the same search as on macOS. Marks are at every step, labels only on whole seconds, and the clip's tick lines use the same step.
- **Playhead and ghost.** Both live in one overlay over the ruler and tracks, placed in viewport coordinates, so scrolling moves them without a rebuild. The stem starts exactly at the head's tip. The ghost's head ducks with `22 * p * (2 - p)`, where `p` falls from 1 to 0 over 26 points of distance from the playhead.
- **Crossing the ruler and tracks.** Leaving one for the other keeps skimming. Ending it there would send the preview to the playhead and back.

### Shortcut styles
The compositor draws a track's own style, but the inspector edited `defaultShortcutStyle`, so Position, the offsets and the keycap colors had no visible effect once a project had been saved and reopened. The inspector now edits the selected track's style, and the first track's style is also written to the default as on macOS. A shortcut's editor edits whichever style wins for it: its override, then its custom style, then its track's.

---

## 35. ADR-35: Windows Recording Bar Devices Before a Recording Starts

**Not yet run on hardware.** Because of ADR-23, no agent has opened a microphone or camera with this code. The owner tests it.

### Microphone meter
An endpoint's peak meter stays at zero unless a stream is open on the device. `MicrophoneLevelMonitor` opens a shared `IAudioClient`, starts it and never reads a sample, then polls `IAudioMeterInformation` every 33 ms from a timer. This avoids the capture thread, event callback and buffer copying of `WasapiCapture`, the path under suspicion in ADR-23. It does still open the device, so it does not prove the risk is gone. The monitor runs while the microphone menu is open, or while a microphone is selected and the bar is showing. Choosing a microphone only takes effect in the meter and at recording start, and the default stays off.

The meter has only a peak to work with, so the macOS curve loses its RMS term. Its attack, release and peak hold are the same.

### One owner per device
The meter and the preview release their devices and finish before `ScreenRecorder` is created, so a device is never open twice. All opening and closing runs in one chain off the UI thread. While recording, the floating preview takes frames from the recorder's own camera stream.

### Differences from macOS
- The preview window is a plain square. A WinUI window has no transparent background here, the same reason as ADR-33.

### Per-app system audio
Choosing apps replaces the all-apps loopback with one process loopback stream per app (`ProcessLoopbackStream`), through `ActivateAudioInterfaceAsync`. The documentation names Windows build 20348, but it was measured working on 19044, so it is offered from build 19041. **Builds from 20348 up have not been run.**

- **The level on 19044 was far too high.** A tone played by another process came back 12 to 23 times louder than the all-apps loopback read it, at an output volume of -25 dB (17.8 times as a gain). It scaled with the tone but moved between runs, and the all-apps path also bent slightly, so a dynamics effect on that device is likely. Builds under 20348 multiply by the current output volume and read the stream as float, because 16 bits would clip before the gain brought it back. This correction fits one device at one volume setting, so treat it as approximate until other volumes and devices are measured. `NS_TEST_APP_AUDIO=1` runs the check.
- **Opening a process right after its last stream closed fails for a moment.** It worked again after 1.5 s, and Restart hits this directly, so a start retries up to 6 times, 200 ms apart.

- **An app is its process name**, matching how macOS keeps bundle ids. Names turn into processes when recording starts, so an app opened later is not recorded.
- **Only the top of an app's tree is captured.** A stream already includes child processes, so also capturing a browser's helpers would play them twice. `AudioAppRoots` skips a process whose parent has the same name.
- **The stream states its format.** This client has no mix format, so it asks for 48 kHz stereo 16-bit with `AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM`.
- **Mixing is on the recording timeline.** `AudioFrameMixer` adds each source at its clock position and writes out 100 ms behind the clock, so a late packet still lands in place. A jump over 40 ms moves a source, and smaller jitter does not, which keeps its samples contiguous. Parts no source wrote come out as silence, which the MP4 sink needs (ADR-23).
- **Nothing is silently lost.** If an app cannot be captured, or nothing runs under a chosen name, the track still exists and the recording bar says that some app sound is missing.
- **Windows apps hosted by `ApplicationFrameHost`** are not listed, because the host process is not the one playing the sound.

### Recording bar and screenshots
As on macOS, the bar is left out of capture only from the moment recording starts until it ends, so a screenshot taken before then shows it.

### Split mode
Click toggles it and holding Alt alone holds it, as Option does on macOS. A hold ends when Alt is released, any other key is pressed, or the window loses focus, because Alt+Tab takes the release to another window. Clicking a clip, zoom, layout or mask cuts that block at the pointer. Resize handles scale from 0.95 to 1 and fade over 160 ms.

**Tracks wiggle on both platforms.** Neighboring tracks move in opposite directions by 1.65 points, 0.42 s each way, and settle over 0.16 s. An earlier macOS version was removed because its 60 Hz `TimelineView` re-evaluated every lane and kept resetting the cursor (see the Flicker-Free Split Mode Cursor entry above). The animation is back without that cost:

- **Windows** runs it on the compositor through each block's `Translation`, so it invalidates nothing on the UI thread.
- **macOS** uses `SplitModeWiggle`, one modifier per lane whose state only `SplitWiggleStrength` and `SplitWiggleEffect` read. A `GeometryEffect` recomputes one transform per frame and no lane body is re-evaluated. The cycle and the amplitude need different curves, and one transaction covers every state change in a tick, so two `withAnimation` calls would let the last one drive both and stop the repeat after one beat. The amplitude therefore animates in `SplitWiggleStrength`, and the cycle gets its own repeating animation from a scoped `animation(_:body:)`. The repeating animation is removed once the amplitude reaches zero, so it costs nothing outside the mode. Lanes hold AppKit views (`RightClickCatcherNSView`) that move with the transform; their cursor rects are all the crosshair in this mode, as is `documentCursor`, so a reset has nothing to flicker to.

### Adding from a track
Hovering an empty part of a row shows a ghost of the block a click adds, as on macOS: centered on the pointer, up to 2.8 s (1.8 s for shortcuts), fitted to the free gap, and hidden within 4 points of a block or in a gap too small for one. `TimelineAddPreview` holds the placement. A click adds exactly the ghost's range, so what is shown is what is created. A press with no ghost on screen only moves the playhead.

### Cursor cards
An SVG decodes after its `Image` loads, so a measurement can find nothing drawn. It used to give up until the next inspector rebuild, leaving sprites off-center. It now measures again on `ImageOpened` and retries up to six times, 60 ms apart.

---

## 36. ADR-36: Recording the App's Own Editor Windows

On Windows the picker lists this app's windows except those excluded from capture, and only the recording bar is excluded while recording. An own window captures its monitor and crops to the window, for the same reason as macOS below. Windows cannot leave other apps out of a monitor capture, so one overlapping the crop appears. The still-screen problem did not exist there, since the recorder already repeats the last frame at stop.

macOS:

The editor can be recorded, so a demo of editing can be made with the app itself. Before this, the picker skipped every window of this process and every capture filter removed them.

- **What stays off camera.** Only the recording UI: the windows with `sharingType = .none` (HUD, picker overlays, camera preview, area highlight) are excluded. Editor, crop and settings windows follow the same rules as any other app's windows.
- **Window mode uses a cropped display filter for our own windows.** `desktopIndependentWindow` drops popovers, menus and tooltips, which are separate windows and much of what a demo shows. The filter is the display minus the recording UI and every other app's windows, with `sourceRect` set to the chosen window. Two alternatives failed on macOS 27: an `including: [app]` filter makes the system replace the window controls with a sharing badge, and `excludingApplications:` gave black frames. In that initializer `exceptingWindows` also means windows to keep, not to remove.
- **No Accessibility calls into our own process.** The picker runs on the main thread at 60 Hz, and such a call would block waiting on itself. Own windows use a fixed 26 pt corner radius, and `Resize` uses `NSWindow` directly, clamped to the window's minimum size.
- **ESC goes to the editor while recording.** The recording bar's local ESC monitor used to swallow the key even though it does nothing during a recording, so it now passes the event through.
- **The Dock icon stays while an editor is open.** `Hide Dock icon` would otherwise remove the menu bar from the app being recorded.

**Known limits.** The crop is fixed when recording starts, so moving our own window during a recording does not move the capture. Windows from other apps opened during the recording are not in the exclusion list, and appear if they overlap the crop.

---

## 37. ADR-37: Caption Tracks and Spring-Driven Reveal

Windows has the same model and the same `CaptionLineLayout`. Its boxes use the rounded rect shader, each word is a cached sprite, and a fading item is blurred in its own small patch rather than across the canvas. Text is measured through DirectWrite by a delegate, so Core stays free of graphics. Windows keeps Whisper as its only engine, so its transcript controls keep the model choice; `Keyterms` is gone from the inspector as on macOS.

macOS:

Editing caption timing in the inspector was slow, so captions are now blocks on timeline tracks, and they animate instead of being redrawn at word boundaries.

- **Block timing is separate from spoken timing.** Words keep their spoken times because `Edit by transcript` cuts by them. A block has its own span and stretches its words to fit, so dragging a caption cannot change a cut.
- **Animation is a function of time.** Preview, scrubbing and export must match, so nothing keeps state between frames. Each frame simulates the previous 500 ms on an absolute 240 Hz grid from a settled start. `frames()` averaged 0.7 ms per call on a 19-word transcript.
- **Words are images, boxes are generators.** Each word is rasterized once and then moved and faded. Boxes use CoreImage generators, so a resizing box costs no rasterization.
- **The current word stays through gaps in `Word by word`.** Using each word's end time made it flicker in the short pause before the next word.

**A track always holds a caption**, as mask tracks do. Adding a track also adds a 2 second caption at the playhead, in one undo step, and any edit that leaves a track with no captions removes it and renumbers the rest. Dragging the only caption of a track past the ends does nothing, because it would only replace the track with a copy at another spot. When the last track goes, the transcript words go with it: a project with words and no tracks reads as one saved before tracks existed, so the next load would bring every deleted caption back. Undo restores them.

**Clicking a caption in the preview.** The Metal frame is only pixels, so the compositor records each visible box in `lastCaptionHitRects01` and invisible SwiftUI views sit over them, as for keycaps. The rects are rounded to 0.5% of the canvas so a growing box does not update SwiftUI on every frame.

**Transcription never invents text.** A failure used to fall back to sample words, which made a recording show "Welcome to Native Screen" with no error. On a Mac with Siri and Dictation off, `SFSpeechRecognizer` always failed this way. macOS 26 and later now use `SpeechTranscriber`, which does not need them, and `SFSpeechRecognizer` remains for macOS 15. Errors appear in the inspector. Sample words are only used by the showcase project.

**Video length on a still screen.** ScreenCaptureKit only delivers frames when the screen changes, so the video and the project ended at the last change, while audio and telemetry went on. `stopCapture` now repeats the last frame at the stop time.

---

## 38. ADR-38: Directional Hover Highlight on Windows

Tool buttons have the same highlight as macOS: it flies in from the side the pointer entered, leans toward the pointer by 2 points, and flies out the way the pointer left. The constants match: a spring of stiffness 1500, damping 100 and mass 2, an escape distance of 10 times the offset, and an entry scale of 0.8.

- **It runs on the compositor.** macOS steps its springs on a 120 Hz timer. Here two springs drive a property set, and expressions turn it into translation, scale and opacity, so nothing runs on the UI thread between pointer events and nothing runs at rest.
- **Spring constants become a period and a damping ratio**: 0.0365 s and 0.913. `Period` is not the oscillation period its name suggests: it acts as `1 / omega`, so `Period = sqrt(mass / stiffness)`. Measured on screen, 0.0365 s reaches 99% in 197 ms against 196 ms for the macOS spring; the textbook value, `2 pi / omega` = 0.229 s, took 1.2 s. Compositor springs do not keep velocity when retargeted the way the macOS solver does, so a fast reversal can differ slightly.
- **Rest is judged by time.** A compositor value cannot be read back, so 250 ms since the pointer left counts as settled, in place of the macOS check on the spring's value.
- **Which buttons.** `NsIconButton` and `NsPillButton`. Option pills and primary buttons keep their plain fill. A lit tool button (mask, split) only leans and does not fly.
- **Made on first hover.** A panel of buttons costs nothing for those never touched, which matters because the inspector rebuilds its controls.

---

## 39. ADR-39: Timeline Waveforms on Windows

Clips and voiceovers draw the same waveforms as macOS, from the same data: the levels (95th percentile reference, power curve 0.62), the mip pyramid and Catmull-Rom spline of ADR-10, the heights and the colors. `Waveform`, `WaveformEnvelope` and `WaveformOutline` live in Core so this is tested without a window.

- **System audio comes from the video when no track names it.** Projects usually carry it inside `display.mp4`, with `systemAudio` unset. Reading only the named track left those clips with no waveform.
- **Each wave is a XAML polygon**, traced on edits and when a volume changes, so nothing runs at rest and a volume slider moves only the waves it affects. At the largest zoom a clip has about 6000 points, which traces in well under a frame.
- **The polygon follows the rounded corners itself**, so the look does not depend on how a block clips its children.
- **A louder or quieter clip changes the wave height**, and below 100% a faint copy shows the wave at full volume, as on macOS.

---

## 40. ADR-40: Voiceover Recording on Windows

**Not yet run on hardware.** The owner chose to add this with ADR-23 still open and tests it. No agent has opened a microphone with this code. It uses `WasapiCapture`, the path under suspicion there, so the risk is unchanged, and the dock now offers it in one click. Update this section with the result, on which machine, before relying on it.

The dock button records, as on macOS: a click starts the microphone and the preview from the playhead, and another click stops both and adds a segment on the first track with nothing after the start. Upload stays in the inspector, the command menu and the voiceover's context menu.

- **The file starts when the preview does.** Opening a device and priming preview audio both take time on Windows and neither is on the UI thread. `VoiceoverRecorder` opens the stream first and drops samples until `MarkStart`, which runs once the clock is moving. Otherwise the take would lie early by that delay.
- **The default input device**, as on macOS, not the one chosen on the recording bar.
- **Closing the window keeps the take.** The segment is added before the final save and the file finishes off the UI thread.

---

## 41. ADR-41: Opening a Project from Explorer on Windows

A package is a folder and Windows applies file type associations only to files, so a double-click always opens File Explorer (ADR-24). Windows gets a context menu verb instead: "Open in Native Screen" under `HKCU\Software\Classes\Directory\shell`, limited to `*.nativescreen` by `AppliesTo`.

- **It is written at each launch**, per user and without elevation, so it follows the app when it moves. There is no uninstaller yet, so a deleted app leaves an entry that fails to run.
- **Not in the MSIX.** A packaged app's registry writes stay in its private view, so it skips this. A packaged verb needs a registered shell extension. Windows 11 also lists this entry only under "Show more options".
- **One process per copy of the app.** Explorer starts a new process each time, which would add a second tray icon and recording bar. The later process hands its path to the running one over a named pipe and exits. The names include the executable's path, so two builds can run side by side. If the running process does not answer within 3 s, the new one carries on by itself.
- **One editor per package.** Opening a package that is already open brings its window forward, since two editors would overwrite each other's saves.

---

## 42. ADR-42: Clip Waveforms Show the Full-Volume Wave Below 100%

A lowered clip used to draw only a shorter wave, so it was hard to tell how much quieter it was. Each source now also draws its full-volume wave faintly behind the volume-scaled one.

- **Two sources, drawn bottom-up:** microphone first (white, opacity 0.35), system audio over it (`#4D2FF5`, opacity 0.5).
- **Per source:** the volume-scaled wave is composited over a copy of the full wave in the same color at opacity 0.10. The copy shows only while the volume is below 0.999, so at 100% nothing changes, and at 0% (muted) only the copy is left.
- **Fade is per column.** In every column, opacity is half at the bottom and full at that column's crest: `mix(0.5, 1, clamp(y / max(h, 1)))`, with `y` measured from the bottom and `h` that column's height. One gradient across the row cannot do this, so the waves are rasterized per device pixel into one premultiplied bitmap (`ClipSegmentDecoration.rasterizeWaveforms`). The crest edge is antialiased as `clamp((h - y) * scale + 0.5)`.
- **Heights:** `env * min(rowHeight * 0.68, 32)` for the full wave, times the volume for the scaled one, both capped at the row height. Envelope reading is unchanged (ADR-10, `pxPerBin = 11`).
- **Cost.** The bitmap is rebuilt only when the decoration's inputs change (`Equatable`), and only rows under the tallest wave are visited. Not yet timed on a long clip at high zoom.
- **`View > Smooth waveform` off** keeps the 2 pt bars on a 3 pt pitch, each sampled at its center; the fade and the full-wave copy apply to bars too.

- **Windows.** `Core/Editing/WaveformRaster.cs` is the same rasterizer, writing premultiplied BGRA into a `WriteableBitmap` shown by an `Image` (`Stretch = Fill`), so no conversion is needed. It also cuts the block's rounded bottom corners per pixel, since the block does not clip its children. Voiceover blocks use it with one white layer at the voiceover's volume. The old polygon outline is gone.

---

## 43. ADR-43: Timeline Snapping

With several tracks, lining items up by eye was slow. While an item is dragged or trimmed, its edges stick to nearby edges.

- **Targets** are collected once when the drag passes the click slop (`snapTargetsTimelineMs`): the start and end of the timeline, the playhead, every clip boundary, and both edges of every zoom, mask, camera layout, voiceover, caption and shortcut segment, in timeline time. The dragged item is left out by id, not by time, so a neighbor that touches it still counts.
- **Threshold:** 8 points on screen, converted to milliseconds with the current zoom, so it feels the same at every zoom level.
- **Moves** test both edges and keep the one closer to its target. **Trims** snap only the moving edge. The result then goes through the usual clamps (no overlap inside a track, minimum length), so snapping never breaks the layout rules.
- **Guide line.** A 1 pt line in the theme purple marks the edge it snapped to, until the drag ends. It is its own view that observes only the guide, so the tracks are not re-evaluated while it moves.
- **Not snapped:** clip slices, since trimming a clip moves everything after it and its edges are source times.
- **Toggle:** a button next to the split button, lit purple while on, plus `View > Snap timeline items`. On by default, remembered app-wide in `NativeScreen.View.SnapToSegments`.

- **Windows.** `Core/Timeline/TimelineSnapping.cs` (`TimelineSnapController`, `TimelineSnapTargets.Collect`). Windows drags work in source time, so an edge goes to timeline time, snaps there, and goes back through the mapper at the speed of the slice it lands in. Targets are collected on press, which also reads the playhead. The guide is a 1 px `#704DFF` line at 90% in the overlay canvas above the tracks. The toggle is next to the split button, and `View > Snap timeline items` is stored as `SnapToSegments` in `settings.json`. Checked with a real mouse drag: the second shortcut's start landed on the first one's end, and the guide showed until the drop.

---

## 44. ADR-44: Localization

The UI is available in English, Vietnamese, Simplified Chinese, Japanese, German, French, Spanish and Brazilian Portuguese. Strings live in `Localizable.xcstrings`, keyed by the English text. Privacy prompts are in `InfoPlist.xcstrings`.

- **Three ways a string reaches the catalog.** SwiftUI literals (`Text`, `Button`, `Toggle`, `.help`) are extracted by the compiler. Display names and AppKit strings (enum `label`/`title`/`descriptionText`, `NSAlert`, `NSMenuItem`, panels) use `String(localized:)`. Components that take a plain `String` (tooltips, segment titles, inspector rows, context menu helpers) translate when they draw with `String.localizedUI`; their keys are marked `manual` in the catalog, since the compiler cannot see them.
- **Values stay English, labels translate.** State such as a selected preset name or a default track name (`Captions`, `Shortcuts`) is stored and compared in English and only translated when shown, so projects and comparisons do not depend on the UI language. A name the user typed has no catalog entry and is shown as is.
- **Whole sentences.** Plurals and choices are separate keys (`Remove 1 filler word` / `Remove %lld filler words`) rather than words spliced into a sentence, which most languages cannot follow.
- **Menus.** Top-level menus are matched by title to reorder them, so the match accepts the English title, our translation and SwiftUI's own (`MainMenu` table of SwiftUI), since `File`, `Edit`, `View`, `Window` and `Help` are translated by the system.
- **Standard terms** (Undo, Copy, Save, Cancel, File, Window...) use the system's own translations, read from SwiftUI's tables, so they match the system menus.
- **Language choice** is in `Settings > General > Language` and is stored where macOS keeps the per-app choice from System Settings (`AppleLanguages` in the app's domain), so the two stay in sync. It applies on relaunch; the row offers `Restart Now`.
- **Not translated:** the exported video (keycap names, caption text), file names, product and format names, and the Reel mode mock content's handle.
- **Layout.** German and French run up to 40% longer. Fixed-width labels shrink (`minimumScaleFactor`) or size to their text instead of wrapping: the recording bar's mode labels and the slider `Reset` button were the ones that broke.

- **Windows.** The app ships the macOS `Localizable.xcstrings` as content (linked in the csproj) and reads only the chosen language at launch (`App/Localization/Loc.cs`): `Loc.T(english)` falls back to the key, and `Loc.F(key, ...)` turns `%lld`, `%d` and `%@` (also `%1$@`) into `{0}`, `{1}`... and `%%` into `%`.
  - **Where text is translated.** Text is translated where it is shown, not at each call site. That covers the shared helpers (`Ui.Text`, `Ui.Option`, `Ui.IconButton`, `Ui.Tip` for every tooltip, the inspector rows, segment menu rows, command menu items, timeline block titles and track labels), literal `Text`, `Title` and dialog button initializers, and `Loc.Apply`, which walks a window's XAML once after `InitializeComponent`. Ids, tab keys and stored names stay English.
  - **Track names.** `Loc.TrackName` translates a default track name and its number (`Captions 2`, `Voiceovers 2` through `Voiceovers %lld`).
  - **Windows-only strings** (File Explorer, `Ctrl` key hints, Windows menus such as `Edit` and `View` that macOS takes from the system) are their own keys in the same catalog with `extractionState: manual`. The file is rewritten with Xcode's layout (` : `, two-space indent, sorted keys), so the diff only adds keys.
  - **No generated symbols.** Xcode generates a Swift symbol for every `manual` key, and keys that differ only in case or in three dots versus the one-character ellipsis (for example `Export video...` on Windows and `Export video` on macOS) get the same symbol, which fails the macOS build. The app looks strings up by their English text, so `STRING_CATALOG_GENERATE_SYMBOLS` is `NO`. Since 2026-11-08 every key and translation writes three dots (`...`), never the ellipsis character; the two keys that existed in both forms were merged, keeping the macOS translations.
  - **Choosing the language.** `Settings > General > Language` stores `Language` in `settings.json` (empty means the system language). It also sets `PrimaryLanguageOverride` when the app is packaged, and `Restart Now` releases the single-instance claim before it starts the new process. `NS_LANGUAGE=<id>` overrides the setting for one run, to check a layout.

---

## 45. ADR-45: Cmd + Scroll Zooms the Timeline at the Cursor

Holding `⌘` (`Ctrl` on Windows) and scrolling anywhere over the timeline (ruler, track labels or lanes) zooms it. The zoom buttons, `⌘+` / `⌘-` and pinch keep the playhead in place; scroll zoom keeps the time under the cursor in place instead, since that is where the user is looking.

- **Anchor.** Before the zoom, the cursor's time is `(scrollX + cursorX - inset) / contentWidth` of the timeline. After it, the scroll offset is set so that time sits at the same `cursorX`, clamped to the scroll range. Over the label column there is no time under the cursor, so it falls back to the playhead.
- **Step.** A mouse wheel notch multiplies the zoom by 1.15 (at most 4 notches per event, as wheels accelerate); a trackpad or other precise device multiplies it by `exp(0.01 * points)`. Wheel away from you or two fingers up zooms in, whatever the natural scrolling setting. The zoom range stays 1x to 6x.
- **Event path.** The lanes' horizontal scroll view gets wheel events first, so a local event monitor catches them, checks that the cursor is over the timeline's frame in this window, and consumes the event so the timeline does not also scroll. Scrolling without `⌘` is left alone.

- **Windows.** `Ctrl` + wheel is caught on the timeline's root grid with `handledEventsToo`, so the ruler, labels and lanes all zoom and the lanes do not scroll. A delta that is a multiple of 120 counts as wheel notches (1.15 each, at most 4). A touchpad, or any other delta, uses `exp(delta / 1200)`. The cursor anchor is resolved in `SetZoom` before the zoom changes, and the scroll is applied right after the layout pass, clamped. Over the label column it keeps the playhead. Checked with synthesized wheel events: the 0:05 tick stayed at the same pixel through 3 notches in and 2 out. A wheel without `Ctrl` still scrolls.

---

## 46. ADR-46: Timeline Zoom Stays Within a Frame

Zooming re-lays out every segment, since every x and width scales with the zoom. Measured on a 12 s project with 27 captions (Release build, 40 zoom steps from 1x to 5.8x, layout plus display per step): 16.8 ms median and 35.7 ms worst before, 11.3 ms median and 22.6 ms worst after. The fixes, by what they saved:

- **Waveform bitmap off the zoom path.** The waveform (ADR-42) was rasterized per device pixel over the whole slice width on every step, tens of thousands of pixels wide at 6x. Now the last bitmap is kept and drawn stretched while only the width changes; a sharp one is rasterized on a background thread 90 ms after the width stops changing. Trims, volume and sample changes still rasterize at once, so edits never show a stale wave.
- **BGRA bitmap.** The bitmap was RGBA, and the compositor converted every pixel to BGRA each time it was drawn (`vImage` permute, about 15% of the main thread during a zoom). It is now written as premultiplied BGRA, little endian.
- **Editor body not invalidated.** The toolbar zoom slider read `timelineZoom` inside the editor body, so every step re-evaluated the whole editor. It is its own view now.
- **No preview skim while zooming.** The cursor stays still while the content moves under it, and the hover handler re-skimmed the preview on every step (a seek per frame). Hover skim pauses for 150 ms after each scroll or pinch zoom step.

The anchor (playhead or cursor) lands in the same layout pass as the zoom: measured drift after each frame is under 0.1 pt. What is left is SwiftUI layout of the segment views and AppKit recomputing the window's drag regions.

- **Windows.** A zoom step used to rebuild the whole timeline tree. Measured on a 10 s project (Release build, 40 `Ctrl` + touchpad-sized wheel steps from 1x to 6x, with `SetZoom` and the layout pass timed through `NS_TIMELINE_ZOOM_STATS=<file>`):
  - **Before:** 17.8 ms median and 39.9 ms worst; the rebuild alone took 11.3 ms median.
  - **After:** 8.3 ms median and 20.2 ms worst. A zoom step now only moves and widens the existing blocks, ruler ticks, trim badges and full-width hover rows (`Relayout`, the same path a clip drag uses). Edge hit areas read the block's width at each event, so they follow the zoom.
  - **Waveforms:** the bitmap for each slice and voiceover is cached across rebuilds, keyed by everything except width. A zoom shows it stretched and re-rasterizes on a worker thread 90 ms after the width stops changing.
  - **Skim:** hover skim pauses for 150 ms after each wheel zoom step.
  - **Still to do:** the window's own resize still rebuilds the tree.

---

## 47. ADR-47: Per-Slice Microphone and System Audio Volume

A clip slice's context menu has one volume slider per recorded source: `Microphone volume` when the recording has a microphone track and `System audio volume` when it has system audio. Each applies only to that slice, in preview and export, multiplied by the project-wide volume of that source and the master volume.

- **Range 0 to 100%.** `AVPlayer.volume` and `AVMutableAudioMixInputParameters` cannot boost, so the old 150% end of the slider did nothing past 100%.
- **Sliders never set `muted`.** The system audio slider used to set `muted` at 0, and `muted` silences every source of the slice. A recording whose audible sound is all microphone then went silent at 0 and sounded unchanged anywhere above it. Moving either slider now clears `muted`, so slices muted that way by older builds recover.
- **File format.** `microphoneVolume` on each slice, default 1, read as 1 when missing (`spec/02`).
- **Voiceover ducking.** After a voiceover that hides the recording, the microphone returns to the volume of the slice playing at that time, not the project-wide one.

The recording HUD sizes its window from the bar's reported width (`onGeometryChange`) instead of reading `fittingSize` right after a state change, which could still return the old layout: a longer microphone name made the bar wider than its window and cut off both rounded ends. The window grows at once and only animates when shrinking.

- **Windows.** `ClipSlice.MicrophoneVolume` (clamped 0 to 2 on read), `SegmentEdits.SetSliceMicrophoneVolume` / `SetSliceSystemAudioVolume` (0 to 1, clear `Muted`), and `AudioMix.MicrophoneGain` multiplies by it. The mixer computes gain per sample frame from the slice under it, in preview and export, so the volume after a hiding voiceover is that slice's without extra code. The clip menu shows each slider only when the metadata names that track (`microphoneAudio`, `systemAudio`). The conformance fixtures gained `"microphoneVolume" : 1` on each slice, which is what the macOS writer now produces. The recording bar also refits when its own size changes, not only after a rebuild, so a label that changes in place cannot overflow the window. Not listened to on Windows yet.

---

## 48. ADR-48: Closing an Editor Releases Its Project

Closing a project used to keep almost all of it in memory. Measured on a 15 MB recording (Debug build): 38 MB at launch, 181 MB with the project open, 117 MB after closing, and about 5 MB more after every open and close of the same project. Each closed session stayed in memory until quit. What kept it alive, and the fix for each:

- **Registry.** `ProjectWorkspaceStore.sessionsByID` never removed a session, so reopening a project reused the old in-memory document (and its undo history) instead of reading `project.json`. `windowWillClose` now removes it after the autosave.
- **Window teardown.** AppKit and SwiftUI's focus tracking keep a closed `NSWindow` alive until another window becomes key. The close handler now sets `contentViewController = nil` inside its own `autoreleasepool`, so the whole editor view tree goes at once. Without the pool, the controller waits in the event loop's pool until the next event.
- **Preview.** `MetalPreviewView.dismantleNSView` pauses and drops every player (video, camera, microphone, voiceovers, background music) and the decoded frames.
- **Event monitors.** The editor's `NSEvent` local monitors capture the view, and with it the session. SwiftUI does not run `onDisappear` when a hosting view is released, so the store posts `editorWillCloseNotification` (object: the session) first, and the editor and inspector remove their monitors on it.
- **AppKit-held NSViews.** AppKit can keep a detached NSView alive for a while, so representables that store closures (right-click catcher, `⌘`-scroll zoom catcher, menu click overlay, title bar metrics) clear them in `dismantleNSView`.

After the fix, closing leaves no preview objects, and memory after close stays at about 100 to 135 MB over repeated open and close cycles of two projects. What remains above launch is one-time framework setup (Metal, AVFoundation, CoreImage, SwiftUI), malloc fragmentation and image caches. The app menu's observation tracking can still hold the last closed session or two until the menu bar next re-evaluates; that is bounded and does not grow.

- **Windows.** Every closed editor stayed in memory with its project, about 65 MB a cycle: 147 MB after the first close and 466 MB after the sixth (Release build, 10 s project). `NS_MEMORY_STATS=<file>` tracks the editor's objects through weak references, then forces collections 2, 6 and 15 s after each close and writes which are still alive. Every one of them was.
  - **Cause.** A WinUI `Window` is not part of XAML's reference tracking. A handler on the window's own events (`Closed`, `Activated`) whose closure reaches the window makes a cycle through native code that the collector never breaks. A heap dump showed no managed root, because the root is the native event source.
  - **Probe.** An empty window was collected after closing, but one registered through `AppTheme.Register` was not, because its `Closed` lambda captured the window.
  - **Fix.** The editor's window handlers are named methods that remove themselves in `WindowClosed`, and `AppTheme` uses a static handler. The close also stops and unhooks the editor's timers, stops the music preview, disposes click sounds and detaches the session's events.
  - **Rule.** Never subscribe to a `Window`'s events with a lambda that captures the window (or anything holding it), unless you remove it on close.
  - **Result:** 97 to 115 MB after close over 8 open and close cycles, flat, with no editor object alive and 3.3 MB managed.
  - **Open-time memory.** With a project open, private bytes are about 580 MB, and the working set is 300 MB. Opening the Media Foundation source reader with hardware decode takes about 265 MB, and decoding the first frames about 210 MB, 50 MB of which is the 6-frame NV12 ring. Software decode was no smaller (working set 490 MB). This is per open editor and is returned on close.

Deleting a project used to trash the package, then close the window, and the close-time autosave recreated the folder with only `project.json`. `ProjectWorkspaceStore.trashProject` now marks the session deleted (`saveNow` does nothing after that, and a pending autosave is cancelled) and removes it from Recent Projects. `Don't Save` also clears the undo and redo stacks, so `⌘Z` cannot bring back discarded edits.

---

## 49. ADR-49: Pay Only for What Is Used

A pass over CPU and memory for work done when nothing needs it.

- **Window picker.** While hovering windows to record, a 60 Hz timer listed every window, and for each one asked Accessibility (several IPC round trips into that window's app) for its corner radius. Now the list skips the radius, only the window under the cursor gets it, and the result is cached per window and size. With the mouse still, the list is refreshed every 0.25 s instead of every tick.
- **Disk checks on the frame path.** `hasRecordedCamera` and the camera and microphone URLs checked the disk on every call, and the compositor asks several times per frame at up to 120 Hz. `recording/` never changes after capture, so the lookup is done once per package location. The background music file is resolved once per `relativePath` (hits only, so a built-in track that is still being generated is picked up). Voiceover files are checked only when their player is created.
- **Mask overlay.** It read the playhead in `body`, so during playback it re-evaluated every frame to draw nothing (handles are hidden while playing). The time-dependent work now runs only while paused.
- **Background music.** The preview created and prepared its `AVAudioPlayer` as soon as a project with music opened. It is now created the first time playback needs the music. The inspector's music preview stops when the editor closes; before, it kept playing after the window was gone.
- **Image caches.** Wallpaper thumbnails were decoded for all built-in and system wallpapers (about 250) when the inspector appeared, and kept until quit. They are now decoded for the category on screen. The graded camera previews (one per preset, intensity and sharpen step, and per custom preset value) and the keycap sprites are capped. Wallpaper thumbnails and camera previews are dropped when the last editor closes.
- **Preview wallpaper.** The background image was decoded at 2560 px for the preview too. It is now decoded to the canvas size in 512 px steps, up to 2560 px, and decoded again only if the canvas grows past that.
- **Undo.** Each slider tick went through `mutate` and pushed a full document copy, so one drag filled the undo stack with one step per tick. Edits less than 0.4 s apart now extend the same undo step.
- **Waveform extraction.** The peak scan reads samples in place from the decoder's buffer (it copies only when the buffer is not contiguous) and takes the 95th percentile from a 1024-bin histogram instead of sorting every peak.

Measured after these changes (Debug build, 15 MB recording): memory after closing all projects is 95 to 113 MB over repeated open and close cycles of two projects, down from 117 to 137 MB. CPU is 0% with a project open and idle.

- **Windows.** The same pass, measured first:
  - **Changed.** The camera's LUT file is checked on disk at most once a second instead of every frame. A custom color preset is serialized once per document snapshot instead of every frame. The preview wallpaper is decoded at the canvas size, in the same 512 px steps. The waveform p95 comes from the same 1024-bin histogram, so both apps produce the same levels. Wallpaper thumbnails are dropped when the last editor closes.
  - **Already fine.** The window picker lists windows once when it opens and once on a click, with no polling. Inspector and menu sliders already coalesce into one undo step (700 ms). Idle CPU is 0.00% at launch and with a project open and paused.

---

## 50. ADR-50: Deleting a Track from Its Label

Tracks had no delete of their own: a track went away only when its last item did, and some kinds never did. Right-clicking a track label now opens a menu with `Hide Track` / `Show Track` and, for every track except Clip and Zoom, `Delete Track`.

- **No confirmation.** The delete is one `mutate`, so `⌘Z` brings back the track and everything on it. A toast names the track and points at `⌘Z`. A selection on the deleted track is cleared first.
- **Layouts** removes every camera layout segment, so the row goes away. **Voiceovers** drops that track's segments, then `normalizeVoiceoverTracks` renumbers the tracks after it and keeps their hidden state. It is not offered while a voiceover is recording. Audio files stay in `assets/` for undo.
- **Shortcuts.** Recorded keystrokes always belong to the first shortcut track, and the first track is recreated on load when the recording has keystrokes. Deleting that track therefore also adds its recorded keystrokes to `hiddenShortcutStartMs`; otherwise they would come back on reopen, or move to the next track. Custom shortcuts on the track are removed and the remaining tracks are renamed `Shortcuts`, `Shortcuts 2`, ...
- **Captions** uses `deleteCaptionTrack`, which removes the track's captions with it.
- **Windows.** `EditorSession.DeleteTimelineTrack(DeletableTimelineTrack)` (`Session/EditorSession.Tracks.cs`) follows the same rules.
  - **Shortcuts:** a recorded keystroke cluster is one whose id starts with `telemetry_`.
  - **Menu:** the label row spans the label column, so a right-click anywhere on it opens the `MenuFlyout` (`Hide Track` / `Show Track`, then a red `Delete Track`).
  - **Toast:** it is its own key, `Deleted %@. Press Ctrl+Z to undo.`, with the macOS translations and `Strg+Z` in German.
  - **Checked in the running app:** deleting a shortcut track removed the row and its items and showed the toast.


---

## 51. ADR-51: Accessibility (VoiceOver, Voice Control, Reduce Motion)

Every control can be found and pressed by VoiceOver, Voice Control, Switch Control and keyboard navigation, and reads in the UI language. Editing a video end to end with VoiceOver alone is not a goal: dragging segments, drawing masks on the canvas and picking a window by hovering stay pointer work. The scope is names for every control, the timeline readable, toasts read out, and Reduce Motion respected.

- **No cost when nobody listens.** Accessibility modifiers only attach data to the view; AppKit builds the tree when an assistive app asks for it. Values are never formatted per frame: the playhead ruler has no value (reading the playhead there would re-evaluate the timeline on every frame), and the transport timecode reuses the string it already shows. Announcements return early when VoiceOver is off.
- **Names come from tooltips.** An icon-only button's name is its tooltip without the shortcut (`Split clip (⌥)` reads "Split clip"), in `InstantTooltipButton` and the recording bar's `HUDInteractiveItemButton`. A button that shows a state adds it as the value (`Playback speed`, `2x`). Pills with text (`SubToolbarPillButton`) keep their text as the name and the tooltip as the hint, or take an explicit label and value.
- **Custom click targets.** Views that take clicks through an AppKit overlay or a gesture (recording bar menu rows, countdown and resolution segments, zoom and mask palette cards, keycap, caption and mask hit targets on the preview) use `accessibleButton(_:isSelected:action:)` in `Views/Accessibility.swift`: one element, the button trait, the selected trait, and VO-Space runs the same action as a click.
- **Controls with hidden labels.** Every `Toggle("")`, `Picker("")` and `Slider` gets the name of its row: `SettingsRow` labels its single control with the row title, the inspector's toggle and slider rows use their title (the visible title is hidden so it is not read twice), and the slider `Reset` button reads "Reset Blur intensity". The AppKit `NSSlider` in segment menus gets `accessibilityLabel` and a value description such as `80%`.
- **Grids.** Wallpaper, mesh, gradient, swatch, cursor, color grade and layout thumbnails read a name and the selected trait. Bundled wallpaper files are named `spring-01`, so they read as "Spring 1". Favorites add the value "Favorite". Gradients and swatches have no names, so they read "Gradient 3" and "Color, #FF5A36".
- **Timeline.** Each segment is one button: its title and what the segment shows ("Zoom, 1.6×, Auto", "Caption, <text>", "Shortcut, ⌘C", plus "Disabled" when dimmed), the value "From 3.0 seconds to 5.5 seconds", the selected trait, and VO-Space does what a click in its middle does (select, or split in split mode). Durations are spelled by `Duration.UnitsFormatStyle`, so they follow the UI language. The ruler is the `Playhead` element and VO-Up / VO-Down moves it by one second. The eye buttons read `Hide Track` / `Show Track`. Segments cannot be moved or resized with VoiceOver; that is left to the pointer.
- **Announcements.** `ProjectSession.showToast` also posts the message as an `announcementRequested` notification, so VoiceOver reads "Deleted Mask 2. Press ⌘Z to undo." without moving its cursor.
- **Reduce Motion** (`NSWorkspace.accessibilityDisplayShouldReduceMotion` in AppKit code, `accessibilityReduceMotion` in SwiftUI): the hover-magnet highlight appears in place without flying in or following the cursor, tooltips fade without the 4 pt slide, the toast fades instead of sliding up, split mode does not wiggle the tracks, and the spring demo dot stays still.
- **Strings.** Labels are English catalog keys like every other string (ADR-44). Literal `Text` labels are extracted by the compiler; labels passed as `String` (tooltips, `accessibleButton`, ternaries) go through `localizedUI` and are `manual` keys. A ternary inside `Text(...)` picks the `String` initializer and is never translated, so ternary labels are written as `Text((cond ? "A" : "B").localizedUI)`.
- **Known gaps.** The window, display and area pickers follow the pointer, so choosing what to record needs a mouse. Mask rectangles and the zoom and caption position pads read their position but are not adjustable with VoiceOver.
- **Windows** (`App/A11y.cs`, UI Automation, read by Narrator and Voice Access):
  - **Names.** `Ui.Tip` names an icon-only button from its tooltip without the shortcut. A button with a text label gets the tooltip as help text instead. `Loc.Apply` does the same for the XAML, now in English too. A button holding an icon and a label reads its label when it has no tooltip. Literal `AutomationProperties.Name` values now go through the catalog (`A11y.Name`). Inspector sliders take their row title, `Reset` reads `Reset %@`, thumbnails report `Selected` and `Favorite` through `ItemStatus`, built-in wallpapers read "Spring 1", and gradients and colors read `Gradient %lld` and `Color, #hex`. Collapsible sections are level-2 headings reporting `Expanded` or `Collapsed`.
  - **Timeline.** Each segment is a `TimelineSegment` peer (Button control type, Invoke and SelectionItem). Its name is the title and what the block shows, translated. Its help text is the range, spelled out from new keys (`%@ seconds`, `1 minute, %@ seconds`, `%lld minutes, %@ seconds`) with the UI culture's decimal separator. Invoke selects the segment, or splits it in split mode.
  - **Playhead.** The ruler is a `RulerSurface` peer named `Playhead` with RangeValue in seconds (small change 1 s). Its value is read only when asked. The playhead marks and snap guide are `AccessibilityView.Raw`.
  - **Announcements and Reduce Motion.** Toasts raise a UIA notification on the toast element. Reduce Motion comes from `UISettings.AnimationsEnabled`: the hover magnet is not attached (the plain hover fill stays), and split mode does not wiggle. WinUI tooltips already follow the system setting, and the Windows toast does not slide.
  - **Checked with UI Automation** (a probe walking the control view, since `FindAll` does not cross the XAML content bridge), in English and Vietnamese:
    - **Names:** 0 unnamed buttons out of 78 in the editor, and 0 out of 9 in the recording bar. Segments read "Phím tắt, Win+K, Từ 0,0 giây đến 1,6 giây".
    - **Playhead:** `SetValue(3)` moved it to 3 s.
    - **Invoke:** invoking a segment selected it.
    - **Cost:** idle CPU stays 0.00%, and closing still leaves no editor object alive.
  - **Not checked:** Narrator speech, Reduce Motion with the system setting off (this pass changes no system setting), and the preview's keycap, caption and mask hit targets. Those draw on one canvas with no element per target, so they are not exposed yet.

---

## 52. ADR-52: AI Agents Through MCP

AI agents (Claude Code, Claude Desktop, Codex, Cursor, VS Code and any other Model Context Protocol client) can record, edit, change settings and export. The feature is `Settings > AI Agents`, off by default.

- **The app is the server.** Recording needs the app's own Screen Recording, Camera and Microphone permissions, and edits must land in the editor the user sees, with undo. So the MCP server runs inside the app (`MCP/MCPServer.swift`) and listens on a Unix socket, `~/Library/Application Support/NativeScreen/mcp.sock`: mode 0600 in a 0700 folder, and peers running as another user are refused (`getpeereid`). No network port is opened.
- **Clients start the app's own executable with `--mcp`** (`MCP/MCPStdioBridge.swift`). Most clients only start stdio servers, so this mode never starts AppKit: it connects to the socket, opens the app in the background (`open -g`) if it is not running and waits up to 20 s, then copies bytes both ways. When the setting is off it answers the first request with an error that says where to turn it on, and exits without opening the app. There is no separate helper target: the bridge ships, is signed and updates with the app, and the config points at `Native Screen.app/Contents/MacOS/Native Screen`.
- **Protocol.** Newline-delimited JSON-RPC, written by hand (`initialize`, `ping`, `tools/list`, `tools/call`, `notifications/progress`, `notifications/cancelled`); it is small, and it keeps a third-party package out of the app. Protocol versions `2025-06-18`, `2025-03-26` and `2024-11-05` are accepted. Tool failures are results with `isError` and a sentence the agent can act on, not protocol errors. Results carry the JSON as text and as `structuredContent`.
- **One tool list for both platforms.** Names, descriptions and input schemas are in `Resources/MCPTools.json`, read at launch; `$ref` to its `definitions` is inlined because clients do not resolve it. Windows ships the same file. There are 28 tools in six groups: projects (`get_status`, `list_projects`, `open_project`, `create_project_from_video`, `close_project`, `delete_project`, `rename_project`, `save_project`), the document (`get_project`, `update_project`, `add_item`, `update_item`, `delete_item`, `split_item`, `undo`, `redo`, `run_action`, `set_background`, `apply_preset`, `list_options`), frames (`render_frame`, `export_frame`), recording (`list_capture_targets`, `start_recording`, `control_recording`), settings (`get_settings`, `update_settings`) and `export_video`.
- **Few tools, the whole document.** Instead of one tool per inspector control, `get_project` returns the `ProjectDocument` JSON and `update_project` takes a JSON Merge Patch (RFC 7386) against it, decoded back into `ProjectDocument` before anything changes, so a bad value is rejected with its path. `update_item` does the same for one element of a timeline array (zoom, mask, slice, caption...), so agents never resend an array. `list_options` gives the allowed enum values by field path, wallpapers, mesh presets, cursor themes, presets and music. Operations with their own logic (adding with defaults, splitting, deleting tracks, transcripts, auto zooms, wallpapers that copy a file) keep dedicated tools that call the same `ProjectSession` methods as the UI.
- **Caption tracks are never empty** (`removeEmptyCaptionTracks`), so a new track starts with a starter caption. `add_item caption` with `trackId: "new"` (or with no caption track yet) creates the track and turns that starter into the requested caption, instead of leaving a stray "New caption" next to it. `add_item caption_track` keeps the starter, as the UI does.
- **Undo.** Every tool call that edits is one undo step: it calls `ProjectSession.startNewUndoStep()` first, since agent calls can come faster than the 0.4 s window that merges slider ticks. Items on one track may not overlap: `add_item` and `update_item` refuse a range that overlaps another zoom, camera layout, caption on the same track or mask on the same track, naming the item in the way.
- **Times.** The document stores positions in the recording (`source*Ms`). `get_project` adds `info.slices` with each clip's timeline range, and the tools that work on what the viewer sees (`split_item`, `render_frame`, `export_frame`) take `timelineMs`.
- **Seeing the result.** `render_frame` returns a PNG of the composited frame (`renderCurrentCompositedCGImage`, the export path) and moves the playhead there, so the agent can check its edit and the user sees the same frame.
- **No confirmations, as agreed for agents.** Destructive tools act at once. `delete_project` moves the package to the Trash. `control_recording cancel` deletes the recording in progress (`discardCurrentRecording`, the alert-free path) and says so in its description. A countdown passed to `start_recording` applies to that recording only; camera, microphone and system audio choices change the recording bar like a click there would.
- **Arguments are checked against the schema before a tool runs.** An unknown top-level key or a missing `required` one is an error. Omitting `project` means the frontmost editor, so `delete_project` with a misspelled key used to trash whichever project was in front.
- **Long work.** `export_video` waits until the file is written, sends progress every 2% when the client passed a `progressToken`, shows the Dock progress, and stops on `notifications/cancelled`. `generate_transcript` returns at once; `get_project` reports `info.isGeneratingTranscript`.
- **The user stays informed.** The first agent to connect shows the toast `AI agent connected`, the menu bar menu lists connected clients, `Settings > AI Agents` shows the status and a copyable line for Claude Code (`claude mcp add`), Codex (`codex mcp add`) and JSON clients. Recording always goes through the recording bar and its countdown.
- **Checked:** with a scripted client over the bridge: launch on demand, every read tool, update and patch errors, add, update, split, delete, undo and redo, overlap refusal, `render_frame` (image checked), `export_frame`, `export_video` with 17 progress notifications, an area recording with pause, resume and stop, a cancelled countdown, and the bridge's answer when the setting is off. Then a real Claude Code session (`claude -p --mcp-config`, the bridge starting the app) was asked to style a project, add a zoom, check a rendered frame and export: it used 10 tool calls with no failures, and the exported MP4 (1280×720, 30 fps, 7.6 s) shows the gradient, rounded corners and the 2x zoom. Codex has not been tried.
- **Windows** (`App/Mcp/`, `Core/Mcp/McpDocument.cs`):
  - **Transport.** The server is a named pipe, `NativeScreen.MCP.<user SID>`, created with `PipeOptions.CurrentUserOnly`. A wait for a client is an overlapped pipe wait: 0.00% CPU while listening.
  - **Bridge.** `NativeScreen.App.exe --mcp` is handled in `Program.Main` (the XAML-generated `Main` is turned off with `DISABLE_XAML_GENERATED_MAIN`) before WinUI starts. The app is a GUI-subsystem executable, and it still gets the client's redirected stdin and stdout, so no separate console helper is needed. When the bridge starts the app, it goes through `ShellExecute`. Started directly, the app inherited the bridge's stdout and kept it open, so the client never saw the bridge exit.
  - **Tools.** The same `MCPTools.json` is linked into the app as content. The dispatch is written by hand, like on macOS. Patches are checked by reading the document back with enums limited to their names: the file reader also takes numbers, and `aspectRatioPreset: 7` would otherwise be stored.
  - **Undo.** `EditorSession.StartNewUndoStep` and `ReplaceDocument` give each call its own undo step.
  - **Frames.** `render_frame` renders through the export path (`ProjectExporter.ExportStillAsync`).
  - **Delete.** `delete_project` uses `SHFileOperation` with no UI, and retries for 5 s while a file is still in use. The error names the busy files. A plain `DeleteDirectory` showed an error dialog that left the call waiting with nobody to answer it.
  - **Settings.** `Settings > AI Agents` has the switch, the status and copy blocks. The tray menu lists connected agents. The macOS texts that say Mac, ⌘Z and Trash have Windows keys (PC, Ctrl+Z, Recycle Bin).
  - **Not on Windows.** `launchAtLogin`, `hideDesktopIcons`, `hideDockIcon`, `cameraMaxResolution` and `useLastProjectSettings` cannot be set. `get_settings` says so in `notes`. ProRes export returns an error.
  - **Bugs found by the tests:**
    - **Pause:** pausing a recording threw 0x800F1000, because the bar reused its clock `TextBlock` while the old row still held it. This failed from the UI too.
    - **File lock:** `AudioFileReader` kept a video with no audio stream open after it failed, so a recording without system audio could not be deleted for a while.
  - **Checked** with a scripted stdio client through the bridge:
    - **Setting off:** the first request gets the "turned off" error, and the app does not start.
    - **Setting on:** the bridge started the app. All 28 tools are listed, with no `$ref` left.
    - **Edits:** open, get, set background, add, update and split a zoom, add a mask and a caption, overlap refusals, a bad enum refused with its path, and undo and redo two steps each.
    - **Frames:** `render_frame` returned a 640×360 PNG; `export_frame` wrote a JPEG.
    - **Export:** `export_video` at 720p took 14.5 s and sent 46 progress notifications, and a second export stopped on `notifications/cancelled`.
    - **Recording:** an area recording with no camera, microphone or system audio. A countdown was cancelled; then start, pause, resume and stop opened the new project, which was closed and moved to the Recycle Bin.
    - **Closing:** `close_project` closed the project, and the bridge exited while the app kept running.
  - **Real client:** Claude Code 2.1 registered the server with `claude mcp add` (health check: Connected) and ran open, wallpaper, zoom, render, undo and redo, a 720p export and close in one session, with the recording tools blocked. In PowerShell the copied line failed, because PowerShell drops a bare `--` before `claude.ps1` sees it. The Settings page now quotes it.
  - **Arguments:** `McpDocument.ValidateArguments` is the macOS check, and `add_item caption` takes `trackId: "new"` in one undo step.
  - **Not checked:** Codex, and a recording with a microphone or camera (not opened on this machine, ADR-23).

---

## 53. ADR-53: Releases, Updates and the Website

Releases are built by GitHub Actions only when started by hand, and land as a draft the maintainer publishes. There is no build on push or pull request: macOS and Windows runner time is kept for releases. Setup and the release checklist are in `docs/releasing.md`.

- **One manual workflow** (`.github/workflows/release.yml`, `workflow_dispatch` with version, platforms and pre-release). The version is the input; the build number (`CFBundleVersion`, Windows file version) is the run number, so it always grows. A `check` job refuses a malformed version or an existing tag before any runner time is spent.
- **macOS:** the `xcode-27` runner image, `xcodebuild archive` with Developer ID signing from a temporary keychain, `-exportArchive` (method `developer-id`), then notarize and staple the app, put it in a DMG, sign, notarize and staple the DMG. The Release configuration has the hardened runtime on (notarization requires it); the entitlements already allow camera, microphone and the exceptions the app needs.
- **Updates on macOS: Sparkle 2** (Swift package, the app's first third-party dependency). Writing a signed updater that replaces a running app bundle is not worth doing by hand. `AppUpdater` wraps `SPUStandardUpdaterController`; `SUFeedURL` is `releases/latest/download/appcast.xml`, so the feed is whatever release is published last, with no server. `SUPublicEDKey` comes from the build setting `SPARKLE_PUBLIC_KEY`, empty in the project and set by the workflow: a build without it (every local build) creates no updater, hides `Check for Updates...` and its setting, and never replaces itself with a release. The workflow signs `appcast.xml` with `generate_appcast` from the same Sparkle version as `Package.resolved`.
- **Windows: Velopack**, unsigned for now. `dotnet publish` self-contained, then `vpk pack` (channel `win`) makes `Setup.exe`, a portable zip and the update feed, uploaded to the same release. MSIX is not used for downloads: an unsigned MSIX cannot be installed at all, while an unsigned `Setup.exe` only shows a SmartScreen warning that the README and website explain. Signing is added when the SignPath Foundation application is approved (the spot is marked in the workflow).
- **Draft, then publish.** `latest/download/...` only resolves published, non pre-release releases, so nothing reaches users until the maintainer presses Publish, and a pre-release never auto-updates anyone. Asset names have no version (`NativeScreen.dmg`, `NativeScreen-win-Setup.exe`) so the README and website link straight to the newest file.
- **Website:** static HTML, CSS and a little JS in `site/`, no build step, published to GitHub Pages by a second manual workflow (`site.yml`). Editorial style: paper and ink colors, serif headlines, hairline rules, the app's purple as the only accent, no gradients or glow. Every section is a feature with a demo exported from the app itself; until those exist the page shows labelled placeholders describing what to record. App features are shown with real screenshots and recordings, never drawn mockups; the only interactive piece is the aspect ratio switch. The page follows light and dark and respects Reduce Motion. `tools/demo-page/` is a made-up web app (fake names, emails and keys) to record those demos against; press `?` in it for the shot list. The macOS demos in `site/assets/demos/` and screenshots in `site/assets/shots/` were recorded against it with real mouse and keyboard events, edited and exported through the MCP tools (ADR-52) and exported straight from the app at 60 fps (the recording's rate; 30 fps looked choppy). The hero is 4K: it is shown about 1100 CSS px wide, so a 1080p file is upscaled on Retina screens and the 2560 px window had already been shrunk to fit 1080p, which made text soft. The smaller cards use 1080p60. All use the Social Media compression (hero about 10 MB for 21 s).
- **Second pass on the demos (2026-11-08).** The hero zoomed in, out and back in within a second: three auto zooms 250 to 424 ms apart. Auto zooms closer than 1.5 s now merge (spec/03 §3.1), and the hero was regenerated with one zoom. The mask demo zooms into the blurred fields, then the pixelated key, with labels in frame and a smaller pixel size so both effects read at card size. The cursor demo follows the cursor at 1.7x with motion blur off, so the cursor is large and sharp. The polish section shows one large video per feature (three quarters of the width) and switches before and after takes with a button instead of two small videos side by side. The aspect ratio switcher showed all three videos because `.media { display: block }` beat the `hidden` attribute; `[hidden]` now wins. Numbers measured on the release build, kept off the page because there is nothing next to them to compare with (M4 Pro, macOS 27): 0.0% CPU idle with a project open, about 170 MB (85 MB after closing it, 38 MB at launch), 9.7 s to export the 21 s hero in 4K60 and 3.4 s in 1080p60. Playing the preview uses about half of one core, and memory rises to about 850 MB while playing and drops back on pause, which is worth a look later.
- **Voice for the transcript shot.** A window recording captures audio only from the app that owns the window, so speech from `say` in another process recorded silence. The demo driver now plays a pre-rendered voice file itself (`play` step), and the take is recorded with system audio on.
- **Two-lane H.264 MP4s did not play in Chrome.** Found while making these demos: two sample descriptions switching every GOP. Fixed in the muxer (ADR-01, in-band parameter sets).
- **Recordings stopped early.** While making these demos the screen recording often ended seconds into a take. Cause and fix in ADR-54. Demo videos live in `site/assets/` (tracked despite the global `*.mp4` ignore). `tools/demo-driver/` holds the app that played the takes and the take scripts.
- **Windows app side.** `Program.Main` runs `VelopackApp` before WinUI (after the `--mcp` check, so the bridge stays fast). `AppUpdater` exists only when `UpdateManager.IsInstalled`, checks once a day, downloads in the background and installs only when the user picks `Install update and restart` (tray or Settings). A package is a folder, so there is no file association to register (ADR-41): the uninstall hook removes the Explorer menu key instead. `dotnet publish` leaves out the compiled XAML (`*.xbf`) and `NativeScreen.App.pri` of an unpackaged app, and WinUI then failed at startup (0xC000027B), so a target in the csproj copies them. Checked: `dotnet publish` and `vpk pack` with the workflow's arguments, the published exe starts, and `--veloapp-uninstall` removes the key. Not checked: running `Setup.exe` and a real update. Velopack installs to `%LocalAppData%\NativeScreen`, the folder that also holds `settings.json`, so uninstalling removes the settings.

## 54. ADR-54: Fragmented Recording Without Frame Reordering

### Problem
The screen recording sometimes stopped a few seconds into a take: `display.mp4` ended at a 2 s fragment boundary while telemetry ran to the end, and the editor showed black after it. The writer had failed with `AVFoundationErrorDomain -11800` (underlying `-16341`) and dropped every later frame without telling anyone.

### Cause
The H.264 writer used High profile with frame reordering (B-frames) allowed, the default, together with `movieFragmentInterval = 2s` (ADR-14). That pair fails. A standalone writer reproduces it every time: frames at 60 fps with pauses of 0.3 to 6 s, the way ScreenCaptureKit stops sending frames while the screen is still, fail on every seed with reordering on and never with it off. A steady 60 fps stream does not fail, which is why an earlier synthetic test missed it. In the app the trigger is not only long pauses: on the demo page (frames every ~17 ms) 3 of 4 control takes with reordering on stopped at 2, 4 and 12 s. Turning fragments off also avoids it, but loses crash safety.

### Solution
The screen and webcam writers set `AVVideoAllowFrameReorderingKey: false`. Decode order is then presentation order, the same as the Windows recorder (H.264 baseline, ADR-22). Recordings are intermediates at a high bitrate (4 bits per pixel), so losing B-frames costs no visible quality. The first frame now sits at 0.0 s instead of about 37 ms (no composition offset).

### Verified
9 of 9 takes of 24 s on the demo page reached the end (video within 20 ms of telemetry), with 0 reordered samples. `kill -9` 9 s into a recording still left 8.0 s of playable video. `tools/demo-driver/takes/idle.json` is the take used.

### A failed capture ends the recording
A failed writer drops every later sample without saying so, and a stream that stops by itself (the recorded window closed, permission taken away) sends no more frames. Either way the old app kept recording black or a frozen frame. Now `ScreenCaptureEngine.onCaptureFailed` fires once, on a capture queue, when the screen, webcam or microphone writer reports `.failed` (checked on each sample and on a failed `append`) or `SCStreamDelegate.stream(_:didStopWithError:)` is called. It is not reported after `stopCapture` has begun. `RecordingCoordinator` then stops the recording as if Stop was pressed and shows an alert saying what failed and how much was saved, with the error code underneath. `get_status` reports the reason as `lastError`.

A failed writer is never finished, so `display.mp4` holds only its complete 2 s fragments. The project length is cut to what `AVURLAsset` can play, so the editor has no black tail. Under 0.5 s, the package is deleted and the alert says nothing was saved.

Verified by building with reordering on: the writer failed about 2 s in, the recording stopped by itself about 2 s later, the alert appeared, and the project was 2051.7 ms long, the same as the playable video (before, it would have been about 4.1 s with a black tail). Not tried: the stream stopping by itself, and webcam or microphone writer failures.

### Windows
Recordings already have no B-frames (ADR-22). `ScreenRecorder.Failed` is raised once for a closed window or display and for a failed screen, webcam or microphone writer. `VideoFileWriter.WriteFailed` is set only for recordings: a failed write is reported once, later samples are dropped, and `Finalize` is skipped, so nothing throws on an audio or timer thread. An export still throws. `GraphicsCaptureItem.Closed` did not fire for a closed window (Windows 10 22H2), so the capture loop also checks `IsWindow`. The alert is a message box, because the recording bar is too small to host a dialog. Verified: closing the recorded window ended the recording, opened the project at 3.8 s and showed the alert with `lastError` set. With a writer forced to fail at 5 s, the project was 4.7 s long and played. A webcam or microphone writer failure was not exercised, because those devices are not opened on this machine (ADR-23).

## 55. ADR-55: Mask Handles Use the Compositor's Stage Rect

### Problem
The handles on the preview sat away from the mask they belonged to. `CanvasCoordinateTransform` worked out the screen rect itself, with padding as a fraction of each canvas side. The compositor uses one uniform margin from the shortest side (`calculateFittedScreenRect`). At the default 0.1 padding on 16:9 the frame is 83.3% of the canvas in the compositor and 80% in the overlay, so handles were about 4% too small and drifted further from the mask toward the canvas edges. A new mask also landed away from where it was dragged.

### Solution
The overlay takes `StageLayout.screenRect` from `MetalFrameCompositor.resolvedStageLayout` (now static), as the Windows overlay already does, so padding, device mockup and split screen can not differ. Mask rects are full-frame coordinates, so the transform now also applies the crop. Rendered masks and saved projects do not change.

### Verified
Mask at (0.01, 0.04, 0.2, 0.12) with 0.1 padding: all four handles land on the corners of the blur in the preview.

### Masks are edited under the zoom on screen
The overlay zoomed out to 1x while a mask was being added or was selected, but the compositor's matching zoom-out never ran for the preview. A mask dragged inside a zoom was therefore computed as if at 1x and appeared away from the drag. Zooming the preview out would fix the math but shrink the very text the user is trying to cover, so neither side zooms out now. The overlay maps points through the zoom on screen, with the compositor's camera math, and the drag area is the part of the canvas the recording covers.

Verified at a 1.8x zoom: a mask added by clicking on a field stays centered on the click, with the handles on its corners, and the preview stays zoomed.

### Windows
The overlay already used `stage.ScreenRect`. `CanvasCoordinateTransform` now takes the crop like the macOS one, and the new-mask layer covers the crop. Unit test: `CanvasMappingUsesFullFrameCoordinatesUnderACrop`.

## 56. ADR-56: Decoder Row Pitch on Windows

### Problem
A 1900-wide recording played sheared, in the preview and in exports: every row started 4 pixels further along. Widths that are a multiple of 16 were fine, so tests and most area recordings never showed it.

### Cause
A hardware decoder pads rows to its macroblock width (1904), while `MF_MT_DEFAULT_STRIDE` still says 1900. `IMF2DBuffer` is no help: it reports the pitch of the mapped texture, which is not the layout `Lock` returns, and using it read past the buffer.

### Solution
A locked NV12 buffer is pitch x padded height x 3/2. `VideoFileReader.MeasureStride` tries the width aligned to 1, 2, 4 ... 128 on the first frame and takes the first pitch that divides the luma size into a height just above the video's. Regression test: `UnalignedWidthRoundTripTests`, which fails without the fix.

## 57. ADR-57: Minimum macOS Is 14

macOS 14 is the floor because the app is built on the Observation framework (`@Observable`, `@Bindable`). Going to macOS 13 would mean moving every model to `ObservableObject`, which invalidates every observing view on any change and would redraw the timeline and inspector with the playhead.

The only macOS 15 API in use was `onScrollGeometryChange`, for the timeline's scroll offsets. `onTimelineScrollChange` keeps it on macOS 15 and later; on macOS 14, `TimelineScrollObserver` reads the same values from the `NSScrollView` (bounds and document frame notifications).

### Verified
The project builds with a macOS 14 target. In a scratch build with the macOS 14 path forced on macOS 27, a horizontal and vertical scroll moved the ruler, track labels and scroll thumb with the tracks. It has not been run on a real macOS 14 machine: check capture, microphone, preview, export and timeline scrolling there before a release.

## 58. ADR-58: Camera Background, Stickers and Face Tracking in the Editor

These are applied after recording, so the camera file stays untouched and every choice can be changed.

- **One person mask.** Cutout and backgrounds share the same Vision mask and edge settings. Cutout is a layout (no background at all), so `backgroundMode` is ignored there.
- **Faces are scanned once, not during playback.** `FaceTrackScanner` reads every other frame of `webcam.mp4` the first time a sticker or face tracking is used and saves `assets/face-track.json` (30 KB for a 22 s recording, about 7 s to scan). Editing never needs a rescan, because samples use webcam time and raw frame coordinates.
- **Smoothing needs no lag.** With the whole recording available, stickers use a centered 5-tap filter over unbroken runs, gaps up to 500 ms are bridged, and longer ones fade over 150 ms. A live filter would trail the head.
- **Framing is a separate, slower path.** A 5% dead zone ignores small head movements, then a Gaussian with a 0.7 s sigma. It replaces the old fixed 1.16x zoom, which never looked at the face.
- **Exports wait for the scan**, so a sticker is not missing from the start of a video.
- **Exports use `.accurate` masks** (49.5 ms per 1080p frame, mask 2016x1512) for hair edges, the preview `.balanced` (11.5 ms, 512x384). This also applies to cutout exports.
- **A camera picture is segmented once.** A 30 fps camera in a 60 fps export shows each picture twice, and Vision used to run on both, about 55 s of a 72 s export of a 22 s recording. The compositor keeps the last two masks, compared by decoded frame identity plus crop and mirror: two because the H.264 lanes take turns on different GOPs, each with its own frame reader. Masks are copied out of Vision's buffer, since the other lane's request runs before a kept mask is used again.
- **Background files are named after the source bytes**, so picking an image again reuses its file. Replaced files are not deleted, because undo can restore them.
- **Order:** person mask, grade, composite on the background, sticker. Grading neither tints the background image nor the sticker.
- **Assets:** 13 Noto Emoji stickers, cropped to their artwork because the sizes in `stickers.json` assume that. The Noto headphones are drawn at an angle and cover the face, so they are left out. Camera backgrounds are nine interior photos; the self-drawn wallpapers suit the canvas behind the video, not a room behind a person.
- **Blur without a halo:** the person is removed before blurring, then alpha is raised so the hole fills from the surrounding background.

### Verified
On a 22 s 1080p recording: crown, sunglasses with blur, cat with an image, top hat on cutout, bow with mirror on, and face tracking at 1.7x all rendered correctly. A 1080p30 export with blur and sticker took 27 s, and the sticker was present from the first frames.
