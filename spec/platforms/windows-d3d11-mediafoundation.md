# Windows Platform Implementation Guide — WinUI 3, Direct3D 11 & Media Foundation

This guide translates the architectural decisions and performance lessons learned on macOS (`spec/06-ENGINEERING-DECISIONS-AND-OPTIMIZATIONS.md` and `spec/platforms/macos-metal-videotoolbox.md`) directly into their **Windows 11 (`WinUI 3` / `Direct3D 11` / `HLSL` / `Windows.Graphics.Capture` / `Media Foundation`)** equivalents for Phase 5 (`NativeScreenWindows/`).

---

## 1. Cross-Platform Architecture Mapping (macOS $\leftrightarrow$ Windows)

| Subsystem | macOS Implementation | Windows Implementation |
| :--- | :--- | :--- |
| **UI Framework** | `SwiftUI` + `AppKit` (`NSWindow`, `NSPanel`, `NSMenu`) | `WinUI 3` (Windows App SDK) + `AppWindow` (`OverlappedPresenter`) |
| **Window Materials** | `NSVisualEffectView` (`.popover`, `.hudWindow`, `.darkAqua`) | `MicaBackdrop` (Main Editor) & `DesktopAcrylicBackdrop` (HUD / Tooltips) |
| **Exclude HUD from Capture** | `panel.sharingType = .none` | `SetWindowDisplayAffinity(hwnd, WDA_EXCLUDEFROMCAPTURE)` |
| **Screen & Window Capture** | `ScreenCaptureKit` (`SCStream`, `SCContentFilter`) | `Windows.Graphics.Capture` (`Direct3D11CaptureFramePool`) |
| **Window Corner Radius Probe** | `CGWindowListCopyWindowInfo` + `AXUIElement` | `DwmGetWindowAttribute(hwnd, DWMWA_EXTENDED_FRAME_BOUNDS)` (`8px` Win11 standard) |
| **Input Telemetry Tap** | `CGEventTap` / `NSEvent` (`cursor.jsonl`, `clicks.jsonl`, `keys.jsonl`) | Low-level hooks `SetWindowsHookEx(WH_MOUSE_LL / WH_KEYBOARD_LL)` or `RawInput` |
| **GPU Compositor** | `Metal` (`MTLDevice`, `CIContext`, `MTLComputePipelineState`) | `Direct3D 11` + `Direct2D 1.3` (`ID3D11Device`, `ID2D1DeviceContext`, `HLSL`) |
| **Sequential Video Decoder** | `AVAssetReader` + `AVAssetReaderTrackOutput` (`420v`) | `IMFSourceReader` with `IMFDXGIDeviceManager` (`MFVideoFormat_NV12`) |
| **Hardware/Hybrid Encoder** | `VideoToolbox` (`VTCompressionSession` HW + SW) | `Media Foundation` Hardware MFT (`NVENC` / `AMF` / `QSV`) + CPU MFT/x264 |

---

## 2. Critical Lessons to Apply on Windows from Day One

### 2.1. Telemetry Clock Synchronization (`t = 0.0 ms`)
- Just like `SCStream` on macOS, `Direct3D11CaptureFramePool.FrameArrived` on Windows has a `30–150 ms` initialization delay after starting the capture session.
- **Rule:** Record the `QueryPerformanceCounter` (QPC) timestamp of the **first arrived `Direct3D11CaptureFrame`** (`SystemRelativeTime`) and use that exact timestamp as `t = 0.0 ms` for `cursor.jsonl`, `clicks.jsonl`, and `keys.jsonl`.
- Implement the exact same **Lookahead Phase-Lag Compensation** (`t + min(75ms, damping / stiffness * 1000)`) and **Active Drag Speed Multiplier (`s = 1.85`)** documented in `spec/03-CINEMATIC-ENGINE-AND-MATH.md` §1.2.

### 2.2. Sequential `IMFSourceReader` Decoding (Never Seek Per-Frame)
- When exporting a timeline, configure `IMFSourceReader` with `MF_SOURCE_READER_D3D_MANAGER` (`IMFDXGIDeviceManager`) and output subtype `MFVideoFormat_NV12`.
- Call `ReadSample(MF_SOURCE_READER_FIRST_VIDEO_STREAM, ...)` sequentially in a forward loop and wrap the returned `IMFDXGIBuffer` into an `ID3D11Texture2D` (Zero-Copy GPU texture).
- Never call `SetCurrentPosition` on every frame; only seek when jumping across a non-contiguous `ClipSlice` cut boundary.

### 2.3. Bake Static 4K Drop Shadows & Rounded Stencils into `ID3D11Texture2D`
- In Direct2D (`ID2D1Effect` Gaussian Blur / Shadow), chaining an uncached `CLSID_D2D1GaussianBlur` node at 4K resolution on every frame wastes ~6–8 ms/frame of GPU time.
- **Rule:** Render the **Background Layer**, **4K Blurred Drop Shadow**, and **Rounded-Corner Alpha Mask** into dedicated `D3D11_USAGE_DEFAULT` `ID3D11Texture2D` targets whenever `CanvasConfig` or `FrameStyleConfig` changes, and sample those pre-baked textures in the per-frame HLSL compositor pass in `< 0.05 ms`.

### 2.4. Constant-Quality I-Frame Budgeting & `ITU-R BT.709` Tags in Media Foundation
- When configuring the hardware H.264/HEVC encoder MFT (NVIDIA `NVENC`, AMD `AMF`, or Intel `QSV`) via `ICodecAPI`:
  - Prefer `CODECAPI_AVEncCommonRateControlMode = eAVEncCommonRateControlMode_Quality` (with `CODECAPI_AVEncCommonQuality` set to `87` for `Studio`, `72` for `Social Media`, `58` for `Web`, `42` for `Web (Low)`) rather than strict 1-second CBR caps so 4K keyframes receive full `600–950 KB` sharpness for small UI text.
  - Set `MF_MT_YUV_MATRIX = MFVideoTransferMatrix_BT709`, `MF_MT_TRANSFER_FUNCTION = MFVideoTransFunc_709`, and `MF_MT_VIDEO_PRIMARIES = MFVideoPrimaries_BT709` on the output `IMFMediaType`.
  - If running on a system where a single hardware MFT is bottlenecked below 100 fps at 4K, use the same **2-second closed-GOP Hybrid Parallel Encoding** architecture (`spec/06-ENGINEERING-DECISIONS-AND-OPTIMIZATIONS.md` §1) to split GOP chunks across the hardware MFT and a multi-core CPU encoder worker.

### 2.5. Retained-Layer `.hover-magnet` & Standalone Callout Tooltip Window
- In WinUI 3, do **not** bind 120Hz button hover-magnet coordinates or playhead positions to C# `INotifyPropertyChanged` properties on the main XAML tree.
- Instead, drive `.hover-magnet` button highlights using **`Windows.UI.Composition.SpriteVisual`** (`ElementCompositionPreview.GetElementVisual`) and `CompositionScopedBatch` / 120Hz spring animations on the Composition thread.
- Render floating tooltips in a borderless, click-through popup window (`WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOOLWINDOW | WS_EX_TOPMOST`) using Direct2D geometry union (`ID2D1PathGeometry::CombineWithGeometry(D2D1_COMBINE_MODE_UNION)`) and inherit `WDA_EXCLUDEFROMCAPTURE` whenever the owner window is the Recording HUD.
