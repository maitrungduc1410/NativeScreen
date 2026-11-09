# AGENTS.md: NativeScreen for macOS (`macos/`)

This directory contains the native macOS implementation of **NativeScreen** built with **Swift, SwiftUI, AppKit, Metal, ScreenCaptureKit, and AVFoundation**.

## 1. Build & Verification Commands

Always verify that the macOS project compiles cleanly using `xcodebuild` before concluding any code change or creating a commit:

```bash
xcodebuild -project NativeScreen.xcodeproj -scheme NativeScreen -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

## 2. Project Structure & Xcode 16+ Synchronized Root Group

- `NativeScreen.xcodeproj` uses `PBXFileSystemSynchronizedRootGroup` pointing at the `NativeScreen/` source folder.
- Any `.swift` or `.metal` file created inside `NativeScreen/` (and its subdirectories) is **automatically compiled by Xcode** without needing manual edits to `project.pbxproj`.
- Keep sources organized in logical subdirectories under `macos/NativeScreen/`:
  - `Models/`: `ProjectDocument`, `RecordingMetadata`, Telemetry `.jsonl` models, and NLE time mapping.
  - `Document/`: `ProjectSession`, Snapshot `UndoStack`, `.nativescreen` package load/save, and multi-window coordination.
  - `Recording/`: `RecordingCoordinator`, Floating HUD (`NSPanel`), `WindowPickerOverlay` (`CGWindowListCopyWindowInfo` + `AXUIElement`), `ScreenCaptureEngine` (`ScreenCaptureKit` + `AVAssetWriter`), and `TelemetryRecorder` (`CGEvent` / `NSEvent`).
  - `Engine/`: `SpringSolver` (120Hz cursor & camera physics), `AutoZoomSolver`, `MetalCompositor` (`MTKView` + Metal shaders), and `HardwareExporter` (`AVAssetReader` + `AVAssetWriter`).
  - `Views/`: Welcome window, Editor window, Inspector sidebar, Preview canvas with interactive Mask/Crop handles, and Multi-Track NLE Timeline.

## 3. macOS Specific Technical Guidelines

1. **Entitlements & Permissions:**
   - Screen Recording (`ScreenCaptureKit` / `CGWindowListCopyWindowInfo`), Microphone (`AVCaptureDevice`), and Window Resizing (`AXUIElement`) require standard macOS permissions; therefore App Sandbox (`ENABLE_APP_SANDBOX`) must be disabled (`NO`) or configured with full screen/audio access so `CGWindowListCopyWindowInfo`, `AXUIElement`, and `/System/Library/Desktop Pictures/` work seamlessly.
2. **Zero Idle CPU in `MTKView`:**
   - Always configure `MTKView` with `isPaused = true` and `enableSetNeedsDisplay = true` when video playback is not actively running. Trigger redraws via `mtkView.needsDisplay = true` when `ProjectDocument` or playhead time changes.
3. **Multi-Project Support:**
   - Users must be able to open multiple `.nativescreen` bundles simultaneously in independent Editor windows. Avoid global singletons for editor state; scope all editing, playback, and undo state to an observable `ProjectSession` per window.
4. **Keep `spec/06-ENGINEERING-DECISIONS-AND-OPTIMIZATIONS.md` Updated:**
   - Before modifying `Engine/` (`SpringTrajectorySolver`, `MetalFrameCompositor`, `HardwareVideoExporter`), `Recording/`, or complex AppKit/SwiftUI views (`InstantTooltipView`, `MultiTrackTimelineView`), read [`../spec/06-ENGINEERING-DECISIONS-AND-OPTIMIZATIONS.md`](../spec/06-ENGINEERING-DECISIONS-AND-OPTIMIZATIONS.md) and [`../spec/platforms/macos-metal-videotoolbox.md`](../spec/platforms/macos-metal-videotoolbox.md).
   - Whenever you add a new optimization, fix a performance bottleneck, or refine an algorithm/shader, **always update `../spec/06-ENGINEERING-DECISIONS-AND-OPTIMIZATIONS.md`** (in plain prose) in the same commit so the architectural knowledge base stays 100% current.
