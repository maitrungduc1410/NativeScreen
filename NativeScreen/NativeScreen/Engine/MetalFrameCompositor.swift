import Foundation
import Metal
import MetalKit
import CoreImage
import CoreImage.CIFilterBuiltins
import AVFoundation
import AppKit
import Vision

/// Shared GPU Compositor that executes the 6-Pass Cinematic Render Pipeline on a `CAMetalDrawable` (for 0% Idle CPU Preview)
/// or an offscreen `CVPixelBuffer` (for ultra-fast `VideoToolbox` hardware MP4/HEVC export).
///
/// Architecture & Performance References:
/// - `spec/03-CINEMATIC-ENGINE-AND-MATH.md` (§3 6-Pass GPU Compositor Pipeline, §4 1-Frame Shutter Motion Blur)
/// - `spec/06-ENGINEERING-DECISIONS-AND-OPTIMIZATIONS.md` (§4 Baking Static 4K GPU Stencils & Drop Shadows into VRAM `MTLTexture`s, §5 Uniform Shortest-Side Padding `padByRatio`)
/// - `spec/platforms/macos-metal-videotoolbox.md` (§2.1 `materializeToGPUTexture` and Frame-0 `waitUntilCompleted` sync)
public final class MetalFrameCompositor {
    public let device: MTLDevice
    public let commandQueue: MTLCommandQueue
    public let ciContext: CIContext

    private var cachedWallpaperURL: URL?
    private var cachedWallpaperCIImage: CIImage?
    private var cachedWallpaperDecodePixels = 0
    private var syntheticScreenTexture: CIImage?

    // Smooth GPU Background Crossfade & Texture Cache
    private struct BackgroundIdentityKey: Equatable {
        let type: BackgroundType
        let solidColor: String
        let gradient: GradientConfig
        let meshPresetId: String?
        let wallpaperRelativePath: String?
        let canvasWidth: Int
        let canvasHeight: Int
    }

    private struct BlurredBackgroundCacheKey: Equatable {
        let identity: BackgroundIdentityKey
        let blurRadiusQuantized: Int
    }

    private var currentBackgroundKey: BackgroundIdentityKey?
    private var currentUnblurredBackgroundImage: CIImage?
    private var previousUnblurredBackgroundImage: CIImage?
    private var backgroundTransitionStartUptime: TimeInterval = 0.0
    private let backgroundTransitionDurationSec: TimeInterval = 0.32

    private var lastBlurredBgCacheKey: BlurredBackgroundCacheKey?
    private var cachedBlurredBackgroundImage: CIImage?

    // Pass 2 (Masked & Cropped Screen) Cache: avoids re-running Gaussian blur masks when adjusting Padding/Shadow/Corners/Background!
    private struct MaskedScreenCacheKey: Equatable {
        let framePtr: ObjectIdentifier?
        let sourceTimeQuantized: Int
        let masks: [MaskItem]
        let cropRect01: Rect01
    }

    private var lastMaskedScreenKey: MaskedScreenCacheKey?
    private var cachedMaskedScreenImage: CIImage?

    // Pass 3 (Screen Rounded Corners & Drop Shadow Stencil) Cache: materialized into GPU `MTLTexture`s so 4K Gaussian blur & rounded-rect generators run only ONCE!
    private struct ShadowCacheKey: Equatable {
        let screenRect: CGRect
        let canvasRect: CGRect
        let scaledRadius: CGFloat
        let shadowConfig: FrameShadowConfig
    }
    private var lastShadowCacheKey: ShadowCacheKey?
    private var cachedBlurredShadowImage: CIImage?

    private struct RoundedMaskCacheKey: Equatable {
        let rect: CGRect
        let radius: CGFloat
    }
    private var lastRoundedMaskCacheKey: RoundedMaskCacheKey?
    private var cachedRoundedMaskImage: CIImage?

    private struct DeviceBezelCacheKey: Equatable {
        let screenRect: CGRect
        let canvasRect: CGRect
        let mockupConfig: DeviceMockupConfig
    }
    private var lastDeviceBezelKey: DeviceBezelCacheKey?
    private var cachedDeviceBezelImage: CIImage?

    // Pass 6 (3D Shortcut Keycap Sprite Cache): avoids re-rasterizing keycap graphics on every frame!
    private var keycapSpriteCache: [String: CIImage] = [:]

    /// Where each visible keycap group was drawn in the last composed frame, normalized `0...1` with a top-left origin.
    /// The preview uses it to place hover / click targets over keycaps it no longer draws itself.
    public private(set) var lastShortcutHitRects01: [String: CGRect] = [:]
    /// Visible caption boxes in the last frame, top-left origin. Rounded so a growing box does not update the views on every frame.
    public private(set) var lastCaptionHitRects01: [String: CGRect] = [:]

    public var isAnimatingBackgroundTransition: Bool {
        guard previousUnblurredBackgroundImage != nil else { return false }
        let elapsed = ProcessInfo.processInfo.systemUptime - backgroundTransitionStartUptime
        return elapsed >= 0.0 && elapsed < backgroundTransitionDurationSec
    }

    public init?() {
        guard let dev = MTLCreateSystemDefaultDevice(),
              let queue = dev.makeCommandQueue() else {
            return nil
        }
        self.device = dev
        self.commandQueue = queue
        self.ciContext = CIContext(mtlDevice: dev, options: [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            .workingFormat: CIFormat.BGRA8,
            .cacheIntermediates: true,
            .priorityRequestLow: false
        ])
    }

