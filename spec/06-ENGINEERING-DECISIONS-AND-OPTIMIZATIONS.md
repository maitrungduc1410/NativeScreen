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
- `HEVC` uses only the hardware lane (software if that lane cannot run, ADR-64). `ProRes` and `GIF` use the same background decoder and main-actor pacing (yield every ~8ms, progress at ~30 Hz).

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
- Retain only the previous and current decoded `CVPixelBuffer`-backed `CIImage` in memory so timeline speed changes (`0.25x–8.0x`) pick the frame at or before the target time without re-decoding (ADR-63).
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
- **Windows:** timeline segments use the same light palettes, the selected outline comes from the palette instead of white, and cursor tiles use the same light grays. Dialogs already followed the theme and the preview has no shadow to shrink. Settings keeps its plain option buttons: WinUI 3 has no built-in segmented control, and a hand-made sliding one and an eased window height looked out of place on Windows, so the window takes each tab's height at once, with its top edge fixed.


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

The UI is available in 15 languages: English, Arabic, Czech, German, Spanish, French, Italian, Japanese, Korean, Brazilian Portuguese, Russian, Turkish, Vietnamese, and Simplified and Traditional Chinese. Strings live in `Localizable.xcstrings`, keyed by the English text. Privacy prompts are in `InfoPlist.xcstrings`.

- **Three ways a string reaches the catalog.** SwiftUI literals (`Text`, `Button`, `Toggle`, `.help`) are extracted by the compiler. Display names and AppKit strings (enum `label`/`title`/`descriptionText`, `NSAlert`, `NSMenuItem`, panels) use `String(localized:)`. Components that take a plain `String` (tooltips, segment titles, inspector rows, context menu helpers) translate when they draw with `String.localizedUI`; their keys are marked `manual` in the catalog, since the compiler cannot see them.
- **Values stay English, labels translate.** State such as a selected preset name or a default track name (`Captions`, `Shortcuts`) is stored and compared in English and only translated when shown, so projects and comparisons do not depend on the UI language. A name the user typed has no catalog entry and is shown as is.
- **Whole sentences.** Plurals and choices are separate keys (`Remove 1 filler word` / `Remove %lld filler words`) rather than words spliced into a sentence, which most languages cannot follow.
- **Filled-in values translate too.** A value put into a translated sentence is a translated string itself, not English built in code. The export estimate's time comes from `1 second` / `%@ seconds`, `1 minute` / `%@ minutes` and `1 hour` / `%@ hours` (`manual` keys, shared with Windows), while `estimateExportDurationString` stays English for the conformance fixtures (`estimates.json`), and the panel calls `localizedEstimateExportDurationString`. Export error messages (`NSLocalizedDescriptionKey`) use `String(localized:)`, since the panel shows `localizedDescription`. A plain `String` passed to `Text` is shown verbatim, so values like the zoom chip's `Auto` / `Manual` go through `localizedUI`.
- **Keys for `localizedUI` text are added by hand.** The compiler only sees literals in `Text` and `String(localized:)`, so a toast, tooltip or hover text passed as a plain `String` stays English until its key is in the catalog (`manual`). A sweep on 2026-11-12 found 26 such keys missing (toasts, timeline trim badges, disabled inspector tab reasons, genre names). Numbered default track names (`Captions 2`, `Masks 3`) go through `String.localizedTrackName`, the same rule as `Loc.TrackName`: the whole name if it has a key, else the translated stem plus the number.
- **Menus.** Top-level menus are matched by title to reorder them, so the match accepts the English title, our translation and SwiftUI's own (`MainMenu` table of SwiftUI), since `File`, `Edit`, `View`, `Window` and `Help` are translated by the system.
- **Standard terms** (Undo, Copy, Save, Cancel, File, Window...) use the system's own translations, read from SwiftUI's tables, so they match the system menus.
- **Language choice** is in `Settings > General > Language` and is stored where macOS keeps the per-app choice from System Settings (`AppleLanguages` in the app's domain), so the two stay in sync. It applies on relaunch; the row offers `Restart Now`.
- **Not translated:** the exported video (keycap names, caption text), file names, product and format names, and the Reel mode mock content's handle.
- **The catalog is shared and Xcode owns its layout.** Xcode rewrites the file when it builds: it sorts the keys in its own order and marks any key the compiler did not extract, unless that key is `manual`, as `stale`. Only the Mac build scans Swift, so Windows-only text (`Loc.T`) and names from JSON (`stickers.json`) look unused to it. Xcode's "Remove Stale" would then delete translations that are still shown. Those keys are `manual`. A key added outside Xcode can land in a different place from where Xcode wants it, and the next Mac build then moves keys around, which can show as thousands of changed lines with no change in content. Commit that reorder on its own, not with a fix.
- **Layout.** German and French run up to 40% longer. Fixed-width labels shrink (`minimumScaleFactor`) or size to their text instead of wrapping: the recording bar's mode labels and the slider `Reset` button were the ones that broke.
- **Seven more languages (2026-11-11).** Arabic, Czech, Italian, Korean, Russian, Turkish and Traditional Chinese (`zh-Hant`, Taiwan terms: 影片, 專案, 輸出, 游標, 剪貼簿) were added to both catalogs and `knownRegions`. Brand, format and platform names stay as they are (`Native Screen`, `MP4`, `TikTok`...). Counts that would need plural forms are written as `Label: %lld` where the language inflects (Russian, Czech, Arabic). Checked by launching in Arabic and Russian.
- **Arabic is right to left.** SwiftUI follows the language: the recording bar mirrors. The editor keeps its left-to-right arrangement (time runs left to right on the timeline, the preview is a picture, the inspector stays on the right) with Arabic text right-aligned inside its controls, which reads fine and keeps the timeline math unchanged.

- **Windows.** The app ships the macOS `Localizable.xcstrings` as content (linked in the csproj) and reads only the chosen language at launch (`App/Localization/Loc.cs`): `Loc.T(english)` falls back to the key, and `Loc.F(key, ...)` turns `%lld`, `%d` and `%@` (also `%1$@`) into `{0}`, `{1}`... and `%%` into `%`.
  - **Where text is translated.** Text is translated where it is shown, not at each call site. That covers the shared helpers (`Ui.Text`, `Ui.Option`, `Ui.IconButton`, `Ui.Tip` for every tooltip, the inspector rows, segment menu rows, command menu items, timeline block titles and track labels), literal `Text`, `Title` and dialog button initializers, and `Loc.Apply`, which walks a window's XAML once after `InitializeComponent`. Ids, tab keys and stored names stay English.
  - **Track names.** `Loc.TrackName` translates a default track name and its number (`Captions 2`, `Voiceovers 2` through `Voiceovers %lld`).
  - **Never `$"..."` for shown text.** An interpolated sentence can never match a key, so it shows in English whatever the helper does. Use `Loc.F` with a whole-sentence key, with a separate singular key for a count of 1 (`Hid 1 face` / `Hid %lld faces`), and translate the filled-in values too (the export time is built by `ExportEstimator.DescribeDuration` from the unit keys, numbers are formatted with the current culture). Text drawn with DirectWrite (`Recording/TargetOverlay.cs`) goes through no helper and calls `Loc` itself. Language names come from `CultureInfo.DisplayName`, which .NET gives in the UI language. A sweep on 2026-11-12 (every UI literal and `Loc.F` key in `NativeScreen.App` checked against the catalog by script) added 66 keys.
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
- **Website:** an Astro site in `site/`, prerendered in all 15 languages (Arabic with `dir="rtl"`, so the stylesheet uses logical properties such as `margin-inline-start`). The privacy policy (`/privacy/`, the URL given to the Microsoft Store) is translated too (`site/src/i18n/privacy/`); English is the binding text, every translation says so at the top, and the build fails if a translation is missing a sentence or changes the shape of a list or table, published to GitHub Pages by a second manual workflow (`site.yml`). Editorial style: paper and ink colors, serif headlines, hairline rules, the app's purple as the only accent, no gradients or glow. Every section is a feature with a demo exported from the app itself; until those exist the page shows labelled placeholders describing what to record. App features are shown with real screenshots and recordings, never drawn mockups; the only interactive piece is the aspect ratio switch. The page follows light and dark and respects Reduce Motion. `tools/demo-page/` is a made-up web app (fake names, emails and keys) to record those demos against; press `?` in it for the shot list. The macOS demos in `site/public/assets/demos/` and screenshots in `site/public/assets/shots/` were recorded against it with real mouse and keyboard events, edited and exported through the MCP tools (ADR-52) and exported straight from the app at 60 fps (the recording's rate; 30 fps looked choppy). The hero is 4K: it is shown about 1100 CSS px wide, so a 1080p file is upscaled on Retina screens and the 2560 px window had already been shrunk to fit 1080p, which made text soft. The smaller cards use 1080p60. All use the Social Media compression (hero about 10 MB for 21 s).
- **Second pass on the demos (2026-11-08).** The hero zoomed in, out and back in within a second: three auto zooms 250 to 424 ms apart. Auto zooms closer than 1.5 s now merge (spec/03 §3.1), and the hero was regenerated with one zoom. The mask demo zooms into the blurred fields, then the pixelated key, with labels in frame and a smaller pixel size so both effects read at card size. The cursor demo follows the cursor at 1.7x with motion blur off, so the cursor is large and sharp. The polish section shows one large video per feature (three quarters of the width) and switches before and after takes with a button instead of two small videos side by side. The aspect ratio switcher showed all three videos because `.media { display: block }` beat the `hidden` attribute; `[hidden]` now wins. Numbers measured on the release build, kept off the page because there is nothing next to them to compare with (M4 Pro, macOS 27): 0.0% CPU idle with a project open, about 170 MB (85 MB after closing it, 38 MB at launch), 9.7 s to export the 21 s hero in 4K60 and 3.4 s in 1080p60. Playing the preview uses about half of one core, and memory rises to about 850 MB while playing and drops back on pause, which is worth a look later.
- **Voice for the transcript shot.** A window recording captures audio only from the app that owns the window, so speech from `say` in another process recorded silence. The demo driver now plays a pre-rendered voice file itself (`play` step), and the take is recorded with system audio on.
- **Two-lane H.264 MP4s did not play in Chrome.** Found while making these demos: two sample descriptions switching every GOP. Fixed in the muxer (ADR-01, in-band parameter sets).
- **Recordings stopped early.** While making these demos the screen recording often ended seconds into a take. Cause and fix in ADR-54. Demo videos live in `site/public/assets/` (tracked despite the global `*.mp4` ignore). `tools/demo-driver/` holds the app that played the takes and the take scripts.
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
The overlay already used `stage.ScreenRect`. `CanvasCoordinateTransform` now takes the crop like the macOS one, and the new-mask layer covers the crop. Unit test: `CanvasMappingUsesFullFrameCoordinatesUnderACrop`. It also uses the compositor's anchor (`ZoomedRect`: the screen's center blending to the canvas center over the first 0.5 of zoom), which only differs under 1.5x or when the screen is off-center. Unit test: `CanvasMappingUsesTheCompositorsAnchorUnderASmallZoom`.

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
- **Assets:** 30 Noto Emoji stickers (13 at first), cropped to their artwork because the sizes in `stickers.json` assume that. The Noto headphones are drawn at an angle and cover the face, so they are left out. Camera backgrounds are nine interior photos; the self-drawn wallpapers suit the canvas behind the video, not a room behind a person.
- **Blur without a halo:** the person is removed before blurring, then alpha is raised so the hole fills from the surrounding background.

