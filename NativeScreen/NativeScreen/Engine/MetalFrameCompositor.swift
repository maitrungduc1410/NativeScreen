import Foundation
import Metal
import MetalKit
import CoreImage
import AVFoundation
import AppKit

/// Shared GPU Compositor that executes the 6-Pass Cinematic Render Pipeline on a `CAMetalDrawable` (for 0% Idle CPU Preview)
/// or an offscreen `CVPixelBuffer` (for ultra-fast `VideoToolbox` hardware MP4/HEVC export).
public final class MetalFrameCompositor {
    public let device: MTLDevice
    public let commandQueue: MTLCommandQueue
    public let ciContext: CIContext

    private var cachedWallpaperURL: URL?
    private var cachedWallpaperCIImage: CIImage?
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

    // Pass 2 (Masked & Cropped Screen) Cache — avoids re-running Gaussian blur masks when adjusting Padding/Shadow/Corners/Background!
    private struct MaskedScreenCacheKey: Equatable {
        let framePtr: ObjectIdentifier?
        let sourceTimeQuantized: Int
        let masks: [MaskItem]
        let cropRect01: Rect01
    }

    private var lastMaskedScreenKey: MaskedScreenCacheKey?
    private var cachedMaskedScreenImage: CIImage?

    // Pass 3 (Screen Rounded Corners & Drop Shadow Stencil) Cache — avoids running 4K Gaussian blur & rounded-rect generators on every frame!
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

    // Pass 6 (3D Shortcut Keycap Sprite Cache) — avoids re-rasterizing keycap graphics on every frame!
    private var keycapSpriteCache: [String: CIImage] = [:]

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
        includeShortcutOverlay: Bool = false
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

        // --- PASS 3: Screen Rounded Corners, Drop Shadow & Camera Zoom/Pan Transform ---
        let screenFrameRect = calculateFittedScreenRect(
            sourceSize: maskedScreen.extent.size,
            inCanvas: canvasRect,
            paddingRatio: CGFloat(doc.canvas.paddingRatio)
        )

        let scaleX = screenFrameRect.width / max(1.0, maskedScreen.extent.width)
        let scaleY = screenFrameRect.height / max(1.0, maskedScreen.extent.height)
        var scaledScreen = maskedScreen.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

        let scaledRadius = CGFloat(doc.frameStyle.borderRadius) * (outputSize.height / 900.0)
        scaledScreen = applyRoundedCorners(
            to: scaledScreen,
            rect: CGRect(origin: .zero, size: screenFrameRect.size),
            radius: scaledRadius
        )

        var positionedScreen = scaledScreen.transformed(
            by: CGAffineTransform(translationX: screenFrameRect.minX, y: screenFrameRect.minY)
        )

