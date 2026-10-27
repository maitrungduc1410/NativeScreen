import SwiftUI
import AppKit
import CoreImage

// MARK: - 1. Live Webcam & Captions Canvas Overlay (Matches Camera Layout, Camera Style & Captions)

public struct PreviewCameraAndCaptionsOverlayView: View {
    @Bindable var session: ProjectSession
    let canvasSize: CGSize

    public init(session: ProjectSession, canvasSize: CGSize) {
        self.session = session
        self.canvasSize = canvasSize
    }

    public var body: some View {
        let sourceMs = session.currentSourceTimeMs
        let camCfg = session.document.camera
        let capCfg = session.document.captions
        let cameraState = session.trajectorySolver.evaluate(atSourceMs: sourceMs).camera

        ZStack {
            // A. Selfie Camera Overlay (`Camera overlay` | `Split screen` | `Camera cutout`)
            if camCfg.enabled && session.hasRecordedCamera {
                let isSilentHidden: Bool = {
                    guard let minSilenceMs = camCfg.hideDuringSilenceMs else { return false }
                    // Check if `sourceMs` falls inside a long silent gap (`>= minSilenceMs`) between spoken words
                    let segs = capCfg.segments.sorted { $0.sourceStartMs < $1.sourceStartMs }
                    for i in 0..<(segs.count - 1) {
                        let gapStart = segs[i].sourceEndMs
                        let gapEnd = segs[i + 1].sourceStartMs
                        if (gapEnd - gapStart) >= minSilenceMs && sourceMs >= gapStart + 150.0 && sourceMs <= gapEnd - 150.0 {
                            return true
                        }
                    }
                    return false
                }()

                if !isSilentHidden {
                    WebcamPipCanvasView(
                        session: session,
                        camCfg: camCfg,
                        currentZoomScale: cameraState.scale,
                        canvasSize: canvasSize
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.94)))
                }
            }

            // B. Live Word-Timed Captions Overlay (`Line by line` / `Word by word`, `Full line` / `Expanding` / `Centered`, `Appear` / `Fade in` / `Slide in`, `Dark` / `Light`)
            if capCfg.enabled && !capCfg.segments.isEmpty {
                LiveCaptionsCanvasView(
                    captionsConfig: capCfg,
                    sourceTimeMs: sourceMs,
                    canvasSize: canvasSize
                )
            }
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
        .allowsHitTesting(false)
    }
}

// MARK: - Selfie Camera Renderer (`Camera overlay`, `Split screen`, `Camera cutout` + 12 Filmic Color Grades + Mirror + Crop + Face Tracking)

private struct WebcamPipCanvasView: View {
    let session: ProjectSession
    let camCfg: CameraConfig
    let currentZoomScale: Double
    let canvasSize: CGSize

