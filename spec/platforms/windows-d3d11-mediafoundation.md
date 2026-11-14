# Windows Implementation Guide: WinUI 3, Direct3D 11 & Media Foundation

How to build the Windows app (`windows/`) so it matches the macOS app in behavior, output and smoothness. Read together
with `spec/07-RENDERING-PARITY.md` (what each pixel must look like) and `spec/08-WINDOWS-PORT-PLAN.md` (what to port, in
which order, and how each phase is verified). Agent rules and commands are in `windows/AGENTS.md`.

The macOS app is finished and stays Swift. Windows is a separate C# implementation that reads and writes the same
`.nativescreen` projects. There is no shared native core. Rust or C++ is allowed only when a C# path is proven
insufficient (measured), and must be recorded as an ADR in `spec/06`.

---

## 1. Stack

| Concern | Choice |
| :--- | :--- |
| Runtime | .NET 10 (LTS), C# latest, nullable enabled, `x64` and `arm64` |
| UI | WinUI 3 (Windows App SDK, latest stable), unpackaged (`WindowsPackageType=None`) for development and the Velopack installer; MSIX with `NsPackage=true` for the Microsoft Store (`NS_STORE`, no updater, `spec/06` ADR-81) |
| MVVM | `CommunityToolkit.Mvvm` (source-generated observable properties and commands) |
| Direct3D 11, DXGI, Direct2D, DirectWrite, Media Foundation | `Vortice.Windows` (`Vortice.Direct3D11`, `Vortice.DXGI`, `Vortice.D3DCompiler`, `Vortice.Direct2D1`, `Vortice.MediaFoundation`, `Vortice.WinUI` for `ISwapChainPanelNative`) |
| Win32 (hooks, DPI, window styles, cursor, QPC) | `Microsoft.Windows.CsWin32` (generated P/Invoke from `NativeMethods.txt`) |
| WinRT (`Windows.Graphics.Capture`, `Windows.Media.Ocr`, `FaceDetector`) | Direct projection via the `net10.0-windows10.0.22621.0` target framework |
| Audio capture / render | WASAPI through CsWin32 (process loopback needs `ActivateAudioInterfaceAsync`); `NAudio.Wasapi` is acceptable for mic and system loopback |
| Speech to text | `Whisper.net` + its native runtime package, same `ggml-*.bin` models as macOS (downloaded on demand, with consent) |
| Person segmentation | `Microsoft.ML.OnnxRuntime.DirectML` with a portrait segmentation model downloaded on demand |
| Timeline / 2D drawing in XAML | `Microsoft.Graphics.Win2D` (`CanvasControl` / `CanvasVirtualControl`) |
| JSON | `System.Text.Json` with source generation, property names matching `spec/schemas/project.schema.json` |
| Tests | xUnit |

Pin every package version in `windows/Directory.Packages.props` (central package management). Never add a package
without pinning it there.

---

## 2. Solution Layout

```text
windows/
├── AGENTS.md                      # Agent rules, commands, handoff protocol
├── HANDOFF.md                     # Current task log between the macOS writer and the Windows verifier
├── NativeScreen.Windows.slnx
├── Directory.Build.props          # LangVersion, Nullable, TreatWarningsAsErrors (nullable + CA rules), EnableWindowsTargeting
├── Directory.Packages.props       # All package versions
├── src/
│   ├── NativeScreen.Core/         # net10.0: no Windows APIs. Models, JSON, time mapping, solvers, layout, clustering,
│   │                              #   estimators, undo stack. Builds and tests on macOS too.
│   ├── NativeScreen.Rendering/    # net10.0-windows: D3D11 device, compositor passes, HLSL (Shaders/*.hlsl as
│   │                              #   EmbeddedResource), DirectWrite text, Direct2D SVG, texture caches
│   ├── NativeScreen.Media/        # net10.0-windows: decode, playback engine, export, capture (WGC), audio (WASAPI),
│   │                              #   telemetry hooks, webcam
│   ├── NativeScreen.Intelligence/ # net10.0-windows: Whisper, segmentation, OCR, face detection
│   └── NativeScreen.App/          # WinUI 3 app: windows, views, view models, HUD, menus, settings
│   ├── NativeScreen.Export/       # Export worker and audio mix; the one library using both Media and Rendering
├── tests/
│   ├── NativeScreen.Core.Tests/       # net10.0: conformance numbers; runs on macOS and Windows
│   ├── NativeScreen.Rendering.Tests/  # Windows: shader compilation, golden frames (SSIM)
│   └── NativeScreen.Media.Tests/      # Windows: decode/encode/mux/fMP4 round trips with generated clips
└── scripts/
    └── verify.ps1                 # Build + test + report; the Windows verifier runs this first
```

