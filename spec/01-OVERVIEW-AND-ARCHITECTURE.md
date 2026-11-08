# NativeScreen: Overview & System Architecture

> **Tagline:** Beautiful, cinematic screen recordings and product demos at native speed. 100% Native UI & GPU Pipeline for macOS (SwiftUI + Metal) and Windows (WinUI 3 + Direct3D 11/12). Zero Electron, Zero WebView, Zero FFmpeg dependency required.

---

## 1. Core Philosophy & Goals

1. **100% Native Look & Feel ("80% OS Native + 20% Custom Pro"):**
   - **80% Native OS Controls:** Window chrome, toolbars, sidebars, inspectors, menus, popovers, sliders, pickers, text fields, and floating HUD panels use native platform toolkits (**SwiftUI + AppKit** with Vibrancy/Liquid Glass & SF Symbols on macOS; **WinUI 3** with Mica/Acrylic & Fluent Icons on Windows).
   - **20% Custom Pro Controls:** The GPU Video Preview Canvas (with interactive crop/mask handles) and the Multi-Track NLE Timeline share a unified visual language and keyboard shortcut model across macOS and Windows.
2. **Uncompromising Performance Budgets:**
   - **Idle CPU (Editor open, video paused):** **`0.0% CPU`** (0 wake-ups/sec via on-demand GPU rendering `enableSetNeedsDisplay = true`).
   - **Memory Footprint:** **`< 120 MB RAM`** per open project (compared to ~950 MB+ in Electron-based alternatives).
   - **Zero-Copy GPU Pipeline:** Screen frames (`CVPixelBuffer` / `IOSurface` on macOS, `ID3D11Texture2D` on Windows) stay in GPU memory from capture/decode through shader compositing to hardware encoding.
   - **Zero FFmpeg Bloat:** All core recording, demuxing, decoding, compositing, and hardware encoding (H.264, HEVC, ProRes) use native OS media engines (`ScreenCaptureKit` + `AVFoundation` + `VideoToolbox` on macOS; `Windows.Graphics.Capture` + `Media Foundation` on Windows).
3. **Cinematic Visual Quality:**
   - Physically based spring animations (cursor glide + virtual camera dolly/zoom).
   - Real-time GPU camera & cursor motion blur.
   - Unlimited **Multi-Track Blur & Spotlight Masks**.
   - High-DPI vector/high-res cursor re-rendering (real cursor is excluded from raw screen capture and synthesized in post-processing).
4. **Multi-Project Document Architecture:**
   - On macOS (and Windows), users can open, edit, and export **multiple `.nativescreen` projects simultaneously** in independent native windows or tabs (`NSDocument` / SwiftUI multi-window architecture).

---

## 2. Repository & Directory Structure

```text
NativeScreen/
├── spec/                           # Cross-platform specifications, schemas, ADRs & platform guides
│   ├── README.md
│   ├── 01-OVERVIEW-AND-ARCHITECTURE.md
│   ├── 02-FILE-FORMAT-AND-SCHEMA.md
│   ├── 03-CINEMATIC-ENGINE-AND-MATH.md
│   ├── 04-UI-UX-AND-LEGAL-GUIDELINES.md
│   ├── 05-FEATURE-CHECKLIST.md
│   ├── 06-ENGINEERING-DECISIONS-AND-OPTIMIZATIONS.md
│   ├── platforms/
│   │   ├── macos-metal-videotoolbox.md
│   │   └── windows-d3d11-mediafoundation.md
│   └── schemas/
│       └── project.schema.json
├── NativeScreen/                   # macOS Native App (Swift, SwiftUI, AppKit, Metal, ScreenCaptureKit)
│   ├── NativeScreen.xcodeproj
│   └── NativeScreen/
└── NativeScreenWindows/            # (Planned Phase 5) Windows Native App (C#, WinUI 3, Direct3D 11, WGC)
```

---

## 3. High-Level System Architecture

Both macOS and Windows implementations share the same logical 5-layer architecture and read/write the exact same `.nativescreen` package format:

