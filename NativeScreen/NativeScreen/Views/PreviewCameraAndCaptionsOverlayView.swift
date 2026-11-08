import SwiftUI
import AppKit
import CoreImage
import AVFoundation
import CoreMedia
import Vision

/// Renders a realistic portrait webcam feed with live CoreImage color grading (`Studio`, `Cinema`, `Film`, `Golden`, `Cream`, `Terra`, `Moody`, `Arctic`, `Neon`, `Punch`, `Fade`, `Mono`), sharpening, crop, and horizontal mirror.
public struct GradedWebcamPortraitView: View {
    public let preset: CameraColorGradePreset
    public var customPreset: CustomCameraColorPreset? = nil
    public let intensity: Double
    public let sharpen01: Double
    public let mirror: Bool
    public let cropRect01: Rect01
    public let enableFaceTracking: Bool
    public let isCutoutMode: Bool
    public var webcamVideoURL: URL?

    public init(
        preset: CameraColorGradePreset,
        customPreset: CustomCameraColorPreset? = nil,
        intensity: Double = 1.0,
        sharpen01: Double = 0.0,
        mirror: Bool = false,
        cropRect01: Rect01 = .full,
        enableFaceTracking: Bool = false,
        isCutoutMode: Bool = false,
        webcamVideoURL: URL? = nil
    ) {
        self.preset = preset
        self.customPreset = customPreset
        self.intensity = intensity
        self.sharpen01 = sharpen01
        self.mirror = mirror
        self.cropRect01 = cropRect01
        self.enableFaceTracking = enableFaceTracking
        self.isCutoutMode = isCutoutMode
        self.webcamVideoURL = webcamVideoURL
    }

    public var body: some View {
        let gradedNSImage = customPreset.map {
            Self.cachedGradedCustomPresetImage(
                customPreset: $0,
                intensity: intensity,
                sharpen01: sharpen01,
                isCutoutMode: isCutoutMode
            )
        } ?? Self.cachedGradedPortraitImage(
            preset: preset,
            intensity: intensity,
            sharpen01: sharpen01,
            isCutoutMode: isCutoutMode
        )

        GeometryReader { geo in
            let w = max(1, geo.size.width)
            let h = max(1, geo.size.height)
            let scaleX = 1.0 / max(0.25, CGFloat(cropRect01.width))
            let scaleY = 1.0 / max(0.25, CGFloat(cropRect01.height))
            let faceZoom: CGFloat = enableFaceTracking ? 1.16 : 1.0
            let offsetX = (0.5 - CGFloat(cropRect01.center.x)) * w * scaleX
            let offsetY = (0.5 - CGFloat(cropRect01.center.y)) * h * scaleY

            Image(nsImage: gradedNSImage)
                .resizable()
                .scaledToFill()
                .frame(width: w, height: h)
                .scaleEffect(
                    x: (mirror ? -1.0 : 1.0) * scaleX * faceZoom,
                    y: scaleY * faceZoom
                )
                .offset(x: offsetX, y: offsetY)
        }
        .onAppear {
            if let url = webcamVideoURL {
                Self.preloadFirstFrameIfNeeded(from: url)
            }
        }
    }

    private static var imageCache: [String: NSImage] = [:]
    private static var preloadedVideoURL: URL?
    fileprivate static let sharedCIContext = CIContext(options: [.useSoftwareRenderer: false])
    private static var basePortraitCIImage: CIImage = buildBasePortraitCIImage()

    /// Each slider tick of intensity, sharpen or a custom preset makes a new key; past this many entries the cache
    /// starts over instead of keeping every 240 px variant until quit.
    private static let imageCacheLimit = 48

    private static func storeInImageCache(_ image: NSImage, forKey key: String) {
        if imageCache.count >= imageCacheLimit {
            imageCache.removeAll(keepingCapacity: true)
        }
        imageCache[key] = image
    }

    /// Drops the graded previews and the project's camera frame (called when the last editor closes).
    public static func purgeCaches() {
        imageCache.removeAll()
        preloadedVideoURL = nil
        basePortraitCIImage = buildBasePortraitCIImage()
    }