### Verified
On a 22 s 1080p recording: crown, sunglasses with blur, cat with an image, top hat on cutout, bow with mirror on, and face tracking at 1.7x all rendered correctly. A 1080p30 export with blur and sticker took 27 s, and the sticker was present from the first frames.

## 59. ADR-59: Voiceover Cuts Share One File

A cut does not write new audio. `fileOffsetMs` says where in the file a segment starts, so a cut stays undoable and costs nothing.

- **Export is bounded by the segment.** It used to insert the whole file, which is harmless for one segment but would play the first half of a cut over the second.
- **The second half starts at the first half's computed end**, not at the cut time. A rounding difference would otherwise read as an overlap and move it to a new track.
- **Trimming the left edge moves `fileOffsetMs` by the same amount**, so the words stay where they are on the timeline. The edge stops where the file begins.
- **Waveform samples always cover the whole file.** A segment draws the part from `fileOffsetMs` to `fileOffsetMs + durationMs`, so a trim is right while dragging and after undo, with no new extraction.
- **Agents can cut too:** `split_item` takes `voiceover`, through the same `splitVoiceover`.

### Windows
The same rules, in `SegmentEdits` and `AudioMixer`. A left-edge trim gets its limit (`SourceStartMs - FileOffsetMs`) at the press, so the block stops at the start of the file while dragging; moves keep the plain neighbor limits. `VoiceoverSplitting` is raised before the edit so the rebuild right after it can draw the waves of the new ids. Verified: `VoiceoverCutMixTests` plays a two-tone file cut in two and moved apart, each half has its own tone and stops on time; in the app, a 1 s left-edge trim moved `fileOffsetMs` by the same amount and undo restored the whole wave.

## 60. ADR-60: Camera Effects on Windows

ADR-58 is the behavior. Windows has no equivalent of Vision, so this records what replaces it.

- **Face landmarks: YuNet, 232 KB, on the CPU.** One small network gives the box and five points of each face, which are exactly what stickers need: both eyes, the nose tip, and the mouth as the middle of its two corners. `Windows.Media.FaceAnalysis.FaceDetector` returns boxes only. The model ships with the app, so stickers and face tracking need no download. It stays off the GPU so a scan does not compete with the preview.
- **Person mask: MODNet through ONNX Runtime.** It outputs a soft matte, which keeps hair edges, and it accepts any size that is a multiple of 32, so one model serves both the preview (320 px on the long side) and exports (672 px). It runs on DirectML and falls back to the CPU. `NS_MODEL_CPU=1` forces the CPU.
- **The input is sampled from the decoded NV12 on the render thread** before inference starts, because the frame's buffer goes back to its pool as soon as the decoder moves on. Four luma taps per pixel keep thin hair from flickering.
- **One mask per picture.** An export compares the `VideoFrame` object plus crop and mirror. Windows encodes on one lane, so one remembered mask is enough where macOS keeps two. The preview runs one job at a time and always draws the newest finished mask.
- **Grading happens before the cutout.** macOS grades an image that already has alpha. The Windows LUT and sharpen passes assume opaque input, so the mask is applied after them. The order against the background (ADR-58) is unchanged.
- **Closing saves.** Windows saves the project when an editor closes and has never asked, so Ctrl+W closes through `Window.Close` with no prompt. A macOS-style prompt would be a new behavior for the title bar's button too.

### Verified
One machine (i9-9880H, Radeon Pro 5500M, Windows 10 19045), the website's 7 s 1080p30 camera clip used as `webcam.mp4`. No camera or microphone was opened.
- Scan: 2.1 s for 105 samples, on the CPU.
- Mask, per picture: 12.7 ms on the GPU and 27.7 ms on the CPU at 320 px; 68.6 and 150.9 ms at 672 px.
- A 1080p export with a photo background and a sticker took 17.7 s at 30 fps and 20.8 s at 60 fps, against 9.5 s at 60 fps with no background. The small rise from 30 to 60 fps shows each picture is segmented once.
- An export started while the scan was running waited, and its first frame has the sticker.

Stickers were placed on one person by eye. Landmarks from another model do not land on the same points as Vision, so check each sticker against a macOS export of the same recording.

### Model downloads (Windows only)

macOS needs no download (Vision and the system speech recognizer). On Windows the person model and each Whisper tier are downloaded once, only when the person asks, and run on the device. `ModelDownloads` owns them for the whole app, so every open editor shows the same state where the model is needed (camera background, cutout, Captions > Model): Download with the size; while downloading, a progress bar moved in place (about a hundred updates, never an inspector rebuild) and Cancel; once on the device, a check mark with the size and Delete, which is off while a transcript reads the model. A cancelled or failed download removes its `.part` file. Pressing Stop on a transcript also cancels the speech model download it started.

## 61. ADR-61: A Camera Is Shut Down Once

`IMFSourceReader` shuts its media source down when it is released, unless told to disconnect. Calling `IMFMediaSource::Shutdown` afterwards fails with `MF_E_SHUTDOWN`, which Vortice throws. In `CameraPreviewSource.Dispose` that fault landed in the device-work chain, so a recording with the camera preview open failed at start, and the same call took the app down when quitting from the tray with the preview open.

`WebcamRecorder.Release` tolerates only that code. The source still has to be shut down when the reader was not released, which happens when the read thread does not stop in time. `StartRecording` also no longer fails because a device could not be closed cleanly.

Errors at the start of a recording go to a message box: a dialog cannot fit in the recording bar's window and was cut off.

No agent has run this with a camera (ADR-23). The error text and stack come from the owner's run and the Windows event log, and the owner confirmed the fix with a camera and microphone.

## 62. ADR-62: Baked Textures Start Cleared

On a macOS 14 machine the background showed two layers: the right mesh in a box around the screen, and other colors outside it. The box was the extent of the blurred shadow, which is smaller than the canvas.

`materializeToGPUTexture` renders a `CIImage` into a new private texture. CoreImage writes only inside the image's extent, and a new private texture holds whatever was in that memory. Apple GPUs happened to give zeros, so the bug never showed on them. On the other machine the old pixels stayed around the shadow, opaque, and covered the background. A test that filled the texture with magenta before the bake kept magenta outside the shadow's extent, and a clear pass in the same command buffer removed it.

Every baked texture now starts with a clear pass, which covers any baked image smaller than its canvas. Preview and export both use this path. The fix was not run on the machine that showed the bug when this was written.

The recording bar on macOS 14 and 15 uses `NSVisualEffectView`, and was see-through with `alphaValue = 0.80` and a rounded layer mask. It now stays at full alpha and is rounded with `maskImage`. macOS 26 and later keep `NSGlassEffectView`.

## 63. ADR-63: Export Holds the Last Frame

A window recording of a mostly still app showed each click's result before the cursor got there, in the export only. A capture writes a frame only when the screen changes, so that file had 12 frames in 12 seconds, up to 3 s apart.

The export reader chose whichever of its two decoded frames was nearest the target time, so a new frame appeared up to half a gap early. The preview was right because the player shows the frame on screen at that time. Export lanes start their own readers at different times, so the early jump also moved around within one export.

The reader now returns the last frame at or before the target, with 0.5 ms for rounding, which is what the preview and the Windows `SequentialVideoSource` do. The cursor and telemetry were never late, so nothing changed in the solver. A reader that starts between two frames gets the held frame stamped with its start time, so a cut lands on the right image too.

## 64. ADR-64: Export Falls Back to the Software Encoder

MP4 export required the hardware encoder, and a 4158x2160 export failed on a macOS 14 machine in both codecs. Apple does not publish the size limits of these encoders, and they can differ by machine, so they are measured. On an M4 Pro the H.264 hardware encoder works at 4096 wide and refuses a session at 4098 (`kVTInvalidSessionErr`, `-12903`), and HEVC works up to 8192 wide. On the macOS 14 machine HEVC got a session and no frame came out. The app must not hard-code a width, which is why it tests the encoder.

A session can be created and still fail every frame, so checking creation is not enough. Before each MP4 export, one throwaway frame goes through a separate hardware session. If no sample comes back, the export uses one software lane, in the chosen codec, at the target bitrate. The probe session is discarded because its frame would clash with the real frame 0.

With no hardware lane there is no bitrate to calibrate against, so the software lane must not wait for one, or the export never starts.

## 65. ADR-65: A Project Is Frozen While It Exports

The exporter reads the live `ProjectSession` for every frame, so an edit made halfway would land in only the second half of the video. An export started in the editor was safe from the user, because its overlay covers the window and the key monitor swallows shortcuts, but an agent could still edit that project. An export started by an agent showed no overlay, so both the user and the agent could edit during it.

- `ProjectSession.isExportRunning` is true during either kind of export.
- An export started by an agent (`AgentExportProgress`) shows the same overlay. Stop and ESC cancel it through the task that runs it, the same way a client's `notifications/cancelled` does.
- While it is true, MCP refuses the tools that change the project, its playhead or its window (`toolsBlockedDuringExport`), including a second `export_video`. Tools that only read keep working.
- `undo` and `redo` return early and `Cut`, `Paste` and `Delete` are disabled, because the menu bar can still be clicked with the mouse. `mutate` is deliberately not guarded: a transcript or scan that finishes during an export would lose its result without any error.

On Windows an export reads a frozen copy of the document, so an edit could never reach the video, but the project on screen would stop matching the file being written. `EditorSession.IsExportRunning` covers both kinds of export, `BlockedDuringExport` is the same list, and `Undo` and `Redo` return early. The card covers the whole window including the menu button, so only the keyboard needed blocking: every key is swallowed while it runs, and Esc stops it, from either source. A client that did not ask for a stop gets an error saying it was stopped in the editor.

---

## 66. ADR-66: Windows Performance and Failure Pass

A review of the Windows port for work repeated without need and for failures that ended the process.

