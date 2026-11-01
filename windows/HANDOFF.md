# Windows Handoff Log

Shared log between the **writer** (macOS) and the **verifier** (Windows). Newest entry on top. See `AGENTS.md` §2.

## Template

```markdown
## <YYYY-MM-DD>, Phase <n>: <short title>

### Writer
- **Scope:** what was ported (Swift sources → C# files)
- **Built on macOS:** projects built / tests run and their result
- **How to verify:** exact steps and expected results (from `spec/08` §3 where possible)
- **Open VERIFY items:** file:line, what to check
- **Risks / unsure:** anything the verifier should look at first

### Verifier
- **Result:** PASS | FAIL
- **verify.ps1:** summary (build, tests, shaders)
- **Measurements:** frame timing, A/V offset, export speed, memory, SSIM, … (with machine: CPU, GPU, display Hz)
- **Changes made:** files and why
- **Spec updates:** ADRs or guide changes added
- **Next:** what the writer should do next
```

---

<!-- Entries start below this line. -->

## 2026-11-01, Phase 6: editor shell

### Writer
- **Scope:** `EditorSession` holds the playhead, inspector tab, command search, and the existing undo stack. The WinUI app opens a welcome window, an editor (menu bar, preview `SwapChainPanel`, inspector tabs, timeline slider, command menu), and a settings window with light and dark. Accelerators use Ctrl. Preview attach is `ISwapChainPanelNative` (`63aad0b8-7c24-40ff-85a8-640d944cc325`).
- **Built on macOS:** `dotnet test windows/tests/NativeScreen.Core.Tests` — 46 passed. The WinUI XAML compiler is a Windows executable, so the app project was not built here.
- **How to verify:** `pwsh windows/scripts/verify.ps1`, then `dotnet run --project windows/src/NativeScreen.App -c Debug -p:Platform=x64`. Welcome opens. Open project loads a `.nativescreen` package into the editor. Play moves the time label and pauses at the end. Scrubbing stops playback. Undo restores the document name. Settings toggles dark and light. Command menu filters titles. Timeline drag must not stall the UI more than 8 ms.
- **Open VERIFY items:** `EditorWindow.xaml.cs` attaches the swap chain on the UI thread; the render thread must wait on the latency object and call `Present(1, 0)`. `WelcomeWindow.xaml.cs` file picker hwnd init. `SwapChainPanelInterop.cs` QueryInterface of the panel.
- **Risks / unsure:** The 16 ms dispatcher timer only updates the time label. The 120 Hz playhead still needs a Composition visual. Inspector pages show the tab title, not the full macOS control set.

### Verifier
- **Result:**
- **verify.ps1:**
- **Measurements:**
- **Changes made:**
- **Spec updates:**
- **Next:**

## 2026-11-01, Phase 5: recording timeline and capture policy

### Writer
- **Scope:** `PauseTimeline` matches `ScreenCaptureEngine.pausedOffset` (samples inside a pause are dropped). Display and webcam bitrates, even dimensions, cursor kind names (`IDC_HAND` → `pointer`, `IDC_IBEAM` → `ibeam`), normalized capture coordinates, package-relative telemetry paths, and jsonl append. `CapturePolicy` records cursor-off, `WDA_EXCLUDEFROMCAPTURE` (`0x11`), and the borderless-capture rule.
- **Built on macOS:** Core tests passed, including a cursor jsonl round trip. No Windows.Graphics.Capture call was made.
- **How to verify:** Record display, window, and area. Cursor is absent from `display.mp4` and present in `telemetry/cursor.jsonl`. Pause removes that span from every track. Kill the process mid-recording and confirm `display.mp4` still opens on macOS. HUD windows are excluded.
- **Open VERIFY items:** `CapturePolicy.cs` — `IsCursorCaptureEnabled`, borderless access, `SetWindowDisplayAffinity`, and QPC inside the hook callback. Fragmented MP4 for the recording (2 s) is still the export writer; the recording path should call `MFCreateFMPEG4MediaSink`.
- **Risks / unsure:** `IDC_SIZEALL` is mapped to `openhand`. Hook callbacks must only enqueue.

### Verifier
- **Result:**
- **verify.ps1:**
- **Measurements:**
- **Changes made:**
- **Spec updates:**
- **Next:**

## 2026-11-01, Phase 4: export job and hardware sink writer

### Writer
- **Scope:** Audio gains match `HardwareVideoExporter` (system, microphone, voiceover mute, music × 2.5). `ExportPlan` frame count, quality 87/72/58/42, and ProRes hidden on Windows. `ExportJob` progress is encoded frames / total frames; cancel deletes the partial file. `FragmentedMp4Writer` creates an `IMFSinkWriter` with hardware transforms, H.264 or HEVC, NV12 input, GOP of 2 s.
- **Built on macOS:** Core tests passed. The sink writer was not opened.
- **How to verify:** Export the conformance project. Progress moves with encoded frames. Cancel leaves no partial file. Encoded frames match `conformance/frames/*.png`. A 30 minute project stays flat in memory. GIF still needs a WIC encoder; the job only plans the frame count.
- **Open VERIFY items:** `FragmentedMp4Writer.cs` — `ICodecAPI` quality, hardware MFT check, BT.709 tags, and `MFCreateFMPEG4MediaSink` for recordings. `ID3D11VideoProcessor` BGRA to NV12 is not wired yet.
- **Risks / unsure:** Quality mode may be rejected; the writer already sets the average bitrate as the fallback value.

### Verifier
- **Result:**
- **verify.ps1:**
- **Measurements:**
- **Changes made:**
- **Spec updates:**
- **Next:**

## 2026-11-01, Phase 3: playback clock and source reader

