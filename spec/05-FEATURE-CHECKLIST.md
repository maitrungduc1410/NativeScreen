# NativeScreen: Master Feature Checklist & Roadmap

> **Instructions:** This is the living implementation tracker for **NativeScreen**.
> - Features are ordered by priority (**Phase 1 MVP** -> **Phase 2 Cinematic Polish** -> **Phase 3 Pro Features** -> **Phase 4 AI & Automation** -> **Phase 5 Windows Port**).
> - As we implement each item, mark it `[x]`. New features can be inserted into any phase at any time.

---

## Phase 1: MVP Core (macOS: Record, Auto-Zoom, Multi-Blur, Edit & Export)
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
- [x] Record NativeScreen's own editor windows: pickable in Window mode, visible in Display and Area mode, and `Record > Record this project window` starts directly.
- [x] Hide real system cursor from the captured video stream (`showsCursor = false` in `SCStreamConfiguration`) so cursor can be rendered synthetically in post.

### 1.3. Multi-Channel Capture & Telemetry Writer
- [x] Crash-safe video recording via `AVAssetWriter` with fragmented `.mp4` (`movieFragmentInterval = 2s` on screen, webcam and microphone writers).
- [ ] Segmented `.m3u8` + `.m4s` fMP4 recording output.
- [x] High-frequency mouse telemetry logger (`telemetry/cursor.jsonl` at 60–120Hz with normalized `0..1` coordinates and cursor type, synchronized `t = 0.0ms` to the first captured `SCStream` video frame).
- [x] Mouse clicks & scroll logger (`telemetry/clicks.jsonl`).
- [x] Keystroke timestamp logger (`telemetry/keys.jsonl`) for typing-aware auto-zoom hold, typing speed-up suggestions, and 3D shortcut keycaps.
- [x] System/App Audio capture (via `ScreenCaptureKit` audio stream) & Microphone capture (`AVCaptureSession`) to separate `.m4a` tracks.

### 1.4. GPU Metal Compositor & Preview Canvas (0% Idle CPU)
- [x] `MTKView` Metal preview renderer with on-demand rendering (`isPaused = true` when playback is paused -> **0.0% Idle CPU**).
- [x] Playback controller (`AVAssetReader` / `AVPlayerItemVideoOutput` synchronized with telemetry clock at 60/120fps).
- [x] **Background Pass:**
  - [x] Load macOS system wallpapers directly from `/System/Library/Desktop Pictures/` (and copy chosen image to `.nativescreen/assets/`).
  - [x] 108 self-drawn built-in wallpapers in 7 categories, with `Pick random wallpaper` across every category (`spec/06` ADR-32).
  - [x] `★` Favorites category for wallpapers and mesh presets, added and removed from each thumbnail's right-click menu (`spec/06` ADR-32).
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
- [x] Dynamic time ruler (`Bf` / `Jp` whole-second label algorithm), playhead scrubbing, timecode display, and playhead-anchored timeline zoom in/out (`⌘+` / `⌘-`), and `⌘` + scroll zoom anchored at the cursor (`spec/06` ADR-45).

### 1.6. Native Hardware Export Pipeline (Zero FFmpeg)
- [x] Hardware-accelerated exporter using `AVAssetImageGenerator` -> `MetalFrameCompositor` (all 6 passes including 3D Shortcut Keycaps) -> `AVAssetWriter` (`VideoToolbox` H.264, HEVC, Both, and Apple ProRes `422 LT`, `422`, `422 HQ`, `4444`) & `ImageIO` animated `GIF`.
- [x] 2-column Export Settings modal (`Format: MP4 | ProRes | GIF`, `Frame rate`, `Resolution: 720p | 1080p | 4K` with dynamic pixel dimensions, `Compression: Studio | Social Media | Web | Web (Low)`, collapsible `Advanced` Codec picker, and non-linear bits-per-pixel file size range & duration estimation).
- [x] Multi-track audio mixdown (Recorded System Audio + Microphone + Voiceover tracks + Slice speed mapping) via `AVMutableComposition` & `AVAssetReaderAudioMixOutput`.
- [x] Full-window dark Export Progress overlay (`Exporting video • 33% ⓘ`, purple progress bar, live elapsed & ETA countdown `00:04 • 00:06 left`, macOS Dock progress bar, and instant `Stop export` cancellation with partial file cleanup) + `Export to File` or `Export to Clipboard`.