    public static func preloadFirstFrameIfNeeded(from url: URL, onLoaded: (@MainActor () -> Void)? = nil) {
        if preloadedVideoURL == url {
            onLoaded?()
            return
        }
        preloadedVideoURL = url
        Task.detached(priority: .userInitiated) {
            let asset = AVURLAsset(url: url)
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            let cmTime = CMTime(seconds: 0.1, preferredTimescale: 600)
            if let (cgImg, _) = try? await gen.image(at: cmTime) {
                let rawCI = CIImage(cgImage: cgImg)
                let side = max(1.0, min(rawCI.extent.width, rawCI.extent.height))
                let cropOriginX = (rawCI.extent.width - side) * 0.5
                let cropOriginY = (rawCI.extent.height - side) * 0.5
                let square = rawCI
                    .cropped(to: CGRect(x: cropOriginX, y: cropOriginY, width: side, height: side))
                    .transformed(by: CGAffineTransform(translationX: -cropOriginX, y: -cropOriginY))
                    .transformed(by: CGAffineTransform(scaleX: 240.0 / side, y: 240.0 / side))
                    .cropped(to: CGRect(x: 0, y: 0, width: 240, height: 240))

                await MainActor.run {
                    basePortraitCIImage = square
                    imageCache.removeAll()
                    onLoaded?()
                }
            }
        }
    }

    public static func cachedGradedPortraitImage(
        preset: CameraColorGradePreset,
        intensity: Double,
        sharpen01: Double,
        isCutoutMode: Bool = false
    ) -> NSImage {
        let intKey = Int(round(intensity * 20.0))
        let sharpKey = Int(round(sharpen01 * 20.0))
        let cacheKey = "\(preset.rawValue)_\(intKey)_\(sharpKey)_\(isCutoutMode)"
        if let existing = imageCache[cacheKey] {
            return existing
        }

        let base = isCutoutMode ? buildBasePortraitCIImage(cutoutBackground: true) : basePortraitCIImage
        let graded = LocalOnDeviceMediaIntelligence.applyCameraGradeAndSharpen(
            to: base,
            preset: preset,
            intensity: intensity,
            sharpen01: sharpen01
        )
        let extent = CGRect(x: 0, y: 0, width: 240, height: 240)
        if let cgImg = sharedCIContext.createCGImage(graded, from: extent) {
            let nsImg = NSImage(cgImage: cgImg, size: NSSize(width: 240, height: 240))
            storeInImageCache(nsImg, forKey: cacheKey)
            return nsImg
        }
        return NSImage(size: NSSize(width: 240, height: 240))
    }

    public static func cachedGradedCustomPresetImage(
        customPreset: CustomCameraColorPreset,
        intensity: Double = 1.0,
        sharpen01: Double = 0.0,
        isCutoutMode: Bool = false
    ) -> NSImage {
        let intKey = Int(round(intensity * 20.0))
        let sharpKey = Int(round(sharpen01 * 20.0))
        let cacheKey = "custom_\(customPreset.id)_\(customPreset.warmth)_\(customPreset.backgroundPop)_\(customPreset.contrast)_\(customPreset.colorIntensity)_\(intKey)_\(sharpKey)_\(isCutoutMode)"
        if let existing = imageCache[cacheKey] {
            return existing
        }

        let base = isCutoutMode ? buildBasePortraitCIImage(cutoutBackground: true) : basePortraitCIImage
        let graded = LocalOnDeviceMediaIntelligence.applyCameraGradeAndSharpen(
            to: base,
            preset: .original,
            customPreset: customPreset,
            intensity: intensity,
            sharpen01: sharpen01
        )
        let extent = CGRect(x: 0, y: 0, width: 240, height: 240)
        if let cgImg = sharedCIContext.createCGImage(graded, from: extent) {
            let nsImg = NSImage(cgImage: cgImg, size: NSSize(width: 240, height: 240))
            storeInImageCache(nsImg, forKey: cacheKey)
            return nsImg
        }
        return NSImage(size: NSSize(width: 240, height: 240))
    }

