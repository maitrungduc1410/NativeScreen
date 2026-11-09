# NativeScreen: UI/UX Design System & Legal Guidelines

---

## 1. UI/UX Design Principles ("80% OS Native + 20% Custom Pro")

### 1.1. Visual Identity & Performance Rules
- **Instant Responsiveness:** Every button, slider, and timeline scrub must respond within a single display refresh (`8.3ms` at 120Hz ProMotion).
- **Zero Idle Resource Usage:** When playback is paused and the user is not interacting, the GPU preview view (`MTKView` / `SwapChainPanel`) must pause its display link (`isPaused = true`), resulting in **0.0% CPU and 0.0% GPU** in Activity Monitor / Task Manager.
- **Native Materials:**
  - **macOS:** Use `NSVisualEffectView` / SwiftUI `.ultraThinMaterial` and `.regularMaterial` for floating HUDs and sidebars, native **SF Symbols 6** with symbol effects, and standard macOS Dark Mode semantics.
  - **Windows:** Use `MicaBackdrop` for the main editor window, `DesktopAcrylicBackdrop` for floating HUDs, and **Segoe Fluent Icons**.

---

## 2. Core Window Flows & Layouts

### 2.1. Floating Recording HUD Bar (Mode Picker)
- **Window Type:** Non-activating, borderless floating panel (`NSPanel` with `.nonactivatingPanel`, `.hudWindow` material, and `.statusBar` level on macOS).
- **Controls (Left to Right):**
  1. **Close (`xmark.circle.fill`)**
  2. **Target Mode Selector:**
     - `Display` (`display`): Full screen capture.
     - `Window` (`macwindow`): Interactive single-window picker. Includes the app's own editor windows, so editing can be demoed.
     - `Area` (`viewfinder`): Interactive drag-to-crop rectangle with size presets (`16:9`, `9:16`, `1:1`).
     - `Device` (`iphone`): Connected iOS device capture (Phase 3).
  3. **Input Toggles:**
     - Camera selector (`video` / `video.slash`)
     - Microphone selector (`mic` / `mic.slash` + live input level meter)
     - System / App Audio selector (`speaker.wave.2`: All system audio or specific apps)
  4. **Projects Folder & Settings menu (`folder`, `gearshape`)**