---

## Phase 2: Cinematic Polish (Motion Blur, Cursor Magic, Audio & UX Refinements)
*Goal: Deliver studio-grade motion polish and workflow speed.*

- [x] **GPU Camera & Cursor Motion Blur:** True 1-frame shutter window (`t` vs `t - 16.67ms`) directional translational blur (`CIMotionBlur`) and fast 3-tap radial zoom shutter blend during fast zooms and pans, plus live Newtonian `SpringPhysicsDemoDotView` preview in the Animations Inspector.
- [x] **Advanced Cursor Polish:**
  - [x] Vector cursor themes (`Classic Dark`, `Classic Light`, `Rounded`, `Dart`, `Dart Color`, `Outline`, `Ring`, `Pixel`, `Touch`) generated by `tools/generate_cursor_assets.py` into `Cursors.bundle`, with color variants and a horizontal auto-centering selector.
  - [x] Velocity-based cursor tilt (`Tilt`) & directional leash (`Follow`) rotation modes (`baseRotationDegrees`, `velocityRotationIntensity`).
  - [x] Micro-shake removal filter (`removeShakeThresholdPx`), `Optimize cursor changes`, `Keep cursor in sync with hovers`, and `Stop cursor movement at the end of the video`.
  - [x] Auto-hide cursor when idle (`hideWhenIdleAfterMs`).
  - [x] Loop cursor position back to start (`loopBackToStartMs`) for seamless looping videos/GIFs.
  - [x] Click effect styles (`None`, `Circle`, `Ripple` as a screen-bending wave) & synthesized click sounds (`Soft`, `Crisp`, also generated by `tools/generate_cursor_assets.py`) with volume & live preview.
  - [x] Capture and render actual macOS cursor shapes (`arrow`, `pointer`, `ibeam`, `crosshair`, `openhand`, `closedhand`).
- [x] **Audio Enhancements:**
  - [x] Catmull-Rom cubic spline + max-reduction mipmap pyramid audio waveform visualization on the timeline.
  - [x] Below 100% volume, a faint copy of the full-volume wave behind the scaled one, per source (`spec/06` ADR-42).
  - [x] Built-in royalty-free / procedural background music tracks + custom `.mp3`/`.m4a` import with auto-ducking during voiceover.
  - [x] Voice enhancement (noise reduction & auto-gain control via Apple `AudioUnit` / `AVAudioEngine`).
  - [x] Post-recording Voiceover recording & audio file upload directly onto the timeline (multiple `Voiceovers` tracks with no overlap inside a track + `Close Voiceover editor` with `Independent` / `Synchronized` attach modes and `Hide & Mute original recording`).
- [x] **Canvas Crop Tool:** Interactive crop modal & overlay to trim unwanted margins of the recorded screen/window.
- [x] **Reel Mode Safe-Zone Overlay:** Interactive TikTok, Instagram Reels & YouTube Shorts safe-zone preview overlay.
- [x] **Extract Current Frame:** Dedicated `Export still frames` modal (`PNG` / `JPEG` squircle toggles, resolution up to `4K`, live preview) and instant `Copy current frame to clipboard`.
- [x] **Command Menu (`⌘K`):** Global searchable command palette (`CommandMenuOverlayView`) with keyboard navigation across all editor actions.
- [x] **Pure AppKit Zero-Lag Tooltips:** Borderless floating `NSPanel` rendered via `PureAppKitTooltipCalloutView` (`< 0.02ms` draw time, zero `NSHostingView` overhead during 120Hz playback).
- [x] **Native Menu Bar:** `File` (Open recent, Open project, Open last project, Show previous projects, Create project from video, Import preset, Save, Save as, Show project in Finder, Remove project), `Edit` (Undo/Redo, Cut/Copy/Paste/Delete routed to text fields or the timeline selection), `Record` (New recording, Record display/window/area, `After Recording` action, Automatically create zooms), `Export` (Export, Quick export to clipboard/file, Show previous clipboard exports, Extract raw recording files, Export current frame as image), `View` (inspector tabs, waveform, loop playback, scrollbar, sidebar/timeline visibility, recording widget), `Window` (Reset windows positions). `Create interactive showcase project` lives in `File`.
- [x] **Settings window** (General, Recording, Editing, Quick export, Shortcuts) and **light / dark appearance** (Settings + command menu).
- [ ] Customizable and global (system-wide) keyboard shortcuts.
- [x] **App Icon:** white squircle with a purple to pink ring (matches the `record.circle` toolbar symbol). `AppIcon.icon` (Icon Composer, Liquid Glass with Default/Dark/Clear/Tinted on macOS 26+) plus `AppIcon.appiconset` PNGs rendered from it with `ictool` on the macOS 11 icon grid (824pt body in 1024, standard shadow) for macOS 15.
- [x] **Create Project from Video:** import any movie file as a `.nativescreen` project (no cursor telemetry) with a draggable `Zoom position` pad for manual zooms (live preview while dragging).
- [ ] `View > Show speaker notes`, `View > Show shortcuts guide`, `View > Preview size`, and quick export to a shareable link.
- [x] **Presets System:** Save, rename, set default for new projects, and apply reusable style presets (`✨ Presets ⌄` popover in top header bar + `ProjectPresetsStore`).
- [x] **Quick Export & GIF Export:**
  - [x] High-quality animated GIF export (`High quality` & `Disable loop` options).
  - [x] Instant `Export to clipboard` directly from the Export modal.
