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

## 2026-11-02, Editor parity: segment menus, command menu, export modals, recording options

### Verifier
- **Result:** PASS for the items exercised below. This is a parity pass, not a phase acceptance, so `spec/05` is unchanged.
- **verify.ps1:** Debug and Release x64 PASS; Core 150, Media 13, Rendering 19 tests passed; 12 shaders compiled.
- **Exercised in the running app, on copies of projects:** real mouse right-click menus on clip, zoom and mask; Duplicate from a menu; split with C and merge with the cut badge; D, Esc, H, Ctrl+C and Ctrl+V; a mask dragged up to a new track (2 to 3 tracks, undo restored it); crop presets with a real recording; zoom position pad (center written to `project.json`); a JPEG still and a clipboard video through the new modals; a 6 s area recording, no microphone or camera, with the highlight window present while recording and gone after, then After Recording set to clipboard, which produced the file.
- **Not exercised:** menus on shortcut, layout and voiceover segments; Alt held for split; file pickers (export to file, both-codec export, still folder choice); a GIF with loop disabled; moving the crop box by drag; the highlight's look, since it is excluded from capture and screenshots cannot show it.
- **Changes made:** `SegmentMenu.cs`, `EditorWindow.Commands.cs`, `EditorWindow.Dialogs.cs`, `ZoomPositionPad.cs`, `Recording/RecordedAreaHighlight.cs`, `EditorSession.Segments.cs`. Two icons missing from the Windows 10 font were replaced.
- **Spec updates:** `spec/06` ADR-28.
- **Next:** Gaps still open against macOS, largest first: voiceover recording (needs microphone testing, ADR-23), custom color presets and LUT loading, camera preview bubble, draw a new mask on the preview, cursor variants, built-in music, transcript word bar editing, custom color and gradient pickers, camera crop, hover skim, per-shortcut styles, preset management, view toggles, settings panes including quick export, hide desktop icons, max camera resolution. Small ones: crop edge handles and thirds grid, trim badges, quick dock layouts, device finish, layout position and ratio, pinch zoom, recents menu items.

## 2026-11-02, Phases 3 to 8: measurements and what is left (verifier work on Windows)

### Verifier
- **Result per phase:**
  - Phase 0 PASS: `verify.ps1` green, `conformance/` committed.
  - Phase 1 PASS: 131 Core tests including numeric conformance; all 26 macOS fixtures round trip.
  - Phase 2 FAIL (partial): `custom-look-warmth` and `camera-cutout` below the frame threshold; full frames blocked by the fixture defect; cutout not implemented. Compose time meets the target on a synthetic frame (ADR-24).
  - Phase 3 FAIL (partial): in the real window, 60 s at 60 Hz with 0.28% of intervals over 1.5x the median (ADR-26), 0.00% CPU paused, first frame 45 ms offscreen. Missing: A/V offset measured on real sound, and someone listening to it.
  - Phase 4 FAIL (partial): MP4 and GIF work and memory peaked at 307 MB, at 1.69x for 1080p and 1.17x for 4K. Not run: 30 minute flat memory, frames compared with `frames/*.png`.
  - Phase 5 FAIL (partial): display, window and area through the app or test, pause, system audio, and a killed process leaving 4.7 of 5 s playable all work. Blocked: microphone resets the machine (ADR-23); camera never completed; a recording not yet opened on macOS.
  - Phase 6 FAIL (partial): trimming clips, adding from the plus on a row, scrubbing, and moving and resizing masks on the preview were driven with real mouse input and checked in project.json. Dragging layouts, shortcuts and voiceovers, and the clip, layout and shortcut inspectors were built but not driven. Not done: global and customizable shortcuts (open on macOS too), the short-video mock interface, which is reduced to plain safe zones. Crop, stills, presets and file pickers not driven end to end, because the pickers cannot be automated here. No UI-stall measurement.
  - Phase 7 FAIL (partial): OCR found text in real engine runs on generated clips. The face engine ran but never saw a face. Whisper downloaded the base model and transcribed the Windows voice correctly, from WAV and from a fragmented recording (ADR-25); no real microphone speech, and the app's dialog path not driven. Cutout missing.
  - Phase 8 FAIL (partial): MSIX built, never installed or signed. Folders cannot take a file association (ADR-24).