- **Saves in a chain.** Each write waits for the one before it. It must not inherit that one's failure: a file locked for a moment made every later save fail without writing, until the editor closed and the wait threw. `ProjectStore.WriteAfter` keeps the order and drops the old failure, which its own caller already reported.
- **Scratch textures.** Blur needs a same-sized scratch layer. Naming it by size made a new permanent texture for every size of the preview, so dragging a window edge could reach gigabytes of video memory. They now live in a list that keeps a size only while it is used: at most 12, and none unused for 8 composes.
- **What a thread boundary does.** An exception on the render, decode or preview audio thread ended the process, with every open editor and any recording. Each thread now catches at its top. The picture stops with a toast, or the sound stops and the clock falls back to QPC. The GPU is not recreated: the project is reopened.
- **Solving the motion.** The key is computed only after an edit, and holds exactly what the solver reads: cursor, motion, zooms and whether the zoom track is hidden. Slices were in it and the hidden flag was not, so a clip drag solved for nothing and hiding the track did not reach the preview. From 60 s of recording a solve runs on one background worker that always takes the newest edit, and `TrajectorySolved` redraws. The first solve when a project opens is still on the UI thread.
- **Frames that did not change.** A display draws several times per video frame, and a still screen has seconds between frames. The Lanczos downscale and the whole camera chain before the sticker are kept while the decoded frame, the document snapshot and the person mask are the same objects. Active masks change with the time, so they skip the Lanczos cache. The sticker follows the time and is always drawn.
- **Recording's frame cap.** Comparing each frame with the last one kept rounds down to a whole number of display refreshes: 37.5 fps at 75 Hz, 48 fps at 144 Hz. `FramePacer` keeps a schedule, so the average holds at 60.
- **Recording's encoder queue.** Live writers turn throttling off (ADR-23), so nothing bounded the queue, at up to 12 MB a frame. Above 30 frames not yet encoded, screen and camera frames are dropped. `IMFSinkWriter::GetStatistics` is called directly, because the wrapper leaves the structure's size at zero and the call fails.
- **Person masks in the preview.** The render thread only copies the picture. Sampling it for the network, a few milliseconds per picture, moved to the worker, and the tensor and two masks are reused: a new tensor per picture was 21 MB/s on the large object heap.
- **Timeline drags.** Trim badges and ruler ticks are moved on each pointer event, not created again.
- **Export over a still screen.** A seek forward is only useful when the next decoded frame is also behind the target. Otherwise it lands on the same frame again, once per exported frame.

## 67. ADR-67: Zoomed Frames Come From Source Pixels

The screen was scaled down to the fitted rect, composited with its corners and cursor, and the finished layer was then enlarged by the camera zoom. A 3456 px recording exported at 1080p with a 1.8x zoom was therefore shrunk to half and enlarged again, which blurred text that the recording held sharply. CoreImage only joins neighboring affine transforms, so a transform on top of a filter or a composite works from pixels already rendered at canvas size. Removing Lanczos alone would not have helped.

The camera transform is now applied while the screen is drawn. The source is scaled once to the zoomed rect (Lanczos when that is still a downscale), and the corners, inset, cursor and click ripple use the zoomed rect and scale. Soft layers (the baked shadow and the device bezel) are still enlarged after rendering. The rounded mask is not baked during a zoom: its rect changes every frame and can be far larger than the canvas, and CoreImage evaluates only the visible part of the generator. Unzoomed frames are unchanged pixel for pixel.

On a test frame at 1.8x, a sharpness measure (Laplacian variance) went from 110 to 150, limited by the source recording. Windows and the `zoom-follow` and `zoom-manual` fixtures still use the old order (`spec/05`).

## 68. ADR-68: GIF Export Streams to Disk

`CGImageDestination` keeps every added image until it finalizes: a 12 s, 50 fps, 1080p GIF took 10.9 GB of memory. `StreamingGIFWriter` encodes each frame alone with ImageIO, which still does the color reduction and compression, and copies its palette and pixel data into one file.

- Only the rectangle that changed since the last frame is stored, with disposal "keep previous", and an identical frame extends the delay of the one before. Without this the same clip was 3 times larger.
- A frame is written only when the next one arrives, because its delay comes before its pixels.
- Delays are whole centiseconds, so they are rounded from the running total. A 30 fps GIF alternates 3 and 4, and keeps its real length.
- No looping means no `NETSCAPE2.0` block, which every player reads as "play once".

The same clip now peaks at 234 MB (178 MB before the export starts), takes 11.7 s instead of 14.2 s, and is 54 MB instead of 46 MB.

## 69. ADR-69: Every Recorded Track Starts at the First Screen Frame

The camera and microphone files counted from their own first sample, and that offset was stored nowhere, so both played early against the screen. In existing recordings the camera was 0.13 to 0.55 s short of the screen and the microphone 0.08 to 0.16 s short, which also put lips and voice up to 0.39 s apart.

The first screen frame now sets `timelineOriginPTS`, and the other tracks place their samples relative to it. Samples before it are dropped. The gap at the start is filled instead of left empty, because transcription and the waveform read an audio file from its first sample, and a hole in the camera file would show the placeholder portrait: the first camera picture is placed at zero, and the microphone file starts with real silence. Recordings made before this fix keep their offset.

## 70. ADR-70: Recordings Survive a Crash, and Quitting Saves

The video was already written in 2 s fragments, but `project.json` and `metadata.json` only appeared when a recording stopped normally, so a crash left a folder the app could not open.

- A recording now writes `metadata.json` (duration 0) and `recording/in-progress` (the process id) when it starts. The marker is removed once `project.json` exists.
- At launch, a package with a marker whose process is gone is finished from what is on disk: the duration comes from `display.mp4`, and a new project is built from the telemetry. It opens with a toast. A file with under 500 ms to play goes to the Trash.
- `applicationShouldTerminate` does what closing a window does: it asks about unsaved edits, saves pending autosaves and warns about a running export. A recording in progress is finished first (`.terminateLater`).
- `isStartingRecording` closes the gap before `isRecording` turns on, which is several awaits long. Two quick starts used to run two captures, and the first could never be stopped. If a start fails, its telemetry, engine and empty package are cleaned up.

## 71. ADR-71: Export Keeps Heavy Work Off the Main Actor

The export loop runs on the main actor because `composeFrame` reads `ProjectSession`. Building a `CIImage` graph is cheap, but some steps were not, and they blocked every window.

- Person segmentation at `.accurate` runs in `prepareExportFrame` on a background task, before `composeFrame`, which then finds the mask ready.
- `BufferedAudioSamples` decodes and mixes audio on its own thread, up to 32 buffers ahead. The muxer takes what is ready and retries later.
- ProRes rendering and GIF rendering and encoding wait for the GPU on a background task.

With a virtual background, the main thread's response time during an export went from a median of 86 ms (worst 1018 ms) to 2.6 ms (worst 62 ms), while the export took 24.3 s instead of 22.2 s.

## 72. ADR-72: Export Audio Volume Changes Are Constant Ramps

`AVMutableAudioMixInputParameters.setVolume(_:at:)` fades from one point to the next in an `AVAssetReaderAudioMixOutput`, measured over 2 s between two points. A slice's volume bled into the next, and a voiceover that hides the recording faded the microphone out instead of cutting it. Each slice, and each part of a slice under such a voiceover, now gets its own `setVolumeRamp` with equal start and end. Hiding is worked out per slice from source time, so it also holds across cuts and speed changes.

## 73. ADR-73: Detecting the Cursor Kind

`NSCursor.currentSystem` returns a new object on every call, so comparing it with `NSCursor.iBeam` was never true and every recording stored `arrow`. A cursor is now recognized by its hotspot and aspect, as ratios so an enlarged system pointer still matches. Open and closed hand share a shape and are told apart by their image data. Unknown cursors stay `arrow`.

The recorder writes the names in `spec/02` §3.1 (`pointingHand`, `iBeam`, `openHand`, `closedHand`). It used to write `pointer` for the hand, which the renderer read as the arrow sprite (also named `pointer`), so links showed an arrow. The renderer now reads a recorded `pointer` as the hand, which fixes recordings made that way on either platform. The Windows recorder still writes `pointer` and its renderer still maps it to the arrow (`spec/05`).

## 74. ADR-74: Preview Playback Costs

- The timeline tracks read `playedTimelineItemIds`, which changes only when an item starts or stops being under the playhead. Reading the playhead there rebuilt every segment at 120 Hz.
- Motion blur uses the lighter settings during playback, based on `isRealtimePreview`. The old test could never be true after the preview began sharing the export path.
- The preview decodes to the same 4:2:0 format as the exporter and the `CIContext` does not cache intermediates. Exported frames are unchanged pixel for pixel. CPU and memory did not change measurably on the 12-frame test recording.
- `CaptionLineLayout` keeps 4 entries instead of 1, so two projects rendering at once do not rebuild each other's lines on every frame.

## 75. ADR-75: Annotations Follow the Recording, at Output Resolution

Text and arrows point at things in the recording, so an annotation pinned to the frame points at the wrong place as soon as a zoom moves the screen. An item can be pinned either way (`anchor`), and `screen` is the default.

- **Coordinates.** Screen-pinned points use the full-frame coordinates masks use and go through the same crop and zoom transform as the screen (Pass 3B). Frame-pinned points are fractions of the output frame (Pass 5C). Changing the pin converts the points at the playhead, so the item stays where it is on screen.
- **Size does not zoom.** Font size and line width are shares of the output frame. Zooming moves an annotation onto what it marks but keeps it readable, instead of growing a 1.8x zoomed label to cover the content.
- **Drawn, not enlarged.** Each item is rasterized at output resolution with CoreGraphics and placed with a translation. Text is cached by content and pixel size, so moving it costs no redraw. An arrow is redrawn only when its pixel geometry changes (during a zoom), and only the part inside the frame, because a zoom can push its ends thousands of pixels away.
- **Layering.** Screen-pinned items join the screen layer before the cursor, so the pointer stays on top and camera motion blur moves them with the content. Frame-pinned items go above the lens and below the camera.
- **Fades scale alpha only.** `CIColorMatrix` works on unpremultiplied color, so scaling the color channels as well darkened a fading item instead of making it transparent.
- **One place for geometry.** The canvas handles measure text and build arrows with the same `AnnotationRenderer` functions and the compositor's transform (`ProjectSession.canvasTransform`), so a handle sits on what is drawn at any zoom. Only the annotations take clicks; the masks, captions and keycaps under them keep theirs.
- **Shapes zoom, text does not.** A rectangle or ellipse frames something, so its size (`size01`) is in the item's own coordinates and a screen-pinned shape grows with the zoom to keep framing it. Its line width, like text size, stays a share of the output frame.
- **Layers are tracks.** The first track draws on top, matching the timeline from the top down, so a layer is something the user can already see and drag. Bringing an item forward moves it to the track above when that track is free at its time, and otherwise inserts a new track right above it; the result is always above what was in the way.
- **Draw-on is a dash.** A line draws on by stroking with a dash as long as the drawn share of its length (the arrow's length from 16 curve samples, Ramanujan's perimeter for an ellipse), so no path has to be cut. Frames are re-rasterized only during the animation, cached by progress in 1/120 steps.
- **Typing on the canvas.** While a text item is typed into, the compositor leaves it out of the preview and a field in the same font, size and plate sits in its place, so the text is never drawn twice.
- **Keyframes edit where you are.** With keyframes, a drag on the preview changes the keyframe at the playhead (within 120 ms) or adds one, and the item's own geometry stays as the fallback. The compositor and the handles both work on the resolved item, so they never disagree about where it is.
- **Clicks are targets.** The recording knows where the pointer went down. A new arrow points at the first click from 0.3 s before the playhead to 2.5 s after it, a step and a shape sit on it, and dragging a screen-pinned arrow end, step or shape within 12 points of a click from the item's time (plus a second either side) snaps onto it.
- **Typewriter keeps the layout.** The hidden characters are drawn in clear ink instead of being left out, so lines wrap where they will end up and the plate does not grow while typing.
- **An image's shadow follows its alpha.** The clipped picture is drawn in a transparency layer with the shadow set, so a logo with transparent corners casts the logo's shape. Filling the box under it showed a dark rectangle behind those corners.
- **Styles are looks, not layouts.** A style sets colors, line width, fill, corners and animations (an animation a kind cannot play is skipped) and never the text, position or size. Saved styles live in the user defaults and are shared by every project.