- [x] **Accessibility:** every control has a name in the UI language (VoiceOver, Voice Control, Switch Control), timeline segments read their kind, content and time range and can be selected, the ruler moves the playhead, toasts are read out, and Reduce Motion turns off the hover, tooltip, toast and split mode motion (`spec/06` ADR-51).
  - [ ] Moving and resizing segments, drawing masks and picking a window or area without a pointer.
- [x] **AI agents (MCP):** `Settings > AI Agents` lets Claude Code, Claude Desktop, Codex, Cursor and other MCP clients record, edit (whole document as JSON merge patches plus timeline item tools, each one undo step), render frames to check their work, change settings and export with progress. Clients run the app's own executable with `--mcp`, which opens the app when needed (`spec/06` ADR-52).
  - [ ] A command line (`nativescreen export ...`) on the same tools.
- [x] **Releases and updates:** manual GitHub Actions release (`docs/releasing.md`, ADR-53) builds a signed, notarized DMG and a Sparkle appcast for macOS and a Velopack installer for Windows, as a draft release. `Check for Updates...` in the app menu and menu bar menu, `Check for updates automatically` in Settings > General (release builds only).
  - [x] Windows: Velopack startup hook and update check in the app (see `windows/HANDOFF.md`).
  - [ ] Windows code signing (SignPath Foundation).
- [x] **README and website** (`site/`, GitHub Pages): editorial layout, an aspect ratio switch, screenshot slots for macOS and Windows; `tools/demo-page/` to record demos against and `tools/demo-driver/` to play scripted takes on it.
  - [x] macOS demo videos and editor screenshots, recorded against `tools/demo-page/`.
  - [x] Second pass: merged hero zooms, mask and cursor demos zoomed in, large before/after switches, light theme screenshots retaken, measured native numbers.
  - [x] Edit by transcript screenshot (a voice take on the demo page, `tools/demo-driver/takes/transcript.json`).
  - [x] AI agent demo video (a real agent session next to the editor, area recording, private text masked).
  - [x] Windows editor screenshot.
- [x] **Fix:** MCP tools reject unknown arguments and enforce `required` (`spec/06` ADR-52).
- [x] **Fix:** a mask added inside a zoom appeared away from the drag; masks are now created and edited under the zoom on screen (`spec/06` ADR-55).
- [x] Solid masks have a color: swatch picker and hex field in the mask inspector (`solidColor`, optional).
- [x] Timeline segment labels collapse as a segment narrows: details, then title, animated (`spec/04`).
- [x] Camera background (blur, image) and face stickers, applied in the editor; real face tracking (`spec/06` ADR-58). macOS only so far.
- [x] Minimum macOS is 14 (`spec/06` ADR-57). Not yet run on a real macOS 14 machine.
- [x] Clip speed menu goes up to 10x (6x, 8x, 10x added).
- [x] **Fix:** mask handles matched the drawn mask only without padding; they now use the compositor's stage rect and the crop (`spec/06` ADR-55).
- [x] Auto zooms closer than 1.5 s merge into one (`spec/03` §3.1), on macOS and in the Windows port.
- [x] **Fix:** two-lane H.264 export wrote two sample descriptions and Chrome could not play past the first switch; now one description with in-band SPS/PPS (`spec/06` ADR-01).
- [x] **Fix:** fragmented recording writer failed mid-take with -11800 / -16341 and the video stopped early; recordings now use H.264 without frame reordering (`spec/06` ADR-54).
- [x] A failed capture writer or a stream that stops by itself ends the recording, keeps what plays back, and tells the user (`spec/06` ADR-54).

