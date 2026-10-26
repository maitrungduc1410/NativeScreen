# NativeScreen — Master Feature Checklist & Roadmap

> **Instructions:** This is the living implementation tracker for **NativeScreen**.
> - Features are ordered by priority (**Phase 1 MVP** -> **Phase 2 Cinematic Polish** -> **Phase 3 Pro Features** -> **Phase 4 AI & Automation** -> **Phase 5 Windows Port**).
> - As we implement each item, mark it `[x]`. New features can be inserted into any phase at any time.

---

## Phase 1: MVP Core (macOS — Record, Auto-Zoom, Multi-Blur, Edit & Export)
*Goal: Deliver a super-fast, 100% native macOS recorder & editor with auto-zoom, backgrounds, and unlimited blur tracks.*

### 1.1. Project Package (`.nativescreen`) & State Engine
- [x] Define `ProjectDocument`, `RecordingMetadata`, and telemetry `Codable` models matching `spec/02-FILE-FORMAT-AND-SCHEMA.md`.
- [x] Register `.nativescreen` package document type (`UTExportedTypeDeclarations`, `LSTypeIsPackage = true`) in macOS `Info.plist`.
- [x] Support opening multiple `.nativescreen` projects simultaneously in separate macOS windows.
- [x] Implement Non-Linear Editing (NLE) time-mapper (`TimelineTime <-> SourceTime` across `slices`).
- [x] Implement Value-Type Snapshot `UndoManager` (`⌘Z` / `⇧⌘Z`) with drag-coalescing for sliders and timeline handles.
- [x] Auto-save `project.json` on edits (debounced).

### 1.2. Native Recording HUD & Target Picker
- [x] Floating borderless Recording HUD (`NSPanel` with native vibrancy/Liquid Glass, `Display`, `Window`, `Area`, `Mic`, `System Audio` toggles).
- [x] **Display Mode:** Select any connected screen (`SCDisplay`) and record at native Retina resolution (60fps).
- [x] **Window Mode (Smart Overlay):**
  - [x] Real-time Z-order window detection under cursor (`CGWindowListCopyWindowInfo` + `SCShareableContent`).
  - [x] Spring-animated purple/accent highlight overlay matching target window bounds & corner radius.
  - [x] Display target app icon, app name, window dimensions (`W × H`), and `[Resize]` preset menu (via `AXUIElement`).
- [x] **Area Mode:** Drag-to-select screen region with aspect ratio presets (`16:9`, `9:16`, `1:1`, `4:3`, Custom) and dimmed outside cover.
- [x] Exclude NativeScreen's own HUD/overlay windows from capture (`excludedWindowIds`).
- [x] Hide real system cursor from the captured video stream (`showsCursor = false` in `SCStreamConfiguration`) so cursor can be rendered synthetically in post.

### 1.3. Multi-Channel Capture & Telemetry Writer
- [x] Crash-safe video recording via `AVAssetWriter` (support direct `.mp4` and segmented `.m3u8` + `.m4s` fMP4 output).
- [x] High-frequency mouse telemetry logger (`telemetry/cursor.jsonl` at 60–120Hz with normalized `0..1` coordinates and cursor type, synchronized `t = 0.0ms` to the first captured `SCStream` video frame).
- [x] Mouse clicks & scroll logger (`telemetry/clicks.jsonl`).
- [x] Keystroke timestamp logger (`telemetry/keys.jsonl`) for typing-aware auto-zoom hold, typing speed-up suggestions, and 3D shortcut keycaps.
- [x] System/App Audio capture (via `ScreenCaptureKit` audio stream) & Microphone capture (`AVCaptureSession`) to separate `.m4a` tracks.

### 1.4. GPU Metal Compositor & Preview Canvas (0% Idle CPU)
- [x] `MTKView` Metal preview renderer with on-demand rendering (`isPaused = true` when playback is paused -> **0.0% Idle CPU**).
- [x] Playback controller (`AVAssetReader` / `AVPlayerItemVideoOutput` synchronized with telemetry clock at 60/120fps).
- [x] **Background Pass:**
  - [x] Load macOS system wallpapers directly from `/System/Library/Desktop Pictures/` (and copy chosen image to `.nativescreen/assets/`).
  - [x] Built-in procedural Mesh Gradients, Linear Gradients (with interactive 2D HSB Color Picker, Eyedropper, Hue rotation slider, and 30 curated gradient presets), Solid Colors, and custom image drop/paste (`⌘V`).
  - [x] Background blur slider, padding slider, and subtle anti-banding noise.