- **Machine note:** every run with the microphone ended in a reset, so none were repeated. `NS_TEST_CAPTURE_PARTS` selects what a capture test turns on.

## 2026-11-02, Phase 3 and 5: preview audio and the recording engine (verifier work on Windows)

### Verifier
- **Result:** Phase 5 FAIL (partial). Phase 3 not measured.
- **Done:** Preview plays the audio mix through WASAPI, and the device position corrects the clock. Display, window and area capture, telemetry hooks, system audio, microphone, webcam, pause and package finishing as a library. The HUD and target picker are not written, so nothing is reachable from the app yet.
- **Measured:** Screen only and screen with system audio, on a 1536×960 capture: about 57 fps, 6 to 7 ms per frame to copy and convert, cursor every 9 ms, pause removed from all times, stop in about 45 ms. Reader times match written times in `FragmentedTimingTests` (ADR-22). Preview audio has not been heard in the app, and no A/V offset was measured.
- **Blocker:** The 3 runs with the microphone reset the machine (ADR-23). Camera alone not run. Window and area capture, crash safety and opening a recording on macOS not run.

## 2026-11-01, Phase 1, 2 and 6: saving and the compositor (verifier work on Windows)

### Verifier
- **Result:** Phase 2 FAIL (partial). Phase 1 project round trip PASS.
- **Done:** Autosave after 350 ms, atomic `project.json`, flush on close, and a real Showcase package on disk. Round trip across all 26 macOS fixtures keeps every value of `project.json` and `metadata.json`. Compositor: background (solid, gradient, mesh, blur), masks (blur, pixelate, solid, spotlight), Lanczos downscale, corners, inset, baked shadow, cursor SVG sprites with drop shadow, click effects, classic zoom, motion blur and lens.
- **Measurements:** Screen region against macOS frames, enforced in `Rendering.Tests` for `basic`, `drag-sync`, `masks`, `mesh`, `slices-speed-cut`, `wallpaper-blur`: SSIM 0.997 or more and 99.6 to 99.9% of pixels within 6/255, except the keycap frame at 2600 ms, which is excluded until keycaps are composited. Other cases are reported and not enforced. Full-frame scores are not meaningful until the fixtures are regenerated. No GPU timing yet.
- **Added after that:** camera overlay with built-in and custom looks, captions, keycaps, device mockup bezel, wallpaper and image backgrounds. Video decode into the preview, scrubbing and seeking. Export to MP4 (H.264, HEVC) and GIF with audio mix, progress and cancel, in `NativeScreen.Export`. `Media.Tests` round trips real clips; `Rendering.Tests` exports a real package and checks frame count, pixels against the compositor, audio, GIF frames and that cancel leaves no file.
- **Measured:** Playing a 1280×720 clip at 30 fps in a 2400×1500 window: about 40 to 46% of one core, 0 ms CPU over 4 s paused. Windows 10, one machine. No late-frame ratio, A/V offset, GPU timing, export speed or 4K numbers yet.
- **Not done in the compositor:** cutout mask, camera sharpen, live background crossfade, keycap and layout springs during edits. `custom-look-warmth` is at 95.4% in the screen region and `camera-cutout` at 94%; both stay out of the enforced list.
- **Not done at all:** audio during preview playback, recording, intelligence, crop, presets, most settings, copy to clipboard, ProRes-equivalent options, waveform.
- **Unexplained:** a fragmented clip reads back 100 ms late under the test host only (`spec/06` ADR-21).
- **Needs macOS:** regenerate the fixtures after making the generator use one compositor per case (`spec/06` ADR-20). Decide whether the vertical flip of baked layers is a bug to fix on macOS.
- **Spec updates:** `spec/06` ADR-20, `spec/07` Pass 1 and Pass 3, `spec/08` §2.4, `windows/AGENTS.md` commands.