    private static func buildBasePortraitCIImage(cutoutBackground: Bool = false) -> CIImage {
        let size = NSSize(width: 240, height: 240)
        let img = NSImage(size: size, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }

            if !cutoutBackground {
                // Bright office ceiling background
                let colors = [
                    NSColor(red: 0.78, green: 0.80, blue: 0.82, alpha: 1.0).cgColor,
                    NSColor(red: 0.88, green: 0.90, blue: 0.91, alpha: 1.0).cgColor
                ] as CFArray
                if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0.0, 1.0]) {
                    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: rect.height), options: [])
                }

                // Subtle ceiling grid lines & recessed light fixtures
                ctx.setStrokeColor(NSColor(white: 0.68, alpha: 0.45).cgColor)
                ctx.setLineWidth(1.2)
                ctx.move(to: CGPoint(x: 0, y: 175))
                ctx.addLine(to: CGPoint(x: 240, y: 195))
                ctx.move(to: CGPoint(x: 65, y: 240))
                ctx.addLine(to: CGPoint(x: 95, y: 90))
                ctx.strokePath()

                // Warm office LED strip bars
                ctx.setFillColor(NSColor(red: 0.98, green: 0.97, blue: 0.92, alpha: 0.92).cgColor)
                ctx.fill(CGRect(x: 8, y: 122, width: 64, height: 8))
                ctx.fill(CGRect(x: 168, y: 122, width: 64, height: 8))
            }

            // Dark jacket & white polo collar shoulders
            ctx.setFillColor(NSColor(red: 0.13, green: 0.14, blue: 0.16, alpha: 1.0).cgColor)
            let jacketPath = CGMutablePath()
            jacketPath.move(to: CGPoint(x: 16, y: 0))
            jacketPath.addQuadCurve(to: CGPoint(x: 224, y: 0), control: CGPoint(x: 120, y: 78))
            jacketPath.closeSubpath()
            ctx.addPath(jacketPath)
            ctx.fillPath()

            ctx.setFillColor(NSColor(red: 0.94, green: 0.95, blue: 0.96, alpha: 1.0).cgColor)
            let shirtPath = CGMutablePath()
            shirtPath.move(to: CGPoint(x: 64, y: 0))
            shirtPath.addQuadCurve(to: CGPoint(x: 176, y: 0), control: CGPoint(x: 120, y: 66))
            shirtPath.closeSubpath()
            ctx.addPath(shirtPath)
            ctx.fillPath()

            // Neck
            ctx.setFillColor(NSColor(red: 0.84, green: 0.68, blue: 0.56, alpha: 1.0).cgColor)
            ctx.fill(CGRect(x: 98, y: 42, width: 44, height: 42))

            // Face oval with warm natural skin tone
            let faceRect = CGRect(x: 74, y: 68, width: 92, height: 112)
            ctx.setFillColor(NSColor(red: 0.89, green: 0.73, blue: 0.61, alpha: 1.0).cgColor)
            ctx.fillEllipse(in: faceRect)

            // Glasses frames
            ctx.setStrokeColor(NSColor(red: 0.22, green: 0.21, blue: 0.20, alpha: 0.90).cgColor)
            ctx.setLineWidth(2.2)
            ctx.strokeEllipse(in: CGRect(x: 84, y: 116, width: 30, height: 22))
            ctx.strokeEllipse(in: CGRect(x: 126, y: 116, width: 30, height: 22))
            ctx.move(to: CGPoint(x: 114, y: 128))
            ctx.addLine(to: CGPoint(x: 126, y: 128))
            ctx.strokePath()

            // Eyes & eyebrows
            ctx.setFillColor(NSColor(red: 0.16, green: 0.14, blue: 0.13, alpha: 1.0).cgColor)
            ctx.fillEllipse(in: CGRect(x: 96, y: 124, width: 6, height: 6))
            ctx.fillEllipse(in: CGRect(x: 138, y: 124, width: 6, height: 6))

            // Subtle smile
            ctx.setStrokeColor(NSColor(red: 0.66, green: 0.44, blue: 0.38, alpha: 0.85).cgColor)
            ctx.setLineWidth(2.0)
            ctx.move(to: CGPoint(x: 106, y: 92))
            ctx.addQuadCurve(to: CGPoint(x: 134, y: 92), control: CGPoint(x: 120, y: 86))
            ctx.strokePath()

            // Dark hair bangs
            ctx.setFillColor(NSColor(red: 0.16, green: 0.13, blue: 0.11, alpha: 1.0).cgColor)
            let hairPath = CGMutablePath()
            hairPath.addArc(center: CGPoint(x: 120, y: 142), radius: 47, startAngle: 0, endAngle: .pi, clockwise: false)
            hairPath.closeSubpath()
            ctx.addPath(hairPath)
            ctx.fillPath()

            return true
        }

        if let tiff = img.tiffRepresentation, let ci = CIImage(data: tiff) {
            return ci
        }
        return CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5))
            .cropped(to: CGRect(x: 0, y: 0, width: 240, height: 240))
    }
}