## 76. ADR-76: Speaker Notes, Custom Cursors and Recording Profiles

- **Notes stay off camera by being there first.** The capture filter leaves out the app windows with `sharingType = .none` that are on screen when the recording starts. Between recordings the notes window is `.readOnly`, so screenshots show it; it switches to `.none` with the HUD just before the filter is built and back when the recording ends. It can be turned off at any time but on only between recordings: a window opened mid-recording would not be in the running filter. Space plays and pauses the prompter while the window is focused, except when the notes are being typed in. It shows whenever the HUD, countdown or recording is up and the option is on, and closing it turns the option off.
- **The prompter is a clock, not a scroll view.** The offset is the distance scrolled before plus `speed * (now - start)`, drawn by a `TimelineView` that pauses when scrolling stops, so it costs nothing at rest and a speed change keeps the position.
- **A custom cursor is a theme sprite.** The picture is drawn into the same 256 px square as an SVG sprite, at 72% of it (about what a theme arrow fills of its view box) and with the hotspot at the same fraction of the square, so size, rotation, tilt and the hotspot math are unchanged. Only the arrow and the hand can be replaced; the I-beam and crosshair keep the theme so text and drawing still read.
- **Profiles skip what is not there.** A window cannot be saved, so a window-mode profile keeps the mode only. A camera or microphone that is not connected is left as it is, and the "checked" state ignores it, so a profile still matches on a machine without that device.

---

## 77. ADR-77: Camera-Only Recordings Use the Screen Path

A `Camera` capture mode records the camera and microphone with no screen.