- [x] **Screen Frame Pass:**
  - [x] SDF anti-aliased rounded corners (`borderRadius`), inner border (`inset`), and directional/classic soft drop shadow (`shadow`).
  - [x] Aspect ratio presets (`Auto`, `Wide 16:9`, `Vertical 9:16`, `Square 1:1`, `Classic 4:3`, `Tall 3:4`, `Portrait 4:5`, `Display 16:10`).
- [x] **Cursor & Auto-Zoom Pass:**
  - [x] 120Hz Spring Physics Solver for smooth cursor glide (`stiffness`, `damping`, `mass`) + lookahead phase-lag compensation (`lagMs = damping / stiffness * 1000`) + drag/click speed boost (`k * speed^2`, `c * speed`) + cursor size slider.
  - [x] Automatic click-clustering zoom generator (`follow-click-groups` + stationary `MovesGroup` dead-zone clusters) + manual zoom target point override + dedicated `Close Zoom editor` Inspector view.
  - [x] Smooth spring-driven virtual camera pan & zoom in Screen-Rect space (`rects.screen`) with boundary clamping (`avoidEmptyBoundsWhenZooming`) and optional `Instant animation`.
- [x] **Multi-Track Blur & Spotlight Masks (Killer MVP Feature):**
  - [x] Support **unlimited parallel Blur / Pixelate / Spotlight mask tracks** on the timeline.
  - [x] Direct on-canvas interactive rectangle handles (drag to move, resize corners, adjust Gaussian blur / Highlight intensity & corner radius).
  - [x] Keyframe support for masks (smoothly move/resize a blur box over time when content scrolls).

### 1.5. Multi-Track NLE Timeline UI
- [x] Custom high-performance SwiftUI `Canvas` + gesture timeline at bottom of Editor with isolated 120Hz Playhead overlay (`TimelinePlayheadsOverlayView`).
- [x] **Video Slice Track:** Split at playhead (`C` or `⌥` Split Mode), golden teardrop merge badges at cut boundaries, trim start/end handles, delete segment (ripple delete), per-slice speed control (`0.25x` – `8x`), and Catmull-Rom cubic spline + mip-pyramid audio waveform.
- [x] **Speed Up Typing Suggestions:** Automatic detection of continuous typing bursts rendered as golden keyboard bars right above the Clip track (`Speed up typing` popover with `Apply suggestion ↵`, `Apply all suggestions ⌘ ↵`, `Remove suggestion`).
- [x] **Zoom Track:** Hover `+` preview block on empty areas to insert zoom, move, resize, disable, or delete zoom blocks; click block to open dedicated Zoom Editor (`Classic` / `Glass Loupe`, `Instant animation`, `Auto` / `Manual`, `Zoom level`).
- [x] **Multi-Row Mask Tracks:** Add multiple overlapping blur/spotlight blocks across independent rows so multiple screen areas can be blurred at the same time.
- [x] **Multi-Track Keyboard Shortcuts Lanes:** Select, move, resize, duplicate, or permanently delete (`Remove shortcut`) shortcut segments; add custom shortcuts on empty track hover or via `+`; create multiple shortcut tracks with independent positions and colors.
- [x] Dynamic time ruler (`Bf` / `Jp` whole-second label algorithm), playhead scrubbing, timecode display, and playhead-anchored timeline zoom in/out (`⌘+` / `⌘-`).