### Writer
- **Scope:** `PlaybackClock` uses QPC, or the audio clock minus device latency when audio is playing. `FrameRing` keeps 4 frames and picks the newest `pts <= clock`. Late-frame ratio, scrub coalescing, and idle-when-paused are in Core. `HardwareVideoReader` starts Media Foundation, requests NV12, disables advanced video processing, and enables hardware transforms. The composition swap chain presents with sync interval 1.
- **Built on macOS:** Core tests passed. `dotnet build windows/src/NativeScreen.Media` — 0 warnings. No file was decoded.
- **How to verify:** Play a 60 s project. Late frames stay under 1%. A/V offset stays within 20 ms. First frame appears within 100 ms of play. Pausing drops to 0% CPU because the render loop blocks.
- **Open VERIFY items:** `HardwareVideoReader.cs` — `IMFDXGIBuffer` textures on the compositor device, and `MFShutdown` at process exit. `CompositionSwapChain.cs` — wait on `FrameLatencyWaitableObject` before `Present(1, 0)`.
- **Risks / unsure:** The reader is synchronous. A scrub must `Flush` and keep only the latest seek.

### Verifier
- **Result:**
- **verify.ps1:**
- **Measurements:**
- **Changes made:**
- **Spec updates:**
- **Next:**

## 2026-11-01, Phase 2: D3D11 compositor and color pipeline

### Writer
- **Scope:** Core color math (`Rgba`, BT.709 limited NV12, source-over, CIColorControls order saturation → brightness → contrast, vibrance, warmth approximation, LUT lerp), mesh preset table, cursor SVG filename parser, `.cube` reader (red fastest), composite pass order and the screen-shadow / click / motion-blur sample caps from `MetalFrameCompositor` and `EffectKernels`. Rendering embeds `Nv12ToRgb`, `RoundedRect`, `MeshBackground`, `MagnifierLens`, `CameraMotionBlur`, and `Lut3D`. `FrameCompositor` compiles them with Vortice.D3DCompiler 3.8.3, creates a B8G8R8A8_UNORM target (not `_SRGB`), and a source-over blend of ONE / INV_SRC_ALPHA. `CompositionSwapChain` is flip, two buffers, waitable latency 1. `verify.ps1` compiles every `.hlsl` with Windows SDK `dxc`.
- **Built on macOS:** `dotnet test windows/tests/NativeScreen.Core.Tests` — 38 passed. `dotnet build windows/src/NativeScreen.Rendering` — 0 warnings. GPU draw, SSIM, and `dxc` were not run here.
- **How to verify:** `pwsh windows/scripts/verify.ps1`. Shader step should PASS (6 files). On a GPU, `FrameCompositor` constructs without throwing and `CompiledShaderCount` is 6. Frame fixtures in `conformance/frames/` are the SSIM target (not compared on macOS). Compose budget is ≤4 ms/frame at 1080p and ≤8 ms at 4K; motion blur stays at 8 samples in preview and 24 in export.
- **Open VERIFY items:** `D3D11GraphicsDevice.cs` hardware device then WARP. `CompositionSwapChain.cs` — `ISwapChainPanelNative.SetSwapChain` is not called yet (Phase 6 preview). `FrameCompositor` runtime `Compiler.Compile` against the embedded HLSL. Mesh radial center is top-down `(0.78 W, 0.28 H)`, matching the Swift bottom-left `(0.78 W, 0.72 H)`.
- **Risks / unsure:** Built-in looks must sample `conformance/looks/*.cube`. The warmth approximation is only for custom presets; if SSIM is under 0.97, fit it, do not reimplement the CI chain for the built-in looks. Shadows are metrics only; they are not baked into a texture yet.

### Verifier
- **Result:**
- **verify.ps1:**
- **Measurements:**
- **Changes made:**
- **Spec updates:**
- **Next:**

## 2026-11-01, Phase 0–1: conformance fixtures and Core engines

### Writer
- **Scope:** macOS `--generate-conformance` writes `conformance/` (already generated). Windows `NativeScreen.Core` ports project JSON, `NLETimeMapper`, `SpringTrajectorySolver`, `AutoZoomClusterGenerator`, stage layout (top-left fixture rects), caption lines, shortcut clusters / envelopes / typing suggestions, export size and duration estimators, snapshot undo, and `LoadedProject`. `NativeScreen.Rendering`, `Media`, and `Intelligence` are empty class libraries. `NativeScreen.App` is an unpackaged WinUI 3 window. `windows/scripts/verify.ps1` builds Debug and Release x64, runs tests, and writes `windows/artifacts/verify-report.md`.
- **Built on macOS:** `dotnet test windows/tests/NativeScreen.Core.Tests` — 27 passed, 0 failed. `dotnet build` of Core, Rendering, Media, and Intelligence — 0 warnings. The WinUI app was not built here.
- **How to verify:** `pwsh windows/scripts/verify.ps1`. Expect Debug and Release x64 builds, Core tests green, and a PASS report. Then `dotnet run --project windows/src/NativeScreen.App -c Debug -p:Platform=x64` and confirm a window titled Native Screen.
- **Open VERIFY items:** `windows/src/NativeScreen.App/App.xaml.cs` — unpackaged WinUI 3 on Windows App SDK 2.6.4, `net10.0-windows10.0.22621.0`, `win-x64`, shows the empty window.
- **Risks / unsure:** No HLSL yet, so the shader step in `verify.ps1` is a skip. Stage transitions compare the camera settings that change placement; a color-only edit does not start a blend because the rects would be identical. `spec/05` Phase 5 stays unchecked until the verifier records PASS.

### Verifier
- **Result:**
- **verify.ps1:**
- **Measurements:**
- **Changes made:**
- **Spec updates:**
- **Next:**