        // Screen Inset Border (`Inset` toggle in Background tab)
        if doc.frameStyle.inset.enabled && doc.frameStyle.inset.size > 0.1 {
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
        // Cached across frames so the 4K Gaussian shadow blur is evaluated only once when parameters change, not on every video frame!
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
                    let computedShadow = shadowBox
                        .applyingGaussianBlur(sigma: Double(max(1.0, shadowBlur * 0.45)))
                        .cropped(to: canvasRect)
                    lastShadowCacheKey = shadowKey
                    cachedBlurredShadowImage = computedShadow
                    blurredShadow = computedShadow
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
        if zoomScale > 1.002 && !cameraState.isLoupeMode {
            let focusX = screenFrameRect.minX + CGFloat(cameraState.center01.x) * screenFrameRect.width
            let focusY = screenFrameRect.minY + CGFloat(1.0 - cameraState.center01.y) * screenFrameRect.height
            let canvasCenterX = canvasRect.midX
            let canvasCenterY = canvasRect.midY

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

        // --- PASS 5: True 1-Frame Shutter Motion Blur ---
        // Compares the current camera state (`sourceTimeMs`) with the camera state 1 frame earlier (`sourceTimeMs - 16.67ms`).
        // - Translational pan blur (`CIMotionBlur`) ONLY fires when the camera center actually translates across pixels (`panPixelsPerFrame > 1.8`).
        // - Radial zoom blur (`CIZoomBlur`) ONLY fires during the fast impulse of a zoom change (`scalePixelsPerFrame > 1.8`).
        // - As soon as per-frame displacement drops below 1.8px (`rf.isStatic`), blur is 0.0 so the image settles crystal-clear!
        if !suppressZoomForMaskEditing && !cameraState.isLoupeMode && doc.motion.motionBlurIntensity > 0.02 {
            let prevCam = session.trajectorySolver.evaluate(atSourceMs: max(0.0, sourceTimeMs - 16.67)).camera
            let blurStrength = CGFloat(min(1.0, max(0.0, doc.motion.motionBlurIntensity)))

            let dxPx = CGFloat(cameraState.center01.x - prevCam.center01.x) * outputSize.width * zoomScale
            let dyPx = CGFloat(-(cameraState.center01.y - prevCam.center01.y)) * outputSize.height * zoomScale
            let panPixelsPerFrame = hypot(dxPx, dyPx) * blurStrength

            let scaleDelta = abs(CGFloat(cameraState.scale - prevCam.scale))
            let scalePixelsPerFrame = scaleDelta * min(outputSize.width, outputSize.height) * 0.22 * blurStrength

            if panPixelsPerFrame > 1.8 {
                let panBlurRadius = min(6.5, Double(panPixelsPerFrame * 0.36))
                let angle = Double(atan2(dyPx, dxPx))
                positionedScreen = positionedScreen
                    .cropped(to: canvasRect)
                    .clampedToExtent()
                    .applyingFilter("CIMotionBlur", parameters: [
                        kCIInputRadiusKey: panBlurRadius,
                        kCIInputAngleKey: angle
                    ])
                    .cropped(to: canvasRect)
            } else if scalePixelsPerFrame > 1.8 {
                // `CIZoomBlur` is prohibitively slow in CoreImage (`~35ms`/frame); instead we use a fast 3-tap radial shutter blend
                // along the zoom trajectory (`1.0 / (1.0 + stepAmount)`) which renders in `<0.4ms` on Metal at 120Hz!
                let stepScale1 = max(0.94, 1.0 - CGFloat(scaleDelta * 0.35 * Double(blurStrength)))
                let stepScale2 = max(0.88, 1.0 - CGFloat(scaleDelta * 0.70 * Double(blurStrength)))
                let cx = canvasRect.midX
                let cy = canvasRect.midY

                let baseImg = positionedScreen.cropped(to: canvasRect)
                let tap1 = baseImg
                    .transformed(by: CGAffineTransform(translationX: cx, y: cy)
                        .scaledBy(x: stepScale1, y: stepScale1)
                        .translatedBy(x: -cx, y: -cy))
                    .applyingFilter("CIColorMatrix", parameters: [
                        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.32)
                    ])
                let tap2 = baseImg
                    .transformed(by: CGAffineTransform(translationX: cx, y: cy)
                        .scaledBy(x: stepScale2, y: stepScale2)
                        .translatedBy(x: -cx, y: -cy))
                    .applyingFilter("CIColorMatrix", parameters: [
                        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.18)
                    ])
                positionedScreen = tap2.composited(over: tap1.composited(over: baseImg)).cropped(to: canvasRect)
            }
        }

        composite = positionedScreen
            .cropped(to: canvasRect)
            .composited(over: composite)
            .cropped(to: canvasRect)

        // --- PASS 5B: Liquid Glass Loupe Lens ---
        // Rendered over the full scene (screen + background) so the 3D glass bevel refracts and casts its thrown shadow
        // and rainbow caustics across both the screen window and the background wallpaper!
        if !suppressZoomForMaskEditing && cameraState.loupePresence01 > 0.005 && cameraState.loupeScale > 1.002 {
            let focusX = screenFrameRect.minX + CGFloat(cameraState.center01.x) * screenFrameRect.width
            let focusY = screenFrameRect.minY + CGFloat(1.0 - cameraState.center01.y) * screenFrameRect.height
            let maxScreenDim = max(screenFrameRect.width, screenFrameRect.height)
            let loupeRadius = max(48.0, maxScreenDim * CGFloat(cameraState.loupeConfig.radius01))

            composite = LiquidGlassLoupeShaderRenderer.apply(
                to: composite,
                canvasRect: canvasRect,
                centerPx: CGPoint(x: focusX, y: focusY),
                radiusPx: loupeRadius,
                zoomScale: CGFloat(cameraState.loupeScale),
                bevelRatio: CGFloat(max(0.18, cameraState.loupeConfig.bevelRatio)),
                chromaticAberration: CGFloat(max(0.55, cameraState.loupeConfig.chromaticAberration)),
                presence: CGFloat(cameraState.loupePresence01)
            )
        }

        // --- PASS 6: 3D Keyboard Shortcut Keycaps Overlay (For Video/GIF/Still-Frame Export!) ---
        if includeShortcutOverlay {
            let activeShortcuts = session.activeShortcutClustersWithStyles(atSourceMs: sourceTimeMs)
            if !activeShortcuts.isEmpty {
                composite = renderShortcutKeycapsOverlay(
                    over: composite,
                    activeItems: activeShortcuts,
                    sourceTimeMs: sourceTimeMs,
                    shortcutsSizeRatio: doc.captions.shortcutsSizeRatio,
                    canvasRect: canvasRect
                )
            }
        }