// MARK: - 3. Standalone Camera Crop Window

public struct StandaloneCameraCropWindowView: View {
    @Bindable var session: ProjectSession
    let onCloseWindow: () -> Void

    @State private var uncroppedWebcamImage: NSImage?
    @State private var webcamPixelSize: CGSize = CGSize(width: 1920, height: 1080)
    @State private var draftCrop01: Rect01
    @State private var dragStartCrop01: Rect01?

    public init(session: ProjectSession, onCloseWindow: @escaping () -> Void) {
        self.session = session
        self.onCloseWindow = onCloseWindow
        self._draftCrop01 = State(initialValue: session.document.camera.cropRect01)
    }

    private var sourcePixelWidth: Double {
        max(640.0, Double(webcamPixelSize.width))
    }

    private var sourcePixelHeight: Double {
        max(360.0, Double(webcamPixelSize.height))
    }

    public var body: some View {
        ZStack {
            // Brighter Studio Slate Base + Soft Ambient Image Bleed
            Color.surface(red: 0.19, green: 0.19, blue: 0.23)
                .ignoresSafeArea()

            if let img = uncroppedWebcamImage {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: 75)
                    .opacity(0.24)
                    .ignoresSafeArea()
            }

            VStack(spacing: 0) {
                // Top Unified Header Bar (`Size [1920] × [1080]  [Select... ⌄]  Position [0] [0]  [Reset]  [⌨]`)
                HStack(spacing: 12) {
                    Spacer()
                        .frame(width: 68) // Space for native macOS traffic lights `🔴 🟡 🟢`

                    Spacer()

                    // Size W × H
                    HStack(spacing: 6) {
                        Text("Size")
                            .font(.system(size: 12, weight: .regular))
                            .foregroundStyle(.ink.opacity(0.45))

                        cropDimensionBadge("\(Int(round(draftCrop01.width * sourcePixelWidth)))")
                        Text("×")
                            .font(.system(size: 12))
                            .foregroundStyle(.ink.opacity(0.45))
                        cropDimensionBadge("\(Int(round(draftCrop01.height * sourcePixelHeight)))")
                    }

                    // Select Aspect Ratio Preset Menu
                    Menu {
                        Button("Full Original") {
                            withAnimation(.spring(response: 0.22, dampingFraction: 0.86)) {
                                draftCrop01 = .full
                            }
                        }
                        Divider()
                        Button("16:9 Widescreen") { applyAspectCrop(ratio: 16.0 / 9.0) }
                        Button("4:3 Classic") { applyAspectCrop(ratio: 4.0 / 3.0) }
                        Button("1:1 Square") { applyAspectCrop(ratio: 1.0) }
                        Button("3:4 Portrait") { applyAspectCrop(ratio: 3.0 / 4.0) }
                        Button("9:16 Vertical") { applyAspectCrop(ratio: 9.0 / 16.0) }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "sidebar.left")
                                .font(.system(size: 12))
                            Text("Select...")
                                .font(.system(size: 12, weight: .regular))
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(.ink.opacity(0.55))
                        }
                        .foregroundStyle(.ink.opacity(0.92))
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .background(Color.ink.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(Color.ink.opacity(0.10), lineWidth: 1)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .fixedSize()

                    // Position X, Y
                    HStack(spacing: 6) {
                        Text("Position")
                            .font(.system(size: 12, weight: .regular))
                            .foregroundStyle(.ink.opacity(0.45))

                        cropDimensionBadge("\(Int(round(draftCrop01.x * sourcePixelWidth)))")
                        cropDimensionBadge("\(Int(round(draftCrop01.y * sourcePixelHeight)))")
                    }

                    // Reset Button
                    Button {
                        withAnimation(.spring(response: 0.22, dampingFraction: 0.86)) {
                            draftCrop01 = .full
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "crop")
                                .font(.system(size: 11.5, weight: .medium))
                            Text("Reset")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundStyle(.ink.opacity(draftCrop01 == .full ? 0.42 : 0.94))
                        .padding(.horizontal, 12)
                        .frame(height: 30)
                        .background(Color.ink.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(Color.ink.opacity(0.10), lineWidth: 1)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Image(systemName: "keyboard")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(.ink.opacity(0.65))
                        .frame(width: 30, height: 30)
                }
                .padding(.horizontal, 18)
                .frame(height: 54)

                // Center Interactive Crop Area with Rule-of-Thirds Grid & 8 Handles
                GeometryReader { geo in
                    let fitted = fitSourceFrame(in: geo.size)
                    let cropRect = CGRect(
                        x: fitted.minX + CGFloat(draftCrop01.x) * fitted.width,
                        y: fitted.minY + CGFloat(draftCrop01.y) * fitted.height,
                        width: max(24, CGFloat(draftCrop01.width) * fitted.width),
                        height: max(24, CGFloat(draftCrop01.height) * fitted.height)
                    )

                    ZStack(alignment: .topLeading) {
                        Group {
                            if let img = uncroppedWebcamImage {
                                Image(nsImage: img)
                                    .resizable()
                                    .interpolation(.high)
                                    .scaleEffect(x: session.document.camera.mirror ? 1.0 : -1.0, y: 1.0)
                            } else {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color(red: 0.12, green: 0.12, blue: 0.16))
                            }
                        }
                        .frame(width: fitted.width, height: fitted.height)
                        .position(x: fitted.midX, y: fitted.midY)

                        // Dimmed Outside Mask
                        Path { path in
                            path.addRect(fitted)
                            path.addRect(cropRect)
                        }
                        .fill(Color.black.opacity(0.58), style: FillStyle(eoFill: true))
                        .allowsHitTesting(false)

                        // Interactive Crop Box + Rule of Thirds Grid + 8 Circular Handles
                        ZStack {
                            Canvas { context, size in
                                let strokeStyle = StrokeStyle(lineWidth: 1, dash: [4, 4])
                                for i in 1...2 {
                                    let frac = CGFloat(i) / 3.0
                                    var vPath = Path()
                                    vPath.move(to: CGPoint(x: size.width * frac, y: 0))
                                    vPath.addLine(to: CGPoint(x: size.width * frac, y: size.height))
                                    context.stroke(vPath, with: .color(.white.opacity(0.32)), style: strokeStyle)

                                    var hPath = Path()
                                    hPath.move(to: CGPoint(x: 0, y: size.height * frac))
                                    hPath.addLine(to: CGPoint(x: size.width, y: size.height * frac))
                                    context.stroke(hPath, with: .color(.white.opacity(0.32)), style: strokeStyle)
                                }
                            }
                            .allowsHitTesting(false)

                            Rectangle()
                                .strokeBorder(Color.white.opacity(0.85), lineWidth: 1.5)
                                .background(Color.white.opacity(0.001))
                                .contentShape(Rectangle())
                                .gesture(
                                    DragGesture(minimumDistance: 1, coordinateSpace: .named("cameraCropModalSpace"))
                                        .onChanged { value in
                                            if dragStartCrop01 == nil {
                                                dragStartCrop01 = draftCrop01
                                            }
                                            guard let start = dragStartCrop01 else { return }
                                            let dx = Double(value.translation.width / max(1, fitted.width))
                                            let dy = Double(value.translation.height / max(1, fitted.height))
                                            draftCrop01 = Rect01(
                                                x: max(0.0, min(1.0 - start.width, start.x + dx)),
                                                y: max(0.0, min(1.0 - start.height, start.y + dy)),
                                                width: start.width,
                                                height: start.height
                                            )
                                        }
                                        .onEnded { _ in
                                            dragStartCrop01 = nil
                                        }
                                )

                            // 8 Circular Handles (4 Corners + 4 Mid-Edges)
                            cameraCropHandle(fitted: fitted, xMode: -1, yMode: -1)
                                .position(x: 0, y: 0)
                            cameraCropHandle(fitted: fitted, xMode: 0, yMode: -1)
                                .position(x: cropRect.width * 0.5, y: 0)
                            cameraCropHandle(fitted: fitted, xMode: 1, yMode: -1)
                                .position(x: cropRect.width, y: 0)

                            cameraCropHandle(fitted: fitted, xMode: -1, yMode: 0)
                                .position(x: 0, y: cropRect.height * 0.5)
                            cameraCropHandle(fitted: fitted, xMode: 1, yMode: 0)
                                .position(x: cropRect.width, y: cropRect.height * 0.5)

                            cameraCropHandle(fitted: fitted, xMode: -1, yMode: 1)
                                .position(x: 0, y: cropRect.height)
                            cameraCropHandle(fitted: fitted, xMode: 0, yMode: 1)
                                .position(x: cropRect.width * 0.5, y: cropRect.height)
                            cameraCropHandle(fitted: fitted, xMode: 1, yMode: 1)
                                .position(x: cropRect.width, y: cropRect.height)
                        }
                        .frame(width: cropRect.width, height: cropRect.height)
                        .position(x: cropRect.midX, y: cropRect.midY)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .coordinateSpace(name: "cameraCropModalSpace")
                }
                .padding(.horizontal, 24)

                // Bottom Confirm / Discard Buttons
                HStack(spacing: 12) {
                    Button {
                        session.mutate { doc in
                            doc.camera.cropRect01 = draftCrop01.clamped()
                        }
                        onCloseWindow()
                    } label: {
                        HStack(spacing: 6) {
                            Text("Confirm changes")
                                .font(.system(size: 13, weight: .medium))
                            Image(systemName: "return")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .frame(height: 36)
                        .background(
                            Color(red: 0.36, green: 0.22, blue: 0.98),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.defaultAction)

                    Button {
                        onCloseWindow()
                    } label: {
                        Text("Discard changes")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.ink.opacity(0.88))
                            .padding(.horizontal, 18)
                            .frame(height: 36)
                            .background(
                                Color.ink.opacity(0.07),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(Color.ink.opacity(0.10), lineWidth: 1)
                            )
                            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                }
                .padding(.vertical, 18)
            }
        }
        .task {
            draftCrop01 = session.document.camera.cropRect01
            if let extracted = await session.extractRawWebcamFrameNSImage() {
                uncroppedWebcamImage = extracted.image
                webcamPixelSize = extracted.pixelSize
            }
        }
    }

    @ViewBuilder
    private func cropDimensionBadge(_ text: String) -> some View {
        Text(text.localizedUI)
            .font(.system(size: 12, weight: .regular).monospacedDigit())
            .foregroundStyle(.ink.opacity(0.94))
            .frame(minWidth: 46)
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(Color.ink.opacity(0.05), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.ink.opacity(0.09), lineWidth: 1)
            )
    }

    @ViewBuilder
    private func cameraCropHandle(fitted: CGRect, xMode: Int, yMode: Int) -> some View {
        Circle()
            .fill(Color(red: 0.16, green: 0.16, blue: 0.20))
            .frame(width: 11, height: 11)
            .overlay(Circle().stroke(Color.white, lineWidth: 1.8))
            .shadow(color: .black.opacity(0.45), radius: 2)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named("cameraCropModalSpace"))
                    .onChanged { value in
                        if dragStartCrop01 == nil {
                            dragStartCrop01 = draftCrop01
                        }
                        guard let start = dragStartCrop01 else { return }
                        let dx = Double(value.translation.width / max(1, fitted.width))
                        let dy = Double(value.translation.height / max(1, fitted.height))

                        var nx = start.x
                        var ny = start.y
                        var nw = start.width
                        var nh = start.height

                        if xMode < 0 {
                            let clampedDx = max(-start.x, min(start.width - 0.08, dx))
                            nx = start.x + clampedDx
                            nw = start.width - clampedDx
                        } else if xMode > 0 {
                            nw = max(0.08, min(1.0 - start.x, start.width + dx))
                        }

                        if yMode < 0 {
                            let clampedDy = max(-start.y, min(start.height - 0.08, dy))
                            ny = start.y + clampedDy
                            nh = start.height - clampedDy
                        } else if yMode > 0 {
                            nh = max(0.08, min(1.0 - start.y, start.height + dy))
                        }

                        draftCrop01 = Rect01(x: nx, y: ny, width: nw, height: nh).clamped()
                    }
                    .onEnded { _ in
                        dragStartCrop01 = nil
                    }
            )
    }