---

## Phase 3: Pro Visual Features (Webcam, Loupe, Device Mockups & Shortcuts)
*Goal: Complete pro visual feature suite.*

- [x] **Webcam Overlay, Layouts & Color Grading (`Camera Layout` & `Camera Style`):**
  - [x] Simultaneous webcam recording (`AVCaptureSession`) saved to `recording/webcam.mp4` + live floating camera preview bubble (`Show camera preview` in HUD).
  - [x] 3 Default Layout modes (`Camera overlay`, `Split screen`, and `Camera cutout`) + dedicated `Layouts` timeline track & Quick Dock buttons with 5 per-segment layout types (`Camera overlay`, `Split screen`, `Camera cutout`, `Fullscreen camera`, `Only screen`), 8-point perimeter `Camera Position` dot grid, `Camera aspect ratio` (`16:9`, `4:3`, `1:1`, `3:4`, `9:16`), and `Camera Size` slider.
  - [x] Auto-shrink webcam bubble (`Make smaller during zoom` / `scaleWhenZoomed`) when the main screen zooms in.
  - [x] 13 built-in filmic color grading looks (`Original`, `Studio`, `Cinema`, `Film`, `Golden`, `Cream`, `Terra`, `Moody`, `Arctic`, `Neon`, `Punch`, `Fade`, `Mono`) + custom `.cube` 3D LUT loader, `Sharpen`, interactive `Crop camera` modal, `Mirror horizontally`, `Face tracking` (100% local via `Vision`), and `Camera delay` (`-200ms ... +200ms`).
  - [x] **AI Person Cutout:** Real-time background removal using macOS native `Vision` framework (`VNGeneratePersonSegmentationRequest`: 0MB model bloat!).
  - [x] Auto-hide webcam during silence (`Hide during silence`).
- [x] **Optical Glass Loupe Zoom:**
  - [x] Alternative zoom presentation mode (`presentation: "loupe"`) with circular magnifying lens, bevel rim highlight, and adjustable loupe radius.
- [x] **Keyboard Shortcuts 3D Keycaps & Multi-Track Editor:**
  - [x] Render 3D bevel keycaps (`⌘`, `⇧`, `⌥`, `⌃`, `Space`, `⌫`, etc.) both on the live Preview Canvas and baked directly into exported videos/GIFs (`Pass 6` in `MetalFrameCompositor`).
  - [x] Prose-typing suppression filter (ignores normal typing words/code even when `Show single key shortcuts` is enabled).
  - [x] Dedicated `Close Shortcut editor` Inspector panel on segment click with live keyboard shortcut recording (`Record shortcut keys...`), 4-edge positioning (`Bottom`, `Top`, `Left` vertical stack, `Right` vertical stack), `Horizontal / Vertical offset` sliders (to avoid captions), `Default / Solid / Gradient` keycap color picker, multi-track support, and permanent deletion (`Remove shortcut`).
- [x] **Device Mockups (`Use device mockup`):**
  - [x] High-DPI vector metallic device bezels (`MacBook Pro 16"`, `MacBook Air 15"`, `iPhone 16 Pro`, `iPad Pro 13"`) with `Perfect` / `Flexible` sizing modes and hardware color finishes (`Space Black`, `Silver`, `Midnight`, `Starlight`, `Black Titanium`, `Natural Titanium`, `Desert Titanium`, `White Titanium`).

---

## Phase 4: On-Device AI & Automation
*Goal: Smart automation using native Apple Silicon Neural Engine (ANE).*

- [x] **AI Auto-Detect Sensitive Data (OCR) & Hide Faces:**
  - [x] Scan video frames using macOS native `Vision` (`VNRecognizeTextRequest` and `VNDetectFaceRectanglesRequest`) to automatically detect emails, phone numbers, card numbers, API keys/tokens, custom user phrases (`Custom phrases`), and faces on screen.
  - [x] One-click generation of tracked Blur Masks on the timeline (`Hide sensitive data` & `Hide faces` in Background Inspector).