    var body: some View {
        let zoomProgress01 = max(0.0, min(1.0, (currentZoomScale - 1.0) / 0.8))
        let zoomScaleMultiplier: CGFloat = camCfg.makeSmallerDuringZoom
            ? CGFloat(1.0 - (1.0 - camCfg.scaleWhenZoomed) * zoomProgress01)
            : 1.0

        let aspect = CGFloat(camCfg.aspectRatioPreset.aspectValue)
        let baseRef = min(canvasSize.width, canvasSize.height)
        let pipHeight = max(64.0, baseRef * CGFloat(camCfg.sizeRatio) * 0.58 * zoomScaleMultiplier)
        let pipWidth = max(64.0, pipHeight * aspect)

        let margin: CGFloat = max(16.0, baseRef * 0.035)
        let availW = max(1.0, canvasSize.width - pipWidth - margin * 2.0)
        let availH = max(1.0, canvasSize.height - pipHeight - margin * 2.0)

        let posX: CGFloat = {
            switch camCfg.layoutMode {
            case .overlay:
                return margin + CGFloat(max(0.0, min(1.0, camCfg.position01.x))) * availW + pipWidth * 0.5
            case .cutout:
                return margin + CGFloat(max(0.0, min(1.0, camCfg.cutoutPositionX01))) * availW + pipWidth * 0.5
            case .splitScreen:
                return camCfg.splitFlip ? (pipWidth * 0.5 + margin) : (canvasSize.width - pipWidth * 0.5 - margin)
            }
        }()

        let posY: CGFloat = {
            switch camCfg.layoutMode {
            case .overlay:
                return margin + CGFloat(max(0.0, min(1.0, camCfg.position01.y))) * availH + pipHeight * 0.5
            case .cutout:
                return canvasSize.height - pipHeight * 0.46
            case .splitScreen:
                return canvasSize.height * 0.5
            }
        }()

        let cornerRadius = min(pipWidth, pipHeight) * CGFloat(max(0.04, min(0.50, camCfg.borderRadiusRatio)))

        ZStack {
            GradedWebcamPortraitView(
                preset: camCfg.colorGradePreset,
                intensity: camCfg.colorGradeIntensity,
                sharpen01: camCfg.sharpen01,
                mirror: camCfg.mirror,
                cropRect01: camCfg.cropRect01,
                enableFaceTracking: camCfg.enableFaceTracking,
                isCutoutMode: camCfg.layoutMode == .cutout
            )
        }
        .frame(width: pipWidth, height: pipHeight)
        .clipShape(
            RoundedRectangle(
                cornerRadius: camCfg.layoutMode == .cutout ? pipWidth * 0.36 : cornerRadius,
                style: .continuous
            )
        )
        .overlay(
            RoundedRectangle(
                cornerRadius: camCfg.layoutMode == .cutout ? pipWidth * 0.36 : cornerRadius,
                style: .continuous
            )
            .strokeBorder(Color.white.opacity(camCfg.layoutMode == .cutout ? 0.0 : 0.16), lineWidth: 1.0)
        )
        .shadow(
            color: .black.opacity(camCfg.layoutMode == .cutout ? 0.35 : 0.48),
            radius: 16,
            y: 6
        )
        .position(x: posX, y: posY)
    }
}

/// Renders a realistic portrait webcam feed with live CoreImage color grading (`Studio`, `Cinema`, `Film`, `Golden`, `Cream`, `Terra`, `Moody`, `Arctic`, `Neon`, `Punch`, `Fade`, `Mono`), sharpening, crop, and horizontal mirror.
public struct GradedWebcamPortraitView: View {
    public let preset: CameraColorGradePreset
    public let intensity: Double
    public let sharpen01: Double
    public let mirror: Bool
    public let cropRect01: Rect01
    public let enableFaceTracking: Bool
    public let isCutoutMode: Bool

    public init(
        preset: CameraColorGradePreset,
        intensity: Double = 1.0,
        sharpen01: Double = 0.0,
        mirror: Bool = false,
        cropRect01: Rect01 = .full,
        enableFaceTracking: Bool = false,
        isCutoutMode: Bool = false
    ) {
        self.preset = preset
        self.intensity = intensity
        self.sharpen01 = sharpen01
        self.mirror = mirror
        self.cropRect01 = cropRect01
        self.enableFaceTracking = enableFaceTracking
        self.isCutoutMode = isCutoutMode
    }