## 2026-11-01, Phase 6: editor shell

### Writer
- **Scope:** `EditorSession` holds the playhead, inspector tab, command search, and the existing undo stack. The WinUI app opens a welcome window, an editor (menu bar, preview `SwapChainPanel`, inspector tabs, timeline slider, command menu), and a settings window with light and dark. Accelerators use Ctrl. Preview attach is `ISwapChainPanelNative` (`63aad0b8-7c24-40ff-85a8-640d944cc325`).
- **Built on macOS:** `dotnet test windows/tests/NativeScreen.Core.Tests` — 46 passed. The WinUI XAML compiler is a Windows executable, so the app project was not built here.
- **How to verify:** `pwsh windows/scripts/verify.ps1`, then `dotnet run --project windows/src/NativeScreen.App -c Debug -p:Platform=x64`. Welcome opens. Open project loads a `.nativescreen` package into the editor. Play moves the time label and pauses at the end. Scrubbing stops playback. Undo restores the document name. Settings toggles dark and light. Command menu filters titles. Timeline drag must not stall the UI more than 8 ms.
- **Open VERIFY items:** `EditorWindow.xaml.cs` attaches the swap chain on the UI thread; the render thread must wait on the latency object and call `Present(1, 0)`. `WelcomeWindow.xaml.cs` file picker hwnd init. `SwapChainPanelInterop.cs` QueryInterface of the panel.
- **Risks / unsure:** The 16 ms dispatcher timer only updates the time label. The 120 Hz playhead still needs a Composition visual. Inspector pages show the tab title, not the full macOS control set.

### Verifier
- **Result:** FAIL. The chrome now follows the macOS layout, but phases 3 to 5 and 7 have no backend behind it. See Next.
- **verify.ps1:** PASS under Windows PowerShell 5.1: Debug and Release x64, Core tests 52 passed, 7 shaders compiled with dxc.
- **Measurements:** Windows 10 19045, 150% scale. Driven through UI Automation and real input: every inspector tab, command menu, export sheet, play and pause, split, undo, zoom drag, light theme, opening a package. No crashes. 0 ms CPU over 5 s idle after a static stage was drawn. No frame timing or drag stall measurement yet.
- **Changes made:** `SwapChainPanelInterop.cs` uses native `QueryInterface`. Editor, Welcome and Settings rebuilt from the Swift views (`App.xaml`, `Ui.cs`, `InspectorPanel.cs`, `TimelineView.cs`). `EditorSession` gained undoable edits: add zoom and mask, split, delete, interactive edits. Timeline duration now comes from the slices. `ShowcaseProject` is in-memory. `PreviewRenderer` and `StageScene` draw the background, shadow, screen, inset and camera placement on a render thread. Open project uses a folder picker, shows a dialog on failure, and no longer resolves the wrong directory.
- **Spec updates:** `spec/06` ADR-18 and ADR-19, `spec/platforms/windows-d3d11-mediafoundation.md` §8 and §9.
- **Next:** Edits are not saved: no `project.json` write exists, and a round trip against macOS projects must be proven before adding one. Inspector values outside the stage (cursor, camera style, captions, masks, device frames) change the document but draw nothing. Then decode and playback, full compositor passes, export, recording, intelligence. Disabled with a tooltip until then: recording, presets, crop, export frame, export start, playback speed, voiceover, image background, transcript generation, sensitive data and face detection, remove project. Missing from the timeline: waveform, hover add, typing suggestions, shortcut blocks from telemetry. System wallpapers and most Settings tabs are absent. Windows 11 behavior was not checked on this machine.

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