    private func fitSourceFrame(in container: CGSize) -> CGRect {
        let aspect = max(0.2, sourcePixelWidth / max(1.0, sourcePixelHeight))
        let availW = max(120, container.width - 12)
        let availH = max(120, container.height - 12)
        var w = availW
        var h = w / aspect
        if h > availH {
            h = availH
            w = h * aspect
        }
        return CGRect(
            x: (container.width - w) * 0.5,
            y: (container.height - h) * 0.5,
            width: w,
            height: h
        )
    }

    private func applyAspectCrop(ratio: Double) {
        let srcAspect = sourcePixelWidth / max(1.0, sourcePixelHeight)
        var newW = 1.0
        var newH = srcAspect / ratio
        if newH > 1.0 {
            newH = 1.0
            newW = ratio / srcAspect
        }
        withAnimation(.spring(response: 0.22, dampingFraction: 0.86)) {
            draftCrop01 = Rect01(
                x: (1.0 - newW) * 0.5,
                y: (1.0 - newH) * 0.5,
                width: newW,
                height: newH
            ).clamped()
        }
    }
}

// MARK: - 4. Standalone "Color preset studio" Window

public struct StandaloneColorPresetStudioWindowView: View {
    @Bindable var session: ProjectSession
    let onCloseWindow: () -> Void

