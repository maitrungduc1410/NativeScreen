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
