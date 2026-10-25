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
        outputSize: CGSize
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

        // Fast GPU Rounded-Rectangle Drop Shadow (Generates shadow directly from `screenFrameRect` shape)
        if doc.frameStyle.shadow.enabled && doc.frameStyle.shadow.intensity > 0.01 {
            let shadowOffset = CGFloat(doc.frameStyle.shadow.distance) * (outputSize.height / 900.0)
            let shadowBlur = CGFloat(doc.frameStyle.shadow.blur) * (outputSize.height / 900.0)
            let shadowAlpha = CGFloat(doc.frameStyle.shadow.intensity)
            let shadowRect = screenFrameRect.offsetBy(dx: 0, dy: -shadowOffset * 0.45)

            if let shadowBox = CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
                "inputExtent": CIVector(cgRect: shadowRect),
                "inputRadius": scaledRadius,
                "inputColor": CIColor(red: 0, green: 0, blue: 0, alpha: shadowAlpha)
            ])?.outputImage {
                let blurredShadow = shadowBox
                    .applyingGaussianBlur(sigma: Double(max(1.0, shadowBlur * 0.42)))
                    .cropped(to: canvasRect)
                positionedScreen = positionedScreen.composited(over: blurredShadow)
            }
        }

        // --- PASS 4: Cursor Sprite & Click Ripple in Screen Space ---
        let activeSlice = session.currentActiveSlice
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

        // Apply Virtual Camera Pan & Zoom Transform (Classic mode) OR Optical Glass Loupe Lens (Loupe mode)
        let zoomScale = CGFloat(max(1.0, cameraState.scale))
        if zoomScale > 1.002 {
            let focusX = screenFrameRect.minX + CGFloat(cameraState.center01.x) * screenFrameRect.width
            let focusY = screenFrameRect.minY + CGFloat(1.0 - cameraState.center01.y) * screenFrameRect.height

            if cameraState.isLoupeMode {
                let loupeRadius = max(40.0, min(screenFrameRect.width, screenFrameRect.height) * CGFloat(cameraState.loupeConfig.radius01))
                let loupeRect = CGRect(
                    x: focusX - loupeRadius,
                    y: focusY - loupeRadius,
                    width: loupeRadius * 2.0,
                    height: loupeRadius * 2.0
                )

                var zoomTransform = CGAffineTransform.identity
                zoomTransform = zoomTransform.translatedBy(x: focusX, y: focusY)
                zoomTransform = zoomTransform.scaledBy(x: zoomScale, y: zoomScale)
                zoomTransform = zoomTransform.translatedBy(x: -focusX, y: -focusY)

                let magnifiedScreen = positionedScreen.transformed(by: zoomTransform).cropped(to: loupeRect)
                if let circleStencil = CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
                    "inputExtent": CIVector(cgRect: loupeRect),
                    "inputRadius": loupeRadius,
                    "inputColor": CIColor.white
                ])?.outputImage {
                    let clearBG = CIImage.empty().cropped(to: loupeRect)
                    let circularLens = magnifiedScreen.applyingFilter("CIBlendWithMask", parameters: [
                        kCIInputBackgroundImageKey: clearBG,
                        kCIInputMaskImageKey: circleStencil
                    ]).cropped(to: loupeRect)

                    // Bevel glass rim around the loupe
                    let borderRadius = loupeRadius + 2.5
                    let borderRect = CGRect(
                        x: focusX - borderRadius,
                        y: focusY - borderRadius,
                        width: borderRadius * 2.0,
                        height: borderRadius * 2.0
                    )
                    if let rimCircle = CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
                        "inputExtent": CIVector(cgRect: borderRect),
                        "inputRadius": borderRadius,
                        "inputColor": CIColor(red: 1, green: 1, blue: 1, alpha: 0.65)
                    ])?.outputImage {
                        positionedScreen = rimCircle.composited(over: positionedScreen)
                    }
                    positionedScreen = circularLens.composited(over: positionedScreen)
                }
            } else {
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
        }

        // --- PASS 5: Camera Motion Blur (Velocity-Driven Shutter Blur, Settled at Clip End) ---
        let camSpeed = hypot(cameraState.velocity01PerSec.x, cameraState.velocity01PerSec.y) + abs(cameraState.scaleVelocityPerSec) * 0.35
        let remainingSliceMs = activeSlice.map { max(0.0, $0.sourceEndMs - sourceTimeMs) } ?? 1000.0
        let endSettleFactor = min(1.0, max(0.0, (remainingSliceMs - 60.0) / 180.0))
        if doc.motion.motionBlurIntensity > 0.05 && camSpeed > 0.35 && endSettleFactor > 0.05 {
            let blurRadius = min(14.0, camSpeed * 12.0 * doc.motion.motionBlurIntensity * endSettleFactor)
            if blurRadius > 0.5 {
                let angle = atan2(-cameraState.velocity01PerSec.y, cameraState.velocity01PerSec.x)
                positionedScreen = positionedScreen
                    .cropped(to: canvasRect)
                    .clampedToExtent()
                    .applyingFilter("CIMotionBlur", parameters: [
                        kCIInputRadiusKey: blurRadius,
                        kCIInputAngleKey: angle
                    ])
                    .cropped(to: canvasRect)
            }
        }

        composite = positionedScreen
            .cropped(to: canvasRect)
            .composited(over: composite)
            .cropped(to: canvasRect)

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
        guard radius > 0.5,
              let roundedMask = CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
                  "inputExtent": CIVector(cgRect: rect),
                  "inputRadius": radius,
                  "inputColor": CIColor.white
              ])?.outputImage else {
            return image
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
