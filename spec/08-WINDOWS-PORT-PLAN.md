# NativeScreen: Windows Port Plan

What to port from the macOS code, how correctness is checked, and the order of work. The implementation details live in
`spec/platforms/windows-d3d11-mediafoundation.md`, the pixel rules in `spec/07-RENDERING-PARITY.md`, and the working
rules for agents in `windows/AGENTS.md`.

---

## 1. Porting Map (Swift → C#)

**Port the code, not the prose.** Each C# type below is a port of the listed Swift code. Read the Swift source while
writing the C#, keep the same names for types, members and constants (C# casing), and copy every constant and formula.
Where the Swift code and a spec disagree, the Swift code wins.

| Swift (macOS, `NativeScreen/NativeScreen/`) | C# (Windows, `windows/src/`) | Notes |
| :--- | :--- | :--- |
| `Models/ProjectDocument.swift` | `Core/Models/*` | Every `init(from:)` default for missing keys must be reproduced (old projects omit fields). Enum raw values are the JSON strings. |
| `Models/RecordingMetadata.swift` | `Core/Models/RecordingMetadata.cs` | `platform = "windows"` when written by Windows. |
| `Models/NLETimeMapper.swift` | `Core/Timeline/NLETimeMapper.cs` | Exact. |
| `Models/WallpaperCatalog.swift` (`MeshPreset`, gradient swatches) | `Core/Styles/*` | Mesh colors and ids exact. System wallpapers: `C:\Windows\Web\Wallpaper\` instead of `/System/Library/Desktop Pictures/`. |
| `Engine/SpringTrajectorySolver.swift` (incl. `AutoZoomClusterGenerator`) | `Core/Motion/*` | Exact, including step size (120 Hz), substeps, clamps, lookahead, drag/click speed boost, dead-zone groups, loupe springs. Same `double` arithmetic order. |
| `Engine/StageLayout.swift`, `MetalFrameCompositor` stage helpers (`resolvedStageLayout`, `rawStageLayout`, `cameraPlacement`, `computeSplitScreenGeometry`, `calculateFittedScreenRect`, `stageKey`, `effectiveCameraConfig`) | `Core/Layout/*` | Pure functions of (project, time, canvas size). |
| `Engine/CaptionLineLayout.swift` | `Core/Captions/CaptionLineLayout.cs` | Exact. |
| `Engine/CanvasCoordinateTransform.swift` | `Core/Layout/CanvasCoordinateTransform.cs` | Preview hit-testing math. |
| `Engine/HardwareVideoExporter.swift` (`ExportConfiguration`, formats, compression, estimators) | `Core/Export/*` | Settings model and file-size / duration estimators exact. The encoding pipeline is Windows-specific (`Media/Export`). |
| `Document/ProjectSession.swift` | split | Logic → Core services: undo stack (snapshot based), selection/split/move/resize rules, mask keyframe math, typing-suggestion detection, shortcut clustering and normalization, camera layout track, voiceover track, transcript edits. UI state (hover, selection, playhead, popovers) → `App/ViewModels/ProjectSessionViewModel`. |
| `Document/ProjectWorkspaceStore.swift` | `App/Workspace/*` | Recent projects, window management, save prompts, presets store, directories. |
| `Document/AppSettings.swift`, `EditorViewPreferences.swift` | `App/Settings/*` | Stored in `%LOCALAPPDATA%\NativeScreen\settings.json`. |
| `Document/VideoProjectImporter.swift` | `Media/Import/VideoProjectImporter.cs` | Same package layout. |
| `Engine/MetalFrameCompositor.swift`, `Engine/EffectKernels.swift`, `Engine/CursorSpriteProvider.swift` | `Rendering/*` | Per `spec/07`. |
| `Engine/MetalPreviewView.swift` | `App/Preview/*` + `Media/Playback/*` | Playback engine and preview loop per the platform guide §3–§5. |
| `Engine/LocalOnDeviceMediaIntelligence.swift` | `Intelligence/*` + camera looks in `Rendering` | Whisper, filler words, SRT, OCR masks, face masks, camera looks, cutout. |
| `Recording/*` | `Media/Capture/*`, `App/Recording/*` | Platform guide §7. HUD and window picker are WinUI windows. |
| `Views/*` | `App/Views/*` | Same layout and behavior; use the Swift views as the reference for every control, spacing and string. |
| `tools/generate_cursor_assets.py` output (`Resources/Cursors.bundle`) | `App/Assets/Cursors/` | Use the generated files as-is (same names). Themes, sprite selection and old-project migration: `spec/06` ADR-22. |

---

## 2. Conformance Fixtures (macOS → Windows)

Windows correctness is checked against outputs produced by the macOS app.

### 2.1. Generator (macOS)
A hidden command-line mode in the macOS app writes the fixtures:
```bash
"Native Screen.app/Contents/MacOS/Native Screen" --generate-conformance <repo>/conformance
```
It builds synthetic projects in code (deterministic: fixed seeds, fixed telemetry, generated source images), runs the
Swift engine, and writes the results. No personal recordings are ever used.

### 2.2. Layout
```text
conformance/
├── README.md                    # How the fixtures were generated, tolerances
├── looks/<preset>.cube          # 33³ LUT per built-in camera look (spec/07 §7.1)
└── cases/<case-id>/
    ├── project.nativescreen/    # project.json, recording/metadata.json, telemetry/*.jsonl (no video)
    ├── inputs/
    │   ├── screen.png           # source screen frame used for every rendered frame
    │   └── webcam.png           # source webcam frame (when the case has a camera)
    └── expected/
        ├── timemap.json         # [{ timelineMs, sourceMs, sliceIndex }]
        ├── trajectory.json      # [{ sourceMs, cursor: { x, y, opacity, rotation, kind, clickProgress }, camera: { scale, cx, cy, loupeScale, loupePresence } }]
        ├── autozoom.json        # zoom blocks generated from the case telemetry
        ├── stage.json           # [{ sourceMs, canvas: [w, h], screenRect, camera: { rect, cornerRadius, opacity, shadowOpacity, borderOpacity, isCutout } }]
        ├── captions.json        # [{ sourceMs, words: [{ text, opacity, isSpokenNow }] }]
        ├── shortcuts.json       # clusters, labels, envelope samples
        ├── estimates.json       # export size and duration estimates for every format / fps / resolution / compression
        └── frames/<sourceMs>.png  # composed export frames at 1280×720, rendered from inputs/*.png
```
Rects are top-left origin, pixels. Times in ms. All numbers as JSON doubles.

### 2.3. Cases (minimum set)
`basic` (padding, corners, shadow, gradient background) · `wallpaper-blur` · `mesh` · `masks` (blur, pixelate, solid,
spotlight, keyframed) · `zoom-follow` (auto zoom, cursor follow, motion blur) · `zoom-manual` · `loupe` · `cursor-styles`
(each theme, click circle and ripple, rotation tilt and follow, idle hide) · `drag-sync` · `slices-speed-cut` ·
`camera-overlay` · `camera-split` (auto, 1/2, 2/3, flipped, padded) · `camera-cutout` · `camera-layout-transitions` ·
`captions-dark` / `captions-light` (each reveal and animation mode) · `keycaps` (each dock position and color mode) ·
`device-mockup` (each device and finish) · `custom-look-warmth` · `aspect-ratios` (16:9, 9:16, 1:1, 4:3).

### 2.4. Tolerances
| Output | Tolerance |
| :--- | :--- |
| Time mapping, trajectory, auto zoom, stage, captions, shortcuts, estimates | `|a - b| ≤ 1e-6` relative or `≤ 1e-4` absolute (pixels / normalized units). Discrete values exact. |
| Frames without text | SSIM ≥ 0.985 and max per-channel difference ≤ 6/255 on 99.5% of pixels |
| Frames with text (captions, keycaps) | SSIM ≥ 0.95 overall; text regions excluded from the max-difference check |
| Camera looks via LUT | max difference ≤ 2/255 |
| Custom camera presets | SSIM ≥ 0.97 on the camera region |

The Windows tests (`Core.Tests`, `Rendering.Tests`) read `conformance/` directly and fail with a per-field diff.

---

## 3. Phases

Each phase ends when its acceptance checks pass on the Windows machine (run by the verifier, recorded in `windows/HANDOFF.md`).

| # | Phase | Scope | Acceptance |
| :---: | :--- | :--- | :--- |
| 0 | Foundations | macOS conformance generator; `windows/` solution skeleton, `Directory.*.props`, `verify.ps1`, empty WinUI window | `verify.ps1` green; `conformance/` committed with all cases |
| 1 | Core | Models + JSON, time mapper, solvers, auto zoom, layout, captions, shortcuts, estimators, undo | All numeric conformance passes (also runs on macOS with `dotnet test`); every macOS sample project round-trips (load → save → identical JSON semantics) |
| 2 | Rendering | Device, all passes, text, cursors, lens, motion blur, LUT looks, cutout post-process | All frame fixtures pass; compose ≤ 4 ms/frame at 1080p and ≤ 8 ms at 4K on the target GPU (GPU timestamps); no per-frame 4K blur |
| 3 | Playback | Readers, playback engine, audio clock, `SwapChainPanel` preview in a minimal window | Plays macOS projects at the display rate: < 1% of frames presented late over 60 s, A/V offset ≤ 20 ms, first frame ≤ 100 ms after Play with no hitch, 0% CPU when paused |
| 4 | Export | MP4 H.264/HEVC, GIF, audio mix, progress, cancel | Exported frames match `frames/*.png` cases (SSIM as §2.4 after decode); flat memory on a 30 min project; even progress; speed recorded for the 4K reference project |
| 5 | Recording | Display, window, area capture; telemetry; mic, system, per-app audio; webcam; HUD; pause; crash safety | A Windows recording opens in the macOS app with correct cursor sync; killing the process mid-recording leaves a playable `display.mp4` |
| 6 | Editor UI | Welcome, editor, inspector tabs, timeline, command menu, menus, settings, presets, multi-window | Feature parity with the macOS items in `spec/05`; timeline drag/resize at display rate with no UI-thread stalls > 8 ms |
| 7 | Intelligence | Captions (Whisper), transcript editing, cutout, OCR / face masks, face tracking | Same project features as macOS; preview never blocks on inference |
| 8 | Packaging | MSIX, `.nativescreen` association and icon, settings migration, signing | Clean install and upgrade on a fresh Windows 11 machine |

Phases 1 and 2 can overlap once the Core models exist. UI work (phase 6) starts only after playback (phase 3), so the
editor is built on a preview that is already smooth.