Rules:
- Dependencies point one way: `App → Intelligence/Media/Rendering → Core`. Core never references Windows types.
- Everything that is math or data goes in Core, so it is testable on macOS. If a Swift type mixes logic and UI state
  (for example `ProjectSession`), split it: logic into Core services, UI state into a view model.
- `EnableWindowsTargeting=true` in `Directory.Build.props` lets the `-windows` class libraries compile on macOS. The
  WinUI 3 app project only builds on Windows.

---

## 3. Threads and Clocks

| Thread | Work | Never does |
| :--- | :--- | :--- |
| UI thread (DispatcherQueue) | XAML, input, view models | Decoding, compositing, file I/O, waiting on GPU or locks held by the render thread |
| Render thread (one per editor window) | Composites and presents to the `SwapChainPanel` swap chain | Touch XAML objects |
| Decode threads | `IMFSourceReader` per video track, read ahead into a small texture ring | Block on the UI |
| Audio thread | WASAPI render (playback) or capture (recording), event-driven | Allocate per buffer |
| Export worker | Sequential decode → compose → encode → mux, bounded queues | Use the preview's resources |

- **Clock:** `Stopwatch` (QPC) everywhere. Convert WGC `SystemRelativeTime` (100 ns, QPC-based) and WASAPI QPC
  positions to the same timeline.
- **Playback master clock:** the audio render clock when any audio track plays (`IAudioClock` position, corrected by
  device latency), otherwise QPC. Video frames are chosen from the clock; never the other way around. This is the
  Windows equivalent of anchoring every `AVPlayer` to one host time (`spec/06`, ADR on playback start).
- **Start of playback:** prime decoders and audio buffers first, then start the clock at an explicit QPC instant, so the
  first frames are never late (the macOS "playhead hitch" was caused by starting before the pipeline was primed).
- **Hot path budget:** do not call anything that can block for milliseconds on the 120 Hz path (on macOS
  `AVPlayer.currentTime()` blocked ~30 ms; the Windows equivalent is any synchronous MF call or a lock shared with a decoder).

---

## 4. Preview (`SwapChainPanel`)

- Create the swap chain with `CreateSwapChainForComposition`, `B8G8R8A8_UNORM`, flip model, 2 buffers,
  `DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT`, max latency 1. Attach with `ISwapChainPanelNative.SetSwapChain`.
- Render thread loop: wait on the latency waitable object, compose, `Present(1, 0)`. Matches the display refresh (60–240 Hz).
- **Idle = 0% CPU:** when not playing and nothing animates (layout springs, keycap springs, background crossfade), the
  loop blocks on an event. Any edit or scrub signals one redraw.
- Handle `CompositionScaleChanged` and size changes by resizing buffers on the render thread (rasterization scale × size).
- 120 Hz values (playhead, magnet hover) must not flow through `INotifyPropertyChanged` bindings. Drive them with
  Composition visuals or Win2D invalidation of a small region (`spec/06` ADR on isolating the 120 Hz playhead).

---

## 5. Decode and Playback

> **Current state:** decode uses system-memory frames rather than the zero-copy path below (`spec/06` ADR-21). Export and
> recording convert on the GPU with `GpuNv12Converter` and read NV12 back. The rest of this section and §6 remain the target
> if measurements require them.