### 1.6. Native Hardware Export Pipeline (Zero FFmpeg)
- [x] Hardware-accelerated exporter using `AVAssetImageGenerator` -> `MetalFrameCompositor` (all 6 passes including 3D Shortcut Keycaps) -> `AVAssetWriter` (`VideoToolbox` H.264, HEVC, Both, and Apple ProRes `422 LT`, `422`, `422 HQ`, `4444`) & `ImageIO` animated `GIF`.
- [x] 2-column Export Settings modal (`Format: MP4 | ProRes | GIF`, `Frame rate`, `Resolution: 720p | 1080p | 4K` with dynamic pixel dimensions, `Compression: Studio | Social Media | Web | Web (Low)`, collapsible `Advanced` Codec picker, and non-linear bits-per-pixel file size range & duration estimation).
- [ ] Multi-track audio mixdown (Recorded System Audio + Microphone + Slice speed mapping) via `AVAudioEngine` / `AVMutableComposition`.
- [x] Full-window dark Export Progress overlay (`Exporting video • 33% ⓘ`, purple progress bar, live elapsed & ETA countdown `00:04 • 00:06 left`, macOS Dock progress bar, and instant `Stop export` cancellation with partial file cleanup) + `Export to File` or `Export to Clipboard`.

---

## Phase 2: Cinematic Polish (Motion Blur, Cursor Magic, Audio & UX Refinements)
*Goal: Deliver studio-grade motion polish and workflow speed.*

- [x] **GPU Camera & Cursor Motion Blur:** True 1-frame shutter window (`t` vs `t - 16.67ms`) directional translational blur (`CIMotionBlur`) and fast 3-tap radial zoom shutter blend during fast zooms and pans, plus live Newtonian `SpringPhysicsDemoDotView` preview in the Animations Inspector.
- [x] **Advanced Cursor Polish:**
  - [x] All 24 vector cursor sets (`147` SVGs in `CursorAssets.bundle`: `macOS`, `Tahoe`, `Touch`, `Custom 1–20`, `Halloween`) with color/style variants and horizontal auto-centering selector.
  - [x] Velocity-based cursor tilt (`Tilt`) & directional leash (`Follow`) rotation modes (`baseRotationDegrees`, `velocityRotationIntensity`).
  - [x] Micro-shake removal filter (`removeShakeThresholdPx`), `Optimize cursor changes`, `Keep cursor in sync with hovers`, and `Stop cursor movement at the end of the video`.
  - [x] Auto-hide cursor when idle (`hideWhenIdleAfterMs`).
  - [x] Loop cursor position back to start (`loopBackToStartMs`) for seamless looping videos/GIFs.
  - [x] Click effect styles (`None`, `Circle`, `Ripple`) & bundled click sound effects (`Magic Mouse™`, `MX Master™`) with volume & live preview.
  - [x] Capture and render actual macOS cursor shapes (`arrow`, `pointer`, `ibeam`, `crosshair`, `openhand`, `closedhand`).
- [ ] **Audio Enhancements:**
  - [x] Catmull-Rom cubic spline + max-reduction mipmap pyramid audio waveform visualization on the timeline.
  - [ ] Built-in royalty-free / procedural background music tracks + custom `.mp3`/`.m4a` import with auto-ducking during voiceover.
  - [ ] Voice enhancement (noise reduction & auto-gain control via Apple `AudioUnit` / `AVAudioEngine`).
  - [ ] Post-recording Voiceover recording directly onto the timeline.
- [x] **Canvas Crop Tool:** Interactive crop modal & overlay to trim unwanted margins of the recorded screen/window.
- [x] **Reel Mode Safe-Zone Overlay:** Interactive TikTok, Instagram Reels & YouTube Shorts safe-zone preview overlay.
- [x] **Extract Current Frame:** Dedicated `Export still frames` modal (`PNG` / `JPEG` squircle toggles, resolution up to `4K`, live preview) and instant `Copy current frame to clipboard`.
- [x] **Command Menu (`⌘K`):** Global searchable command palette (`CommandMenuOverlayView`) with keyboard navigation across all editor actions.
- [x] **Pure AppKit Zero-Lag Tooltips:** Borderless floating `NSPanel` rendered via `PureAppKitTooltipCalloutView` (`< 0.02ms` draw time, zero `NSHostingView` overhead during 120Hz playback).
- [ ] **Presets System:** Save and apply reusable style presets (Background + Padding + Shadow + Cursor + Zoom settings).
- [x] **Quick Export & GIF Export:**
  - [x] High-quality animated GIF export (`High quality` & `Disable loop` options).
  - [x] Instant `Export to clipboard` directly from the Export modal.

---

## Phase 3: Pro Visual Features (Webcam, Loupe, Device Mockups & Shortcuts)
*Goal: Complete pro visual feature suite.*

