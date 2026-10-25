# NativeScreen — Master Feature Checklist & Roadmap

> **Instructions:** This is the living implementation tracker for **NativeScreen**.
> - Features are ordered by priority (**Phase 1 MVP** -> **Phase 2 Cinematic Polish** -> **Phase 3 Pro Features** -> **Phase 4 AI & Automation** -> **Phase 5 Windows Port**).
> - As we implement each item, mark it `[x]`. New features can be inserted into any phase at any time.

---

## Phase 1: MVP Core (macOS — Record, Auto-Zoom, Multi-Blur, Edit & Export)
*Goal: Replace the need for external editors (like CapCut) by delivering a super-fast, 100% native macOS recorder & editor with auto-zoom, backgrounds, and unlimited blur tracks.*

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
- [x] High-frequency mouse telemetry logger (`telemetry/cursor.jsonl` at 60–120Hz with normalized `0..1` coordinates and cursor type).
- [x] Mouse clicks & scroll logger (`telemetry/clicks.jsonl`).
- [x] Keystroke timestamp logger (`telemetry/keys.jsonl`) for typing-aware auto-zoom hold.
- [x] System/App Audio capture (via `ScreenCaptureKit` audio stream) & Microphone capture (`AVCaptureSession`) to separate `.m4a` tracks.

### 1.4. GPU Metal Compositor & Preview Canvas (0% Idle CPU)
- [x] `MTKView` Metal preview renderer with on-demand rendering (`isPaused = true` when playback is paused -> **0.0% Idle CPU**).
- [x] Playback controller (`AVAssetReader` / `AVPlayerItemVideoOutput` synchronized with telemetry clock at 60/120fps).
- [x] **Background Pass:**
  - [x] Load macOS system wallpapers directly from `/System/Library/Desktop Pictures/` (and copy chosen image to `.nativescreen/assets/`).
  - [x] Built-in procedural Mesh Gradients, Linear Gradients, Solid Colors, and custom image drop.
  - [x] Background blur slider, padding slider, and subtle anti-banding noise.
- [x] **Screen Frame Pass:**
  - [x] SDF anti-aliased rounded corners (`borderRadius`), inner border (`inset`), and directional soft drop shadow (`shadow`).
  - [x] Aspect ratio presets (`Auto`, `16:9`, `9:16` Vertical/Reels, `1:1`, `4:3`).
- [x] **Cursor & Auto-Zoom Pass:**
  - [x] 120Hz Spring Physics Solver for smooth cursor glide (`stiffness`, `damping`, `mass`) + cursor size slider.
  - [x] Automatic click-clustering zoom generator (`follow-click-groups`) + manual zoom target point override.
  - [x] Smooth spring-driven virtual camera pan & zoom with boundary clamping (`avoidEmptyBoundsWhenZooming`).
- [x] **Multi-Track Blur & Spotlight Masks (Killer MVP Feature):**
  - [x] Support **unlimited parallel Blur / Pixelate / Spotlight mask tracks** on the timeline.
  - [x] Direct on-canvas interactive rectangle handles (drag to move, resize corners, adjust Gaussian blur intensity & corner radius).
  - [x] Keyframe support for masks (smoothly move/resize a blur box over time when content scrolls).

### 1.5. Multi-Track NLE Timeline UI
- [x] Custom high-performance SwiftUI `Canvas` + gesture timeline at bottom of Editor.
- [x] **Video Slice Track:** Split at playhead (`⌘B`), trim start/end handles, delete segment (ripple delete), per-slice speed control (`0.5x` – `4x`).
- [x] **Zoom Track:** Add, move, resize, disable, or delete zoom blocks; click block to edit zoom scale (`1.2x` – `3.0x`) and target center.
- [x] **Multi-Row Mask Tracks:** Add multiple overlapping blur/spotlight blocks across independent rows so multiple screen areas can be blurred at the same time.
- [x] Playhead scrubbing, timecode display, and timeline zoom in/out (`⌘+` / `⌘-`).