    @State private var presetName: String = "My preset"
    @State private var warmth: Double = 0.0
    @State private var backgroundPop: Double = 0.20
    @State private var contrast: Double = 0.25
    @State private var colorIntensity: Double = 0.20
    @State private var sourceWebcamCIImage: CIImage?

    public init(session: ProjectSession, onCloseWindow: @escaping () -> Void) {
        self.session = session
        self.onCloseWindow = onCloseWindow
    }

    private var draftPreset: CustomCameraColorPreset {
        CustomCameraColorPreset(
            name: presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "My preset" : presetName,
            warmth: warmth,
            backgroundPop: backgroundPop,
            contrast: contrast,
            colorIntensity: colorIntensity
        )
    }

    private var liveGradedPreviewImage: NSImage {
        let preset = draftPreset
        if let rawCI = sourceWebcamCIImage {
            let graded = LocalOnDeviceMediaIntelligence.applyCustomColorPreset(to: rawCI, preset: preset)
            if let cg = GradedWebcamPortraitView.sharedCIContext.createCGImage(graded, from: rawCI.extent) {
                return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            }
        }
        return GradedWebcamPortraitView.cachedGradedCustomPresetImage(customPreset: preset)
    }

    public var body: some View {
        let previewNSImage = liveGradedPreviewImage

        ZStack {
            // Brighter Studio Slate Base + Soft Ambient Image Bleed
            Color.surface(red: 0.19, green: 0.19, blue: 0.23)
                .ignoresSafeArea()

            Image(nsImage: previewNSImage)
                .resizable()
                .scaledToFill()
                .blur(radius: 80)
                .opacity(0.24)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Top Centered Window Title ("Color preset studio")
                HStack {
                    Spacer()
                    Text("Color preset studio")
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(.ink.opacity(0.88))
                    Spacer()
                }
                .frame(height: 44)

                // Main Split Area: Left Live 16:9 Camera Preview + Right Controls Column
                HStack(alignment: .center, spacing: 28) {
                    // Left: Large Live Graded Camera Preview
                    GeometryReader { geo in
                        let aspect: CGFloat = 16.0 / 9.0
                        let availW = max(200, geo.size.width)
                        let availH = max(160, geo.size.height)
                        let w = min(availW, availH * aspect)
                        let h = w / aspect

                        Image(nsImage: previewNSImage)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFill()
                            .scaleEffect(x: session.document.camera.mirror ? 1.0 : -1.0, y: 1.0)
                            .frame(width: w, height: h)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
                            .position(x: geo.size.width * 0.5, y: geo.size.height * 0.5)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    // Right: Preset Name & 4 Grading Sliders + Create / Cancel Buttons
                    VStack(alignment: .leading, spacing: 20) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Preset name")
                                .font(.system(size: 13, weight: .regular))
                                .foregroundStyle(.ink.opacity(0.92))

                            TextField("My preset", text: $presetName)
                                .textFieldStyle(.plain)
                                .font(.system(size: 13.5, weight: .regular))
                                .foregroundStyle(.ink)
                                .padding(.horizontal, 12)
                                .frame(height: 36)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(Color.ink.opacity(0.05))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .strokeBorder(Color.ink.opacity(0.08), lineWidth: 1)
                                )
                        }

                        studioSliderRow(title: "Warmth", value: $warmth, range: -1.0...1.0, defaultValue: 0.0)
                        studioSliderRow(title: "Background pop", value: $backgroundPop, range: 0.0...1.0, defaultValue: 0.20)
                        studioSliderRow(title: "Contrast", value: $contrast, range: -1.0...1.0, defaultValue: 0.25)
                        studioSliderRow(title: "Color intensity", value: $colorIntensity, range: -1.0...1.0, defaultValue: 0.20)

                        Spacer()

                        VStack(spacing: 10) {
                            Button {
                                let created = draftPreset
                                session.mutate { doc in
                                    doc.camera.customColorPresets.append(created)
                                    doc.camera.selectedCustomColorPresetID = created.id
                                    doc.camera.customLUTRelativePath = nil
                                    doc.camera.colorGradeIntensity = 1.0
                                }
                                onCloseWindow()
                            } label: {
                                HStack(spacing: 6) {
                                    Text("Create preset")
                                        .font(.system(size: 13.5, weight: .medium))
                                    Image(systemName: "return")
                                        .font(.system(size: 11, weight: .semibold))
                                }
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 38)
                                .background(
                                    Color(red: 0.36, green: 0.22, blue: 0.98),
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                                )
                                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .keyboardShortcut(.defaultAction)

                            Button {
                                onCloseWindow()
                            } label: {
                                Text("Cancel")
                                    .font(.system(size: 13.5, weight: .medium))
                                    .foregroundStyle(.ink.opacity(0.90))
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 38)
                                    .background(
                                        Color.ink.opacity(0.07),
                                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .strokeBorder(Color.ink.opacity(0.10), lineWidth: 1)
                                    )
                                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .keyboardShortcut(.cancelAction)
                        }
                    }
                    .frame(width: 280)
                    .padding(.vertical, 8)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 22)
            }
        }
        .task {
            if let cgImg = await session.extractRawWebcamFrameCGImage() {
                sourceWebcamCIImage = CIImage(cgImage: cgImg)
            }
        }
    }

    @ViewBuilder
    private func studioSliderRow(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        defaultValue: Double
    ) -> some View {
        let isAtDefault = abs(value.wrappedValue - defaultValue) < 0.005
        VStack(alignment: .leading, spacing: 8) {
            Text(title.localizedUI)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.ink.opacity(0.92))

            HStack(spacing: 12) {
                Slider(value: value, in: range)
                    .tint(Color(red: 0.44, green: 0.32, blue: 0.98))
                    .accessibilityLabel(Text(title.localizedUI))

                Button {
                    withAnimation(.easeOut(duration: 0.14)) {
                        value.wrappedValue = defaultValue
                    }
                } label: {
                    Text("Reset")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(.ink.opacity(isAtDefault ? 0.25 : 0.72))
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color.ink.opacity(0.03))
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(isAtDefault)
            }
        }
    }
}

public struct CameraCropModalView: View {
    @Bindable var session: ProjectSession
    public init(session: ProjectSession) {
        self.session = session
    }
    public var body: some View {
        StandaloneCameraCropWindowView(session: session) {
            session.isShowingCameraCropModal = false
        }
    }
}