- [ ] **Webcam Overlay & Layouts:**
  - [ ] Simultaneous webcam recording (`AVCaptureSession`) saved to `recording/webcam.mp4`.
  - [ ] 3 Layout modes changeable along the timeline: `Camera Overlay (PiP)`, `Split Screen`, and `Full Camera`.
  - [ ] Auto-shrink webcam bubble (`scaleWhenZoomed`) when the main screen zooms in.
  - [ ] Circle / Squircle / Rounded Rectangle shapes, mirror toggle, border & drop shadow.
  - [ ] **AI Person Cutout:** Real-time background removal / blur using macOS native `Vision` framework (`VNGeneratePersonSegmentationRequest` — 0MB model bloat!).
  - [ ] Auto-hide webcam during silence.
- [x] **Optical Glass Loupe Zoom:**
  - [x] Alternative zoom presentation mode (`presentation: "loupe"`) with circular magnifying lens, bevel rim highlight, and adjustable loupe radius.
- [x] **Keyboard Shortcuts 3D Keycaps & Multi-Track Editor:**
  - [x] Render 3D bevel keycaps (`⌘`, `⇧`, `⌥`, `⌃`, `Space`, `⌫`, etc.) both on the live Preview Canvas and baked directly into exported videos/GIFs (`Pass 6` in `MetalFrameCompositor`).
  - [x] Prose-typing suppression filter (ignores normal typing words/code even when `Show single key shortcuts` is enabled).
  - [x] Dedicated `Close Shortcut editor` Inspector panel on segment click with live keyboard shortcut recording (`Record shortcut keys…`), 4-edge positioning (`Bottom`, `Top`, `Left` vertical stack, `Right` vertical stack), `Horizontal / Vertical offset` sliders (to avoid captions), `Default / Solid / Gradient` keycap color picker, multi-track support, and permanent deletion (`Remove shortcut`).
- [ ] **Device Mockups & iOS Recording:**
  - [ ] Record connected iPhone/iPad screen via `AVCaptureSession` CoreMediaIO.
  - [ ] Clean vector/3D-rendered device bezels (iPhone, iPad, MacBook frames) with auto-orientation support.

---

## Phase 4: On-Device AI & Automation
*Goal: Smart automation using native Apple Silicon Neural Engine (ANE).*

- [ ] **AI Auto-Detect Sensitive Data (OCR):**
  - [ ] Scan video frames using macOS native `Vision` (`VNRecognizeTextRequest`) to automatically detect emails, API keys, tokens, IP addresses, or custom user phrases.
  - [ ] One-click generation of tracked Blur Masks on the timeline.
- [ ] **AI Auto-Captions (Speech-to-Text):**
  - [ ] On-device transcription using Apple `Speech` framework (`SFSpeechRecognizer`) or local Whisper Metal.
  - [ ] Animated word-by-word / line-by-line caption overlay renderer with editable transcript.
- [ ] **Window Bounds Tracking:**
  - [ ] Dynamically adjust frame size if the recorded window was resized or moved during capture (`window.jsonl`).
- [ ] **Speaker Notes / Teleprompter:**
  - [ ] Floating window visible only to the presenter (excluded from `ScreenCaptureKit` stream) while recording.

---

## Phase 5: NativeScreen for Windows (WinUI 3 + Direct3D 11 + Media Foundation)
*Goal: Bring the exact same `.nativescreen` project compatibility and native performance to Windows 11.*

- [ ] Initialize `NativeScreenWindows` solution (C# / .NET 9 / Windows App SDK / WinUI 3).
- [ ] Shared `.nativescreen` (`project.json` + `.jsonl` + `.mp4`/`.m3u8`) reader/writer in C#.
- [ ] Native capture engine using `Windows.Graphics.Capture` (cursor exclusion + window/monitor picker) + `WASAPI` process-loopback audio + `SetWindowsHookEx` mouse/key telemetry.
- [ ] Direct3D 11 / Win2D HLSL shader compositor matching all 6 render passes of the macOS Metal pipeline.
- [ ] Hardware-accelerated MP4/HEVC exporter via `Media Foundation` (`IMFSinkWriter` NVENC / AMF / QuickSync).
