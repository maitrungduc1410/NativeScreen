# macOS Platform Deep Dive: AppKit, Metal, CoreImage & VideoToolbox

This guide documents the macOS-specific implementation details, API pitfalls, and hardware benchmarks for **NativeScreen** (`NativeScreen/NativeScreen/`). Any contributor modifying the macOS engine should read these notes first to avoid regressions.

---

## 1. Video Decoding & Hardware Export (`HardwareVideoExporter.swift`)

### 1.1. Never Use `AVAssetImageGenerator` for Sequential Export
- **Pitfall:** `AVAssetImageGenerator.image(at:)` with `.requestedTimeToleranceBefore = .zero` and `.requestedTimeToleranceAfter = .zero` is stateless. On a 60fps H.264 file with a 60-frame GOP (`keyFrameInterval = 60`), requesting frame $k$ seeks back to the nearest I-frame and decodes an average of 30 frames per call, plus copies the `CVPixelBuffer` to a CPU `CGImage`. On a 22.5s 4K clip (`1,350` frames), export takes `~70 seconds` (`~50 ms/frame`).
- **Solution:** Always use `SequentialVideoFrameReader` (`AVAssetReader` + `AVAssetReaderTrackOutput`) configured with:
  ```swift
  let outputSettings: [String: Any] = [
      kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
      kCVPixelBufferMetalCompatibilityKey as String: true
  ]
  output.alwaysCopiesSampleData = false
  ```
- **Benchmark:** Decoding `1,345` frames in native `420v` bi-planar YUV takes **`1.85 seconds` (`1.3 ms/frame`)**, compared to `4.22 seconds` for `32BGRA` and `65+ seconds` for `AVAssetImageGenerator`.

### 1.2. Apple Silicon H.264 Hardware Media Engine Ceiling (~74 fps at 4K) & Hybrid Parallel Encoding
- **Pitfall:** The dedicated H.264 Hardware Media Engine on Apple Silicon has a fixed physical throughput of **~74 fps** at `3226×2160` (`18.2 seconds` for `1,350` frames), regardless of whether `expectsMediaDataInRealTime` is `true` or `false`, or whether 1, 2, or 4 hardware `VTCompressionSession` instances are created.
- **Solution:** Run a **Hardware `VTCompressionSession`** lane (`kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true`) and a **Software `VTCompressionSession`** lane (`kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: false`) at the same time on different 2-second closed GOPs (whichever lane is free takes the next GOP), re-target the software lane's average bitrate to the hardware lane's measured bitrate, and stream the re-ordered `CMSampleBuffer`s into `.mp4` while encoding via `AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: formatDesc)`. See `spec/06` ADR-01 for measurements and muxer deadlock rules.
- **Benchmark:** Total 4K/60fps H.264 export time drops from **`18.3s` to `11–14s`**.

### 1.3. Software `VTCompressionSession` 14-Frame Internal Lookahead & `@MainActor` Deadlock Prevention
- **Pitfall:** Apple's software H.264 `VTCompressionSession` buffers **14 input frames** internally before emitting the callback for the first encoded frame. If the caller throttles in-flight frames with a semaphore of size `< 14` (e.g. `DispatchSemaphore(value: 6).wait()`) on `@MainActor`, the export will **deadlock permanently** as soon as the first software GOP chunk begins (at frame `126` / `8%`), and blocking `@MainActor` will mark the app "Non-responsive".
- **Solution:**
  1. Mark `VTParallelCompressionWorker` as `nonisolated` so its internal `DispatchQueue` and `VTCompressionSession` completion callbacks never contend for `@MainActor` (especially when the Xcode project has `-default-isolation=MainActor` enabled).
  2. Set `maxInFlightFrames = 28` (well above the 14-frame lookahead threshold).
  3. Use non-blocking async backpressure (`while !activeWorker.hasCapacity { try await Task.sleep(for: .milliseconds(2)) }`) instead of `DispatchSemaphore.wait()`.

### 1.4. Avoid `kVTCompressionPropertyKey_DataRateLimits` on Hardware Constant-Quality Exports
- **Pitfall:** Setting a 1-second byte cap via `kVTCompressionPropertyKey_DataRateLimits` on the hardware H.264 encoder starves the I-frame at the start of each 2-second GOP (shrinking 4K keyframes from `~650–1,000 KB` down to `105–350 KB`), causing blurry text and dark macroblocking across the entire GOP.
- **Solution:** Use pure constant-quality mode (`kVTCompressionPropertyKey_Quality = 0.87` for `Studio`, `0.72` for `Social Media`, `0.58` for `Web`, `0.42` for `Web (Low)`) on the hardware encoder without `DataRateLimits`, and attach explicit `ITU_R_709_2` color tags (`ColorPrimaries`, `TransferFunction`, `YCbCrMatrix`).