```text
┌─────────────────────────────────────────────────────────────────────────┐
│                    1. UI & DOCUMENT LAYER                               │
│  macOS: SwiftUI + AppKit (NSPanel HUD, Multi-Window Editor, Inspector)  │
│  Windows: WinUI 3 + Windowing API (Acrylic HUD, Editor, Inspector)      │
├─────────────────────────────────────────────────────────────────────────┤
│                    2. NLE & UNDO/REDO STATE ENGINE                      │
│  Immutable Raw Media + Value-Type `ProjectDocument` State               │
│  Snapshot Stack Undo/Redo (⌘Z / ⇧⌘Z) with Slider Drag Coalescing        │
├─────────────────────────────────────────────────────────────────────────┤
│                    3. CINEMATIC SOLVER ENGINE                           │
│  • Spring Physics Solver (Cursor Path & Virtual Camera Zoom/Pan)        │
│  • Auto-Zoom Click Cluster & Keystroke Hold Analyzer                    │
│  • NLE Timeline Time-Mapper (Timeline Time <-> Source Time + Speed)     │
├─────────────────────────────────────────────────────────────────────────┤
│                    4. GPU COMPOSITOR & SHADER PIPELINE                  │
│  macOS: Metal (MTKView + Compute/Render Pipelines)                      │
│  Windows: Direct3D 11 / Direct2D (SwapChainPanel + HLSL Shaders)        │
│  Passes: Background -> Shadow/Inset -> Screen Frame (Rounded) ->        │
│          Multi-Region Blur/Spotlight Masks -> Cursor + Click Ripple ->  │
│          Loupe Glass -> Camera PiP/Cutout -> Motion Blur -> Captions    │
├─────────────────────────────────────────────────────────────────────────┤
│                    5. NATIVE CAPTURE & HARDWARE MEDIA ENGINE            │
│  macOS: ScreenCaptureKit, CGEventTap, AVAssetReader/Writer, Vision,     │
│         HLS/fMP4 Segmented Writer                                       │
│  Windows: Windows.Graphics.Capture, WASAPI, SetWindowsHookEx,           │
│           Media Foundation (IMFSourceReader / IMFSinkWriter)            │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 4. Non-Linear Editing (NLE) & Undo/Redo Architecture

### 4.1. Strict Non-Destructive Principle
- Raw recorded files inside `project.nativescreen/recording/` (`display.mp4`, `webcam.mp4`, `microphone.m4a`, `cursor.jsonl`, `clicks.jsonl`, `keys.jsonl`) are **strictly read-only and immutable** once recording finishes.
- Splitting a clip, trimming dead air, changing playback speed (`0.25x` – `10.0x`), adding zooms, or adding multiple blur masks **never modifies the underlying video or telemetry files**.
- All edits only mutate the in-memory `ProjectDocument` struct, which serializes to `project.json`.

### 4.2. Timeline Time vs. Source Time Mapping
- Every `ClipSlice` on the timeline defines:
  - `sourceStartMs`: Start timestamp in the original recording.
  - `sourceEndMs`: End timestamp in the original recording.
  - `speed`: Playback rate multiplier (e.g., `1.0`, `2.0`).
- Duration of a slice on the timeline:
  $$\text{timelineDurationMs} = \frac{\text{sourceEndMs} - \text{sourceStartMs}}{\text{speed}}$$
- Zooms, Multi-Track Masks, and Cursor telemetry can be anchored either to **Source Time** (so trimming an earlier slice never breaks downstream zooms/masks/cursor alignment) or **Timeline Time**. By default, **Zooms, Masks, and Cursor events are anchored to `sourceMs`** so they remain 100% locked to the visual content of the recording regardless of cuts or speed changes.

### 4.3. Value-Type Snapshot Undo/Redo
- Because `ProjectDocument` is a lightweight value-type (`struct` in Swift, `record` in C#) weighing ~10–50 KB in memory:
  - Every discrete user action pushes the previous `ProjectDocument` onto `undoStack: [ProjectDocument]` (capped at e.g. 200 states = ~4 MB RAM max) and clears `redoStack`.
  - Continuous interactions (dragging a slider, resizing a blur box, dragging a timeline trim handle) call `beginInteractiveEdit()` on mouse-down (recording a single undo snapshot) and `endInteractiveEdit()` on mouse-up.
  - Pressing `⌘Z` / `Ctrl+Z` swaps the state in `< 0.1 ms` with zero risk of state desynchronization.

---

## 5. Multi-Project Support on macOS

- Each `.nativescreen` project opens in its own independent Editor Window.
- The Recording HUD Bar (`NSPanel`) and Menu Bar item (`NSStatusItem`) act as a global coordinator that can initiate a new recording at any time and spawn a new Editor Window upon completion while existing project windows remain open.
- Each Editor Window owns its own isolated `ProjectSession` (holding its own `ProjectDocument`, `UndoManager`, `AVAssetReader`/Preview decoder, and `MTKView` renderer).
- When an Editor Window is in the background or paused, its `MTKView.isPaused` is set to `true`, consuming **0% CPU and 0% GPU**.
