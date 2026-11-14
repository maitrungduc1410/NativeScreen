# AGENTS.md: NativeScreen for Windows (`windows/`)

C# implementation of NativeScreen for Windows 11: WinUI 3, Direct3D 11, HLSL, Media Foundation, Windows.Graphics.Capture.
It must open, edit, play, export and record `.nativescreen` projects exactly like the macOS app (`macos/`, Swift),
which is finished and is the reference for every behavior.

## 1. Read Before Writing Code

1. [`../spec/08-WINDOWS-PORT-PLAN.md`](../spec/08-WINDOWS-PORT-PLAN.md): porting map (which Swift file becomes which C# code), conformance fixtures, phases and acceptance checks.
2. [`../spec/platforms/windows-d3d11-mediafoundation.md`](../spec/platforms/windows-d3d11-mediafoundation.md): stack, solution layout, threads and clocks, preview, decode, export, recording, UI, pitfalls.
3. [`../spec/07-RENDERING-PARITY.md`](../spec/07-RENDERING-PARITY.md): every compositor pass and CoreImage behavior expressed for HLSL / Direct2D / DirectWrite.
4. [`../spec/02-FILE-FORMAT-AND-SCHEMA.md`](../spec/02-FILE-FORMAT-AND-SCHEMA.md), [`../spec/03-CINEMATIC-ENGINE-AND-MATH.md`](../spec/03-CINEMATIC-ENGINE-AND-MATH.md), [`../spec/06-ENGINEERING-DECISIONS-AND-OPTIMIZATIONS.md`](../spec/06-ENGINEERING-DECISIONS-AND-OPTIMIZATIONS.md).
5. The Swift source of whatever you are porting. **The Swift code is the source of truth**; specs summarize it.

## 2. Two Roles

Work is split between two agents on two machines. Know which one you are.

| | **Writer** (macOS, Cursor) | **Verifier** (Windows, Claude Code) |
| :--- | :--- | :--- |
| Can run | `dotnet build` / `dotnet test` for Core and the `-windows` class libraries (`EnableWindowsTargeting`), the macOS app | Everything: WinUI app, D3D11, HLSL compiler, Media Foundation, capture, GPU timing |
| Cannot run | WinUI app, shaders, any Windows API | (nothing) |
| Job | Port features phase by phase, compile what can be compiled, hand off | Build, run, measure, fix, accept or reject the phase |

### Writer rules
1. Work on one phase (or one clearly named slice of a phase) at a time, in the order of `spec/08` §3.
2. Port from the Swift code: same names, constants and formulas. Do not redesign algorithms.
3. Before handing off, run on macOS:
   ```bash
   dotnet build windows/src/NativeScreen.Core
   dotnet test windows/tests/NativeScreen.Core.Tests
   dotnet build windows/src/NativeScreen.Rendering
   dotnet build windows/src/NativeScreen.Media
   dotnet build windows/src/NativeScreen.Intelligence
   ```
   All must succeed with zero warnings. The WinUI app and shaders are checked by the verifier.
4. When you are not certain about a Windows or Vortice API detail (signature, enum value, required attribute, threading
   requirement), write the best code you can and add a `// VERIFY: <what to check>` comment on that line. Never leave a
   guess unmarked.
5. Add tests with every port: Core logic gets conformance tests; each HLSL shader gets a compile test in
   `Rendering.Tests`; each new media path gets a smoke test in `Media.Tests`.
6. Append an entry to [`HANDOFF.md`](./HANDOFF.md) (template there): what was done, files, how to verify, open `VERIFY` items, known risks.
7. macOS code may change only for the conformance generator (phase 0). Build the macOS app after any Swift change
   (`macos/AGENTS.md` §1).

### Verifier rules
1. Pull, then run `pwsh windows/scripts/verify.ps1`. It builds the whole solution (x64, Debug and Release), runs all test
   projects, compiles every shader, and writes `windows/artifacts/verify-report.md`.
2. Fix build and test failures with the smallest correct change. Resolve every `// VERIFY:` item touched by the handoff
   and delete the marker.
3. Run the phase acceptance checks from `spec/08` §3 on real hardware, with numbers (frame timing, A/V offset, export
   speed, memory). Use `ffprobe` / `ffmpeg` only as measurement tools; the app itself never depends on them.
4. Record the result in `HANDOFF.md`: `PASS` or `FAIL`, measurements, what you changed and why.
5. When you find a Windows-specific pitfall or make a design decision, add it to `spec/06` (ADR) and, if it changes how
   things should be written, to `spec/platforms/windows-d3d11-mediafoundation.md`, so the writer does not repeat it.
6. Tick finished phases in `spec/05` Phase 5.

## 3. Commands

| Task | Command |
| :--- | :--- |
| Full verification (Windows) | `pwsh windows/scripts/verify.ps1` |
| Build solution (Windows) | `dotnet build windows/NativeScreen.Windows.slnx -c Debug -p:Platform=x64` |
| Run the app (Windows) | `dotnet run --project windows/src/NativeScreen.App -c Debug -p:Platform=x64` |
| Core tests (macOS or Windows) | `dotnet test windows/tests/NativeScreen.Core.Tests` |
| Frame fixture tests (Windows) | `dotnet test windows/tests/NativeScreen.Rendering.Tests -c Debug -p:Platform=x64`. Scores per frame go to `%TEMP%\ns-frame-report.txt`; set `NS_DUMP_FRAMES=<folder>` to write the composed PNGs. |
| Real capture test (Windows) | `NS_TEST_CAPTURE=1 NS_TEST_CAPTURE_PARTS=system dotnet test windows/tests/NativeScreen.Media.Tests -c Debug -p:Platform=x64 --filter DisplayRecording`. `NS_TEST_CAPTURE_TARGET` is `window` or `area`. Adding `mic` reset one machine; read `spec/06` ADR-23 first. |
| Performance numbers (Windows) | `NS_TEST_PERF=1 dotnet test windows/tests/NativeScreen.Rendering.Tests -c Debug -p:Platform=x64 --filter PerformanceMeasurements`. Results go to `%TEMP%\ns-perf-report.txt`. |
| App audio test (Windows) | `NS_TEST_APP_AUDIO=1 dotnet test windows/tests/NativeScreen.Media.Tests -c Debug -p:Platform=x64 --filter AppAudioCapture`. Plays a quiet tone for a few seconds. Opens no microphone. |
| Whisper test (Windows) | `NS_TEST_WHISPER=1 dotnet test windows/tests/NativeScreen.Rendering.Tests -c Debug -p:Platform=x64 --filter WhisperTranscript`. Downloads the 142 MB base model once. |
| Camera effects on real models (Windows) | `NS_TEST_CAMERA=<folder> dotnet test windows/tests/NativeScreen.Rendering.Tests -c Release -p:Platform=x64 --filter CameraEffectsRealModel`. Reads the website's camera clip, opens no camera, writes frames and `timings.txt`. Downloads the 26 MB person model once. Run the app with `NS_MODEL_CPU=1` to keep inference off the GPU. |
| Preview frame statistics (Windows) | Run the app with `NS_PREVIEW_STATS=<file>`. Present intervals are written when the editor closes. |
| Leaks after closing an editor (Windows) | Run the app with `NS_MEMORY_STATS=<file>`. 2, 6 and 15 s after each close it collects garbage and appends memory and the editor objects still alive (`none` is the goal). |
| MCP tool errors (Windows) | Run the app with `NS_MCP_TRACE=<file>`. Every tool failure other than a plain refusal is appended with its stack. Clients reach the app with `NativeScreen.App.exe --mcp` once `Settings > AI Agents` is on. |
| Timeline zoom cost (Windows) | Run the app with `NS_TIMELINE_ZOOM_STATS=<file>`. Each zoom step appends the zoom, the relayout ms and the total ms. |
| UI in another language (Windows) | Run the app with `NS_LANGUAGE=<id>` (`en`, `cs`, `de`, `es`, `fr`, `it`, `pt-BR`, `tr`, `vi`, `ru`, `ar`, `ja`, `ko`, `zh-Hans`, `zh-Hant`) for one run. |
| Separate user data (Windows) | Run the app with `NS_LOCAL_APP_DATA=<folder>` to keep settings, presets and models in `<folder>\NativeScreen Data` instead of `%LOCALAPPDATA%`. The test projects set it to a temporary folder (`spec/06` ADR-90). |
| Build the MSIX (Windows) | `powershell windows/scripts/package-msix.ps1` builds the Store package (`NS_STORE`, no updater) with the local test identity into `windows/artifacts/msix` and checks its images, native libraries and data files. Store identity and version: `-IdentityName -Publisher -PublisherDisplayName -Version` (`docs/releasing.md`). |
| Store listing (Windows) | `windows/store-listing/`: `listing.csv`, screenshots per language and logos, imported with Partner Center > Store listings > Import listings > **Upload folder**. Every image path in the CSV must start with the folder name (`store-listing/...`), or the import fails with no details (`docs/releasing.md`, Store listing). |
| Redraw the Store tiles (Windows) | `powershell windows/scripts/make-store-assets.ps1` (from the macOS app icon, into `Assets/Store`) |
| Regenerate conformance fixtures (macOS) | `"Native Screen.app/Contents/MacOS/Native Screen" --generate-conformance conformance` |

If a command changes, update this table in the same commit.

## 4. Engineering Rules

**Correctness**
- Projects must round-trip with macOS: unknown JSON fields are preserved, missing fields get the same defaults as the
  Swift `init(from:)`, enum strings are identical, coordinates stay normalized with a top-left origin.
- Output frames must match the conformance fixtures (`spec/08` §2.4). Never "improve" a look without changing macOS too.

**Performance (the app must feel native and smooth)**
- Nothing on the UI thread may block: no decoding, file I/O, GPU waits or locks shared with the render or decode threads.
- One render thread per editor window, paced by the swap chain's latency waitable object. 0% CPU when nothing changes.
- No per-frame allocations on hot paths (render loop, decode loop, audio callback, encoder loop): pool textures and
  buffers, no LINQ, no closures, no boxing, `Span<T>` / `stackalloc` for small buffers.
- Never run a large Gaussian blur per frame: bake static layers (background, shadow, rounded mask, bezel) into textures
  keyed by their inputs.
- 120 Hz values never go through XAML data binding.
- Windows App SDK stays on 1.8 (`Directory.Packages.props`): 2.x makes every window lag when dragged on Windows 10 (`spec/06` ADR-97). Check an empty WinUI window on Windows 10 before changing it.
- Bounded queues everywhere between producer and consumer; memory must stay flat for any project length.

**Code**
- C# latest, file-scoped namespaces, one public type per file, `sealed` unless designed for inheritance, nullable
  enabled with no suppressions (`!`) except at interop boundaries.
- COM / D3D / MF objects are `IDisposable`: dispose deterministically, never rely on finalizers; release on the thread
  that owns them when the API requires it.
- `async void` only for XAML event handlers. Long work uses `Task` with `CancellationToken`.
- Comments explain why, briefly. Do not name other products.

**Git**
- Conventional Commits with the `win` scope (`feat(win): ...`, `fix(win): ...`), author `Duc Trung Mai <maitrungduc1410@gmail.com>`.
- Never push; the owner reviews and pushes.