---

## 2. Metal & CoreImage Compositor (`MetalFrameCompositor.swift`, `EffectKernels.swift`)

### 2.1. Materializing Lazy `CIImage` Graphs into VRAM `MTLTexture`s
- **Pitfall:** A `CIImage` is a lazy filter recipe. Storing `shadowBox.applyingGaussianBlur(...)` in a property and compositing it on every frame still re-runs the 4K Gaussian Blur on every frame!
- **Solution:** Use `materializeToGPUTexture(_:extent:)` to render static layers (Background, 4K Blurred Drop Shadow, and Rounded-Corner Stencil Mask) once into a private `MTLTexture` (`pixelFormat = .bgra8Unorm`, `storageMode = .private`).
- **Crucial Frame-0 Sync:** Always call `cmdBuf.waitUntilCompleted()` after `cmdBuf.commit()` inside `materializeToGPUTexture(_:extent:)`. Because `materializeToGPUTexture` only runs once when parameters change, waiting `< 0.8 ms` guarantees that Frame 0 never samples an uninitialized stencil texture on a concurrent command queue.

### 2.2. Runtime-Compiled Metal Shaders (`MTLLibrary` from Source)
- **Context:** To avoid fragile Xcode build-rule dependencies or missing `.metallib` resources when embedding shaders in `CIImageProcessorKernel`, `EffectKernels` compiles its Metal compute shaders (`magnifierLens`, `cameraMotionBlur`) once at runtime via `device.makeLibrary(source:options:)` and caches the `MTLComputePipelineState`s in a static singleton.

---

## 3. AppKit & SwiftUI Integration (`InstantTooltipView.swift`, `TimelineSegmentContextPopovers.swift`, `WallpaperCatalog.swift`)

### 3.1. `NSMenu` Coordinate Flipping & Custom View Sizing
- **Pitfall:** `NSMenu.popUp(positioning:at:in:)` positions the **top-left** of the menu at `location`. When opening a context menu above a timeline segment or button, using a hardcoded height offset causes the menu to jump or overlap the segment.
- **Solution:** Read `menu.size.height` after populating the menu items (or use `NSApp.currentEvent?.locationInWindow`) and clamp against `screen.visibleFrame` so the menu flips cleanly above/below or left/right near screen edges.

### 3.2. Eliminating QoS Priority Inversion in `WallpaperCatalog`
- **Pitfall:** Decoding system wallpaper thumbnails on a `.background` QoS queue while a `.userInitiated` / `@MainActor` caller awaits or locks shared cache state triggers an Xcode Thread Performance Checker priority inversion warning (`WallpaperCatalog.swift:185`), and passing `kCGImageSourceShouldCacheImmediately: true` on full-res images spikes memory.
- **Solution:** Preload thumbnails on a `.utility` / `.userInitiated` queue and use `CGImageSourceCreateThumbnailAtIndex` with `kCGImageSourceCreateThumbnailFromImageAlways: true` and `kCGImageSourceThumbnailMaxPixelSize` without `kCGImageSourceShouldCacheImmediately`.

### 3.3. Native `NSSavePanel` & Destructive Overwrite `NSAlert`
- **Save Panel Expansion:** Set `UserDefaults.standard.set(true, forKey: "NSNavPanelExpandedStateForSaveMode")`, `savePanel.message = "Where to save new recording export?"`, `savePanel.showsTagField = false`, and `savePanel.canCreateDirectories = true` so the user always sees the full Finder sidebar, directory contents, file extension, and `New Folder` button.
- **Overwrite Confirmation (`ExportStillFrameModalView` & `Both` Codec Export):** When checking `FileManager.default.fileExists(atPath:)` manually outside `NSSavePanel`, configure `NSAlert` with `alert.alertStyle = .critical`, `alert.icon = NSImage(named: NSImage.cautionName)` (yellow warning triangle), and `replaceButton.hasDestructiveAction = true` (red destructive button) to match macOS Finder's native overwrite dialog 1:1.