### 2.2. Interactive Window Picker Overlay (When `Window` Mode is Active)
- **How It Works:**
  1. Query all on-screen windows in front-to-back Z-order via `CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)` paired with `SCShareableContent`.
  2. Track mouse cursor position at 60/120Hz and hit-test the topmost window under the cursor (excluding NativeScreen's own windows).
  3. Display a full-screen transparent overlay window (`backgroundColor = .clear`, `ignoresMouseEvents = false`) that draws a **smooth spring-animated highlight rectangle** (`cornerRadius: window.borderRadius`) snapped to `hoveredWindow.bounds`.
  4. In the center of the highlighted window, render a floating card showing:
     - **High-resolution App Icon** (`NSRunningApplication(processIdentifier: pid)?.icon`)
     - **App Name & Window Title** (e.g., `Google Chrome`)
     - **Dimensions Badge + `[Resize]` menu** (e.g., `761 × 1090 [Resize]`: uses `AXUIElementSetAttributeValue` to resize the target window to standard 16:9 / 9:16 / 4:3 presets before recording!).
     - **`[Start Recording]` primary button**.

### 2.3. Main Editor Window (Multi-Document Support)
Each `.nativescreen` project opens in its own Editor Window with 4 zones:

```text
┌────────────────────────────────────────────────────────────────────────────┐
│ [● ● ●]  📂  🗑️          MyDemo.nativescreen          ↩ ↪  ✨ Presets [Export]│
├──────────────────────────────────────────────────────┬─────────────────────┤
│        [16:9 ▾]   [Crop]   [Preview: Full ▾]         │ [🎨] Background     │
│                                                      │  Wallpaper | Grad   │
│         ┌──────────────────────────────────┐         │  ┌───┐ ┌───┐ ┌───┐  │
│         │                                  │         │  └───┘ └───┘ └───┘  │
│         │       GPU METAL / D3D11          │         │  Blur     ───●────  │
│         │        PREVIEW CANVAS            │         │  Padding  ────●───  │
│         │   (with interactive Mask/Crop    │         │  Corners  ──●─────  │
│         │         overlay handles)         │         │  Shadow   ─────●──  │
│         └──────────────────────────────────┘         │ [🖱️] Cursor         │
│                                                      │ [🔍] Zoom           │
│                  00:12.40  ⏮  ▶️  ⏭  01:04.45        │ [🔒] Masks / Blur   │
│                                                      │ [🔊] Audio          │
├──────────────────────────────────────────────────────┴─────────────────────┤
│ ✂️ Split | 🧲 Snap | + Zoom | + Blur Mask                 🔍 Timeline Zoom │
│ 0:00          0:05          0:10          0:15          0:20          0:25 │
│ ██████████████████████████████████████████████████████████████████████████ │ <- Clip Slice Track (Orange)
│       ▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒               ▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒ │ <- Auto-Zoom Track (Purple)
│             ░░░░░░░░░░░░░░░░░                                              │ <- Blur Mask Track 1 (Teal)
│                   ░░░░░░░░░░░░░░░░░░░░░░                                   │ <- Blur Mask Track 2 (Teal)
└────────────────────────────────────────────────────────────────────────────┘
```

---

## 3. Copyright & Asset Guidelines

To keep **NativeScreen** distributable under its open-source license (MIT) on GitHub, the Mac App Store, and the Microsoft Store:

### 3.1. Asset & Code Rules
1. **NO Copying of Third-Party Proprietary Assets:**
   - **DO NOT** bundle proprietary third-party `.jpg` wallpapers, `.mp3`/`.wav` audio files, or proprietary `.png` device frames.
2. **Original Code:**
   - Do not copy code from other products. Implement features from this project's specs and the official Apple and Microsoft SDK documentation.

### 3.2. How NativeScreen Provides Wallpapers, Cursors & Sounds Legally

1. **System Wallpapers (Zero Bundle Size, 100% Legal):**
   - **On macOS:** Read available system wallpapers directly at runtime from `/System/Library/Desktop Pictures/` (and `/System/Library/Desktop Pictures/.thumbnails/`) as well as the user's current desktop wallpaper (`NSWorkspace.shared.desktopImageURL(for:)`).
   - **On Windows:** Read directly from `C:\Windows\Web\Wallpaper\`.
   - **Project Portability:** When a user selects a system wallpaper (or drops a custom image) into a project, NativeScreen copies/transcodes that selected image into `MyDemo.nativescreen/assets/background-<id>.jpg` so the project renders identically if moved to another machine.
2. **Self-Drawn Wallpapers and Mesh Gradients (Built-in):**
   - 108 wallpapers (*Spring, Sunset, Radiant, Energy, Iridescent, Midnight, Glassmorphism*) drawn from scratch by `tools/generate_wallpapers.py` and shipped in `Wallpapers.bundle`, about 20 MB. Never add images taken from other apps or wallpaper packs (`spec/06` ADR-32).
   - 8 Mesh Gradient presets rendered by the compositor at any resolution with zero file size. Color hex palettes are not copyrightable.
3. **Native System Cursors:**
   - Capture the active system cursor image directly from macOS (`NSCursor` / CoreGraphics cursor APIs) during recording, or render clean vector cursor SVGs/PDFs designed specifically for NativeScreen.
4. **Camera Stickers:**
   - `Resources/Stickers.bundle` is original Noto Emoji artwork (Apache 2.0), only cropped. Keep its `LICENSE` and `NOTICE.txt` next to it.
   - `Resources/CameraBackgrounds.bundle` holds photos from Pexels and Pixabay under their own licenses, not this project's MIT license (`NOTICE.txt`).
   - Windows has no system person segmentation or face landmarks, so it uses two models. **YuNet** (MIT, `windows/src/NativeScreen.Intelligence/Models`, 232 KB) ships with the app, with its `NOTICE.txt`. **MODNet** (Apache 2.0, the `Xenova/modnet` ONNX export, 26 MB) is downloaded once when someone presses Download, from a pinned revision and checked against its SHA-256.
5. **Synthesized / Royalty-Free Click Sounds:**
   - Generate crisp mechanical & capacitive mouse click audio (`down.wav`, `up.wav`) procedurally via DSP synthesis (or CC0 Public Domain recordings).

### Timeline snapping

The snap button sits right after the split button and uses the same lit style: purple icon on a highlighted fill while on, plain icon while off. Its tooltip says `Snapping on` or `Snapping off`. While an edge is snapped, a 1 pt purple line runs down the tracks at that time.

### Timeline zoom

Hold `⌘` (`Ctrl` on Windows) and scroll over the ruler, the track labels or the lanes to zoom the timeline. The time under the cursor stays where it is (`spec/06` ADR-45). The zoom buttons and `⌘+` / `⌘-` keep the playhead in place.

### Camera background, sticker and face tracking

These live in the Camera style tab, above Color grading, and apply to the whole video.

- **Background:** `None`, `Blur` or `Image` (a few built-in images, or `Choose image...`), with `Edge softness` and `Edge inset`. Hidden for the cutout layout, which has no background.
- **Sticker:** one at a time, or none, in every layout.
- **Face tracking:** the camera zooms in (`Zoom`) and follows the face within the crop.
- Choosing a sticker or face tracking the first time scans the webcam once, with `Finding your face...` and a progress bar. `No face found in this recording.` is shown if there is none.

### Timeline segment labels

A segment shows its title and, under it, its details (`Zoom` over `1.8× Auto`). As it narrows, the details fade out once they no longer fit in full and the title slides to the vertical center over 0.18 s (instant with Reduce Motion). When the title no longer fits it fades out too, leaving the bare segment. Text that can truncate (captions, mask names) stays until about 44 pt of it is left. The smallest segment is set by time (200 to 250 ms depending on the track), not by its label.

### Language

`Settings > General > Language` lists `System`, then each language in its own name (`Tiếng Việt`, `日本語`, ...). Changing it shows `Restart Native Screen to use the new language.` with `Restart Now`. Every new UI string must go through the catalog (`spec/06` ADR-44): a literal in a SwiftUI control, `String(localized:)` for AppKit and display names, or `.localizedUI` inside a component that takes a `String`. Leave room for text 40% longer than English.

### Caption tracks in the inspector

Selecting a caption shows its text and an `Apply to all captions in this track` checkbox, off by default: the options then change only that caption. With no caption selected, the options apply to the track chosen in `Track`. `Transcript method` offers `Local` only.

The inspector does not add caption tracks or turn captions off: tracks are added from the quick dock left of the preview (or a caption's right-click menu), and `Disable captions` / `Enable captions` is in a caption's right-click menu. While captions are off, the inspector says so and points to that menu.