- [x] **Timeline snapping:** dragged and trimmed items stick to edges on every track, the playhead and clip boundaries, with a purple guide line; toggle next to the split button and in `View`, on by default (`spec/06` ADR-43).
- [x] **Track label menu:** right-click a track's label to hide or show it, or delete it with everything on it (one undo step, with a toast). Every track except Clip and Zoom can be deleted (`spec/06` ADR-50).
- [x] **Per-slice audio volume:** `Microphone volume` and `System audio volume` sliders in the clip context menu, each applied only to that slice (`spec/06` ADR-47).
- [x] **Localization:** English, Vietnamese, Simplified Chinese, Japanese, German, French, Spanish and Brazilian Portuguese, with a language picker in `Settings > General` (`spec/06` ADR-44).
- [x] **Caption tracks:** multiple tracks on the timeline; move, trim, split and add captions, drag them between tracks, per-caption style with `Apply to all captions in this track`, 2D `Caption position` pad.
- [x] **AI Auto-Captions & Edit by Transcript (100% Local On-Device Speech-to-Text):**
  - [x] On-device transcription using Apple `Speech` framework (`SFSpeechRecognizer` with `requiresOnDeviceRecognition = true`) with language selector, custom `Keyterms` prompt, and `.srt` export.
  - [x] Animated `Line by line` / `Word by word` caption overlay renderer with `Font style` (`Sans-serif`, `Serif`, `Mono`), `Line growth` (`Full line`, `Expanding`, `Centered`), `Word animation` (`Appear`, `Fade in`, `Slide in`), and `Color` (`Dark`, `Light`).
  - [x] Interactive `Edit by transcript` inspector: one-click `Remove N filler words` (`"um"`, `"uh"`, ...), one-click `Tighten N pauses` (`··· 1.3s`), and per-word `Cut video`, `Cut transcript`, and `Restore`.
- [ ] **Window Bounds Tracking:**
  - [ ] Dynamically adjust frame size if the recorded window was resized or moved during capture (`window.jsonl`).
- [ ] **Speaker Notes / Teleprompter:**
  - [ ] Floating window visible only to the presenter (excluded from `ScreenCaptureKit` stream) while recording.

---

## Phase 5: NativeScreen for Windows (WinUI 3 + Direct3D 11 + Media Foundation)
*Goal: the same `.nativescreen` projects, the same output frames and the same smoothness on Windows 11.*

Plan, porting map and acceptance checks: [`spec/08-WINDOWS-PORT-PLAN.md`](./08-WINDOWS-PORT-PLAN.md). Implementation guide:
[`platforms/windows-d3d11-mediafoundation.md`](./platforms/windows-d3d11-mediafoundation.md). Tick an item only after the
Windows verifier recorded `PASS` for it in `windows/HANDOFF.md`.

- [x] **5.0 Foundations:** macOS conformance generator (`--generate-conformance`) and committed `conformance/`; `windows/` solution, central package versions, `verify.ps1`, empty WinUI window.
- [x] **5.1 Core:** models + JSON round-trip with macOS projects, `NLETimeMapper`, spring solvers and auto zoom, stage layout and split screen, captions layout, shortcut clustering, export estimators, snapshot undo.
- [ ] **5.2 Rendering:** D3D11 compositor (all passes in `spec/07`), DirectWrite captions and keycaps, SVG cursors, lens and motion blur kernels, LUT camera looks, cutout post-process.
- [ ] **5.3 Playback:** `IMFSourceReader` decode, audio master clock, `SwapChainPanel` preview at display rate, 0% idle CPU.
- [ ] **5.4 Export:** hardware H.264 / HEVC via `IMFSinkWriter`, audio mix, GIF, even progress, cancel.
- [ ] **5.5 Recording:** `Windows.Graphics.Capture` display / window / area, telemetry hooks, mic + system + per-app audio, webcam, HUD excluded from capture, pause, fragmented MP4.
- [ ] **5.6 Editor UI:** welcome, editor, inspector tabs, timeline, command menu, menus, settings, presets, multi-window, light/dark.
- [ ] **5.7 Intelligence:** Whisper captions and transcript editing, person cutout (ONNX), OCR and face masks, face tracking.
- [ ] **5.8 Packaging:** MSIX, `.nativescreen` file association and icon, signing.