        return composite
    }

    public func screenFrameRectInCanvas(session: ProjectSession, canvasSize: CGSize) -> CGRect {
        let rawSize = CGSize(
            width: max(640, session.metadata.captureTarget.pixelSize.width),
            height: max(400, session.metadata.captureTarget.pixelSize.height)
        )
        return calculateFittedScreenRect(
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

        // Fast path: return cached background (including blur) when background & blur haven't changed!
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
        lastBlurredBgCacheKey = blurCacheKey
        cachedBlurredBackgroundImage = finalBg
        return finalBg
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
        if cachedWallpaperURL != url || cachedWallpaperCIImage == nil {
            cachedWallpaperURL = url
            // Decode and downsample once into an immediately-cached `CGImage` (capped at 2560px)
            // so CoreImage NEVER re-decodes multi-megabyte 6K `.heic`/`.jpg` data on every frame!
            if let cgImg = SystemWallpaperCatalog.downsampleCGImage(at: url, maxPixelSize: 2560) {
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

    private func calculateFittedScreenRect(sourceSize: CGSize, inCanvas canvas: CGRect, paddingRatio: CGFloat) -> CGRect {
        let insetX = canvas.width * min(0.42, max(0.0, paddingRatio))
        let insetY = canvas.height * min(0.42, max(0.0, paddingRatio))
        let available = canvas.insetBy(dx: insetX, dy: insetY)

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
            lastRoundedMaskCacheKey = maskKey
            cachedRoundedMaskImage = generated
            roundedMask = generated
        }
        let clearBG = CIImage.empty().cropped(to: rect)
        return image.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: clearBG,
            kCIInputMaskImageKey: roundedMask
        ]).cropped(to: rect)
    }

    private func renderCursorAndRipple(
        over image: CIImage,
        screenFrameRect: CGRect,
        cursorState: SpringTrajectorySolver.CursorFrameState,
        cursorConfig: CursorConfig,
        canvasScale: CGFloat
    ) -> CIImage {
        var result = image
        let cx = screenFrameRect.minX + CGFloat(cursorState.position01.x) * screenFrameRect.width
        let cy = screenFrameRect.minY + CGFloat(1.0 - cursorState.position01.y) * screenFrameRect.height

        // 1. Click Effect (`Circle` vs `Ripple`)
        if let progress = cursorState.activeClickProgress, cursorConfig.clickEffect.visualStyle != .none {
            let maxRippleRadius = 46.0 * canvasScale * CGFloat(cursorConfig.scale)
            let radius = max(4.0, maxRippleRadius * CGFloat(progress))
            let alpha = CGFloat(max(0.0, (1.0 - progress) * 0.72 * cursorState.opacity))
            let rippleExtent = CGRect(x: cx - radius, y: cy - radius, width: radius * 2, height: radius * 2)

            if cursorConfig.clickEffect.visualStyle == .circle {
                if let circle = CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
                    "inputExtent": CIVector(cgRect: rippleExtent),
                    "inputRadius": radius,
                    "inputColor": CIColor(red: 1.0, green: 1.0, blue: 1.0, alpha: alpha * 0.65)
                ])?.outputImage {
                    result = circle.composited(over: result)
                }
            } else {
                // Ripple ring wave (outer disc minus inner cutout disc)
                let ringThickness = max(2.5, 6.0 * canvasScale * CGFloat(1.0 - progress * 0.5))
                let innerRadius = max(0.0, radius - ringThickness)
                let innerExtent = CGRect(x: cx - innerRadius, y: cy - innerRadius, width: innerRadius * 2, height: innerRadius * 2)
                if let outer = CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
                    "inputExtent": CIVector(cgRect: rippleExtent),
                    "inputRadius": radius,
                    "inputColor": CIColor(red: 1.0, green: 1.0, blue: 1.0, alpha: alpha)
                ])?.outputImage {
                    if innerRadius > 1.0,
                       let innerMask = CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
                           "inputExtent": CIVector(cgRect: innerExtent),
                           "inputRadius": innerRadius,
                           "inputColor": CIColor.white
                       ])?.outputImage {
                        let ring = outer.applyingFilter("CISourceOutCompositing", parameters: [
                            kCIInputBackgroundImageKey: innerMask
                        ]).cropped(to: rippleExtent)
                        result = ring.composited(over: result)
                    } else {
                        result = outer.composited(over: result)
                    }
                }
            }
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
    /// used identically by both `PreviewShortcutKeycapsOverlayView` (Preview) and `MetalFrameCompositor` (Export)!
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
        canvasRect: CGRect
    ) -> CIImage {
        var output = baseImage
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

            let spriteOriginX = contentOriginX - shadowPad
            let spriteOriginY = contentOriginY - shadowPad
            let spriteCenterX = groupSprite.extent.width * 0.5
            let spriteCenterY = groupSprite.extent.height * 0.5

            var transform = CGAffineTransform.identity
            transform = transform.translatedBy(x: spriteOriginX + spriteCenterX, y: spriteOriginY + spriteCenterY)
            if abs(env.scale - 1.0) > 0.001 {
                transform = transform.scaledBy(x: env.scale, y: env.scale)
            }
            transform = transform.translatedBy(x: -spriteCenterX, y: -spriteCenterY)

            var positioned = groupSprite.transformed(by: transform)
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