- **The camera movie is the screen.** `tracks.displayVideo` names `webcam.mp4` and `tracks.webcamVideo` is null, so the decoders, the timeline, export, recovery and MCP read it with no new code, and zooms, crop, padding, corners, shadow, masks, annotations and captions apply as they do to a screen. Writing it as a camera layer over nothing would have meant a second stage layout for a picture that fills the frame anyway.
- **No device frame.** A camera picture in a laptop bezel makes no sense and the Device Frame tab is unavailable, so the compositor ignores `deviceMockup` for camera-only projects (`usesDeviceMockup`) even when a preset or MCP turned it on.
- **Camera styling moves onto that picture.** Before Pass 2 the compositor runs the frame through the camera preparation (mirror, background blur or image, color grade, sharpen, sticker) with the camera crop left out: cropping is the canvas crop, and there is no delay to adjust since the camera is the picture. The sticker uses the face track scanned from this movie at the source time, so a sticker alone also starts the scan. The masked-screen cache is skipped, since the picture changes every frame and its styling is not in the key. Export segments the person on each frame as it does for a camera background.
- **The first camera frame is time zero.** With no screen stream, the engine sets the timeline origin from the first usable camera frame (cold black frames are skipped as before) and the microphone counts from it, so pauses and the gap fill work unchanged. The duration is the last written frame plus one frame. No telemetry is recorded; the cursor, click and key files are empty, like a project made from a video, and the cursor pass now draws nothing when `cursor.jsonl` is empty (it used to draw a still cursor in the middle).
- **System audio is left out.** It comes from the screen stream, which this mode does not start. The selector is hidden rather than shown off.
- **One preview window from pick to stop.** The large preview is the camera bubble window at a bigger size with an overlay. A flag set when the mode is picked (or a recording is requested) keeps it up through the countdown and the recording, so it is never rebuilt and moved back between steps; Esc, a second click on the mode or hiding the bar closes it. It is `.readOnly`, since nothing on screen is being captured.
- **Framing is a fill rectangle, not a new layout.** `Full frame` and `Cutout` replace the screen rectangle from `resolvedStageLayout` with one that covers the canvas (aspect fill), so every user of that function (compositor, annotation and mask overlays) agrees, and zoom, masks and annotations keep working. They drop corners, inset and shadow; `Cutout` also runs the person cutout on the picture so the canvas background shows around the person. They are not timeline segments yet.
- **One face tracking setting.** `Face tracking` in Camera Style is the same switch and Zoom slider as for the camera layer; an earlier `Keep my face centered` in Camera Layout set the same field under another name and was removed. New camera-only projects start at zoom 1.0, since the camera is the whole video.
- **The face moves the crop and the zoom, not the spring.** With face tracking on, the fill rectangle is enlarged by `faceTrackingZoom` and puts `FaceTrack.framingCenter` (already smoothed, with a dead zone) in the middle, clamped so the canvas stays covered. The framing center sits below the eyes, so centering it already leaves room above the head; an extra 8% lift pushed the head out of a zoomed frame and cut off hats; that is what makes a 9:16 crop of a 16:9 camera follow the person. `ProjectSession.evaluatedCamera` blends the zoom center toward the face as the zoom grows in (fully at +0.25 scale) and clamps it so the zoomed picture covers its frame. Both depend only on the time, so preview and export match; the preview spring is reset on every time change, so it does not lag the face.
- **Notes go under the lens.** Reading near the camera keeps the eyes on the viewer, so while the Camera mode is open the notes window docks at the top center of the screen (autosave off, the user's frame kept) and the preview is placed under it. Closing the mode or hiding the bar puts the notes back.
- **Checked:** two recordings over MCP with pause and resume (camera and microphone tracks start at 0 and end within 30 ms of each other), frames exported with the default frame, with background blur and a 1.6x zoom, the preview window kept through countdown and recording, and the idle preview and bar captured; then frames for Full frame, Cutout, 9:16 Full frame and a 2x zoom (face centered in each) and the docked notes with the preview under them. Not tried by hand: clicking the mode and the record button, dragging the preview, Esc, a head moving across the frame.

---

## 78. ADR-78: Green Screen Is Another Source of the Person Mask

- **One switch, every user of the mask.** `camera.backgroundRemoval` picks where the person mask comes from: Vision (`ai`) or a color key (`green-screen`). The cutout layout, a blurred or replaced camera background and the camera-only Cutout all read the mask in `prepareRecordedWebcamFrame`, so they all key without code of their own, and the edge softness and inset controls work the same.
- **Color cubes, not a new kernel.** The key and the spill removal are per-color functions, so each is a 64³ `CIColorCubeWithColorSpace` built once per setting (cached, a few ms to build): GPU work with no Metal source to keep in sync, and Windows can build the same cubes. Chroma distance in BT.601 CbCr ignores how bright the backdrop is, so uneven lighting keys as one color.
- **Same frame in preview and export.** Unlike segmentation, the key is cheap and exact, so the live preview keys every frame synchronously and exports skip the Vision prefetch.
- **Presets keep the room.** Applying a preset keeps the project's `backgroundRemoval`, `chroma*` and `cameraOnlyFraming`: they describe how this recording was made, so a preset from a green screen project must not key a normal room, and one from a screen project must not reframe a camera-only picture. Only the last few cubes (4 MB each) are cached, so dragging a slider does not pile up memory.
- **Picking the color.** Choosing Green screen samples the average of the top 12% of the camera picture at the playhead (where the backdrop usually shows), with Green and Blue presets and the system color sampler for anything else.
- **Checked:** a generated backdrop video (an uneven green gradient, a figure with a green-tinted rim) as a camera-only project: Cutout with spill 0.5 and 0, a very low similarity, and Framed with background blur, exported over MCP. Not tried by hand: the inspector, the color sampler, detection on a real backdrop.

---

## 79. ADR-79: Drawing While Recording Becomes Annotations

- **Never burned in.** Drawing on screen usually ends up in the video for good. Here the presenter draws on clear panels that the capture leaves out, and each stroke is saved as data. The project gets them as a `Live drawing` annotation track, so a stroke can be moved, recolored, retimed or deleted, follows zoom like any screen-pinned annotation, and replays at the speed it was drawn (`pen` items keep each point's time).
- **The panels exist before the filter.** The capture filter leaves out the app windows with `sharingType = .none` that are on screen when it is built (ADR-76), so one clear, click-through panel per screen is put up just before; drawing only switches it to take the mouse and keys. They sit one level under floating windows, above apps and under the notes and the bar, and are removed when the recording ends.
- **Data, not ink.** Strokes are points normalized to the recorded area, like the cursor, with per-point times, in `telemetry/drawings.jsonl` (written per stroke, so a crash keeps them and recovery converts them). No PencilKit: the frames come from our renderer in preview and export, and Windows reads the same file and draws with the same rules.
- **Drawing is not a click.** The telemetry ignores events from the drawing panels, so strokes and the drawing keys never become clicks, auto zooms or keycaps. The cursor keeps being sampled, so it follows the pen in the video (as a crosshair).
- **Fade or stay, by burst.** Strokes fade together 3 s after drawing stops, on screen and in the project alike, unless `Drawings Stay Until Cleared` is on (read when the recording starts, so the screen and the saved strokes never disagree; a change applies to the next recording); a word or a sketch goes away as a whole. Clear and Undo end strokes at that moment rather than deleting them from the video. Pausing stops drawing.
- **Few tracks.** A track cannot hold overlapping items, and one stroke per track would mean dozens of tracks (all strokes before a clear overlap when they stay). So the pen strokes of one tool and color in a burst become one `pen` item with `strokeStarts` (the replay keeps the pen-up gaps), and the items are packed first fit in start order, which needs exactly as many tracks as things are on screen at once: usually one to three. The cost: strokes merged into one item move and delete together; an undone stroke stays separate so it can end on its own. Tracks drawn first are on top, so a later stroke packed onto a higher track can draw under an earlier one; strokes rarely cross, and the highlighter is see-through. Projects opened with overlapping annotation items are repacked the same way.
- **Checked (bursts and packing):** a scripted `drawings.jsonl` recovered as an interrupted recording: two red strokes merged into one item with a pen-up gap in the replay, a highlighter and an undone arrow on their own tracks, a later burst back on the first track, kept strokes merged and ended by a clear (3 tracks in all), and an overlapping track split on open with its id kept.
- **Checked:** an area recording over MCP with the panels on both screens (left out of capture), strokes written to `drawings.jsonl` (pen, highlighter, arrow, rectangle, clear) turned into the track with the right times, and frames with all four drawn and zoomed. Not tried by hand: drawing with the mouse, the bar's tools and keys, the fade on screen.

---

## 80. ADR-80: No Device Mode; iPhones Are Recorded as a Window

- **iPhone Mirroring is a window.** On macOS 15 and later, iPhone Mirroring shows the phone in a window that ScreenCaptureKit records like any other, and the phone is driven with the Mac's pointer, so cursor telemetry, clicks, auto zoom and click effects all work. Capturing a cabled device (CoreMediaIO screen capture devices) would add a second video source, give no cursor or clicks, and exist on macOS only; Windows has no way to record an iPhone over a cable at all.
- **So the `Device` button is gone** on both platforms (it recorded the whole display meanwhile). An iPhone is picked in Window mode; the iPhone device frame and a 9:16 canvas finish the look.
- **Old files still open.** `CaptureTargetMode` decodes `"device"` as `display`, so recordings and saved profiles from that mode keep working.
- **Left out:** recording a cabled device at its native resolution, or where iPhone Mirroring is not available (Intel Macs without T2, the EU). It can come back as a camera-like source if users ask for it.

---

## 81. ADR-81: Microsoft Store MSIX Build Next to the Velopack Installer (Windows)

Windows ships through two channels from one source: the Velopack `Setup.exe` on GitHub releases (ADR-53) and an MSIX for the Microsoft Store, which Microsoft signs at certification, so Store users get no SmartScreen warning and the Store updates them. `NsPackage=true` (`windows/scripts/package-msix.ps1`) selects the Store build; nothing changes for the unpackaged build or the Velopack publish.

- **Two updaters must never touch one install.** `NsPackage=true` defines `NS_STORE` and drops the Velopack package reference, so the Store build cannot call it: `Program.Main` has no `VelopackApp` hook, and `AppUpdater.Store.cs` (compiled instead of the Velopack `AppUpdater.cs`) is never available, so Settings and the tray hide their update items with no switch of their own. Its `InstalledVersion` is the package version (`Package.Current.Id.Version`); the run number still comes from the file version. `package-msix.ps1` fails if a `Velopack*` file is in the package.
- **Identity is a build input.** Partner Center gives the identity name, the `CN=<GUID>` publisher and the publisher display name once the name is reserved. They come in as `NsStoreIdentityName`, `NsStorePublisher` and `NsStorePublisherDisplayName` (repository variables in CI), and a build target writes them, with `NsPackageVersion` (`major.minor.build.0`, as the Store needs a zero revision; taken from `Version` by default), into a copy of `Package.appxmanifest` under `obj/`. The committed manifest keeps local values (`NativeScreen`, `CN=NativeScreen`) so a test package still builds and sideloads; real identities are never committed.
- **Nothing outside the process keeps the package path.** The package folder is named after the version, so the exe path changes with every Store update. MCP clients get the execution alias `%LOCALAPPDATA%\Microsoft\WindowsApps\nativescreen.exe` (manifest `uap5:AppExecutionAlias`; Settings > AI Agents shows its full path, which also works for clients started without that folder on `PATH`). `App.Restart` and the MCP bridge's launch activate `shell:AppsFolder\<family name>!App` through the shell instead of starting `Environment.ProcessPath`, so the new copy starts as it does from Start, inherits no handles and is always the installed version. `SingleInstance` keys on the package family name when packaged (stable across versions; two versions never run side by side) and on the exe path otherwise, as before. Packaging is detected with `GetCurrentPackageFamilyName` (Win32), because the MCP bridge asks before WinRT is set up.
- **Borderless capture: declared, not left out.** The installed Windows SDK (10.0.26100, `UapManifestSchema_v11.xsd`, type `ST_Capability_Uap_11`) defines `graphicsCaptureWithoutBorder` and `graphicsCaptureProgrammatic` as `uap11:Capability`, the general-use capability element, and Microsoft Learn's capability list puts both under general-use capabilities, which need no Store approval (restricted ones are `rescap:`). The manifest declares `graphicsCaptureWithoutBorder`, required for `GraphicsCaptureSession.IsBorderRequired`. `graphicsCaptureProgrammatic` is only for items made from a `WindowId` or `DisplayId`; the recorder makes items from `HWND`/`HMONITOR` through interop, so it is not declared. `uap11` is in `IgnorableNamespaces`, so Windows 10 still installs the package and keeps the border.
- **Minimum version is 10.0.19041.0 in both places.** `GraphicsCaptureSession.IsCursorCaptureEnabled` (always set) needs Windows 10 2004, so `TargetPlatformMinVersion` went from 17763 to 19041 to agree with the manifest. The MSIX tooling writes `TargetPlatformMinVersion` and `TargetPlatformVersion` (10.0.22621.0) into `MinVersion` and `MaxVersionTested` whatever the source says, so the source manifest shows the same values. Raising `MaxVersionTested` means raising the SDK version of the target framework.
- **Languages are listed.** `<Resource>` entries for the fifteen UI languages of the shared string catalog (en-US first, the default) replace `x-generate`, so the Store lists them.
- **One native runtime per path.** The Windows App SDK (its machine learning part) and the inference packages both bring `onnxruntime.dll` and `DirectML.dll`, and an MSIX holds one file per path (APPX1101; the package script did not build before this). The unpackaged build ends up with the Windows App SDK's copies (onnxruntime 1.27, DirectML 1.15.4 from that package), so the Store build keeps those and drops the others from the payload: both builds load the same binaries. The payload also leaves out `.pdb` files (which skips a symbol package that needs a Visual Studio tool), `DirectML.Debug.dll`, and the arm64 and x86 speech runtimes (the package is x64). Everything loaded at run time sits next to the exe or under `runtimes\win-x64\`, as MSIX ignores `PATH`; `package-msix.ps1` checks the list.
- **Tiles from the real icon.** `windows/scripts/make-store-assets.ps1` draws every logo, tile, splash and `targetsize-*` variant (with `altform-unplated` and `altform-lightunplated`) from the macOS 1024 px icon, cropped to its rounded square, into `Assets/Store`. The Store rejects blank or placeholder tiles, so `package-msix.ps1` opens the built `.msix`, reads `AppxManifest.xml` and fails if an image it names has no file or variant in the package.
- **Read-only package folder.** Nothing writes next to `AppContext.BaseDirectory`: settings, presets, downloaded models (Whisper, person segmentation), background music and MCP frames go to `LocalApplicationData` or the temp folder, which Windows redirects per package for new files. A settings file a GitHub install already created is read and changed in place, so both installs share it.
- **Left as is.** The Store build has no "Open in Native Screen" Explorer entry (`ExplorerContextMenu` already skipped it when packaged; `desktop4:FileExplorerContextMenus` needs a COM `IExplorerCommand` and is not needed for the first submission). The MCP pipe name is per Windows user, not per install, so a GitHub copy and a Store copy running at once would contend for it.
- **CI.** A `store` job in `release.yml`, for stable versions only, builds the MSIX with the identity from repository variables and keeps it as the `store-msix` workflow artifact. It is not attached to the GitHub release (an unsigned MSIX cannot be installed); submissions are uploaded in Partner Center by hand for now.


---

## 82. ADR-82: Windows Port of Annotations, Live Drawing, Camera-Only Recording and Green Screen

The Windows side of ADR-67 and ADR-75 to ADR-80. The macOS code stays the reference; these are the places Windows had to choose.

- **Zoom draw order (ADR-67).** The compositor no longer draws the screen layer at rest size and enlarges it. It works out the zoomed screen rect first and draws the screen, inset, cursor, click and ripple into it, so a zoomed frame comes from source pixels (Lanczos when that is still a downscale). Only the baked shadow and the bezel are placed through the same transform after rendering. Screen-pinned annotations (Pass 3B) need this: they must sit under the cursor and still keep their size, which an enlarged layer could not give. `zoom-follow` and `zoom-manual` were made with the old order and are now softer than both apps; their threshold is relaxed until they are regenerated on a Mac (`spec/05`).
- **Annotations are Direct2D sprites.** Each item is drawn once into its own texture at output resolution (text with DirectWrite in Segoe UI, shapes and pens as path geometries, images through a high-quality bitmap brush), with its soft shadow made by blurring a copy of what casts it (the plate for a text with a background, the whole body otherwise). The sprite is then placed with a quad: a translation, or rotation and scale about the center for text, steps and images. Sprites are cached by content and pixel geometry, as on macOS, but under a pixel budget (48 M pixels) with the least recently used dropped first, since a draw-on makes a new raster per step and GPU memory is shared with the video.
- **Dashes count in line widths.** CoreGraphics dash lengths are in points and Direct2D's in multiples of the stroke width, so the draw-on dash is the drawn length divided by the width.
- **The handles measure like the compositor.** `AnnotationMeasure` lays text out with the same DirectWrite format the compositor uses and reads picture sizes from the file header (orientation applied), so a box on the preview sits on what is drawn. Pixels are top-down on Windows; the arrow's bend normal, rotation sign and shadow offset are mirrored from the CoreGraphics code accordingly (`AnnotationMath`).
- **Green screen is per pixel.** One compute shader evaluates the §7.4 functions directly instead of sampling 64³ cubes: no cube to build or cache per setting, and dragging a slider costs nothing. The result differs from the trilinear cube only within its interpolation error. The mask is taken from the cropped, mirrored picture before the spill step, and the same switch serves the cutout layout, the camera background and the camera-only Cutout. Exports never ask for a segmentation mask when keying. There is no system color sampler on Windows, so the backdrop color is detected from the top 12% of the picture at the playhead, chosen from Green and Blue, or typed as hex.
- **Camera-only recordings.** `CameraOnlyRecorder` opens the camera through the existing `WebcamRecorder`, which reports its first frame brighter than near black; that host time becomes time zero for the camera and the microphone, with the same pause timeline as a screen recording. The duration is the last written frame plus one frame. The package names `webcam.mp4` as the display video; the loader treats such a project as having no camera layer and passes `CameraOnly` to the compositor, which runs the main picture through the camera preparation (crop treated as full, no sticker), replaces the screen rect with the face-placed fill for Full frame and Cutout, drops corners, inset, shadow and bezel, and centers zooms on the face. The stage layout takes the same flags, so the preview handles and the compositor agree.
- **One preview from pick to stop.** The Camera mode opens a 16:9 stage window (thirds, camera name, no-microphone warning, Start recording) fed by the preview source while idle and by the recorder while recording, so it is not rebuilt between steps. The system audio button is hidden in this mode.
- **Live drawing over the recorded display.** A per-pixel-alpha Win32 window drawn with Direct2D covers the display being recorded; it is created when drawing first starts, which is enough on Windows because `WDA_EXCLUDEFROMCAPTURE` applies at once. It lets clicks through (`WS_EX_TRANSPARENT`) except while drawing, and while drawing the telemetry hooks drop clicks and keys so strokes never become clicks, zooms or keycaps; the cursor is still sampled. It takes mouse messages, which a pen also produces, rather than `WM_POINTER`. Strokes go to `drawings.jsonl` as they finish, and `RecordingPackage.Finish` turns them into tracks with the shared conversion (`LiveDrawingEvent.AnnotationTracks`, tested against the macOS rules).
- **Speaker notes switch capture exclusion at any time.** The notes window is left out of capture from the start of a recording to its end and shows in screenshots otherwise; unlike macOS it can be turned on mid-recording. The prompter is the same clock (offset plus speed times elapsed), drawn by a timer that runs only while scrolling.
- **Profiles keep the mode only.** The Windows bar picks a display, window or area for each recording, so a profile restores devices and options, and opens the Camera mode when it was saved there.

Review fixes, so they are not undone:

- **The notes leave capture before the recorder starts.** The recorder's first frame is time zero; excluding the window only after `WaitForFirstFrame` put the notes into it. A start that fails gives the window back to screenshots.
- **The bar stays above the drawing overlay.** The overlay is topmost and takes the mouse while drawing, so the bar is raised over it with `SWP_NOACTIVATE` after every switch to drawing and every tool, color, undo or clear: the bar stays clickable and the overlay keeps the keys.
- **A pen dot draws on.** A pen item replays by its own clock only when its last point time is above 1 ms; a single click (one point at 0 ms) otherwise stayed at progress 0 and never showed. Fixed on both platforms (`Annotation.swift`, `Annotation.cs`).
- **The default preset comes before face tracking.** As on macOS, a camera-only project turns face tracking on after the default preset is applied, since the preset replaces the camera settings.
- **Camera-only pictures keep their inset with a device mockup on**, because no bezel is drawn for them; the same source size (no 640 × 400 floor) is used to place new annotations as to draw them; MCP checks annotation overlaps with the track's 20 ms tolerance.
- **Nothing slow repeats per frame or per keystroke.** A cached text sprite keeps its box, so the render thread makes no DirectWrite layout for it; a custom cursor that cannot be read is remembered and old tip positions are dropped; handle sizes of pictures come from the file header, not a decode on the UI thread; the notes write the settings once typing settles.
- **Text is typed into on a counted double-click.** Every click rebuilds the preview handles, so the second click of a double-click lands on a new element and `DoubleTapped` never forms; the overlay counts two presses on the same item within the system double-click time instead. The profile name is asked for in a flyout, since a dialog would be clipped to the bar.

## 83. ADR-83: Long Recordings: Repeated Frames on a Still Screen and a Free Disk Space Guard

A review of hour-long recordings (an 11 minute macOS soak, then `kill -9`) found memory flat at 77 to 114 MB and the killed file readable to within 2 s. Nothing in the capture path grows with the length of a recording except the files themselves: telemetry is written line by line, the writers keep a few bytes of sample table per frame, and a writer that cannot keep up drops frames (`isReadyForMoreMediaData` on macOS, the backlog limit of 30 on Windows) instead of queuing them. Two gaps remained.

- **A still screen wrote no fragments on macOS.** ScreenCaptureKit sends nothing while the screen does not change, and a writer with no new samples finishes no fragments. A crash 20 minutes into talking over one slide left `display.mp4` ending at the last change, and recovery (ADR-70) sizes the project from that file, so the microphone after it was lost as well. `ScreenCaptureEngine` now repeats the last frame at the current time when nothing was written for 1 s (a timer on the video queue, skipped while paused). A repeat can be written after a real frame was captured but before it reached the queue; that frame is moved 1 ms after the repeat rather than dropped, because a still screen may send nothing after it. Windows already did this (`ScreenRecorder.RepeatLastFrame`, every 250 ms). Repeats stop the moment Stop is pressed, before the stop time is taken, so the video never outlasts the microphone; and only a frame that reached the file moves the last written time. Checked by dropping real frames after 3 s: a `kill -9` at 23 s left a readable 22.5 s file.
- **A full disk failed the writers.** The fragments written before survived, but the project file and the end of the movies need space too, and nothing told the user. A recording no longer starts with less than 2 GB free on the projects folder's volume (`volumeAvailableCapacityForImportantUsage`), and stops by itself, like Stop, when free space falls under 500 MB, checked every 5 s off the main thread. The start check runs once, in `requestStartRecording`, which every start goes through; an MCP start gets the message as its error instead of a modal alert. 2 GB is about half an hour of a busy Retina screen (about 3.7 GB an hour measured); 500 MB leaves room to finish the files at any bitrate the app writes.

Considered and left out: a keyframe interval in seconds (`AVVideoMaxKeyFrameIntervalDurationKey`) next to the 60-frame one. A still screen stretches a GOP in time but not in frames, so seeking still decodes at most 59 frames, and more keyframes would only grow the file.

## 84. ADR-84: An Item's Way Out Starts on Its End (Tried the Other Way, Reverted)

A zoom, loupe, camera layout segment, voiceover with "Hide recording" or caption block animates in from its first frame, and animates out starting on its last frame, so the way out plays after the playhead has left the item (about 380 ms for the stage, up to about 1.2 s for a zoom spring, about 100 ms for a caption).

On 2026-11-12 and 2026-11-13 we tried the opposite rule: finish the way out inside the item's last moments, so nothing of it is left once the playhead leaves it and the preview matches the timeline exactly. The camera layout exit shipped on both platforms, then zooms, loupes, voiceover hides and captions on macOS (zoom out started one spring settle time before the block's end and was blended onto full frame on it; captions faded over the last 150 ms of the block). It was reverted on both platforms:

- **It looked worse.** Zooms and layouts started leaving while the moment they were made for was still on screen, and every short item lost half its time to animation.
- **It made editing harder.** In a screen recording a segment means "start the effect here, and start undoing it here". With the early exit, the end of a block no longer marked where the undoing begins, so blocks had to be stretched past the moment they were meant to end on.

Do not bring the early exit back. If the lag after an item ever needs work, change how fast it settles, not where it starts. Masks, annotations and shortcut keycaps were never part of this: they show only inside their items and fade within them, which suits overlays that sit on top of the recording.

## 85. ADR-85: Mac App Store Build Next to the Notarized DMG

The Mac App Store requires the App Sandbox; the DMG build keeps it off. A second Xcode target, `NativeScreen AppStore`, builds the same sources (the synchronized `NativeScreen/` folder) with the Swift flag `APPSTORE`, `NativeScreen-AppStore.entitlements` (sandbox, camera, microphone, user-selected files, app-scoped bookmarks, `~/Movies` and `~/Downloads`), `Info-AppStore.plist` (no Sparkle keys, `ITSAppUsesNonExemptEncryption` off) and no Sparkle package. Both use the bundle ID `com.dmai.NativeScreen`. It is the macOS side of ADR-81: what the sandbox rules out is turned off with `#if APPSTORE`, and the DMG build is unchanged.

- **Updates.** `AppUpdater` is a stub that is never available, so the menu item and the setting stay hidden. The store updates the app; two updaters must never act on one install.
- **AI Agents (MCP) are off.** The sandbox puts the socket and the `--mcp` bridge in the app's container (the socket path would also pass the 104-byte `sun_path` limit there), and an agent could not reach projects outside the folders the user granted. `MCPServer.applySetting` returns early, `--mcp` is not handled, and the settings tab is hidden.
- **Keystrokes come from a listen-only event tap.** `NSEvent.addGlobalMonitorForEvents(.keyDown)` needs Accessibility, which a sandboxed app cannot be given; `KeyEventTap` (`CGEvent.tapCreate`, `.listenOnly`) needs Input Monitoring instead, asked for with `CGRequestListenEventAccess` when a recording starts. The tap sees keys typed into the app as well, so the local monitor takes only mouse events in this build. Keys typed while the live drawing panel is key are skipped, as before. The Esc monitor of the picker and countdown still works only while the app is active.
- **Other apps' windows cannot be resized** from the window picker (`WindowDiscoveryService.canResize`): that also needs Accessibility. Window corner radii fall back to the defaults for the same reason.
- **Files.** New projects go to `~/Movies/Native Screen Projects` (the sandbox's home folder is the container, so the real home comes from `getpwuid`). `SandboxAccess` keeps a security-scoped bookmark for each folder the user picks (projects, presets, still frame exports) and for each recent project, and reopens them before anything else at launch. Pictures, audio and LUTs picked in the editor are copied into the project, so they need nothing. An MP4 export with `Both` codecs would write a second file next to the one the save panel granted, which the sandbox refuses, so this build offers H.264 or HEVC alone.
- **Privacy manifest.** `PrivacyInfo.xcprivacy` (in both builds) declares no tracking and no collected data, and the reasons for UserDefaults (`CA92.1`), system uptime (`35F9.1`, recording clocks), free disk space (`E174.1`, ADR-83) and file timestamps (`C617.1`, `3B52.1`, recent projects and LUT caching).
- **Checked on a Mac:** both targets build in Debug and Release; the App Store app has no `Frameworks/Sparkle.framework`, carries the sandbox entitlements, and launches with no sandbox denials. Recording, keycaps under Input Monitoring, bookmarks across relaunch and the language relaunch (`/bin/sh` from the sandbox) are not checked yet.

## 86. ADR-86: Crop-Safe Playback Motion and a Sharp Loupe Scene

Motion used recording time even after speed edits and cuts. Cursor/click overlays and zoom focus also used original normalized positions on an already-cropped screen. A fading Loupe replaced the screen camera's center and suppressed its transform, and the lens enlarged a canvas-resolution input. These are derived-state/rendering bugs, not package-format changes.

- **Time:** `PlaybackTrajectorySolver` projects retained cursor/click/zoom data into edited time. Adjacent source-contiguous slices share history, including speed changes; real cuts start separate 120 Hz trajectories. Incoming cursor and active camera/lens targets are initialized at the cut. Expand sparse recording-time pause holds before time projection, so slowing 60 Hz footage does not falsely turn its samples into stationary gaps. Use explicit timeline time in preview, all exports and slice visibility. The incoming slice owns a boundary; neither interpolation nor motion blur crosses a cut. Slice edits invalidate cursor and camera caches.
- **Space:** keep telemetry, manual focus and click waves normalized to the original recording. Group bounds use the crop-scaled viewport; targets enter crop space before camera solving, cursor/clicks only before drawing. Do not clamp outside points to crop edges. Crop edits invalidate camera groups but can reuse the cursor trajectory.
- **Interaction:** superseded by ADR-87. Insert derived down/up samples. A button held through a trim anchors the drag but makes no click wave. Clock offsets of older recordings: ADR-88.
- **Loupe:** follow the same resolved focus groups as the camera, retaining the existing slow decorative drift and glass shading. `center01` and `loupeCenter01` are independent crop-space centers. Invisible glass prewarms toward the next focus for 450 ms, including during the preceding screen zoom; a visible exiting lens is not moved by prewarming. The screen camera keeps settling while glass appears/disappears. Exits still start on the item end (ADR-84).
- **Sharp content:** render a second, pre-magnified scene directly from source pixels at lens scale, with privacy masks, screen annotations, cursor, frame and background. Give the compute kernel only an integral patch with half-side `1.7 * radius + 2`, independent of zoom. Preserve rim bend, fringe, gloss and shadow; sample the patch without dividing offsets by zoom again. Carry each texture ROI's canvas origin into Metal. Webcam, keycaps, captions and canvas annotations stay above the lens.
- **Auto zoom:** merge generated intervals with gaps strictly below 2500 ms, preserving typing hold and tail margin. A useful reading pause should not cause a zoom-out/in detour.

Verification is reproducible with `--verify-motion <output-folder>` (synthetic math checks and real GPU pixels). Motion fixtures are generated separately with `--generate-conformance conformance/motion-v2 --motion-only`; edited-time rows/frames cover crop, speed, cuts, repeated footage and screen/Loupe transitions. Windows needs the ADR-86 port before these replace its legacy motion expectations. 

- **Windows.** `Core/Motion/PlaybackTrajectorySolver.cs`, `MotionGeometry.cs`, `CursorTelemetry.cs` and the camera loop of `SpringTrajectorySolver.cs`, ported line by line. The solver API names the clock: `EvaluateAtTimeline` for rendering, `EvaluateAtSource` for editing helpers (first occurrence), so no caller mixes the two by accident. `ComposeRequest` carries `TimelineMs`; the live preview clock returns edited time (`EditorSession.LiveTimelineClock`) and the request derives its source time per frame. The editor re-solves when slices or the crop change, keeping the cursor when only zooms, motion or crop changed. The sharp lens (`FrameCompositor.Lens`) draws the screen scene a second time through a `SceneView` (magnify about the lens center, move to the patch origin) into a square patch of half-side `ceil(1.7 * radius + 2)`: screen, inset and cursor are drawn from source pixels at lens scale; shadow and bezel reuse their canvas bakes through a remapped placement; screen annotations pass the view to `DrawSprite`; the ripple and the patch have their own layer names so neither recreates the canvas textures. `MagnifierLens.hlsl` takes the patch as `t1` and samples `center + offset * bend - contentOrigin`. Measured on the demo project at 60 Hz: compose and present 4.9 ms median with the lens against 5.3 ms without it.No media or telemetry migration is needed.

## 87. ADR-87: Planned Cursor Sync Instead of an Error Disc

ADR-86 kept the fixed lookahead and drag/click speed boosts, then pulled the solved tip into a disc around the raw cursor. With hover sync on (the default) the disc was 24 capture pixels everywhere, so a Retina recording lost its glide: the cursor followed the raw path and its frame-to-frame speed changed more than the raw cursor's. With hover sync off, entering the 180 ms click window clamped a lag of a few hundred pixels at once, a visible jump.

- **Planner:** `CursorPathPlanner` plans the cursor as a plain spring on `path(t + lead(t))` with speed `s(t)` (stiffness x s^2, damping x s), lead and speed raised only where an anchor needs them, smallest speed level first, then smallest lead, error measured at the anchors. Constants and rules are in spec/03 section 2.2. The spring never gets a position correction, so velocity is continuous.
- **Anchors:** down/up and held-button samples at 2 pt, cursor-shape changes at 4 pt (hover sync) or 6 pt. NativeScreen records no hover changes; shape changes are the closest signal.
- **Units:** tolerances, shake filtering and rotation use capture points (`logicalBounds`), not pixels, so Retina and standard captures behave the same.
- **Merging:** a failing group is also merged with the previous one while that group's lead is still decaying (span at most 4000 ms). Without it, about 1% of clicks in fast synthetic sessions missed by up to 30 pt, since a large lead chosen at 1x decays at only 0.35 ms/ms.
- **Cost:** the planner simulates at 1 ms. A 10 minute synthetic session (26k samples, 760 clicks) solves in about 0.4 s in a Release-optimized probe; the result is reused while only zooms or crop change.
- **Measured** (synthetic, 1728x1117 pt): every click within 1.5 pt (max 1.64 pt over about 3000 clicks), drags within 1.5 pt, peak speed of a 150 ms flick 3.9 pt/ms against 8.6 raw, largest frame-to-frame speed change 0.66 pt/ms. For comparison on a 3456x2234 capture, the ADR-86 disc changed speed by up to 1.88 px/ms per frame (raw cursor 1.64, previous lookahead solver 0.64), and the click window jumped from 6.1 to 14.1 px/ms in one frame.

`--verify-motion` covers click/drag tolerance, no speed jump and kept glide for a flick ending on a click.

- **Windows.** `Core/Motion/CursorPathPlanner.cs` and `PlannedCursorPath.cs`. The Swift curves are value types; in C# `LeadCurve` and `SpeedCurve` are classes and every copy that is then extended is a `Clone()` (context, trial knots, committed state, the state saved before a commit). The motion checks without a GPU are `MotionRegressionTests` (same inputs and thresholds), and the lens checks are `SharpLensTests`.

## 88. ADR-88: Older Recordings on the Video Clock, Checked on Real Projects

Before 2026-10-26 the telemetry clock started before capture, so cursor, clicks and keys run late by the startup delay. The solver used to subtract the first cursor sample's time when it was between 60 and 900 ms. That guess overshot by 30 to 70 ms and skipped recordings whose first sample came later; four of the ten older recordings here were 0.9 to 1.4 s off. ADR-86 removed the guess, leaving all of them off.

- **Detection:** current recordings always write a cursor sample at exactly `t = 0`. A later first sample marks an older recording.
- **Delay:** telemetry and capture stopped together, so `D = min(firstCursor.t, max(0, lastEvent.t - durationMs))` (ignored below 20 ms). On the ten older recordings the first move then falls 28 to 71 ms after the first frame. On the Xcode recording every corrected click is followed by a UI change 7 to 39 ms later (149 ms for the first); raw click times line up with nothing and some fall after the end of the video.
- **Where:** `ProjectSession.load` moves cursor, clicks and keys by `-D` in memory (`LegacyTelemetryEpoch`). Files are untouched. Zooms already saved in such projects keep their times.
- **Click samples:** a click more than 16 pt from the recorded cursor and from both bracketing samples is not inserted into the path. Real recordings agree within 1 pt; the sample project placed its clicks away from its cursor and is fixed to click on it.
- **Windows.** `LegacyTelemetryEpoch` runs in `LoadedProject`, so the editor, exports and the MCP tools all see corrected events; the files are never rewritten.

`--verify-projects <output> <package>...` copies real projects and checks them headlessly: click accuracy and frame-to-frame speed on the edited timeline, frames at clicks, a full 1080p60 MP4 export (duration and frame count), and composition time. Results on an Apple M4 Pro (Debug build), six recordings including three older ones, a 43 s edited timeline with a cut and a cursor warp:

- **Cursor:** 52 of 53 clicks within 1.5 pt (mean 0.4 to 1.0 pt); the other is 3.4 pt, a click 12 ms before the recorded cursor jumps 363 pt. Largest frame-to-frame speed change 0.4 to 2.1 pt/ms, except that warp (19 pt/ms, raw 22).
- **Export:** all six finished; durations within 15 ms of the timeline, 60 frames per second.
- **Sharp Loupe cost** (median / p95 ms per frame, GPU complete, distinct frames): 1080p 3.7/4.4 to 10.4/15.0, 4K 6.8/10.5 to 14.9/18.2. Compared with no zoom: +0.8 to +1.9 ms median at 1080p, +2.3 to +3.7 ms at 4K. A 4K preview frame with the Loupe can exceed 16.7 ms on heavy recordings, where 4K without any zoom already reaches 17.8 ms p95. With the default radius (0.35) the lens patch is close to the canvas size, so the bound mainly matters for small radii.
- **Aside:** no zoom costs more than a 2x screen zoom (6.2 against 2.9 ms at 1080p) because the Retina source is Lanczos-downscaled to the canvas. That is a separate optimization.

Not checked: driving the editor UI (live playback pacing, scrubbing). The preview uses the same compositor and solver calls with explicit timeline time.

## 89. ADR-89: Right-to-Left Captions

Captions are laid out word by word, each word in its own box, so the words can be timed and animated. Offsets were accumulated left to right for every language, so an Arabic or Hebrew line put its first word on the left and read backwards. Each word was shaped correctly; only the order was wrong.

- **Direction per line:** from the first strong letter of the line's text (Unicode bidi rules P2 and P3). RTL letters are the alphabetic scalars in U+0590 to U+08FF, U+FB1D to U+FDFF, U+FE70 to U+FEFF, U+10800 to U+10FFF and U+1E800 to U+1EFFF. Digits, punctuation and spaces are neutral; a line with no strong letter is left to right. A mixed line follows its first strong letter, and its words keep their logical order in that direction (no reordering of embedded runs).
- **Mirroring:** a word's place is `contentWidth - leftToRightOffset - width`, using the content width at that time. This one rule covers every reveal style: the line reads from the right, `Expanding` grows from the right edge, `Slide in` arrives from the left, and `Word by word` pushes the previous word out to the right.
- **Unchanged:** timing, box size, fonts, spring and the text shown on the timeline and in the inspector, which is drawn as a normal string.

`--verify-motion` checks direction detection, word order in four styles for Arabic and English, growth from the right edge, and writes `caption-rtl.png`.

- **Windows.** `Core/Captions/CaptionLineLayout.cs`: `Line.IsRightToLeft` from `IsRightToLeft(text)`, which walks the `Rune`s and lets the first letter decide (the same ranges; `Rune.IsLetter` only differs from `isAlphabetic` on combining marks, which never come first). The expanding line is anchored at the right edge and `TargetWordOffset` mirrors `LeftToRightWordOffset`. DirectWrite still draws each word on its own and shapes it joined. `CaptionDirectionTests` has the macOS checks with a fixed-width measure.

## 90. ADR-90: Windows User Data Outside the Installer's Folder

The GitHub build's installer uses the package id `NativeScreen` and installs into `%LOCALAPPDATA%\NativeScreen`. The app kept its own data in that same folder: `settings.json`, `Presets`, `Models` (person model), `WhisperModels` and `BackgroundAudio`. Uninstalling that build deletes the whole folder, so a user who removed it in order to install the Store build lost their settings and presets and had to download the models again.

- **Folder:** `%LOCALAPPDATA%\NativeScreen Data` (`Core/Storage/UserDataFolder.cs`). Every user data path goes through `UserDataFolder.PathOf`. The package id stays `NativeScreen`, because changing it would stop updates for existing installs.
- **Migration, once per start:** each known item that exists in the old folder and not in the new one is moved there (a rename, so the models are not copied). If a move fails because a file is in use or access is denied, `settings.json` and `Presets` are copied instead and the models stay where they are, to be downloaded again when needed. The installer's own files (`current`, `packages`, `Update.exe`) are never touched. The migration never throws and never overwrites newer data.
- **Store build:** an MSIX app's writes to `%LOCALAPPDATA%` go to its package's private copy, which Windows removes on uninstall, and this applies to the new folder name as well. That is the Store's normal behavior.
- **Tests and trial runs:** `NS_LOCAL_APP_DATA=<folder>` replaces `%LOCALAPPDATA%` for user data. The Core and Rendering test assemblies set it to `%TEMP%\ns-test-local-app-data` in a module initializer, so tests never move or write real data. `UserDataFolderTests` covers the move, the installer's files, existing data, files in use and a repeated run.
- **macOS:** not affected. The app's data lives in its own container and Application Support, apart from the app bundle.

## 91. ADR-91: Automatic Masks Packed Into Tracks Without Overlaps

A track never holds two items at the same time: adding, moving and the MCP tools all check it, and the timeline draws one row per track. The sensitive data and face scans broke that rule. Each scan put everything it found on one new track, so two regions on screen together (an email in a sidebar that is still visible when a settings page with another email slides in) landed on the same row, drawn on top of each other. A rescan also removed the old automatic masks but kept their track, so every scan left an empty "Masks n" row behind.

- **Packing:** `ProjectSession.replaceAutoMasks` sorts the scan's masks by start and puts each one on the first new track whose last mask has ended by then (`end <= start`, so back-to-back masks share a row), opening another track only when none fits. The result is the fewest rows that hold the scan without overlaps.
- **Own tracks:** automatic masks still go on tracks of their own, never into the user's free space, so turning the scan off or rescanning removes exactly what the scan made.
- **Old tracks:** a track made only of the kind being replaced is removed with its masks. A track that also holds a user mask (one dragged in by hand, say) stays, minus the automatic ones. Turning a scan off goes through the same function with no masks, so it leaves no empty row either.

Checked on a 21 s recording whose two detected emails overlap by 0.5 s: two tracks, no overlap, and a second scan leaves the same two tracks. Windows: `TranscriptEditing.Replace` has the same single-track code and needs the same change (see `windows/HANDOFF.md`).

## 92. ADR-92: Windows Editor Chrome Matches macOS

The owner listed several places where the Windows editor looked or behaved unlike macOS. Each follows the macOS view now.

- **Export and still-frame modals:** the card used a fixed dark fill, so in the light theme its dark-on-light text was invisible. It now uses `SurfaceModal`, set again each time the card opens, so a theme change in between applies. The still-frame preview well is black at 45 % (dark) or 5 % (light), as on macOS, and shows a small `ProgressRing` until the rendered frame has decoded (`ImageOpened`), or until rendering fails.
- **Crop editor (recording and camera):** laid out like `StandaloneCropWindowView`. The top bar has Size W × H, the preset menu (Full Original, 16:9, 9:16, 1:1, 4:3), Position X Y and Reset; Reset fades when nothing is cropped. Eight dark handles ringed in white surround the frame, with a dashed rule-of-thirds grid and a 62 % black shade outside the crop. Confirm changes and Discard changes are centered below. Unlike macOS, the size and position fields are editable, in pixels of the recording. A typed size keeps the position when it fits. The preset menu names the preset the crop matches (Full Original, 16:9 Widescreen, Custom, ...) instead of the macOS "Select...", which read like cut-off text; the button grows with the translated name. The top bar covers the title bar, so while it is open its controls are the window's only click-through region (`UpdateTitleBarRegions`) and the rest of the bar drags the window. The frame follows window resizes. `RootKeyDown` routes keys while the editor is open: Esc discards; Enter confirms, unless a field is being typed in, where Enter commits the value; other keys never reach the timeline behind it.
- **Segment titles:** 11.5 pt semibold at 55 % white, as on macOS (was 11 pt regular).
- **Selection outline:** a 1 px line in the palette's `selectedOuterOutline` color, 1.5 px outside the segment; the segment keeps its normal ring. A rounded WinUI panel clips its children, so a child with a negative margin is cut off. The outline is therefore the segment's sibling on the timeline canvas: it follows the segment's place and size on `LayoutUpdated` and joins its row's wiggle.
- **Shortcut segments:** replaced by ADR-93 (the emerald palette); only the 12 pt semibold, 96 % white label remains from this change.
- **Preview:** a 1 px ink outline at 8 % always marks the frame's edge. In the flat style there is no shadow, so without it a white recording merged into the light editor. On hover the outline goes to 28 % and 1.5 px and a 3.5 % ink wash fades in over 150 ms. A press on the bare preview (not on a mask, annotation, keycap or caption) closes what is open and shows the Background inspector. While a new mask is being placed, a press does not do this.

## 93. ADR-93: Shortcut Segments Drawn Like the Other Tracks, in Emerald

Shortcut segments had a view of their own. They were a see-through gradient (42 % at the top to 8 % at the bottom) with a light glow along the bottom, a white outline when selected and a colored shadow, tinted with the keycap color, which is `#4D2FF5` by default. Three problems came out of that. They always looked dimmed next to the solid segments of every other track, so they seemed to dim along with any selection and only "lit up" when clicked. Their default color is the dark zoom fill and close to the light one, so the two rows read as the same thing. And selecting a shortcut did not dim the other shortcuts, the rule every other track follows.

- **Body:** `ShortcutTimelineSegmentView` now draws `SegmentBodyCanvas` with a `.shortcut` palette, the selection outline in that palette, and the same opacity rules as `TimelineInteractiveSegmentView`: 0.50 when hidden, 0.30 when another shortcut is selected. Selecting an item on another track leaves shortcuts alone, as it leaves every other track. The bottom glow and the shadow are gone. Its drag, resize, track move and menu are unchanged.
- **Color:** emerald, the one hue no other row uses (clip amber, zoom violet, mask and voiceover magenta, caption teal, annotation coral, camera layout gray). Light `#2E9E6A` to `#4FC38D`, dark `#1C6B47` to `#2A9966`, built the way the other palettes are. The hover `+` preview uses the same palette.
- **Keycap color:** the segment no longer follows the keycap color chosen in the inspector. That color still drives the keycaps in the video; the timeline colors a row by what it is, like every other track.

Windows draws shortcuts with the camera layout palette and a violet add ghost; the port is in `windows/HANDOFF.md`.

## 94. ADR-94: Known Issue, Not Fixed: Window Capture Can Write One or Two Shrunk or Shifted Frames

Seen once, on macOS, recording a Chrome window (3840 × 2160, 60 fps). About 1.7 s after a click on a download link, while Chrome put its download icon in the toolbar, `display.mp4` got two frames out of place: in the first the whole window is scaled down slightly, leaving a black band along the right and bottom edges; in the second it is shifted right, leaving a band on the left. The next frame is normal again. In playback it shows as a short jump; paused on that frame it looks like a black scrollbar. Nothing moved on the real screen.

- **Cause (likely):** in single-window capture ScreenCaptureKit fits the window into the output size, and for a moment it saw the window with a different extent (Chrome's download animation is the guess, not proven). Every frame carries `SCStreamFrameInfo.contentRect` and `contentScale`; `ScreenCaptureEngine` checks only `status == .complete` and writes the frame.
- **Fix if it is needed:** for window capture only, hold frames whose `contentRect` / `contentScale` differ from the steady state. If the steady state comes back within about 150 ms, drop the held frames; otherwise write them with their own times. A change the user makes (resizing, moving to another display, full screen) lasts longer, so its frames are written exactly as today, only up to 150 ms later. Display and area capture always fill the frame and need nothing. Check whether `Windows.Graphics.Capture` does the same before porting.
- **Workaround:** cut the two frames out in the editor; the cut is not visible.

Left as is because it was seen once and the cost of holding frames is not worth it until it shows up again.

## 95. ADR-95: The Cursor Presses In on Clicks, and a Hand Folds Its Finger

Telemetry already has each button down and up (`clicks.jsonl`) and the system cursor kind of every sample (`cursor.jsonl`), so the editor knows when a click starts, how long the button is held and whether the cursor was a hand at the time. The cursor now shows the press:

- **Timing:** `SpringTrajectorySolver.pressAmount` goes 0 to 1 with a smoothstep, starting 30 ms before the button goes down and taking 70 ms, so the finger lands as the ripple starts. It stays at 1 while the button is held, at least 120 ms (a normal click is 50 to 100 ms and would be too short to see), then eases back over 140 ms. Left and right buttons count; a down with no up holds for the minimum. Overlapping presses (double clicks) take the larger amount. A run that starts at a cut while a button is held (`held`) starts fully pressed. The amount is part of `CursorFrameState`, solved at 120 Hz on edited time like the ripple, and interpolated between steps.
- **Every cursor:** scales to 92 % around its hotspot at full press.
- **Theme hands:** the index finger also folds. Above 30 % of the view box from the top (`CursorSpriteProvider.handFingerSeam01`) every theme hand, pixel included, holds only the index finger; `tools/generate_cursor_assets.py` keeps it that way. That strip is squashed toward the seam to 58 % at full press, and the hotspot moves with it, so the fingertip stays on the click and the palm drops toward it, as a hand does when it taps. The map is continuous at the seam, so the finger does not tear; the palm keeps one extra row under the finger so resampling leaves no faint line. Custom hand pictures only scale, since their shape is unknown.
- **No new assets or settings:** a second "pressed" sprite per theme would need a crossfade, which shows two fingers halfway. Folding the one sprite is smooth at every amount and works for all 9 themes. There is no toggle yet; it is always on, also in exports.

- **Windows.** `SpringTrajectorySolver.ButtonPresses` and `PressAmount` (same constants, the skip index kept as a parameter), `CursorFrameState.PressAmount` solved, interpolated and copied into the cropped state. `DrawCursor` scales by `1 - 0.08 * press` and, for a theme hand (`OverlayRasterizer.IsThemeHand`: the sprite drawn is a `pointinghand` file and there is no custom picture), passes the seam (30 % of the 256 px layer, rounded) and the squash to the `TexturedQuad` shader. The shader folds the uv itself (`v = seam - (seam - v) / squash` above the seam). This is the same continuous map as on macOS, done in one pass, so it needs no extra palm row and holds when the cursor is tilted. `CursorPressTests` checks the timing; `CursorPressRenderingTests` checks that the hand keeps its fingertip and gets shorter, and that the arrow keeps its tip at 92 %.

## 96. ADR-96: Windows Recording Bar and Camera Bubble Move Like a Title Bar

The recording bar and the camera bubble have no title bar. They used to move by hand: every XAML `PointerMoved` called `AppWindow.Move`, so each step waited for the UI thread. With a real mouse the owner saw the bar trail the pointer and catch up after it stopped, in the Store build too, while title bars of other apps keep up. A title bar keeps up because the system move loop moves the window itself.

- **Caption regions:** `SystemDrag.Attach` marks the whole window as a caption region (`InputNonClientPointerSource`) and every visible `Control` in it as click-through. It recomputes them on `LayoutUpdated` and sends them only when the rectangles change. A press between the buttons now starts the system move. Maximizing is off on both windows, so a double click does nothing.
- **Not from a XAML press:** starting the system move from `PointerPressed` (`WM_NCLBUTTONDOWN` with `HTCAPTION`) also kept up, but XAML never saw that button go up and swallowed the next press, so every second drag did nothing.
- **Saving the place:** the bar's center is saved 400 ms after it stops moving (`AppWindow.Changed`), not on every step.
- **Measured** with synthetic drags of one pointer event per millisecond, three in a row: the bar trails the pointer by 0.3 px on average (max 5) and moves every time; Notepad trails by 1.3 px. Synthetic drags did not show the old lag, which needs a real mouse. The editor already moves through `SetTitleBar`: 3 px on average, and in captures taken mid-drag its pixels stay with its frame, the same as Notepad.