    public var body: some View {
        let gradedNSImage = Self.cachedGradedPortraitImage(
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
    }

    private static var imageCache: [String: NSImage] = [:]
    private static let sharedCIContext = CIContext(options: [.useSoftwareRenderer: false])
    private static var basePortraitCIImage: CIImage = buildBasePortraitCIImage()

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
            imageCache[cacheKey] = nsImg
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

// MARK: - 2. Live Word-Timed Captions Renderer

private struct LiveCaptionsCanvasView: View {
    let captionsConfig: CaptionsConfig
    let sourceTimeMs: Double
    let canvasSize: CGSize

    var body: some View {
        let visibleWords = captionsConfig.segments.filter { !$0.isHidden }.sorted { $0.sourceStartMs < $1.sourceStartMs }
        let activeLine = resolveActiveCaptionLine(words: visibleWords, at: sourceTimeMs)

        if let line = activeLine, !line.words.isEmpty {
            let fontSize = max(14.0, canvasSize.height * CGFloat(captionsConfig.fontSizeRatio))
            let fontDesign: Font.Design = {
                switch captionsConfig.fontStyle {
                case .sansSerif: return .default
                case .serif: return .serif
                case .mono: return .monospaced
                }
            }()
            let isDarkTheme = (captionsConfig.colorTheme == .dark)
            let boxBgColor = isDarkTheme ? Color.black.opacity(0.82) : Color.white.opacity(0.92)
            let baseTextColor = isDarkTheme ? Color.white : Color.black

            let displayedWords: [CaptionSegment] = {
                switch captionsConfig.wordsReveal {
                case .wordByWord:
                    if let current = line.words.last(where: { $0.sourceStartMs <= sourceTimeMs }) ?? line.words.first {
                        return [current]
                    }
                    return []
                case .lineByLine:
                    switch captionsConfig.lineGrowth {
                    case .fullLine:
                        return line.words
                    case .expanding, .centered:
                        let spoken = line.words.filter { $0.sourceStartMs <= sourceTimeMs + 40.0 }
                        return spoken.isEmpty ? [line.words[0]] : spoken
                    }
                }
            }()

            let posX = canvasSize.width * CGFloat(max(0.15, min(0.85, captionsConfig.position01.x)))
            let posY = canvasSize.height * CGFloat(max(0.12, min(0.90, captionsConfig.position01.y)))

            HStack(spacing: fontSize * 0.28) {
                ForEach(displayedWords) { word in
                    let isSpokenNow = (sourceTimeMs >= word.sourceStartMs && sourceTimeMs <= word.sourceEndMs + 120.0)
                    let isFutureWord = (sourceTimeMs < word.sourceStartMs)
                    let wordOpacity: Double = {
                        switch captionsConfig.wordAnimation {
                        case .appear:
                            return isFutureWord ? 0.0 : 1.0
                        case .fadeIn:
                            return isFutureWord ? 0.38 : 1.0
                        case .slideIn:
                            return isFutureWord ? 0.25 : 1.0
                        }
                    }()
                    let slideOffsetY: CGFloat = (captionsConfig.wordAnimation == .slideIn && isSpokenNow) ? -1.5 : 0.0

                    Text(word.text)
                        .font(.system(size: fontSize, weight: .semibold, design: fontDesign))
                        .foregroundStyle(baseTextColor.opacity(wordOpacity))
                        .offset(y: slideOffsetY)
                }
            }
            .padding(.horizontal, fontSize * 0.72)
            .padding(.vertical, fontSize * 0.38)
            .background(
                RoundedRectangle(cornerRadius: fontSize * 0.42, style: .continuous)
                    .fill(boxBgColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: fontSize * 0.42, style: .continuous)
                    .strokeBorder(isDarkTheme ? Color.white.opacity(0.12) : Color.black.opacity(0.10), lineWidth: 1.0)
            )
            .shadow(color: .black.opacity(0.38), radius: 12, y: 4)
            .position(x: posX, y: posY)
        }
    }

    private struct CaptionLineGroup {
        let startMs: Double
        let endMs: Double
        let words: [CaptionSegment]
    }

    private func resolveActiveCaptionLine(words: [CaptionSegment], at timeMs: Double) -> CaptionLineGroup? {
        guard !words.isEmpty else { return nil }
        var lines: [CaptionLineGroup] = []
        var bucket: [CaptionSegment] = []

        func flush() {
            guard let f = bucket.first, let l = bucket.last else { return }
            lines.append(CaptionLineGroup(startMs: f.sourceStartMs, endMs: l.sourceEndMs, words: bucket))
            bucket.removeAll()
        }

        for w in words {
            if let prev = bucket.last {
                let gap = w.sourceStartMs - prev.sourceEndMs
                let isSentenceEnd = prev.text.hasSuffix(".") || prev.text.hasSuffix("?") || prev.text.hasSuffix("!")
                if gap >= 750.0 || isSentenceEnd || bucket.count >= 6 {
                    flush()
                }
            }
            bucket.append(w)
        }
        flush()

        return lines.first { timeMs >= $0.startMs - 140.0 && timeMs <= $0.endMs + 320.0 }
    }
}

// MARK: - 3. Interactive Camera Crop Modal

public struct CameraCropModalView: View {
    @Bindable var session: ProjectSession
    @State private var draftCrop: Rect01

    public init(session: ProjectSession) {
        self.session = session
        self._draftCrop = State(initialValue: session.document.camera.cropRect01)
    }

    public var body: some View {
        ZStack {
            Color.black.opacity(0.66)
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation(.easeOut(duration: 0.14)) {
                        session.isShowingCameraCropModal = false
                    }
                }

            VStack(spacing: 18) {
                HStack {
                    Label("Crop camera", systemImage: "crop")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.95))
                    Spacer()
                    Button {
                        withAnimation(.easeOut(duration: 0.14)) {
                            session.isShowingCameraCropModal = false
                        }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                    .buttonStyle(.plain)
                }

                // Live Interactive Camera Crop Frame
                ZStack {
                    GradedWebcamPortraitView(
                        preset: session.document.camera.colorGradePreset,
                        intensity: session.document.camera.colorGradeIntensity,
                        sharpen01: session.document.camera.sharpen01,
                        mirror: session.document.camera.mirror,
                        cropRect01: .full,
                        enableFaceTracking: false,
                        isCutoutMode: false
                    )
                    .frame(width: 280, height: 280)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        GeometryReader { geo in
                            let w = geo.size.width
                            let h = geo.size.height
                            let rectX = CGFloat(draftCrop.x) * w
                            let rectY = CGFloat(draftCrop.y) * h
                            let rectW = CGFloat(draftCrop.width) * w
                            let rectH = CGFloat(draftCrop.height) * h

                            ZStack(alignment: .topLeading) {
                                Color.black.opacity(0.45)
                                    .mask(
                                        ZStack {
                                            Rectangle()
                                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                .frame(width: rectW, height: rectH)
                                                .position(x: rectX + rectW * 0.5, y: rectY + rectH * 0.5)
                                                .blendMode(.destinationOut)
                                        }
                                        .compositingGroup()
                                    )

                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(Color(red: 0.58, green: 0.48, blue: 1.0), lineWidth: 2.0)
                                    .frame(width: rectW, height: rectH)
                                    .position(x: rectX + rectW * 0.5, y: rectY + rectH * 0.5)
                                    .gesture(
                                        DragGesture()
                                            .onChanged { value in
                                                let dx = Double(value.translation.width / max(1, w))
                                                let dy = Double(value.translation.height / max(1, h))
                                                let nx = max(0.0, min(1.0 - draftCrop.width, session.document.camera.cropRect01.x + dx))
                                                let ny = max(0.0, min(1.0 - draftCrop.height, session.document.camera.cropRect01.y + dy))
                                                draftCrop.x = nx
                                                draftCrop.y = ny
                                            }
                                    )
                            }
                        }
                    }
                }

                // Zoom / Crop Scale Slider
                HStack(spacing: 12) {
                    Text("Crop zoom")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(.white.opacity(0.85))

                    Slider(
                        value: Binding(
                            get: { 1.0 / max(0.35, draftCrop.width) },
                            set: { zoom in
                                let span = max(0.35, min(1.0, 1.0 / max(1.0, zoom)))
                                let cx = draftCrop.center.x
                                let cy = draftCrop.center.y
                                draftCrop = Rect01(
                                    x: max(0.0, min(1.0 - span, cx - span * 0.5)),
                                    y: max(0.0, min(1.0 - span, cy - span * 0.5)),
                                    width: span,
                                    height: span
                                )
                            }
                        ),
                        in: 1.0...2.5
                    )
                    .tint(Color(red: 0.48, green: 0.36, blue: 0.98))

                    Button("Reset") {
                        draftCrop = .full
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                }

                HStack(spacing: 10) {
                    Button {
                        withAnimation(.easeOut(duration: 0.14)) {
                            session.isShowingCameraCropModal = false
                        }
                    } label: {
                        Text("Cancel")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.88))
                            .frame(maxWidth: .infinity)
                            .frame(height: 36)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.white.opacity(0.06))
                            )
                    }
                    .buttonStyle(.plain)

                    Button {
                        session.mutate { doc in
                            doc.camera.cropRect01 = draftCrop.clamped()
                        }
                        withAnimation(.easeOut(duration: 0.14)) {
                            session.isShowingCameraCropModal = false
                        }
                    } label: {
                        Text("Apply crop")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 36)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color(red: 0.38, green: 0.26, blue: 0.96))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(22)
            .frame(width: 340)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(red: 0.09, green: 0.09, blue: 0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.6), radius: 28, y: 12)
        }
    }
}