### 1.6. Native Hardware Export Pipeline (Zero FFmpeg)
- [x] Hardware-accelerated exporter using `AVAssetReader` -> `Metal Offscreen Compositor` -> `AVAssetWriter` (`VideoToolbox` H.264 & HEVC).
- [x] Resolution presets (`1080p`, `2K`, `4K`, `Original Retina`), frame rate (`30fps`, `60fps`), and bitrate/quality controls.
- [ ] Multi-track audio mixdown (Recorded System Audio + Microphone + Slice speed mapping) via `AVAudioEngine` / `AVMutableComposition`.
- [x] Export progress modal with real-time FPS/ETA and "Copy to Clipboard" / "Reveal in Finder".

---

## Phase 2: Cinematic Polish (Motion Blur, Cursor Magic, Audio & UX Refinements)
*Goal: Match 100% of the signature motion polish and workflow speed.*

- [x] **GPU Camera & Cursor Motion Blur:** Velocity-driven directional shutter blur shader during fast zooms, pans, and cursor swipes.
- [ ] **Advanced Cursor Polish:**
  - [x] Velocity-based cursor tilt/rotation (`velocityRotationIntensity`).
  - [x] Micro-shake removal filter (`removeShakeThresholdPx`).
  - [x] Auto-hide cursor when idle (`hideWhenIdleAfterMs`).
  - [x] Loop cursor position back to start (`loopBackToStartMs`) for seamless looping videos/GIFs.
  - [x] Click ripple animations & synthesized mechanical/Magic Mouse click sound effects.
  - [x] Capture and render actual macOS cursor shapes (`arrow`, `pointingHand`, `iBeam`, `crosshair`, `resize`).
- [ ] **Audio Enhancements:**
  - [x] Audio waveform visualization on the timeline.
  - [ ] Built-in royalty-free / procedural background music tracks + custom `.mp3`/`.m4a` import with auto-ducking during voiceover.
  - [ ] Voice enhancement (noise reduction & auto-gain control via Apple `AudioUnit` / `AVAudioEngine`).
  - [ ] Post-recording Voiceover recording directly onto the timeline.
- [x] **Canvas Crop Tool:** Interactive crop overlay to trim unwanted margins of the recorded screen/window.
- [x] **Reel Mode Safe-Zone Overlay:** Interactive TikTok & Instagram Reels safe-zone preview overlay.
- [x] **Extract Current Frame:** Export or copy the current composited GPU frame as a high-res PNG.
- [ ] **Presets System:** Save and apply reusable style presets (Background + Padding + Shadow + Cursor + Zoom settings).
- [ ] **Quick Export & GIF Export:**
  - [ ] High-quality GIF export.
  - [ ] Menu bar Quick Record & instant clipboard export widget.

---

## Phase 3: Pro Visual Features (Webcam, Loupe, Device Mockups & Shortcuts)
*Goal: Complete visual feature parity with 4.x.*

- [ ] **Webcam Overlay & Layouts:**
  - [ ] Simultaneous webcam recording (`AVCaptureSession`) saved to `recording/webcam.mp4`.
  - [ ] 3 Layout modes changeable along the timeline: `Camera Overlay (PiP)`, `Split Screen`, and `Full Camera`.
  - [ ] Auto-shrink webcam bubble (`scaleWhenZoomed`) when the main screen zooms in.
  - [ ] Circle / Squircle / Rounded Rectangle shapes, mirror toggle, border & drop shadow.
  - [ ] **AI Person Cutout:** Real-time background removal / blur using macOS native `Vision` framework (`VNGeneratePersonSegmentationRequest` — 0MB model bloat!).
  - [ ] Auto-hide webcam during silence.
- [x] **Optical Glass Loupe Zoom:**
  - [x] Alternative zoom presentation mode (`presentation: "loupe"`) with glass refraction, bevel highlight, and chromatic aberration shader.
- [ ] **Keyboard Shortcuts HUD Overlay:**
  - [ ] Render stylish animated keystroke badges (e.g. `⌘ + K`, `⇧ + ⌘ + P`) from `keys.jsonl` with customizable size, position, and filter (ignore single letters).
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