- `IMFSourceReader` with `MF_SOURCE_READER_D3D_MANAGER` (`IMFDXGIDeviceManager` on the compositor's device),
  `MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS`, `MF_SOURCE_READER_ENABLE_ADVANCED_VIDEO_PROCESSING = false`, output `NV12`.
  Samples come back as `IMFDXGIBuffer` → `ID3D11Texture2D` + subresource index. Convert to RGB on the GPU (§1 of `spec/07`).
- Read forward sequentially. Seek only at slice boundaries or user scrubs; coalesce scrub seeks (latest wins).
- Read ahead 3–6 frames per track into a ring; the render thread picks the newest frame with `pts <= clock`.
- Timeline slices with `speed != 1`: map timeline time → source time with the ported `NLETimeMapper`, and resample
  audio (WASAPI render path) with a high-quality resampler; keep pitch (time-stretch) only if macOS does.
- Webcam, microphone and system audio are separate tracks: one reader each, all driven by the same clock.

---

## 6. Export

Pipeline: decode (same reader setup, sequential) → compose into an offscreen `B8G8R8A8` texture → convert to NV12 with
`ID3D11VideoProcessor` → `IMFSinkWriter` (`MF_SINK_WRITER_D3D_MANAGER`, hardware transforms enabled) → `.mp4`.

- **Encoder:** hardware H.264 / HEVC MFT (NVENC, Quick Sync, AMF) chosen by `MFTEnumEx` with `MFT_ENUM_FLAG_HARDWARE`.
  Configure through `ICodecAPI` from `GetServiceForStream`: `CODECAPI_AVEncCommonRateControlMode = Quality` with
  `CODECAPI_AVEncCommonQuality` 87 / 72 / 58 / 42 for Studio / Social Media / Web / Web (Low) (start values; tune against
  the macOS file sizes from `HardwareVideoExporter.ExportCompression.referenceBitsPerPixel`). If the driver rejects
  Quality mode, fall back to VBR with the reference bits-per-pixel. GOP 2 s, closed. BT.709 tags (`spec/07` §1).
- **Hybrid encoding** (HW + SW lanes, `spec/06` ADR-01) is **not** a default on Windows. Build it only if a single
  hardware encoder measures below 1.5× realtime at 4K on the target machines.
- **Audio:** decode all audio tracks, mix exactly like the macOS exporter (volumes, mute ranges, voiceovers, background
  music, fades), encode AAC 48 kHz stereo through the same sink writer.
- **Back-pressure:** bounded queues between stages (max ~8 frames). Memory must stay flat for any duration.
- **Progress:** encoded frames / total frames (not submitted frames), so progress moves evenly.
- **GIF:** WIC GIF encoder, palette per frame or global (match macOS frame rates and sizes in `allowedFPSModes`,
  `allResolutionHeights`). Stream frames; never hold the whole animation in memory.
- **ProRes:** not available natively on Windows. Hide the option (or offer HEVC 10-bit as the high-quality format).
- **Cancel:** stop immediately, finalize nothing, delete the partial file.

---

## 7. Recording

Output must match the macOS package layout (`spec/02` §1) so projects open on either platform.

| Track | Windows source | Format |
| :--- | :--- | :--- |
| `display.mp4` | `Windows.Graphics.Capture` (`Direct3D11CaptureFramePool.CreateFreeThreaded`, BGRA) → `ID3D11VideoProcessor` NV12 → sink writer | H.264, bitrate `max(8 Mbps, w × h × 4)`, up to 60 fps, **fragmented MP4** (`MFTranscodeContainerType_FMPEG4`, 2 s fragments) |
| system audio | WASAPI loopback (all apps) or process loopback (per app, `AUDIOCLIENT_ACTIVATION_TYPE_PROCESS_LOOPBACK`) | AAC 48 kHz stereo 192 kbps, muxed into `display.mp4` (`tracks.systemAudio = "display.mp4"`) |
| `microphone.m4a` | WASAPI capture on the chosen device | AAC 48 kHz mono 128 kbps |
| `webcam.mp4` | `IMFSourceReader` on the camera (or `MediaCapture` frame reader) | H.264, bitrate `max(10 Mbps, w × h × 5)` |
| `telemetry/*.jsonl` | Low-level hooks (`WH_MOUSE_LL`, `WH_KEYBOARD_LL`) on a dedicated thread with a message loop, plus `GetCursorInfo` sampling | Same schemas as macOS (`spec/02` §3) |

Rules:
- **Cursor excluded from video:** `GraphicsCaptureSession.IsCursorCaptureEnabled = false`. The cursor is drawn later from telemetry.
- **Yellow capture border:** request `GraphicsCaptureAccess.RequestAccessAsync(GraphicsCaptureAccessKind.Borderless)`
  and set `IsBorderRequired = false` (Windows 11). If access is denied, keep recording with the border.
- **HUD excluded from capture:** `SetWindowDisplayAffinity(hwnd, WDA_EXCLUDEFROMCAPTURE)` on the HUD and every other app window that may overlap.
- **t = 0:** the QPC time of the first captured frame (`SystemRelativeTime`). Telemetry and audio are offset to it (`spec/03` §2.1).
- **Hook timestamps:** call `QueryPerformanceCounter` inside the hook callback; `KBDLLHOOKSTRUCT.time` is `GetTickCount`
  based and must not be used. Keep hook callbacks tiny (enqueue and return), or Windows silently removes the hook.
- **Coordinates:** process is per-monitor DPI aware v2. Normalize cursor positions by the captured monitor or window
  rect in physical pixels (top-left origin). Window capture: follow window moves/resizes and write `window.jsonl`.
- **Cursor kind:** compare `CURSORINFO.hCursor` with the system cursors (`IDC_ARROW`, `IDC_HAND`, `IDC_IBEAM`, `IDC_CROSS`,
  `IDC_SIZEALL`, ...) and write the same kind names macOS writes.
- **Pause / resume:** same pause-interval timeline as macOS (`ScreenCaptureEngine.pausedOffset(forHostPTS:)`): every
  track subtracts the accumulated paused time.
- **Crash safety:** fragmented MP4 for video tracks; audio-only tracks flush regularly. A crash loses at most ~2 s.
- **`metadata.json`:** `platform = "windows"`, `scaleFactor` = monitor DPI / 96, `refreshRate` from the display mode,
  `windowBorderRadius` 8 on Windows 11 (0 for maximized windows).

---

## 8. UI (WinUI 3)

- Match the macOS layout and behavior (`spec/04`, macOS views as reference), with Windows conventions: Mica on the
  editor window, Desktop Acrylic on HUD and popups, custom title bar with the app menu (`MenuBar`) since Windows has no
  global menu bar, keyboard accelerators with `Ctrl` instead of `Cmd`.
- Timeline: retained XAML blocks on a `Canvas`, with the playhead moved by transform (`spec/06` ADR-19). Move to Win2D
  `CanvasVirtualControl` when a stall is measured. Waveforms are per-pixel BGRA bitmaps (`spec/06` ADR-42), cached per
  slice and stretched during a zoom. A zoom step moves existing blocks instead of rebuilding them (ADR-46).
- Text: every user-visible string goes through `Loc` (`App/Localization/Loc.cs`), backed by the shared macOS catalog
  (`spec/06` ADR-44). New UI goes through the shared helpers or `Loc.T`; a Windows-only string becomes a `manual` key in
  `Localizable.xcstrings` with all 8 languages.
- Tooltips and hover magnet: Composition animations (`spec/06` ADR on retained-layer hover physics).
- Multiple projects open at once, each in its own window with its own session, undo stack and render thread.
- Light and dark themes (`RequestedTheme`), driven by settings.

---

## 9. Known Windows Pitfalls

| Pitfall | Rule |
| :--- | :--- |
| Mixed-DPI multi-monitor setups, negative coordinates | Per-monitor DPI v2; use physical pixels end to end; test on a secondary monitor left of the primary. |
| Hybrid GPU laptops | Create the D3D11 device on the adapter that drives the captured monitor; WGC frames from another adapter need a copy. |
| A handler on a `Window` event that captures the window leaks the window and everything it holds | `Window` is outside XAML reference tracking. Use a named handler and remove it in `Closed`, or a static one (`spec/06` ADR-48). Check with `NS_MEMORY_STATS`. |
| PowerShell drops a bare `--` before it reaches a `.ps1` script, which is how npm installs `claude` and `codex` | A command line shown for the user to paste quotes it (`'--'`), or `claude mcp add nativescreen -- "<exe>" --mcp` fails with `unknown option '--mcp'`. |
| Moving or fading many small labels | Set `Opacity` and `Translation` with `OpacityTransition` and `TranslationTransition`. They run on the compositor, need no layout pass, and are created only when a label first changes. |
| `MF_MT_DEFAULT_STRIDE` does not include a hardware decoder's row padding | Derive the pitch from the locked buffer's length (`spec/06` ADR-56). Test widths that are not a multiple of 16. |
| `GraphicsCaptureItem.Closed` may not fire when the captured window closes | Check `IsWindow` in the capture loop too (`spec/06` ADR-54). |
| A `TextBox` given `Text` before `AcceptsReturn` keeps only the first line | Set `AcceptsReturn` first. |
| A recorder's writer failing on an audio or timer thread ends the process | Set `WriteFailed` on the writer so it reports once and drops later samples. |
| A process started with `UseShellExecute = false` inherits the parent's std handles | A helper that starts the app (the MCP bridge) uses `ShellExecute`, or the app keeps the client's pipe open and the client hangs (`spec/06` ADR-52). |
| An object that opens a file in its constructor and then throws leaves the file open until a collection | Dispose what was opened in a `catch` before rethrowing (`AudioFileReader` on a video with no audio). |
| Adding an element that still has a parent throws 0x800F1000, "No installed components were detected" | Rebuild children instead of moving a reused element between rebuilt panels. |
| A `DispatcherQueueTimer` nothing references is collected and never fires | Keep a reference to it until it has fired. |
| A source reader seek can land well before the keyframe asked for | Never decide to seek again from the landed frame alone; compare with the last seek's target (`spec/06` ADR-34). |
| Encoder differences (NVENC / QSV / AMF) | Never assume an `ICodecAPI` property is supported; check `IsSupported` and log the fallback. |
| Sink writer silently falls back to software | Verify the active transform is hardware (`MFT_ENUM_HARDWARE_URL_Attribute`) and log it. |
| Low-level hook timeouts | Callbacks over ~1 s get the hook removed; never do I/O in the callback. |
| Source reader without a device | Software decoding, even with the hardware transforms flag. Give it `MF_SOURCE_READER_D3D_MANAGER` (`spec/06` ADR-26). |
| Per-frame arrays | 9 MB frames on the Large Object Heap miss frames, and only a 60 s run shows it. Pool them (`spec/06` ADR-26). |
| Reported times of fragmented MP4 | Media Foundation writes no `tfdt` and then misreports fragment starts by hundreds of ms. Read times from the boxes (`spec/06` ADR-22). |
| WASAPI loopback during silence | It delivers nothing, and the MP4 sink then holds video back. Write silence yourself and disable sink writer throttling (`spec/06` ADR-23). |
| Microphone capture on Boot Camp | Froze and reset one Mac three times. Not understood (`spec/06` ADR-23). |
| Casting a projected WinUI object to a `[ComImport]` interface | Always throws `InvalidCastException` (projected objects are not COM wrappers). Call `QueryInterface` on `IWinRTObject.NativeObject.ThisPtr` (`spec/06` ADR-18). |
| Caption buttons and window sizes | Set `AppWindowTitleBar` button colors from the app theme; `AppWindow` sizes are physical pixels, so scale DIPs by the window DPI (`spec/06` ADR-19). |
| `SwapChainPanel` before the first opaque present | The panel shows what is behind the window, even after presenting alpha 0. Present an opaque frame right after `SetSwapChain` (`spec/06` ADR-18). |
| `SwapChainPanel` and XAML airspace | Popups over the preview must be XAML `Popup` or separate windows, not other swap chains. |
| WASAPI device changes | Handle `IMMNotificationClient` (device removed / default changed) during recording and playback. |
| Timer resolution | Do not use `Thread.Sleep` for pacing; use waitable objects (swap chain latency, WASAPI events, `CreateWaitableTimerEx` high resolution). |
| `OpacityTransition` (or another implicit transition) on an element that has a `RenderTransform` | WinUI throws `UnauthorizedAccessException` ("Access is denied ... RenderTransform property in use") from the setter, and inside an event handler that ends the app. Offset such elements with `Translation`, which works with the transitions (`CursorThemeCards` centers its sprites this way). Likewise, rounded panels clip their children: draw an outline outside an element as a sibling, not a child with a negative margin (ADR-92). |