    /// Renders a complete composited frame for `sourceTimeMs` into a target `MTLTexture` (or `CVPixelBuffer`).
    public func composeFrame(
        sourceVideoFrame: CIImage?,
        sourceTimeMs: Double,
        session: ProjectSession,
        outputSize: CGSize,
        includeShortcutOverlay: Bool = false,
        webcamVideoFrame: CIImage? = nil,
        isRealtimePreview: Bool = false
    ) -> CIImage {
        let doc = session.document
        let canvasRect = CGRect(origin: .zero, size: outputSize)
        let eval = session.trajectorySolver.evaluate(atSourceMs: sourceTimeMs)
        let cursorState = eval.cursor
        let cameraState = eval.camera

        // --- PASS 1: Cached Background Layer (Mesh / Wallpaper / Gradient / Solid + Crossfade + Blur) ---
        var composite = renderBackgroundLayer(doc: doc, session: session, canvasRect: canvasRect)

        // --- PASS 2: Cached Source Screen Frame + Atomic Multi-Track Blur & Spotlight Masks ---
        let activeMasks = session.activeMasks(atSourceMs: sourceTimeMs)
        let crop01 = doc.canvas.cropRect01
        let hasAnimatedMaskKeyframes = activeMasks.contains { $0.keyframes.count > 1 }
        let maskCacheKey = MaskedScreenCacheKey(
            framePtr: sourceVideoFrame.map { ObjectIdentifier($0) },
            sourceTimeQuantized: hasAnimatedMaskKeyframes ? Int(round(sourceTimeMs / 16.0)) : 0,
            masks: activeMasks,
            cropRect01: crop01
        )

        let maskedScreen: CIImage
        if maskCacheKey == lastMaskedScreenKey, let cached = cachedMaskedScreenImage {
            maskedScreen = cached
        } else {
            let rawScreen = (sourceVideoFrame ?? fallbackSyntheticScreenImage(size: CGSize(
                width: max(640, session.metadata.captureTarget.pixelSize.width),
                height: max(400, session.metadata.captureTarget.pixelSize.height)
            )))
            let screenExtent = rawScreen.extent

            var computed = applyMultiTrackMasks(
                to: rawScreen,
                screenExtent: screenExtent,
                activeMasks: activeMasks,
                sourceTimeMs: sourceTimeMs
            )

            if crop01 != .full {
                let cropRect = CGRect(
                    x: screenExtent.minX + CGFloat(crop01.x) * screenExtent.width,
                    y: screenExtent.minY + CGFloat(1.0 - crop01.y - crop01.height) * screenExtent.height,
                    width: max(16.0, CGFloat(crop01.width) * screenExtent.width),
                    height: max(16.0, CGFloat(crop01.height) * screenExtent.height)
                )
                computed = computed
                    .cropped(to: cropRect)
                    .transformed(by: CGAffineTransform(translationX: -cropRect.minX, y: -cropRect.minY))
            }
            lastMaskedScreenKey = maskCacheKey
            cachedMaskedScreenImage = computed
            maskedScreen = computed
        }

        // --- PASS 3: Screen Rounded Corners, Device Mockup Bezel, Drop Shadow & Camera Zoom/Pan Transform ---
        // Screen and camera placement, including timeline transitions (identical in preview and export) and, in the
        // live preview only, a spring toward the new placement when a setting is edited.
        let targetStage = Self.resolvedStageLayout(
            session: session,
            sourceTimeMs: sourceTimeMs,
            canvasRect: canvasRect,
            screenSourceSize: maskedScreen.extent.size,
            zoomScale: cameraState.scale
        )
        let stage = isRealtimePreview
            ? animatedPreviewStage(target: targetStage, sourceTimeMs: sourceTimeMs, canvasSize: outputSize)
            : targetStage
        let screenFrameRect = stage.screenRect

        let scaleX = screenFrameRect.width / max(1.0, maskedScreen.extent.width)
        let scaleY = screenFrameRect.height / max(1.0, maskedScreen.extent.height)
        var scaledScreen: CIImage
        if abs(scaleX - scaleY) < 0.002 && scaleX < 0.99 {
            scaledScreen = maskedScreen.applyingFilter("CILanczosScaleTransform", parameters: [
                kCIInputScaleKey: scaleX,
                kCIInputAspectRatioKey: 1.0
            ])
        } else {
            scaledScreen = maskedScreen.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        }

        let baseRadius = doc.frameStyle.deviceMockup.enabled
            ? (doc.frameStyle.deviceMockup.deviceId?.contains("iphone") == true ? 34.0 : 14.0)
            : doc.frameStyle.borderRadius
        let scaledRadius = CGFloat(baseRadius) * (outputSize.height / 900.0)
        scaledScreen = applyRoundedCorners(
            to: scaledScreen,
            rect: CGRect(origin: .zero, size: screenFrameRect.size),
            radius: scaledRadius
        )

        var positionedScreen = scaledScreen.transformed(
            by: CGAffineTransform(translationX: screenFrameRect.minX, y: screenFrameRect.minY)
        )

        // Device Mockup Bezel
        if doc.frameStyle.deviceMockup.enabled {
            if let bezelImg = renderDeviceMockupBezel(
                screenRect: screenFrameRect,
                canvasRect: canvasRect,
                screenRadius: scaledRadius,
                mockup: doc.frameStyle.deviceMockup
            ) {
                positionedScreen = bezelImg.composited(over: positionedScreen)
            }
        } else if doc.frameStyle.inset.enabled && doc.frameStyle.inset.size > 0.1 {
            // Screen Inset Border (`Inset` toggle in Background tab)
            let insetPx = CGFloat(doc.frameStyle.inset.size) * (outputSize.height / 900.0)
            let outerInsetRect = screenFrameRect.insetBy(dx: -insetPx, dy: -insetPx)
            let c = CIColor(hexString: doc.frameStyle.inset.color)
            if let insetBox = CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
                "inputExtent": CIVector(cgRect: outerInsetRect),
                "inputRadius": scaledRadius + insetPx,
                "inputColor": CIColor(red: c.red, green: c.green, blue: c.blue, alpha: CGFloat(doc.frameStyle.inset.opacity))
            ])?.outputImage {
                positionedScreen = positionedScreen.composited(over: insetBox)
            }
        }

        // Fast GPU Rounded-Rectangle Drop Shadow (`Classic` vs `Directional` + `Distance`, `Angle`, `Blur`)
        // Crucial: Materialized once into a concrete GPU `MTLTexture`-backed `CIImage` so CoreImage NEVER re-runs
        // the 4K Gaussian blur filter graph on every single video frame!
        if doc.frameStyle.shadow.enabled && doc.frameStyle.shadow.intensity > 0.01 {
            let shadowKey = ShadowCacheKey(
                screenRect: screenFrameRect,
                canvasRect: canvasRect,
                scaledRadius: scaledRadius,
                shadowConfig: doc.frameStyle.shadow
            )
            let blurredShadow: CIImage?
            if shadowKey == lastShadowCacheKey, let cached = cachedBlurredShadowImage {
                blurredShadow = cached
            } else {
                let shadowDist = CGFloat(doc.frameStyle.shadow.distance) * (outputSize.height / 900.0)
                let shadowBlur = CGFloat(doc.frameStyle.shadow.blur) * (outputSize.height / 900.0)
                let shadowAlpha = CGFloat(doc.frameStyle.shadow.intensity)
                let angleRad = CGFloat(doc.frameStyle.shadow.angleDegrees) * .pi / 180.0
                let dx = doc.frameStyle.shadow.isDirectional ? (cos(angleRad) * shadowDist * 0.55) : 0.0
                let dy = doc.frameStyle.shadow.isDirectional ? (-sin(angleRad) * shadowDist * 0.55) : (-shadowDist * 0.20)
                let shadowRect = screenFrameRect.offsetBy(dx: dx, dy: dy)

                if let shadowBox = CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
                    "inputExtent": CIVector(cgRect: shadowRect),
                    "inputRadius": scaledRadius,
                    "inputColor": CIColor(red: 0, green: 0, blue: 0, alpha: shadowAlpha)
                ])?.outputImage {
                    let shadowRecipe = shadowBox
                        .applyingGaussianBlur(sigma: Double(max(1.0, shadowBlur * 0.45)))
                        .cropped(to: canvasRect)
                    let materialized = materializeToGPUTexture(shadowRecipe, extent: canvasRect) ?? shadowRecipe
                    lastShadowCacheKey = shadowKey
                    cachedBlurredShadowImage = materialized
                    blurredShadow = materialized
                } else {
                    blurredShadow = nil
                }
            }
            if let blurredShadow {
                positionedScreen = positionedScreen.composited(over: blurredShadow)
            }
        }

        // --- PASS 4: Cursor Sprite & Click Ripple in Screen Space ---
        let activeSlice = session.document.timeline.slices.first {
            sourceTimeMs >= $0.sourceStartMs && sourceTimeMs <= $0.sourceEndMs
        } ?? session.currentActiveSlice
        let hideCursorInSlice = activeSlice?.hideCursor ?? false
        if !hideCursorInSlice && cursorState.opacity > 0.01 {
            positionedScreen = renderCursorAndRipple(
                over: positionedScreen,
                canvasRect: canvasRect,
                screenFrameRect: screenFrameRect,
                cursorState: cursorState,
                cursorConfig: doc.cursor,
                canvasScale: outputSize.height / 900.0
            )
        }

        // Apply Virtual Camera Pan & Zoom Transform (Classic mode)
        // Note: When the user is interactively selecting or editing a Mask on the paused Preview Canvas,
        // zoom out to 1x (`zoomScale = 1.0`) so masks are drawn/adjusted on the full unzoomed source clip!
        let suppressZoomForMaskEditing = !includeShortcutOverlay
            && !session.isPlaying
            && (session.pendingAddMaskType != nil || session.selectedMaskId != nil)
        let zoomScale = suppressZoomForMaskEditing ? 1.0 : CGFloat(max(1.0, cameraState.scale))
        let hasCenterOffset = hypot(cameraState.center01.x - 0.5, cameraState.center01.y - 0.5) > 0.0005
        if !suppressZoomForMaskEditing && !cameraState.isLoupeMode && (zoomScale > 1.0005 || hasCenterOffset) {
            let focusX = screenFrameRect.minX + CGFloat(cameraState.center01.x) * screenFrameRect.width
            let focusY = screenFrameRect.minY + CGFloat(1.0 - cameraState.center01.y) * screenFrameRect.height
            let zoomInterp01 = min(1.0, max(0.0, (zoomScale - 1.0) / 0.5))
            // Zooming moves the focus from the screen's center to the canvas center (the same point unless the
            // screen is offset, e.g. in split screen or mid layout transition).
            let canvasCenterX = screenFrameRect.midX + (canvasRect.midX - screenFrameRect.midX) * zoomInterp01
            let canvasCenterY = screenFrameRect.midY + (canvasRect.midY - screenFrameRect.midY) * zoomInterp01

            var cameraTransform = CGAffineTransform.identity
            cameraTransform = cameraTransform.translatedBy(x: canvasCenterX, y: canvasCenterY)
            cameraTransform = cameraTransform.scaledBy(x: zoomScale, y: zoomScale)
            cameraTransform = cameraTransform.translatedBy(x: -focusX, y: -focusY)

            // Crop immediately to `canvasRect` (+ small margin for motion blur) so downstream filters
            // NEVER evaluate an oversized 1.8x–3.5x zoomed intermediate texture outside the visible canvas!
            let zoomedMargin = canvasRect.insetBy(dx: -24, dy: -24)
            positionedScreen = positionedScreen
                .transformed(by: cameraTransform)
                .cropped(to: zoomedMargin)
        }

        // --- PASS 5: Camera motion blur ---
        // Compare where the screen sits now and one frame earlier (16.67ms) and blur along that motion
        // (`EffectKernels.applyCameraMotionBlur`). Skipped during instant zoom snaps, at the paused end frame and in loupe mode.
        let isInInstantSnapWindow = doc.timeline.zooms.contains { z in
            !z.disabled && z.instantAnimation && sourceTimeMs >= z.sourceStartMs && sourceTimeMs <= z.sourceEndMs + 50.0
        }
        // Paused on the last frame: the camera is at rest, so no blur.
        let isPausedAtTimelineEnd = !includeShortcutOverlay
            && !session.isPlaying
            && session.hoverSkimTimelineMs == nil
            && session.playheadTimelineMs >= session.timeMapper.totalTimelineDurationMs - 16.7
        if !suppressZoomForMaskEditing
            && !isPausedAtTimelineEnd
            && !isInInstantSnapWindow
            && !cameraState.isLoupeMode
            && doc.motion.motionBlurIntensity > 0.02
            && sourceTimeMs > 8.0 {
            let prevSourceMs = max(0.0, sourceTimeMs - 16.67)
            let prevCam = session.trajectorySolver.evaluate(atSourceMs: prevSourceMs).camera
            let blurStrength = CGFloat(min(1.0, max(0.0, doc.motion.motionBlurIntensity)))

            func zoomedScreenRectInCanvas(for cam: SpringTrajectorySolver.CameraFrameState) -> CGRect {
                let s = CGFloat(max(1.0, cam.scale))
                let hasOffset = hypot(cam.center01.x - 0.5, cam.center01.y - 0.5) > 0.0005
                guard !cam.isLoupeMode && (s > 1.0005 || hasOffset) else {
                    return screenFrameRect
                }
                let fx = screenFrameRect.minX + CGFloat(cam.center01.x) * screenFrameRect.width
                let fy = screenFrameRect.minY + CGFloat(1.0 - cam.center01.y) * screenFrameRect.height
                let zInterp = min(1.0, max(0.0, (s - 1.0) / 0.5))
                let cx = screenFrameRect.midX + (canvasRect.midX - screenFrameRect.midX) * zInterp
                let cy = screenFrameRect.midY + (canvasRect.midY - screenFrameRect.midY) * zInterp

                let newMinX = (screenFrameRect.minX - fx) * s + cx
                let newMinY = (screenFrameRect.minY - fy) * s + cy
                return CGRect(
                    x: newMinX,
                    y: newMinY,
                    width: screenFrameRect.width * s,
                    height: screenFrameRect.height * s
                )
            }

            let rectNow = zoomedScreenRectInCanvas(for: cameraState)
            let rectPrev = zoomedScreenRectInCanvas(for: prevCam)

            positionedScreen = EffectKernels.applyCameraMotionBlur(
                to: positionedScreen,
                canvasRect: canvasRect,
                rectNow: rectNow,
                rectPrevious: rectPrev,
                shutter: blurStrength,
                isExportQuality: includeShortcutOverlay || !session.isPlaying
            )
        }

        composite = positionedScreen
            .cropped(to: canvasRect)
            .composited(over: composite)
            .cropped(to: canvasRect)

        // --- PASS 5B: Magnifier lens (loupe zoom) ---
        // Drawn over the whole scene (screen + background) so the lens and its shadow work over the wallpaper too.
        if !suppressZoomForMaskEditing && cameraState.loupePresence01 > 0.005 && cameraState.loupeScale > 1.002 {
            let focusX = screenFrameRect.minX + CGFloat(cameraState.center01.x) * screenFrameRect.width
            let focusY = screenFrameRect.minY + CGFloat(1.0 - cameraState.center01.y) * screenFrameRect.height
            let maxScreenDim = max(screenFrameRect.width, screenFrameRect.height)
            let loupeRadius = max(48.0, maxScreenDim * CGFloat(cameraState.loupeConfig.radius01))

            composite = EffectKernels.applyMagnifierLens(
                to: composite,
                canvasRect: canvasRect,
                centerPx: CGPoint(x: focusX, y: focusY),
                radiusPx: loupeRadius,
                zoomScale: CGFloat(cameraState.loupeScale),
                rimRatio: CGFloat(max(0.18, cameraState.loupeConfig.bevelRatio)),
                colorFringe: CGFloat(max(0.55, cameraState.loupeConfig.chromaticAberration)),
                presence: CGFloat(cameraState.loupePresence01)
            )
        }

        // --- PASS 6: 3D Keyboard Shortcut Keycaps + Camera & Captions Overlay (For Video/GIF/Still-Frame Export!) ---
        if includeShortcutOverlay {
            if session.hasRecordedCamera && stage.camera.opacity > 0.004 {
                composite = renderWebcamOverlay(
                    packageURL: session.packageURL,
                    over: composite,
                    webcamFrame: webcamVideoFrame,
                    placement: stage.camera,
                    isRealtimePreview: isRealtimePreview,
                    canvasRect: canvasRect
                )
            }

            lastCaptionHitRects01 = [:]
            if doc.captions.enabled && !doc.captions.captionBlocks.isEmpty {
                composite = renderCaptionTracks(
                    over: composite,
                    captionsConfig: doc.captions,
                    sourceTimeMs: sourceTimeMs,
                    canvasRect: canvasRect
                )
            }

            let activeShortcuts = session.activeShortcutClustersWithStyles(atSourceMs: sourceTimeMs)
            lastShortcutHitRects01 = [:]
            if activeShortcuts.isEmpty {
                isAnimatingPreviewKeycaps = false
                keycapSprings.removeAll()
            } else {
                // Live preview brightens the hovered / selected keycaps; exports never do.
                let highlighted: Set<String> = isRealtimePreview
                    ? Set([session.hoveredShortcutId, session.selectedShortcutId].compactMap { $0 })
                    : []
                composite = renderShortcutKeycapsOverlay(
                    over: composite,
                    activeItems: activeShortcuts,
                    sourceTimeMs: sourceTimeMs,
                    shortcutsSizeRatio: doc.captions.shortcutsSizeRatio,
                    canvasRect: canvasRect,
                    highlightedClusterIds: highlighted,
                    isRealtimePreview: isRealtimePreview
                )
            }
        }

        return composite
    }

    public struct SplitScreenStageGeometry: Equatable, Sendable {
        public let screenRect: CGRect
        public let cameraRect: CGRect
        public let zoomArea: CGRect
        public let hasPadding: Bool
        public let padPx: CGFloat
    }

    /// Split-Screen Stage Geometry:
    /// Computes both the Screen region (`screenRect` fitted inside `zoomArea`) and the Camera region (`cameraRect`)
    /// for `Auto` (`<= 0`), `½ | ½` (`0.5`), and `⅔ | ⅓` (`2/3`), honoring `splitFlip` and `splitEnablePadding` (`Fullscreen` vs `Padded`).
    public static func computeSplitScreenGeometry(
        canvasSize: CGSize,
        sourceScreenSize: CGSize,
        cameraConfig: CameraConfig,
        canvasPaddingRatio: Double
    ) -> SplitScreenStageGeometry {
        let hasPadding = cameraConfig.splitEnablePadding && canvasPaddingRatio > 0.001
        let clampedRatio = hasPadding ? min(0.45, max(0.0, CGFloat(canvasPaddingRatio))) : 0.0
        let shortestSide = min(canvasSize.width, canvasSize.height)
        let padPx = (shortestSide - shortestSide / (1.0 + 2.0 * clampedRatio)) * 0.5
        let area = CGRect(
            x: padPx,
            y: padPx,
            width: max(64.0, canvasSize.width - padPx * 2.0),
            height: max(64.0, canvasSize.height - padPx * 2.0)
        )

        let screenAspect = max(0.2, sourceScreenSize.width / max(1.0, sourceScreenSize.height))
        let isHorizontal = (canvasSize.width >= canvasSize.height)

        if isHorizontal {
            let availW = max(64.0, area.width - padPx)
            let cameraW: CGFloat
            if cameraConfig.splitScreenRatio01 <= 0.01 {
                // `Auto` ratio
                let naturalScreenW = min(availW * 0.68, area.height * screenAspect)
                let rawCamW = availW - naturalScreenW
                if (rawCamW / max(1.0, area.height)) > 0.40 {
                    cameraW = min(availW * 0.62, rawCamW)
                } else {
                    cameraW = min(availW * 0.50, area.height * 0.50)
                }
            } else {
                // Explicit `½ | ½` (`0.5`) or `⅔ | ⅓` (`2/3`) ratio
                let screenShare = CGFloat(max(0.25, min(0.75, cameraConfig.splitScreenRatio01)))
                let cameraShare = 1.0 - screenShare
                let rawCamW = availW * cameraShare
                if (rawCamW / max(1.0, area.height)) > 0.40 {
                    cameraW = rawCamW
                } else {
                    cameraW = min(availW * 0.50, area.height * 0.50)
                }
            }

            let zoomAreaW = max(64.0, availW - cameraW)
            let zoomArea: CGRect
            let cameraRect: CGRect
            if cameraConfig.splitFlip {
                // Flipped: Camera on Left, Screen on Right ( & 2!)
                cameraRect = CGRect(x: area.minX, y: area.minY, width: cameraW, height: area.height)
                zoomArea = CGRect(x: area.maxX - zoomAreaW, y: area.minY, width: zoomAreaW, height: area.height)
            } else {
                // Default: Screen on Left, Camera on Right ( & 4!)
                zoomArea = CGRect(x: area.minX, y: area.minY, width: zoomAreaW, height: area.height)
                cameraRect = CGRect(x: area.maxX - cameraW, y: area.minY, width: cameraW, height: area.height)
            }

            // Fit screen inside `zoomArea`
            let maxScreenH = hasPadding ? (zoomArea.height * 0.90) : zoomArea.height
            var sw = zoomArea.width
            var sh = sw / screenAspect
            if sh > maxScreenH {
                sh = maxScreenH
                sw = sh * screenAspect
            }
            let screenRect = CGRect(
                x: zoomArea.midX - sw * 0.5,
                y: zoomArea.midY - sh * 0.5,
                width: sw,
                height: sh
            )
            return SplitScreenStageGeometry(
                screenRect: screenRect,
                cameraRect: cameraRect,
                zoomArea: zoomArea,
                hasPadding: hasPadding,
                padPx: padPx
            )
        } else {
            // Vertical split for portrait canvases (e.g. 9:16)
            let availH = max(64.0, area.height - padPx)
            let screenShare: CGFloat = (cameraConfig.splitScreenRatio01 <= 0.01)
                ? 0.50
                : CGFloat(max(0.25, min(0.75, cameraConfig.splitScreenRatio01)))
            let cameraH = availH * (1.0 - screenShare)
            let zoomAreaH = max(64.0, availH - cameraH)

            let zoomArea: CGRect
            let cameraRect: CGRect
            if cameraConfig.splitFlip {
                cameraRect = CGRect(x: area.minX, y: area.minY, width: area.width, height: cameraH)
                zoomArea = CGRect(x: area.minX, y: area.maxY - zoomAreaH, width: area.width, height: zoomAreaH)
            } else {
                zoomArea = CGRect(x: area.minX, y: area.minY, width: area.width, height: zoomAreaH)
                cameraRect = CGRect(x: area.minX, y: area.maxY - cameraH, width: area.width, height: cameraH)
            }

            let maxScreenW = hasPadding ? (zoomArea.width * 0.90) : zoomArea.width
            var sh = zoomArea.height
            var sw = sh * screenAspect
            if sw > maxScreenW {
                sw = maxScreenW
                sh = sw / screenAspect
            }
            let screenRect = CGRect(
                x: zoomArea.midX - sw * 0.5,
                y: zoomArea.midY - sh * 0.5,
                width: sw,
                height: sh
            )
            return SplitScreenStageGeometry(
                screenRect: screenRect,
                cameraRect: cameraRect,
                zoomArea: zoomArea,
                hasPadding: hasPadding,
                padPx: padPx
            )
        }
    }

    public func screenFrameRectInCanvas(session: ProjectSession, canvasSize: CGSize) -> CGRect {
        let crop01 = session.document.canvas.cropRect01
        let rawSize = CGSize(
            width: max(640.0, Double(session.metadata.captureTarget.pixelSize.width) * crop01.width),
            height: max(400.0, Double(session.metadata.captureTarget.pixelSize.height) * crop01.height)
        )
        let doc = session.document
        if doc.camera.enabled && session.hasRecordedCamera && doc.camera.layoutMode == .splitScreen {
            return Self.computeSplitScreenGeometry(
                canvasSize: canvasSize,
                sourceScreenSize: rawSize,
                cameraConfig: doc.camera,
                canvasPaddingRatio: doc.canvas.paddingRatio
            ).screenRect
        }
        return Self.calculateFittedScreenRect(
            sourceSize: rawSize,
            inCanvas: CGRect(origin: .zero, size: canvasSize),
            paddingRatio: CGFloat(session.document.canvas.paddingRatio)
        )
    }

    // MARK: - Pass Helpers

    private func renderBackgroundLayer(doc: ProjectDocument, session: ProjectSession, canvasRect: CGRect) -> CIImage {
        let bg = doc.background
        let newKey = BackgroundIdentityKey(
            type: bg.type,
            solidColor: bg.solidColor,
            gradient: bg.gradient,
            meshPresetId: bg.meshPresetId,
            wallpaperRelativePath: bg.wallpaperRelativePath,
            canvasWidth: Int(canvasRect.width),
            canvasHeight: Int(canvasRect.height)
        )

        if let existingKey = currentBackgroundKey {
            if existingKey != newKey {
                previousUnblurredBackgroundImage = currentUnblurredBackgroundImage
                let rawTarget = buildRawBackgroundImage(bg: bg, session: session, canvasRect: canvasRect)
                currentUnblurredBackgroundImage = rawTarget
                currentBackgroundKey = newKey
                backgroundTransitionStartUptime = ProcessInfo.processInfo.systemUptime
                lastBlurredBgCacheKey = nil
                cachedBlurredBackgroundImage = nil
            }
        } else {
            let rawTarget = buildRawBackgroundImage(bg: bg, session: session, canvasRect: canvasRect)
            currentBackgroundKey = newKey
            currentUnblurredBackgroundImage = rawTarget
        }

        let rawTarget = currentUnblurredBackgroundImage ?? buildRawBackgroundImage(bg: bg, session: session, canvasRect: canvasRect)

        // If crossfading between two backgrounds, blend dynamically
        if let prev = previousUnblurredBackgroundImage {
            let elapsed = ProcessInfo.processInfo.systemUptime - backgroundTransitionStartUptime
            if elapsed < backgroundTransitionDurationSec {
                let t = max(0.0, min(1.0, elapsed / backgroundTransitionDurationSec))
                let eased = CGFloat(1.0 - pow(1.0 - t, 3.0))
                let fadedNew = rawTarget.applyingFilter("CIColorMatrix", parameters: [
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: eased)
                ])
                var blended = fadedNew.composited(over: prev).cropped(to: canvasRect)
                if bg.blurRadius > 0.5 {
                    blended = blended
                        .clampedToExtent()
                        .applyingGaussianBlur(sigma: bg.blurRadius * 0.4)
                        .cropped(to: canvasRect)
                }
                return blended
            } else {
                previousUnblurredBackgroundImage = nil
            }
        }

        // Fast path: return cached background (including blur) materialized into a GPU texture!
        let blurQuantized = Int(round(bg.blurRadius * 2.0))
        let blurCacheKey = BlurredBackgroundCacheKey(identity: newKey, blurRadiusQuantized: blurQuantized)
        if blurCacheKey == lastBlurredBgCacheKey, let cachedBg = cachedBlurredBackgroundImage {
            return cachedBg
        }

        var finalBg = rawTarget
        if bg.blurRadius > 0.5 {
            finalBg = finalBg
                .clampedToExtent()
                .applyingGaussianBlur(sigma: bg.blurRadius * 0.4)
                .cropped(to: canvasRect)
        }
        let materializedBg = materializeToGPUTexture(finalBg, extent: canvasRect) ?? finalBg
        lastBlurredBgCacheKey = blurCacheKey
        cachedBlurredBackgroundImage = materializedBg
        return materializedBg
    }

    /// Bakes a lazy `CIImage` filter recipe into a concrete GPU-resident `MTLTexture` so subsequent frames sample it in O(1) time (`<0.05ms`)!
    private func materializeToGPUTexture(_ image: CIImage, extent: CGRect) -> CIImage? {
        let w = Int(round(extent.width))
        let h = Int(round(extent.height))
        guard w > 4, h > 4 else { return nil }

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: w,
            height: h,
            mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite, .renderTarget]
        desc.storageMode = .private
        guard let tex = device.makeTexture(descriptor: desc),
              let cmdBuf = commandQueue.makeCommandBuffer() else {
            return nil
        }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let shifted = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        ciContext.render(
            shifted,
            to: tex,
            commandBuffer: cmdBuf,
            bounds: CGRect(x: 0, y: 0, width: w, height: h),
            colorSpace: colorSpace
        )
        cmdBuf.commit()
        // Wait for the one-time texture bake to finish on the GPU so Frame 0 never samples an uninitialized texture!
        cmdBuf.waitUntilCompleted()

        guard let baked = CIImage(mtlTexture: tex, options: [.colorSpace: colorSpace]) else {
            return nil
        }
        // `render(_:to:)` and `CIImage(mtlTexture:)` use the same row order, so the round trip keeps the image upright.
        return baked.transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
    }

    private func buildRawBackgroundImage(bg: BackgroundConfig, session: ProjectSession, canvasRect: CGRect) -> CIImage {
        switch bg.type {
        case .solid:
            let color = CIColor(hexString: bg.solidColor)
            return CIImage(color: color).cropped(to: canvasRect)

        case .gradient:
            let c0 = CIColor(hexString: bg.gradient.stops.first?.color ?? "#4776E6")
            let c1 = CIColor(hexString: bg.gradient.stops.last?.color ?? "#8E54E9")
            let filter = CIFilter(name: "CISmoothLinearGradient", parameters: [
                "inputPoint0": CIVector(x: canvasRect.width * CGFloat(bg.gradient.start01.x),
                                        y: canvasRect.height * CGFloat(1.0 - bg.gradient.start01.y)),
                "inputPoint1": CIVector(x: canvasRect.width * CGFloat(bg.gradient.end01.x),
                                        y: canvasRect.height * CGFloat(1.0 - bg.gradient.end01.y)),
                "inputColor0": c0,
                "inputColor1": c1
            ])
            return (filter?.outputImage ?? CIImage(color: c0)).cropped(to: canvasRect)

        case .mesh:
            let preset = MeshPreset.preset(withId: bg.meshPresetId)
            let c0 = CIColor(hexString: preset.colorsHex[0])
            let c1 = CIColor(hexString: preset.colorsHex[1])
            let c2 = CIColor(hexString: preset.colorsHex[2])
            let grad1 = CIFilter(name: "CISmoothLinearGradient", parameters: [
                "inputPoint0": CIVector(x: 0, y: canvasRect.height),
                "inputPoint1": CIVector(x: canvasRect.width, y: 0),
                "inputColor0": c0,
                "inputColor1": c1
            ])?.outputImage?.cropped(to: canvasRect) ?? CIImage(color: c0).cropped(to: canvasRect)

            let radial = CIFilter(name: "CIRadialGradient", parameters: [
                "inputCenter": CIVector(x: canvasRect.width * 0.78, y: canvasRect.height * 0.72),
                "inputRadius0": canvasRect.width * 0.05,
                "inputRadius1": canvasRect.width * 0.75,
                "inputColor0": c2,
                "inputColor1": CIColor(red: c2.red, green: c2.green, blue: c2.blue, alpha: 0.0)
            ])?.outputImage?.cropped(to: canvasRect)

            if let rad = radial {
                return rad.composited(over: grad1).cropped(to: canvasRect)
            }
            return grad1

        case .wallpaper, .image:
            if let relPath = bg.wallpaperRelativePath {
                let url = session.packageURL.appendingPathComponent(relPath)
                if let img = loadCachedWallpaper(url: url, targetRect: canvasRect) {
                    return img
                }
            }
            return CIImage(color: CIColor(hexString: "#1E1E2E")).cropped(to: canvasRect)
        }
    }

    private func loadCachedWallpaper(url: URL, targetRect: CGRect) -> CIImage? {
        // Decoded only as large as the canvas needs (in 512 px steps, at most 2560 px): the preview canvas is far
        // smaller than an export, and a 2560 px decode is 25 MB. A larger canvas later decodes again, larger.
        let neededPixels = Int(max(targetRect.width, targetRect.height).rounded(.up))
        let decodePixels = min(2560, max(1024, ((neededPixels + 511) / 512) * 512))
        if cachedWallpaperURL != url || cachedWallpaperCIImage == nil || decodePixels > cachedWallpaperDecodePixels {
            cachedWallpaperURL = url
            cachedWallpaperDecodePixels = decodePixels
            // Decode and downsample once into an immediately-cached `CGImage`
            // so CoreImage NEVER re-decodes multi-megabyte 6K `.heic`/`.jpg` data on every frame!
            if let cgImg = SystemWallpaperCatalog.downsampleCGImage(at: url, maxPixelSize: decodePixels) {
                cachedWallpaperCIImage = CIImage(cgImage: cgImg)
            } else {
                cachedWallpaperCIImage = CIImage(contentsOf: url)
            }
        }
        guard let raw = cachedWallpaperCIImage else { return nil }
        let scaleX = targetRect.width / max(1.0, raw.extent.width)
        let scaleY = targetRect.height / max(1.0, raw.extent.height)
        let scale = max(scaleX, scaleY)
        let scaled = raw.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let offsetX = (targetRect.width - scaled.extent.width) * 0.5
        let offsetY = (targetRect.height - scaled.extent.height) * 0.5
        return scaled
            .transformed(by: CGAffineTransform(translationX: offsetX, y: offsetY))
            .cropped(to: targetRect)
    }

    private func applyMultiTrackMasks(
        to screenImage: CIImage,
        screenExtent: CGRect,
        activeMasks: [MaskItem],
        sourceTimeMs: Double
    ) -> CIImage {
        guard !activeMasks.isEmpty else { return screenImage }
        var output = screenImage

        for mask in activeMasks {
            let r01 = mask.interpolatedRect(at: sourceTimeMs)
            let pixelRect = CGRect(
                x: screenExtent.minX + CGFloat(r01.x) * screenExtent.width,
                y: screenExtent.minY + CGFloat(1.0 - r01.y - r01.height) * screenExtent.height,
                width: max(8.0, CGFloat(r01.width) * screenExtent.width),
                height: max(8.0, CGFloat(r01.height) * screenExtent.height)
            ).intersection(screenExtent)

            guard !pixelRect.isNull && pixelRect.width > 2 && pixelRect.height > 2 else { continue }

            switch mask.type {
            case .blur:
                let filteredPatch: CIImage
                switch mask.style {
                case .pixelate:
                    let scale = max(8.0, mask.intensity * 0.85)
                    let paddedRect = pixelRect.insetBy(dx: -scale * 2.0, dy: -scale * 2.0).intersection(screenExtent)
                    filteredPatch = output
                        .cropped(to: paddedRect)
                        .clampedToExtent()
                        .applyingFilter("CIPixellate", parameters: [
                            kCIInputScaleKey: scale,
                            kCIInputCenterKey: CIVector(x: pixelRect.midX, y: pixelRect.midY)
                        ])
                        .cropped(to: pixelRect)
                case .solid:
                    filteredPatch = CIImage(color: CIColor(red: 0.08, green: 0.08, blue: 0.11, alpha: 1.0))
                        .cropped(to: pixelRect)
                default:
                    // Fast Pyramid Downsample -> Small Sigma Blur -> Upsample ONLY inside `paddedRect`!
                    // Supports ultra-strong blur up to intensity 160!
                    let sigma = max(4.0, mask.intensity * 0.92)
                    let pad = CGFloat(sigma * 2.4)
                    let paddedRect = pixelRect.insetBy(dx: -pad, dy: -pad).intersection(screenExtent)
                    let downscale: CGFloat = 0.25
                    let smallSigma = max(1.2, sigma * Double(downscale))

                    filteredPatch = output
                        .cropped(to: paddedRect)
                        .clampedToExtent()
                        .transformed(by: CGAffineTransform(scaleX: downscale, y: downscale))
                        .applyingGaussianBlur(sigma: smallSigma)
                        .transformed(by: CGAffineTransform(scaleX: 1.0 / downscale, y: 1.0 / downscale))
                        .cropped(to: pixelRect)
                }

                let maxRadius = min(pixelRect.width, pixelRect.height) * 0.5
                let scaledCornerRadius = min(maxRadius, CGFloat(mask.cornerRadius) * (screenExtent.height / 900.0))
                if scaledCornerRadius > 0.5,
                   let roundedStencil = CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
                       "inputExtent": CIVector(cgRect: pixelRect),
                       "inputRadius": scaledCornerRadius,
                       "inputColor": CIColor.white
                   ])?.outputImage {
                    let clearBG = CIImage.empty().cropped(to: pixelRect)
                    let clippedBlur = filteredPatch
                        .applyingFilter("CIBlendWithMask", parameters: [
                            kCIInputBackgroundImageKey: clearBG,
                            kCIInputMaskImageKey: roundedStencil
                        ])
                        .cropped(to: pixelRect)
                    output = clippedBlur.composited(over: output)
                } else {
                    output = filteredPatch.composited(over: output)
                }

            case .spotlight:
                // `mask.intensity` is 0..100% dimming opacity (e.g. 50% -> surroundings are 50% brightness)
                let dimStrength01 = max(0.0, min(0.95, mask.intensity / 100.0))
                let keepFactor = CGFloat(1.0 - dimStrength01)
                let dimmed = output.applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: keepFactor, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: keepFactor, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: keepFactor, w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
                ]).cropped(to: screenExtent)

                let brightRegion = output.cropped(to: pixelRect)
                let maxRadius = min(pixelRect.width, pixelRect.height) * 0.5
                let scaledCornerRadius = min(maxRadius, CGFloat(mask.cornerRadius) * (screenExtent.height / 900.0))
                if scaledCornerRadius > 0.5,
                   let roundedStencil = CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
                       "inputExtent": CIVector(cgRect: pixelRect),
                       "inputRadius": scaledCornerRadius,
                       "inputColor": CIColor.white
                   ])?.outputImage {
                    let clearBG = CIImage.empty().cropped(to: pixelRect)
                    let clippedBright = brightRegion
                        .applyingFilter("CIBlendWithMask", parameters: [
                            kCIInputBackgroundImageKey: clearBG,
                            kCIInputMaskImageKey: roundedStencil
                        ])
                        .cropped(to: pixelRect)
                    output = clippedBright.composited(over: dimmed)
                } else {
                    output = brightRegion.composited(over: dimmed)
                }
            }
        }

        return output
    }

    private static func calculateFittedScreenRect(sourceSize: CGSize, inCanvas canvas: CGRect, paddingRatio: CGFloat) -> CGRect {
        let clampedRatio = min(0.45, max(0.0, paddingRatio))
        let shortestCanvasSide = min(canvas.width, canvas.height)
        // `padByRatio(-paddingRatio01)`:
        // Uniform margin `m` on all 4 sides such that `shortestCanvasSide = innerShortest * (1 + 2 * r)`.
        let uniformMargin = (shortestCanvasSide - shortestCanvasSide / (1.0 + 2.0 * clampedRatio)) * 0.5
        let available = canvas.insetBy(dx: uniformMargin, dy: uniformMargin)

        let aspect = max(0.1, sourceSize.width / max(1.0, sourceSize.height))
        var w = available.width
        var h = w / aspect
        if h > available.height {
            h = available.height
            w = h * aspect
        }
        return CGRect(
            x: canvas.midX - w * 0.5,
            y: canvas.midY - h * 0.5,
            width: w,
            height: h
        )
    }

    private func applyRoundedCorners(to image: CIImage, rect: CGRect, radius: CGFloat) -> CIImage {
        guard radius > 0.5 else { return image }
        let maskKey = RoundedMaskCacheKey(rect: rect, radius: radius)
        let roundedMask: CIImage
        if maskKey == lastRoundedMaskCacheKey, let cached = cachedRoundedMaskImage {
            roundedMask = cached
        } else {
            guard let generated = CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
                "inputExtent": CIVector(cgRect: rect),
                "inputRadius": radius,
                "inputColor": CIColor.white
            ])?.outputImage else {
                return image
            }
            let materialized = materializeToGPUTexture(generated, extent: rect) ?? generated
            lastRoundedMaskCacheKey = maskKey
            cachedRoundedMaskImage = materialized
            roundedMask = materialized
        }
        let clearBG = CIImage.empty().cropped(to: rect)
        return image.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: clearBG,
            kCIInputMaskImageKey: roundedMask
        ]).cropped(to: rect)
    }

    private func renderCursorAndRipple(
        over image: CIImage,
        canvasRect: CGRect,
        screenFrameRect: CGRect,
        cursorState: SpringTrajectorySolver.CursorFrameState,
        cursorConfig: CursorConfig,
        canvasScale: CGFloat
    ) -> CIImage {
        var result = image
        let cx = screenFrameRect.minX + CGFloat(cursorState.position01.x) * screenFrameRect.width
        let cy = screenFrameRect.minY + CGFloat(1.0 - cursorState.position01.y) * screenFrameRect.height

        // 1. Click Effect (`Circle` vs `Ripple`)
        switch cursorConfig.clickEffect.visualStyle {
        case .none:
            break
        case .circle:
            if let progress = cursorState.activeClickProgress {
                let radius = max(4.0, 46.0 * canvasScale * CGFloat(cursorConfig.scale) * CGFloat(progress))
                let alpha = CGFloat(max(0.0, (1.0 - progress) * 0.72 * cursorState.opacity))
                if let circle = CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
                    "inputExtent": CIVector(cgRect: CGRect(x: cx - radius, y: cy - radius, width: radius * 2, height: radius * 2)),
                    "inputRadius": radius,
                    "inputColor": CIColor(red: 1.0, green: 1.0, blue: 1.0, alpha: alpha * 0.65)
                ])?.outputImage {
                    result = circle.composited(over: result)
                }
            }
        case .ripple, .pulse, .ring:
            result = EffectKernels.applyClickRipple(
                to: result,
                canvasRect: canvasRect,
                screenRect: screenFrameRect,
                waves: cursorState.clickWaves
            )
        }

        // 2. High-DPI Vector Cursor Sprite (With Set + Variant + Always-Use-Pointer support!)
        let (rawSprite, hotspot01) = CursorSpriteProvider.shared.ciCursorImage(
            themeId: cursorConfig.themeId,
            variantId: cursorConfig.variantId,
            alwaysUsePointer: cursorConfig.alwaysUsePointer,
            cursorType: cursorState.cursorType
        )
        let targetSpriteHeight = 32.0 * canvasScale * CGFloat(cursorConfig.scale)
        let spriteScale = targetSpriteHeight / max(1.0, rawSprite.extent.height)

        let hotspotX = CGFloat(hotspot01.x) * rawSprite.extent.width
        let hotspotY = CGFloat(1.0 - hotspot01.y) * rawSprite.extent.height

        var transform = CGAffineTransform.identity
        transform = transform.translatedBy(x: cx, y: cy)
        if abs(cursorState.rotationRadians) > 0.002 {
            transform = transform.rotated(by: CGFloat(cursorState.rotationRadians))
        }
        transform = transform.scaledBy(x: spriteScale, y: spriteScale)
        transform = transform.translatedBy(x: -hotspotX, y: -hotspotY)

        var transformedCursor = rawSprite.transformed(by: transform)
        if cursorState.opacity < 0.99 {
            transformedCursor = transformedCursor.applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(cursorState.opacity))
            ])
        }

        result = transformedCursor.composited(over: result)
        return result
    }

    // MARK: - Pass 6: 3D Keyboard Shortcut Keycaps Renderer (`renderShortcutKeycapsOverlay`)

    /// Computes the deterministic WYSIWYG fade-in & fade-out envelope (`opacity`, `scale`, `slideProgress`) for a shortcut cluster at `sourceTimeMs`,
    /// used by the compositor for both the live preview and exports.
    public static func shortcutTransitionEnvelope(
        for cluster: ProjectSession.ShortcutPressCluster,
        atSourceMs sourceTimeMs: Double
    ) -> (opacity: Double, scale: CGFloat, slideOffsetMultiplier: CGFloat) {
        let fadeInMs = 150.0
        let fadeOutMs = 180.0
        let elapsedIn = max(0.0, sourceTimeMs - cluster.displayStartMs)
        let remainingOut = max(0.0, cluster.displayEndMs - sourceTimeMs)

        let rawIn = min(1.0, max(0.0, elapsedIn / fadeInMs))
        let rawOut = min(1.0, max(0.0, remainingOut / fadeOutMs))
        let t = min(rawIn, rawOut)
        // Cubic smoothstep (`3t^2 - 2t^3`) for buttery-smooth fade in & out
        let smooth = t * t * (3.0 - 2.0 * t)
        let scale = CGFloat(0.95 + 0.05 * smooth)
        let slideMult = CGFloat(1.0 - smooth)
        return (opacity: smooth, scale: scale, slideOffsetMultiplier: slideMult)
    }

    private func renderShortcutKeycapsOverlay(
        over baseImage: CIImage,
        activeItems: [(cluster: ProjectSession.ShortcutPressCluster, style: ShortcutStyleConfig)],
        sourceTimeMs: Double,
        shortcutsSizeRatio: Double,
        canvasRect: CGRect,
        highlightedClusterIds: Set<String> = [],
        isRealtimePreview: Bool = false
    ) -> CIImage {
        var output = baseImage
        var keycapsAnimating = false
        defer {
            isAnimatingPreviewKeycaps = keycapsAnimating
            // Forget springs of keycaps that are no longer on screen.
            if isRealtimePreview {
                let visible = Set(activeItems.map(\.cluster.id))
                keycapSprings = keycapSprings.filter { visible.contains($0.key) }
            }
        }
        let keyHeight = max(34.0, round(canvasRect.height * CGFloat(shortcutsSizeRatio)))
        let spacing = round(keyHeight * 0.10)
        let edgeMargin = max(16.0, round(canvasRect.height * 0.05))
        let shadowPad = max(18.0, ceil(keyHeight * 0.35))

        for entry in activeItems {
            let cluster = entry.cluster
            let style = entry.style
            guard !cluster.keyCaps.isEmpty else { continue }

            let env = Self.shortcutTransitionEnvelope(for: cluster, atSourceMs: sourceTimeMs)
            guard env.opacity > 0.005 else { continue }

            let cacheKey = "\(cluster.id)_\(cluster.compactTimelineLabel)_\(Int(keyHeight))_\(style.dockPosition.rawValue)_\(style.colorMode.rawValue)_\(style.solidColorHex)_\(style.gradientStartHex)_\(style.gradientEndHex)_\(style.textColorHex)"

            let groupSprite: CIImage
            if let cached = keycapSpriteCache[cacheKey] {
                groupSprite = cached
            } else if let rendered = rasterizeShortcutClusterCIImage(
                keyCaps: cluster.keyCaps,
                style: style,
                keyHeight: keyHeight,
                spacing: spacing,
                shadowPad: shadowPad
            ) {
                if keycapSpriteCache.count > 128 {
                    keycapSpriteCache.removeAll(keepingCapacity: true)
                }
                keycapSpriteCache[cacheKey] = rendered
                groupSprite = rendered
            } else {
                continue
            }

            let contentW = groupSprite.extent.width - shadowPad * 2.0
            let contentH = groupSprite.extent.height - shadowPad * 2.0
            let slideDistance = keyHeight * 0.10 * env.slideOffsetMultiplier

            // Base position in CoreImage bottom-left coordinates (`y = 0` at bottom, `y = canvasRect.height` at top)
            var contentOriginX: CGFloat
            var contentOriginY: CGFloat

            switch style.dockPosition {
            case .bottom:
                contentOriginX = (canvasRect.width - contentW) * 0.5
                contentOriginY = edgeMargin - slideDistance
            case .top:
                contentOriginX = (canvasRect.width - contentW) * 0.5
                contentOriginY = canvasRect.height - edgeMargin - contentH + slideDistance
            case .left:
                contentOriginX = edgeMargin - slideDistance
                contentOriginY = (canvasRect.height - contentH) * 0.5
            case .right:
                contentOriginX = canvasRect.width - edgeMargin - contentW + slideDistance
                contentOriginY = (canvasRect.height - contentH) * 0.5
            }

            // Apply normalized `offsetX` and `offsetY` (note: SwiftUI `offsetY > 0` moves down, so in bottom-up CoreImage it subtracts!)
            contentOriginX += CGFloat(style.offsetX) * canvasRect.width
            contentOriginY -= CGFloat(style.offsetY) * canvasRect.height

            let spriteCenterX = groupSprite.extent.width * 0.5
            let spriteCenterY = groupSprite.extent.height * 0.5

            // Edits in the live preview (position, offsets, size) glide: the keycap center and key height spring
            // toward their new values. Playback and exports place them exactly.
            var centerX = contentOriginX + contentW * 0.5
            var centerY = contentOriginY + contentH * 0.5
            var sizeScale: CGFloat = 1.0
            if isRealtimePreview {
                let target = [Double(centerX), Double(centerY), Double(keyHeight)]
                var spring = keycapSprings[cluster.id] ?? SpringVector(target)
                if previewFrameIsEdit {
                    if spring.step(toward: target, dt: previewFrameDt) {
                        keycapsAnimating = true
                    }
                } else {
                    spring.snap(to: target)
                }
                keycapSprings[cluster.id] = spring
                centerX = CGFloat(spring.values[0])
                centerY = CGFloat(spring.values[1])
                sizeScale = CGFloat(spring.values[2]) / max(1.0, keyHeight)
            }

            let isHighlighted = highlightedClusterIds.contains(cluster.id)
            let totalScale = CGFloat(env.scale) * sizeScale * (isHighlighted ? 1.02 : 1.0)
            let transform = CGAffineTransform(translationX: centerX, y: centerY)
                .scaledBy(x: totalScale, y: totalScale)
                .translatedBy(x: -spriteCenterX, y: -spriteCenterY)

            let contentRect = CGRect(
                x: centerX - contentW * sizeScale * 0.5,
                y: centerY - contentH * sizeScale * 0.5,
                width: contentW * sizeScale,
                height: contentH * sizeScale
            )
            lastShortcutHitRects01[cluster.id] = CGRect(
                x: contentRect.minX / canvasRect.width,
                y: 1.0 - contentRect.maxY / canvasRect.height,
                width: contentRect.width / canvasRect.width,
                height: contentRect.height / canvasRect.height
            )

            var positioned = groupSprite.transformed(by: transform)
            if isHighlighted {
                positioned = positioned.applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: 0.08])
            }
            if env.opacity < 0.995 {
                positioned = positioned.applyingFilter("CIColorMatrix", parameters: [
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(env.opacity))
                ])
            }
            positioned = positioned.cropped(to: canvasRect)
            output = positioned.composited(over: output)
        }

        return output.cropped(to: canvasRect)
    }

    private func rasterizeShortcutClusterCIImage(
        keyCaps: [ProjectSession.ShortcutKeyCap],
        style: ShortcutStyleConfig,
        keyHeight: CGFloat,
        spacing: CGFloat,
        shadowPad: CGFloat
    ) -> CIImage? {
        let isVertical = style.dockPosition.isVerticalStack
        let keyWidths = keyCaps.map { round(keyHeight * CGFloat($0.widthRatio)) }

        let contentW: CGFloat
        let contentH: CGFloat
        if isVertical {
            contentW = keyWidths.max() ?? keyHeight
            contentH = CGFloat(keyCaps.count) * keyHeight + CGFloat(max(0, keyCaps.count - 1)) * spacing
        } else {
            contentW = keyWidths.reduce(0, +) + CGFloat(max(0, keyCaps.count - 1)) * spacing
            contentH = keyHeight
        }

        let bitmapW = max(4, Int(ceil(contentW + shadowPad * 2.0)))
        let bitmapH = max(4, Int(ceil(contentH + shadowPad * 2.0)))
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

        guard let ctx = CGContext(
            data: nil,
            width: bitmapW,
            height: bitmapH,
            bitsPerComponent: 8,
            bytesPerRow: bitmapW * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        // Flip CGContext so `y = 0` is at the top (matching SwiftUI top-down layout!)
        ctx.translateBy(x: 0, y: CGFloat(bitmapH))
        ctx.scaleBy(x: 1.0, y: -1.0)

        let nsGraphicsCtx = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsGraphicsCtx
        defer { NSGraphicsContext.restoreGraphicsState() }

        var cursorX = shadowPad
        var cursorY = shadowPad

        for (idx, cap) in keyCaps.enumerated() {
            let kw = keyWidths[idx]
            let kh = keyHeight
            let capX = isVertical ? (shadowPad + (contentW - kw) * 0.5) : cursorX
            let capY = isVertical ? cursorY : shadowPad
            let capRect = CGRect(x: capX, y: capY, width: kw, height: kh)

            drawSingle3DKeycap(in: ctx, rect: capRect, cap: cap, style: style)

            if isVertical {
                cursorY += kh + spacing
            } else {
                cursorX += kw + spacing
            }
        }

        guard let cgImg = ctx.makeImage() else { return nil }
        return CIImage(cgImage: cgImg)
    }

    private func drawSingle3DKeycap(
        in ctx: CGContext,
        rect: CGRect,
        cap: ProjectSession.ShortcutKeyCap,
        style: ShortcutStyleConfig
    ) {
        let kh = rect.height
        let outerRadius = kh * 0.125
        let borderThickness = max(1.2, kh * (3.0 / 256.0))
        let innerRadius = max(2.0, outerRadius - borderThickness)
        let innerPad = (kh - borderThickness * 2.0) * 0.125
        let innerRect = rect.insetBy(dx: borderThickness, dy: borderThickness)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

        let outerPath = CGPath(roundedRect: rect, cornerWidth: outerRadius, cornerHeight: outerRadius, transform: nil)
        let innerPath = CGPath(roundedRect: innerRect, cornerWidth: innerRadius, cornerHeight: innerRadius, transform: nil)

        // 1. Soft Drop Shadow + Base Dark Backing
        ctx.saveGState()
        ctx.setShadow(
            offset: CGSize(width: 0, height: kh * 0.10),
            blur: kh * 0.22,
            color: NSColor.black.withAlphaComponent(0.42).cgColor
        )
        ctx.setFillColor(NSColor(srgbRed: 0.08, green: 0.08, blue: 0.10, alpha: 1.0).cgColor)
        ctx.addPath(outerPath)
        ctx.fillPath()
        ctx.restoreGState()

        // 2. Outer 3D Bevel Border Gradient
        let bevelTop: CGColor
        let bevelBottom: CGColor
        switch style.colorMode {
        case .defaultDark:
            bevelTop = NSColor(srgbRed: 0.396, green: 0.396, blue: 0.396, alpha: 0.92).cgColor
            bevelBottom = NSColor(srgbRed: 0.098, green: 0.098, blue: 0.098, alpha: 1.0).cgColor
        case .solid, .gradient:
            bevelTop = NSColor.white.withAlphaComponent(0.38).cgColor
            bevelBottom = NSColor.black.withAlphaComponent(0.55).cgColor
        }

        if let bevelGrad = CGGradient(colorsSpace: colorSpace, colors: [bevelTop, bevelBottom] as CFArray, locations: [0.0, 1.0]) {
            ctx.saveGState()
            ctx.addPath(outerPath)
            ctx.clip()
            ctx.drawLinearGradient(
                bevelGrad,
                start: CGPoint(x: rect.midX, y: rect.minY),
                end: CGPoint(x: rect.midX, y: rect.maxY),
                options: []
            )
            ctx.restoreGState()
        }

        // 3. Inner Keycap Body Gradient (`#2B2B2B -> #191919` or Custom Solid / Gradient!)
        let bodyStart: CGColor
        let bodyEnd: CGColor
        switch style.colorMode {
        case .defaultDark:
            bodyStart = NSColor(srgbRed: 0.169, green: 0.169, blue: 0.169, alpha: 1.0).cgColor
            bodyEnd = NSColor(srgbRed: 0.098, green: 0.098, blue: 0.098, alpha: 1.0).cgColor
        case .solid:
            let c = nsColorFromHex(style.solidColorHex)
            bodyStart = c.cgColor
            bodyEnd = c.withAlphaComponent(0.76).cgColor
        case .gradient:
            bodyStart = nsColorFromHex(style.gradientStartHex).cgColor
            bodyEnd = nsColorFromHex(style.gradientEndHex).cgColor
        }

        if let bodyGrad = CGGradient(colorsSpace: colorSpace, colors: [bodyStart, bodyEnd] as CFArray, locations: [0.0, 1.0]) {
            ctx.saveGState()
            ctx.addPath(innerPath)
            ctx.clip()
            let gradStart = (style.colorMode == .gradient)
                ? CGPoint(x: innerRect.minX, y: innerRect.minY)
                : CGPoint(x: innerRect.midX, y: innerRect.minY)
            let gradEnd = (style.colorMode == .gradient)
                ? CGPoint(x: innerRect.maxX, y: innerRect.maxY)
                : CGPoint(x: innerRect.midX, y: innerRect.maxY)
            ctx.drawLinearGradient(bodyGrad, start: gradStart, end: gradEnd, options: [])
            ctx.restoreGState()
        }

        // 4. Keycap Symbol & Label Typography
        let textNSColor: NSColor = (style.colorMode == .defaultDark) ? .white : nsColorFromHex(style.textColorHex)
        let contentPad = borderThickness + innerPad
        let textBox = rect.insetBy(dx: contentPad, dy: contentPad)

        switch cap.labelPlacement {
        case .center:
            let font = NSFont.systemFont(ofSize: kh * 0.33, weight: .regular)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: textNSColor
            ]
            let nsStr = cap.label as NSString
            let sz = nsStr.size(withAttributes: attrs)
            let tx = rect.midX - sz.width * 0.5
            let ty = rect.midY - sz.height * 0.5
            nsStr.draw(at: CGPoint(x: tx, y: ty), withAttributes: attrs)

        case .bottomLeft:
            if let sym = cap.symbol, !sym.isEmpty {
                let symFont = NSFont.systemFont(ofSize: kh * 0.31, weight: .regular)
                let symAttrs: [NSAttributedString.Key: Any] = [
                    .font: symFont,
                    .foregroundColor: textNSColor
                ]
                let nsSym = sym as NSString
                nsSym.draw(at: CGPoint(x: textBox.minX, y: textBox.minY), withAttributes: symAttrs)
            }
            if !cap.label.isEmpty {
                let lblFont = NSFont.systemFont(ofSize: kh * 0.215, weight: .medium)
                let lblAttrs: [NSAttributedString.Key: Any] = [
                    .font: lblFont,
                    .foregroundColor: textNSColor.withAlphaComponent(0.96)
                ]
                let nsLbl = cap.label as NSString
                let lSz = nsLbl.size(withAttributes: lblAttrs)
                nsLbl.draw(at: CGPoint(x: textBox.minX, y: textBox.maxY - lSz.height), withAttributes: lblAttrs)
            }

        case .bottomCenter:
            if let sym = cap.symbol, !sym.isEmpty {
                let symFont = NSFont.systemFont(ofSize: kh * 0.31, weight: .regular)
                let symAttrs: [NSAttributedString.Key: Any] = [
                    .font: symFont,
                    .foregroundColor: textNSColor
                ]
                let nsSym = sym as NSString
                let sSz = nsSym.size(withAttributes: symAttrs)
                nsSym.draw(at: CGPoint(x: rect.midX - sSz.width * 0.5, y: textBox.minY), withAttributes: symAttrs)
            }
            if !cap.label.isEmpty {
                let lblFont = NSFont.systemFont(ofSize: kh * 0.215, weight: .medium)
                let lblAttrs: [NSAttributedString.Key: Any] = [
                    .font: lblFont,
                    .foregroundColor: textNSColor.withAlphaComponent(0.96)
                ]
                let nsLbl = cap.label as NSString
                let lSz = nsLbl.size(withAttributes: lblAttrs)
                nsLbl.draw(at: CGPoint(x: rect.midX - lSz.width * 0.5, y: textBox.maxY - lSz.height), withAttributes: lblAttrs)
            }
        }
    }

    private func nsColorFromHex(_ hex: String) -> NSColor {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var rgb: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&rgb)
        let r = CGFloat((rgb >> 16) & 0xFF) / 255.0
        let g = CGFloat((rgb >> 8) & 0xFF) / 255.0
        let b = CGFloat(rgb & 0xFF) / 255.0
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1.0)
    }

    private func fallbackSyntheticScreenImage(size: CGSize) -> CIImage {
        if let existing = syntheticScreenTexture, existing.extent.size == size {
            return existing
        }
        let rect = CGRect(origin: .zero, size: size)
        let base = CIImage(color: CIColor(red: 0.06, green: 0.06, blue: 0.08, alpha: 1.0)).cropped(to: rect)
        syntheticScreenTexture = base
        return base
    }

    private func renderDeviceMockupBezel(
        screenRect: CGRect,
        canvasRect: CGRect,
        screenRadius: CGFloat,
        mockup: DeviceMockupConfig
    ) -> CIImage? {
        let key = DeviceBezelCacheKey(
            screenRect: screenRect,
            canvasRect: canvasRect,
            mockupConfig: mockup
        )
        if key == lastDeviceBezelKey, let cached = cachedDeviceBezelImage {
            return cached
        }

        let isPhone = (mockup.deviceId?.contains("iphone") == true)
        let isPad = (mockup.deviceId?.contains("ipad") == true)
        let scale = canvasRect.height / 900.0
        let bezelW: CGFloat = isPhone ? (14.0 * scale) : (isPad ? (16.0 * scale) : (12.0 * scale))
        let rimW: CGFloat = max(2.2, 3.2 * scale)
        let totalPad: CGFloat = bezelW + rimW + 24.0 * scale

        let outerFrameRect = screenRect.insetBy(dx: -(bezelW + rimW), dy: -(bezelW + rimW))
        let innerBezelRect = screenRect.insetBy(dx: -bezelW, dy: -bezelW)
        let drawExtent = screenRect.insetBy(dx: -totalPad, dy: -totalPad).integral
        let bitmapW = max(8, Int(drawExtent.width))
        let bitmapH = max(8, Int(drawExtent.height))
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

        guard let ctx = CGContext(
            data: nil,
            width: bitmapW,
            height: bitmapH,
            bitsPerComponent: 8,
            bytesPerRow: bitmapW * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        // Translate so `drawExtent.origin` maps to `(0, 0)` in CoreGraphics bottom-left coordinates
        ctx.translateBy(x: -drawExtent.minX, y: -drawExtent.minY)

        let finishHex: (outer: NSColor, highlight: NSColor) = {
            switch mockup.colorVariantId {
            case "silver", "white-titanium":
                return (
                    NSColor(srgbRed: 0.82, green: 0.83, blue: 0.85, alpha: 1.0),
                    NSColor(srgbRed: 0.95, green: 0.96, blue: 0.98, alpha: 1.0)
                )
            case "natural-titanium", "starlight":
                return (
                    NSColor(srgbRed: 0.68, green: 0.66, blue: 0.62, alpha: 1.0),
                    NSColor(srgbRed: 0.84, green: 0.82, blue: 0.78, alpha: 1.0)
                )
            case "desert-titanium":
                return (
                    NSColor(srgbRed: 0.72, green: 0.63, blue: 0.56, alpha: 1.0),
                    NSColor(srgbRed: 0.88, green: 0.80, blue: 0.73, alpha: 1.0)
                )
            case "midnight":
                return (
                    NSColor(srgbRed: 0.16, green: 0.19, blue: 0.25, alpha: 1.0),
                    NSColor(srgbRed: 0.30, green: 0.35, blue: 0.44, alpha: 1.0)
                )
            default: // "space-black", "black-titanium"
                return (
                    NSColor(srgbRed: 0.20, green: 0.20, blue: 0.22, alpha: 1.0),
                    NSColor(srgbRed: 0.38, green: 0.38, blue: 0.42, alpha: 1.0)
                )
            }
        }()

        let outerRadius = screenRadius + bezelW + rimW
        let innerBezelRadius = screenRadius + bezelW

        // 1. Draw Anodized Metallic Outer Rim Ring + Inner Glass Black Bezel Ring (with screen cutout hole!)
        ctx.saveGState()
        let outerRingPath = CGMutablePath()
        outerRingPath.addRoundedRect(in: outerFrameRect, cornerWidth: outerRadius, cornerHeight: outerRadius)
        outerRingPath.addRoundedRect(in: screenRect, cornerWidth: screenRadius, cornerHeight: screenRadius)
        ctx.addPath(outerRingPath)
        ctx.clip(using: .evenOdd)

        // Metallic chassis gradient
        if let grad = CGGradient(
            colorsSpace: colorSpace,
            colors: [finishHex.highlight.cgColor, finishHex.outer.cgColor, finishHex.highlight.cgColor] as CFArray,
            locations: [0.0, 0.5, 1.0]
        ) {
            ctx.drawLinearGradient(
                grad,
                start: CGPoint(x: outerFrameRect.minX, y: outerFrameRect.maxY),
                end: CGPoint(x: outerFrameRect.maxX, y: outerFrameRect.minY),
                options: []
            )
        }

        // Inner black glass bezel ring
        let blackBezelPath = CGMutablePath()
        blackBezelPath.addRoundedRect(in: innerBezelRect, cornerWidth: innerBezelRadius, cornerHeight: innerBezelRadius)
        blackBezelPath.addRoundedRect(in: screenRect, cornerWidth: screenRadius, cornerHeight: screenRadius)
        ctx.setFillColor(NSColor(srgbRed: 0.04, green: 0.04, blue: 0.05, alpha: 1.0).cgColor)
        ctx.addPath(blackBezelPath)
        ctx.fillPath(using: .evenOdd)
        ctx.restoreGState()

        // 2. Top Notch (MacBook Pro / Air) or Dynamic Island (iPhone)
        if isPhone {
            let islandW = min(screenRect.width * 0.28, 96.0 * scale)
            let islandH = max(12.0, 22.0 * scale)
            let islandRect = CGRect(
                x: screenRect.midX - islandW * 0.5,
                y: screenRect.maxY - islandH - 10.0 * scale,
                width: islandW,
                height: islandH
            )
            let islandPath = CGPath(roundedRect: islandRect, cornerWidth: islandH * 0.5, cornerHeight: islandH * 0.5, transform: nil)
            ctx.setFillColor(NSColor(srgbRed: 0.03, green: 0.03, blue: 0.04, alpha: 1.0).cgColor)
            ctx.addPath(islandPath)
            ctx.fillPath()
        } else if !isPad {
            // MacBook camera notch at top-center + subtle bottom aluminum keyboard deck lip
            let notchW = min(screenRect.width * 0.14, 130.0 * scale)
            let notchH = max(10.0, 18.0 * scale)
            let notchRect = CGRect(
                x: screenRect.midX - notchW * 0.5,
                y: screenRect.maxY - notchH + 2.0,
                width: notchW,
                height: notchH
            )
            let notchPath = CGPath(roundedRect: notchRect, cornerWidth: 6.0 * scale, cornerHeight: 6.0 * scale, transform: nil)
            ctx.setFillColor(NSColor(srgbRed: 0.04, green: 0.04, blue: 0.05, alpha: 1.0).cgColor)
            ctx.addPath(notchPath)
            ctx.fillPath()

            // Subtle camera lens dot inside notch
            let lensR = max(2.0, 3.0 * scale)
            let lensRect = CGRect(x: screenRect.midX - lensR, y: notchRect.midY - lensR, width: lensR * 2.0, height: lensR * 2.0)
            ctx.setFillColor(NSColor(srgbRed: 0.12, green: 0.16, blue: 0.24, alpha: 1.0).cgColor)
            ctx.fillEllipse(in: lensRect)
        }

        guard let cgImg = ctx.makeImage() else { return nil }
        let ciImg = CIImage(cgImage: cgImg)
            .transformed(by: CGAffineTransform(translationX: drawExtent.minX, y: drawExtent.minY))
        let materialized = materializeToGPUTexture(ciImg, extent: drawExtent) ?? ciImg
        lastDeviceBezelKey = key
        cachedDeviceBezelImage = materialized
        return materialized
    }

    // MARK: - Stage Layout (screen + camera placement)

    /// The camera settings in effect at `sourceTimeMs` (project camera config with the active layout segment applied).
    private static func effectiveCameraConfig(
        session: ProjectSession,
        segment: CameraLayoutSegment?
    ) -> CameraConfig {
        var c = session.document.camera
        guard let seg = segment else { return c }
        switch seg.layoutType {
        case .cameraOverlay:
            c.layoutMode = .overlay
            if let pos = seg.overlayPosition01 {
                c.position01 = pos
            }
        case .splitScreen:
            c.layoutMode = .splitScreen
        case .cutoutCamera:
            c.layoutMode = .cutout
            if let x01 = seg.cutoutPositionX01 {
                c.cutoutPositionX01 = x01
            }
        case .fullscreenCamera, .screenOnly:
            break
        }
        return c
    }

    private static func stageKey(session: ProjectSession, at t: Double) -> StageLayout.Key {
        let segment = session.activeCameraLayoutSegment(atSourceMs: t)
        let isScreenOnly = segment?.layoutType == .screenOnly
        let visible = session.document.camera.enabled
            && session.hasRecordedCamera
            && !isScreenOnly
            && !session.isOriginalRecordingHiddenAndMutedByVoiceover(atSourceMs: t)
            && !session.isCameraHiddenDuringSilence(atSourceMs: t)
        return StageLayout.Key(
            config: effectiveCameraConfig(session: session, segment: segment),
            isFullscreenCamera: segment?.layoutType == .fullscreenCamera,
            isCameraVisible: visible
        )
    }

    /// Placement for one discrete set of settings (no transition).
    private static func rawStageLayout(
        key: StageLayout.Key,
        session: ProjectSession,
        canvasRect: CGRect,
        screenSourceSize: CGSize,
        zoomScale: Double
    ) -> StageLayout {
        let doc = session.document
        let cfg = key.config
        let isSplit = key.isCameraVisible && !key.isFullscreenCamera && cfg.layoutMode == .splitScreen
        let splitGeo = Self.computeSplitScreenGeometry(
            canvasSize: canvasRect.size,
            sourceScreenSize: screenSourceSize,
            cameraConfig: cfg,
            canvasPaddingRatio: doc.canvas.paddingRatio
        )
        let screenRect: CGRect = {
            if isSplit {
                return splitGeo.screenRect
            }
            let padding: CGFloat = doc.frameStyle.deviceMockup.enabled
                ? max(0.08, CGFloat(doc.canvas.paddingRatio))
                : CGFloat(doc.canvas.paddingRatio)
            return Self.calculateFittedScreenRect(sourceSize: screenSourceSize, inCanvas: canvasRect, paddingRatio: padding)
        }()

        var camera = Self.cameraPlacement(
            config: cfg,
            isFullscreenCamera: key.isFullscreenCamera,
            splitGeo: splitGeo,
            zoomScale: zoomScale,
            canvasRect: canvasRect
        )
        if !key.isCameraVisible {
            // Hidden cameras fade out while shrinking slightly toward their center.
            camera.opacity = 0.0
            camera.rect = camera.rect.insetBy(dx: camera.rect.width * 0.03, dy: camera.rect.height * 0.03)
        }
        return StageLayout(screenRect: screenRect, camera: camera)
    }

    /// How long a timeline layout change (segment boundary, silence hide, voiceover hide) takes to animate.
    private static let stageTransitionMs = 380.0

    /// Placement at `sourceTimeMs`, blending from the previous layout for `stageTransitionMs` after a change on the
    /// timeline. Depends only on the project and the time, so preview and export produce the same frames.
    static func resolvedStageLayout(
        session: ProjectSession,
        sourceTimeMs: Double,
        canvasRect: CGRect,
        screenSourceSize: CGSize,
        zoomScale: Double
    ) -> StageLayout {
        let keyNow = Self.stageKey(session: session, at: sourceTimeMs)
        let current = Self.rawStageLayout(key: keyNow, session: session, canvasRect: canvasRect, screenSourceSize: screenSourceSize, zoomScale: zoomScale)
        let windowStart = sourceTimeMs - Self.stageTransitionMs
        guard windowStart > 0 else { return current }
        let keyBefore = Self.stageKey(session: session, at: windowStart)
        guard keyBefore != keyNow else { return current }

        // Binary-search the change point inside the window (to ~1 ms).
        var lo = windowStart
        var hi = sourceTimeMs
        while hi - lo > 1.0 {
            let mid = (lo + hi) * 0.5
            if Self.stageKey(session: session, at: mid) == keyNow {
                hi = mid
            } else {
                lo = mid
            }
        }
        let previousKey = Self.stageKey(session: session, at: lo)
        let previous = Self.rawStageLayout(key: previousKey, session: session, canvasRect: canvasRect, screenSourceSize: screenSourceSize, zoomScale: zoomScale)
        let progress = StageLayout.ease(CGFloat((sourceTimeMs - hi) / Self.stageTransitionMs))
        return StageLayout.blend(previous, current, progress)
    }

    // Live preview spring state (edits glide; playback and scrubbing follow the timeline exactly).
    private var previewStageSpring: SpringVector?
    private var previewStageLastSourceMs: Double = -1.0
    private var previewStageLastUptime: TimeInterval = 0.0
    private var previewStageLastCanvas: CGSize = .zero
    public private(set) var isAnimatingPreviewLayout: Bool = false
    public private(set) var isAnimatingPreviewKeycaps: Bool = false
    private var keycapSprings: [String: SpringVector] = [:]
    /// Set by `animatedPreviewStage` for the frame being composed: `true` when the time did not move (an edit).
    private var previewFrameIsEdit = false
    private var previewFrameDt: Double = 0.0

    /// The live preview must keep redrawing (even while paused) until these settle.
    public var isAnimatingPreviewOverlays: Bool {
        isAnimatingPreviewLayout || isAnimatingPreviewKeycaps
    }

    /// Springs toward `target` only when the time is unchanged since the last preview frame, i.e. the change came from
    /// an edit. Playback, scrubbing and window resizes follow the target exactly.
    private func animatedPreviewStage(target: StageLayout, sourceTimeMs: Double, canvasSize: CGSize) -> StageLayout {
        let now = ProcessInfo.processInfo.systemUptime
        let dt = min(1.0 / 30.0, max(0.0, now - previewStageLastUptime))
        previewStageLastUptime = now
        let timeChanged = abs(sourceTimeMs - previewStageLastSourceMs) > 0.01
        previewStageLastSourceMs = sourceTimeMs
        let canvasChanged = canvasSize != previewStageLastCanvas
        previewStageLastCanvas = canvasSize

        previewFrameIsEdit = !timeChanged && !canvasChanged
        previewFrameDt = dt
        let targetValues = target.animatableValues
        if previewStageSpring == nil || timeChanged || canvasChanged {
            previewStageSpring = SpringVector(targetValues)
            isAnimatingPreviewLayout = false
            return target
        }
        isAnimatingPreviewLayout = previewStageSpring!.step(toward: targetValues, dt: dt)
        return target.applying(previewStageSpring!.values)
    }

    /// Camera rectangle, corner radius and chrome for one camera configuration.
    private static func cameraPlacement(
        config camCfg: CameraConfig,
        isFullscreenCamera: Bool,
        splitGeo: SplitScreenStageGeometry,
        zoomScale: Double,
        canvasRect: CGRect
    ) -> StageLayout.CameraPlacement {
        let zoomProgress01 = max(0.0, min(1.0, (zoomScale - 1.0) / 0.8))
        let zoomScaleMultiplier: CGFloat = camCfg.makeSmallerDuringZoom
            ? CGFloat(1.0 - (1.0 - camCfg.scaleWhenZoomed) * zoomProgress01)
            : 1.0

        let aspect = CGFloat(camCfg.aspectRatioPreset.aspectValue)
        let baseRef = min(canvasRect.width, canvasRect.height)
        let overlayHeight = max(64.0, baseRef * CGFloat(camCfg.sizeRatio) * 0.58 * zoomScaleMultiplier)
        let overlayWidth = max(64.0, overlayHeight * aspect)

        let splitZoomedSide = max(84.0, baseRef * 0.34)
        let pipWidth: CGFloat = isFullscreenCamera
            ? canvasRect.width
            : ((camCfg.layoutMode == .splitScreen)
                ? (splitGeo.cameraRect.width + (splitZoomedSide - splitGeo.cameraRect.width) * CGFloat(zoomProgress01))
                : overlayWidth)
        let pipHeight: CGFloat = isFullscreenCamera
            ? canvasRect.height
            : ((camCfg.layoutMode == .splitScreen)
                ? (splitGeo.cameraRect.height + (splitZoomedSide - splitGeo.cameraRect.height) * CGFloat(zoomProgress01))
                : overlayHeight)

        let margin: CGFloat = max(16.0, baseRef * 0.035)
        let availW = max(1.0, canvasRect.width - pipWidth - margin * 2.0)
        let availH = max(1.0, canvasRect.height - pipHeight - margin * 2.0)

        let originX: CGFloat = {
            if isFullscreenCamera {
                return 0.0
            }
            switch camCfg.layoutMode {
            case .overlay:
                return margin + CGFloat(max(0.0, min(1.0, camCfg.position01.x))) * availW
            case .cutout:
                return margin + CGFloat(max(0.0, min(1.0, camCfg.cutoutPositionX01))) * availW
            case .splitScreen:
                let baseOriginX = splitGeo.cameraRect.minX
                let zoomedOriginX = camCfg.splitFlip ? margin : (canvasRect.width - margin - pipWidth)
                return baseOriginX + (zoomedOriginX - baseOriginX) * CGFloat(zoomProgress01)
            }
        }()

        // Bottom-left CoreImage Y coordinate
        let originY: CGFloat = {
            if isFullscreenCamera {
                return 0.0
            }
            switch camCfg.layoutMode {
            case .overlay:
                return margin + CGFloat(1.0 - max(0.0, min(1.0, camCfg.position01.y))) * availH
            case .cutout:
                // Sits on the bottom edge with 4% of its height cropped off, so the cutout reads as standing in frame.
                return -pipHeight * 0.04
            case .splitScreen:
                let baseOriginY = splitGeo.cameraRect.minY
                let zoomedOriginY = margin
                return baseOriginY + (zoomedOriginY - baseOriginY) * CGFloat(zoomProgress01)
            }
        }()

        let baseRadius = min(pipWidth, pipHeight) * CGFloat(max(0.0, min(0.50, camCfg.borderRadiusRatio)))
        let cornerRadius: CGFloat = {
            if isFullscreenCamera {
                return 0.0
            }
            switch camCfg.layoutMode {
            case .cutout:
                return pipWidth * 0.36
            case .splitScreen:
                // With no padding, split screen only rounds the camera while zoomed.
                return splitGeo.hasPadding ? baseRadius : (baseRadius * CGFloat(zoomProgress01))
            case .overlay:
                return baseRadius
            }
        }()

        // Edge-to-edge camera (fullscreen, or unzoomed split screen without padding) has no border or shadow.
        let isEdgeToEdge = isFullscreenCamera
            || (camCfg.layoutMode == .splitScreen && !splitGeo.hasPadding && zoomProgress01 < 0.02)
        let isCutout = !isFullscreenCamera && camCfg.layoutMode == .cutout
        return StageLayout.CameraPlacement(
            rect: CGRect(x: originX, y: originY, width: pipWidth, height: pipHeight),
            cornerRadius: cornerRadius,
            opacity: 1.0,
            shadowOpacity: isEdgeToEdge ? 0.0 : (isCutout ? 0.35 : 0.45),
            borderOpacity: (isEdgeToEdge || isCutout) ? 0.0 : 0.14,
            isCutout: isCutout,
            config: camCfg
        )
    }

    private func renderWebcamOverlay(
        packageURL: URL,
        over background: CIImage,
        webcamFrame: CIImage?,
        placement: StageLayout.CameraPlacement,
        isRealtimePreview: Bool,
        canvasRect: CGRect
    ) -> CIImage {
        let camCfg = placement.config
        let pipRect = placement.rect
        let baseRef = min(canvasRect.width, canvasRect.height)
        let activeCustomPreset = camCfg.selectedCustomColorPresetID.flatMap { id in
            camCfg.customColorPresets.first(where: { $0.id == id })
        }
        guard let rawCI = webcamFrame.map({
            self.prepareRecordedWebcamFrame($0, packageURL: packageURL, camCfg: camCfg, customPreset: activeCustomPreset, isCutoutMode: placement.isCutout, isRealtimePreview: isRealtimePreview)
        }) ?? Self.placeholderWebcamImage(camCfg: camCfg, customPreset: activeCustomPreset, isCutoutMode: placement.isCutout) else {
            return background
        }

        // Aspect-fill crop inside `pipRect` so portrait/landscape split-screen camera frames never stretch!
        // Face tracking adds the same 1.16x punch-in the preview applies.
        let faceZoom: CGFloat = camCfg.enableFaceTracking ? 1.16 : 1.0
        let scale = max(pipRect.width / max(1.0, rawCI.extent.width), pipRect.height / max(1.0, rawCI.extent.height)) * faceZoom
        let scaledW = rawCI.extent.width * scale
        let scaledH = rawCI.extent.height * scale
        let scaled = rawCI
            .transformed(by: CGAffineTransform(translationX: -rawCI.extent.minX, y: -rawCI.extent.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(
                translationX: pipRect.minX + (pipRect.width - scaledW) * 0.5,
                y: pipRect.minY + (pipRect.height - scaledH) * 0.5
            ))
            .cropped(to: pipRect)

        var pip = scaled
        if placement.cornerRadius > 0.5,
           let mask = CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
               "inputExtent": CIVector(cgRect: pipRect),
               "inputRadius": placement.cornerRadius,
               "inputColor": CIColor.white
           ])?.outputImage?.cropped(to: pipRect),
           let masked = CIFilter(name: "CIBlendWithAlphaMask", parameters: [
               kCIInputImageKey: scaled,
               kCIInputBackgroundImageKey: CIImage.empty(),
               kCIInputMaskImageKey: mask
           ])?.outputImage?.cropped(to: pipRect) {
            pip = masked
        }

        var layer = CIImage.empty()
        if placement.shadowOpacity > 0.004 {
            // Soft drop shadow following the camera's alpha (the person's silhouette in cutout mode).
            let shadow = pip
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: placement.shadowOpacity)
                ])
                .applyingGaussianBlur(sigma: Double(baseRef * 0.011))
                .transformed(by: CGAffineTransform(translationX: 0, y: -baseRef * 0.008))
            layer = shadow
        }
        layer = pip.composited(over: layer)
        if placement.borderOpacity > 0.004,
           let border = CIFilter(name: "CIRoundedRectangleStrokeGenerator", parameters: [
               "inputExtent": CIVector(cgRect: pipRect.insetBy(dx: 0.5, dy: 0.5)),
               "inputRadius": max(0.0, placement.cornerRadius - 0.5),
               "inputColor": CIColor(red: 1, green: 1, blue: 1, alpha: placement.borderOpacity),
               "inputWidth": max(1.0, baseRef * 0.0014)
           ])?.outputImage {
            layer = border.cropped(to: pipRect).composited(over: layer)
        }
        if placement.opacity < 0.996 {
            layer = layer.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: placement.opacity, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: placement.opacity, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: placement.opacity, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: placement.opacity)
            ])
        }
        return layer.composited(over: background).cropped(to: canvasRect)
    }

    /// One segmentation request reused across exported frames (keeps the Vision model and its temporal state warm).
    private lazy var webcamSegmentationRequest: VNGeneratePersonSegmentationRequest = {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        return request
    }()

    /// Person segmentation for the live preview: runs off the main thread and applies the newest finished mask, so a
    /// 120Hz preview never waits on Vision. Exports segment every frame synchronously instead (exact mask per frame).
    public let realtimePersonSegmenter = AsyncPersonSegmenter()

    private func prepareRecordedWebcamFrame(
        _ frame: CIImage,
        packageURL: URL,
        camCfg: CameraConfig,
        customPreset: CustomCameraColorPreset?,
        isCutoutMode: Bool,
        isRealtimePreview: Bool
    ) -> CIImage {
        let frameIdentity = ObjectIdentifier(frame)
        var img = frame.transformed(by: CGAffineTransform(translationX: -frame.extent.minX, y: -frame.extent.minY))
        let ext = img.extent
        let crop = camCfg.cropRect01
        if crop != .full {
            // `Rect01` is top-left based; CoreImage is bottom-left based.
            let cropRect = CGRect(
                x: CGFloat(crop.x) * ext.width,
                y: CGFloat(1.0 - crop.y - crop.height) * ext.height,
                width: max(16.0, CGFloat(max(0.25, crop.width)) * ext.width),
                height: max(16.0, CGFloat(max(0.25, crop.height)) * ext.height)
            ).intersection(ext)
            img = img.cropped(to: cropRect)
                .transformed(by: CGAffineTransform(translationX: -cropRect.minX, y: -cropRect.minY))
        }
        // Matches the preview's `scaleEffect(x: mirror ? 1 : -1)`: the raw camera frame is flipped unless `mirror` is on.
        if !camCfg.mirror {
            img = img.transformed(by: CGAffineTransform(scaleX: -1.0, y: 1.0).translatedBy(x: -img.extent.width, y: 0.0))
        }
        if isCutoutMode && isRealtimePreview {
            if let mask = realtimePersonSegmenter.latestMask(segmenting: img, frameIdentity: frameIdentity) {
                img = LocalOnDeviceMediaIntelligence.applyPersonCutout(
                    to: img,
                    mask: mask,
                    edgeSoftness: camCfg.cutoutEdgeSoftness,
                    edgeInset: camCfg.cutoutEdgeInset
                )
            }
        } else if isCutoutMode {
            img = LocalOnDeviceMediaIntelligence.applyOnDevicePersonCutout(
                to: img,
                edgeSoftness: camCfg.cutoutEdgeSoftness,
                edgeInset: camCfg.cutoutEdgeInset,
                reusing: webcamSegmentationRequest
            )
        }
        return LocalOnDeviceMediaIntelligence.applyCameraGradeAndSharpen(
            to: img,
            preset: customPreset == nil ? camCfg.colorGradePreset : .original,
            customPreset: customPreset,
            customLUT: camCfg.customLUTRelativePath.flatMap { CubeLUTCache.table(at: packageURL.appendingPathComponent($0)) },
            intensity: camCfg.colorGradeIntensity,
            sharpen01: camCfg.sharpen01
        )
    }

    /// Still placeholder used only when no `webcam.mp4` frame could be decoded (missing or unreadable file).
    private static func placeholderWebcamImage(
        camCfg: CameraConfig,
        customPreset: CustomCameraColorPreset?,
        isCutoutMode: Bool
    ) -> CIImage? {
        let gradedNSImg = customPreset.map {
            GradedWebcamPortraitView.cachedGradedCustomPresetImage(
                customPreset: $0,
                intensity: camCfg.colorGradeIntensity,
                sharpen01: camCfg.sharpen01,
                isCutoutMode: isCutoutMode
            )
        } ?? GradedWebcamPortraitView.cachedGradedPortraitImage(
            preset: camCfg.colorGradePreset,
            intensity: camCfg.colorGradeIntensity,
            sharpen01: camCfg.sharpen01,
            isCutoutMode: isCutoutMode
        )
        guard let cg = gradedNSImg.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return CIImage(cgImage: cg)
    }

    private struct CaptionWordCacheKey: Hashable {
        let text: String
        let fontSize: CGFloat
        let fontStyle: CaptionFontStyle
        let colorTheme: CaptionColorTheme
    }
    private var captionWordCache: [CaptionWordCacheKey: CIImage] = [:]

    /// Draws each caption track from `CaptionLineLayout`. Boxes come from CoreImage generators, so a box that is resizing
    /// costs nothing to redraw, and each word is rasterized once and then moved and faded as an image.
    private func renderCaptionTracks(
        over background: CIImage,
        captionsConfig: CaptionsConfig,
        sourceTimeMs: Double,
        canvasRect: CGRect
    ) -> CIImage {
        let frames = CaptionLineLayout.frames(in: captionsConfig, at: sourceTimeMs, stageSize: canvasRect.size)
        var composite = background

        for frame in frames {
            let isDark = frame.style.colorTheme == .dark
            let blurScale = min(canvasRect.width, canvasRect.height) / 1080.0

            func toCanvas(_ rect: CGRect) -> CGRect {
                CGRect(
                    x: canvasRect.minX + rect.minX,
                    y: canvasRect.minY + canvasRect.height - rect.maxY,
                    width: rect.width,
                    height: rect.height
                )
            }
            func fadeBlurred(_ image: CIImage, opacity: Double) -> CIImage {
                guard opacity < 0.99 else { return image }
                return image.applyingGaussianBlur(sigma: (1.0 - opacity) * Self.captionFadeBlurRadius * Double(blurScale))
            }

            if frame.boxOpacity > 0.5 {
                func rounded(_ value: CGFloat) -> CGFloat { (value * 200.0).rounded() / 200.0 }
                lastCaptionHitRects01[frame.blockId] = CGRect(
                    x: rounded(frame.boxRect.minX / canvasRect.width),
                    y: rounded(frame.boxRect.minY / canvasRect.height),
                    width: rounded(frame.boxRect.width / canvasRect.width),
                    height: rounded(frame.boxRect.height / canvasRect.height)
                )
            }

            let boxRect = toCanvas(frame.boxRect)
            let radius = frame.fontSize * 0.3

            if frame.boxOpacity > 0.002 {
                let fill = CIFilter.roundedRectangleGenerator()
                fill.extent = boxRect
                fill.radius = Float(radius)
                fill.color = CIColor(
                    red: isDark ? 0.0 : 1.0,
                    green: isDark ? 0.0 : 1.0,
                    blue: isDark ? 0.0 : 1.0,
                    alpha: (isDark ? 0.82 : 0.92) * frame.boxOpacity
                )
                let outline = CIFilter.roundedRectangleStrokeGenerator()
                outline.extent = boxRect
                outline.radius = Float(radius)
                outline.width = Float(max(1.0, frame.fontSize * 0.025))
                outline.color = CIColor(
                    red: isDark ? 1.0 : 0.0,
                    green: isDark ? 1.0 : 0.0,
                    blue: isDark ? 1.0 : 0.0,
                    alpha: 0.12 * frame.boxOpacity
                )
                if let fillImage = fill.outputImage, let outlineImage = outline.outputImage {
                    let box = fadeBlurred(outlineImage.composited(over: fillImage), opacity: frame.boxOpacity)
                    composite = box.composited(over: composite)
                }
            }

            // Pushed words must not show outside the box.
            let clipsToBox = frame.style.wordsReveal == .wordByWord
            for word in frame.words {
                guard let image = captionWordImage(
                    text: word.text,
                    fontSize: frame.fontSize,
                    fontStyle: frame.style.fontStyle,
                    colorTheme: frame.style.colorTheme
                ) else { continue }

                let target = toCanvas(word.rect)
                var placed = image.transformed(by: CGAffineTransform(translationX: target.minX, y: target.minY))
                if word.opacity < 0.999 {
                    placed = placed.applyingFilter("CIColorMatrix", parameters: [
                        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(word.opacity))
                    ])
                    if !word.isDimmedAtRest {
                        placed = fadeBlurred(placed, opacity: word.opacity)
                    }
                }
                if clipsToBox {
                    placed = placed.cropped(to: boxRect)
                }
                composite = placed.composited(over: composite)
            }
        }
        return composite.cropped(to: canvasRect)
    }

    private static let captionFadeBlurRadius = 5.0

    private func captionWordImage(
        text: String,
        fontSize: CGFloat,
        fontStyle: CaptionFontStyle,
        colorTheme: CaptionColorTheme
    ) -> CIImage? {
        let key = CaptionWordCacheKey(text: text, fontSize: fontSize, fontStyle: fontStyle, colorTheme: colorTheme)
        if let hit = captionWordCache[key] {
            return hit
        }
        let attributed = NSAttributedString(string: text, attributes: [
            .font: CaptionLineLayout.font(style: fontStyle, size: fontSize),
            .foregroundColor: colorTheme == .dark ? NSColor.white : NSColor.black
        ])
        let size = attributed.size()
        let width = max(1, Int(ceil(size.width)))
        let height = max(1, Int(ceil(size.height)))
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        attributed.draw(at: .zero)
        NSGraphicsContext.restoreGraphicsState()

        guard let cg = ctx.makeImage() else { return nil }
        let image = CIImage(cgImage: cg)
        if captionWordCache.count > 512 {
            captionWordCache.removeAll()
        }
        captionWordCache[key] = image
        return image
    }
}

// MARK: - Hex Color Helper

extension CIColor {
    convenience init(hexString: String) {
        let cleaned = hexString.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var rgb: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&rgb)
        let r, g, b, a: CGFloat
        switch cleaned.count {
        case 6:
            r = CGFloat((rgb >> 16) & 0xFF) / 255.0
            g = CGFloat((rgb >> 8) & 0xFF) / 255.0
            b = CGFloat(rgb & 0xFF) / 255.0
            a = 1.0
        case 8:
            r = CGFloat((rgb >> 24) & 0xFF) / 255.0
            g = CGFloat((rgb >> 16) & 0xFF) / 255.0
            b = CGFloat((rgb >> 8) & 0xFF) / 255.0
            a = CGFloat(rgb & 0xFF) / 255.0
        default:
            r = 0.28; g = 0.46; b = 0.90; a = 1.0
        }
        self.init(red: r, green: g, blue: b, alpha: a)
    }
}

// MARK: - Async Person Segmentation (live preview)

/// Segments at most one webcam frame at a time on a background queue and hands out the newest finished mask.
/// The mask is copied out of Vision's reusable buffer, so it stays valid while the next frame is being segmented.
public nonisolated final class AsyncPersonSegmenter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.nativescreen.preview.segmentation", qos: .userInitiated)
    private let lock = NSLock()
    private var mask: CIImage?
    private var isBusy = false
    private var lastSubmittedFrame: ObjectIdentifier?
    private let context = CIContext(options: [.useSoftwareRenderer: false])
    private lazy var request: VNGeneratePersonSegmentationRequest = {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        return request
    }()

    /// Called on the main queue when a new mask is ready (the paused preview redraws on demand only).
    public var onMaskUpdated: (@MainActor () -> Void)?

    /// Returns the newest mask (possibly one frame old) and starts segmenting `image` if idle and it is a new frame.
    func latestMask(segmenting image: CIImage, frameIdentity: ObjectIdentifier) -> CIImage? {
        lock.lock()
        let current = mask
        let shouldSubmit = !isBusy && lastSubmittedFrame != frameIdentity
        if shouldSubmit {
            isBusy = true
            lastSubmittedFrame = frameIdentity
        }
        lock.unlock()

        if shouldSubmit {
            nonisolated(unsafe) let frame = image
            queue.async { [weak self] in
                guard let self else { return }
                var copied: CIImage?
                if let raw = LocalOnDeviceMediaIntelligence.personSegmentationMask(for: frame, reusing: self.request),
                   let cg = self.context.createCGImage(raw, from: raw.extent) {
                    copied = CIImage(cgImage: cg)
                }
                self.lock.lock()
                if let copied {
                    self.mask = copied
                }
                self.isBusy = false
                self.lock.unlock()
                if copied != nil, let callback = self.onMaskUpdated {
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { callback() }
                    }
                }
            }
        }
        return current
    }
}

