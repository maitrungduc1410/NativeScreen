import SwiftUI
import AppKit
import UniformTypeIdentifiers

public enum ReelPlatformStyle: String, CaseIterable, Identifiable, Sendable {
    case instagramReels = "Instagram"
    case tiktok = "TikTok"

    public var id: String { rawValue }
}

public enum StillFrameResolution: String, CaseIterable, Identifiable, Sendable {
    case p480 = "480P"
    case p720 = "720P"
    case p1080 = "1080P"
    case k2 = "2K"
    case k4 = "4K"
    case k8 = "8K"

    public var id: String { rawValue }

    public var pixelHeight: Double {
        switch self {
        case .p480: return 480
        case .p720: return 720
        case .p1080: return 1080
        case .k2: return 1440
        case .k4: return 2160
        case .k8: return 4320
        }
    }
}

public enum StillFrameFormat: String, CaseIterable, Identifiable, Sendable {
    case png = "PNG"
    case jpeg = "JPEG"

    public var id: String { rawValue }

    public var fileExtension: String {
        switch self {
        case .png: return "png"
        case .jpeg: return "jpg"
        }
    }
}

// MARK: - 1. Reel Mode Safe-Zone Preview Overlay (TikTok & Instagram Reels — Smooth Show/Hide & Switch)

public struct ReelModeSafeZoneOverlayView: View {
    @Bindable var session: ProjectSession
    let canvasSize: CGSize

    public init(session: ProjectSession, canvasSize: CGSize) {
        self.session = session
        self.canvasSize = canvasSize
    }

    public var body: some View {
        let scale = max(0.55, min(1.25, canvasSize.height / 680.0))

        ZStack {
            // Top & Bottom subtle vignette gradients like TikTok / Instagram Reels
            VStack(spacing: 0) {
                LinearGradient(
                    colors: [Color.black.opacity(0.45), Color.clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 110 * scale)

                Spacer()

                LinearGradient(
                    colors: [Color.clear, Color.black.opacity(0.58)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 180 * scale)
            }

            // Main Overlay UI
            VStack(spacing: 0) {
                // Dynamic Island Pill
                Capsule()
                    .fill(Color.black)
                    .frame(width: 96 * scale, height: 26 * scale)
                    .padding(.top, 12 * scale)

                // Top Header Bar (TikTok vs Instagram Reels)
                if session.reelPlatformStyle == .tiktok {
                    HStack {
                        Image(systemName: "play.tv")
                            .font(.system(size: 16 * scale, weight: .semibold))
                            .foregroundStyle(.white)

                        Spacer()

                        HStack(spacing: 14 * scale) {
                            Text("Following")
                                .font(.system(size: 13 * scale, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.65))

                            VStack(spacing: 3 * scale) {
                                Text("For You")
                                    .font(.system(size: 13 * scale, weight: .bold))
                                    .foregroundStyle(.white)
                                Capsule()
                                    .fill(Color.white)
                                    .frame(width: 28 * scale, height: 2.5 * scale)
                            }
                        }

                        Spacer()

                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 16 * scale, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 18 * scale)
                    .padding(.top, 10 * scale)
                } else {
                    HStack {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 16 * scale, weight: .semibold))
                            .foregroundStyle(.white)

                        Spacer()

                        Text("Reels")
                            .font(.system(size: 15 * scale, weight: .bold))
                            .foregroundStyle(.white)

                        Spacer()

                        Image(systemName: "camera")
                            .font(.system(size: 16 * scale, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 18 * scale)
                    .padding(.top, 10 * scale)
                }

                Spacer()

                // Bottom-Left Caption & Right-Side Social Action Column
                HStack(alignment: .bottom, spacing: 10 * scale) {
                    VStack(alignment: .leading, spacing: 8 * scale) {
                        if session.reelPlatformStyle == .instagramReels {
                            HStack(spacing: 8 * scale) {
                                Circle()
                                    .fill(
                                        LinearGradient(
                                            colors: [Color(red: 0.48, green: 0.36, blue: 1.0), Color.indigo],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                                    .frame(width: 28 * scale, height: 28 * scale)
                                    .overlay(Circle().stroke(Color.white, lineWidth: 1.5))

                                Text("nativescreen")
                                    .font(.system(size: 12.5 * scale, weight: .bold))
                                    .foregroundStyle(.white)

                                Text("Follow")
                                    .font(.system(size: 11 * scale, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 10 * scale)
                                    .padding(.vertical, 3.5 * scale)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6 * scale, style: .continuous)
                                            .strokeBorder(.white.opacity(0.85), lineWidth: 1)
                                    )
                            }

                            Text("Beautiful screen recordings, in minutes. Made on a Mac.")
                                .font(.system(size: 11.5 * scale, weight: .medium))
                                .foregroundStyle(.white.opacity(0.95))
                                .lineLimit(2)

                            HStack(spacing: 5 * scale) {
                                Image(systemName: "music.note")
                                    .font(.system(size: 10.5 * scale))
                                Text("Original audio")
                                    .font(.system(size: 11 * scale, weight: .medium))
                            }
                            .foregroundStyle(.white.opacity(0.90))
                        } else {
                            Text("@nativescreen")
                                .font(.system(size: 13 * scale, weight: .bold))
                                .foregroundStyle(.white)

                            Text("Beautiful screen recordings, in minutes. #mac #productivity")
                                .font(.system(size: 11.5 * scale, weight: .medium))
                                .foregroundStyle(.white.opacity(0.95))
                                .lineLimit(2)

                            HStack(spacing: 5 * scale) {
                                Image(systemName: "music.note")
                                    .font(.system(size: 10.5 * scale))
                                Text("original sound — NativeScreen")
                                    .font(.system(size: 11 * scale, weight: .medium))
                            }
                            .foregroundStyle(.white.opacity(0.90))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    // Right-Side Action Icons Column
                    VStack(spacing: 16 * scale) {
                        if session.reelPlatformStyle == .tiktok {
                            Circle()
                                .fill(
                                    LinearGradient(
                                        colors: [Color(red: 0.48, green: 0.36, blue: 1.0), Color.indigo],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .frame(width: 40 * scale, height: 40 * scale)
                                .overlay(Circle().stroke(Color.white, lineWidth: 1.5))

                            reelMetricIcon(systemName: "heart.fill", label: "25.1K", scale: scale)
                            reelMetricIcon(systemName: "bubble.right.fill", label: "1,862", scale: scale)
                            reelMetricIcon(systemName: "bookmark.fill", label: "3,420", scale: scale)
                            reelMetricIcon(systemName: "arrowshape.turn.up.right.fill", label: "971", scale: scale)

                            ZStack {
                                Circle()
                                    .fill(Color.black.opacity(0.85))
                                    .frame(width: 36 * scale, height: 36 * scale)
                                Circle()
                                    .fill(Color(red: 0.44, green: 0.34, blue: 0.98))
                                    .frame(width: 14 * scale, height: 14 * scale)
                            }
                        } else {
                            reelMetricIcon(systemName: "heart", label: "2,504", scale: scale)
                            reelMetricIcon(systemName: "bubble.right", label: "186", scale: scale)
                            reelMetricIcon(systemName: "arrow.2.squarepath", label: "342", scale: scale)
                            reelMetricIcon(systemName: "paperplane", label: "97", scale: scale)

                            Image(systemName: "ellipsis")
                                .font(.system(size: 15 * scale, weight: .bold))
                                .foregroundStyle(.white)

                            RoundedRectangle(cornerRadius: 6 * scale, style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [Color(red: 0.48, green: 0.36, blue: 1.0), Color.indigo],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .frame(width: 26 * scale, height: 26 * scale)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6 * scale, style: .continuous)
                                        .strokeBorder(Color.white, lineWidth: 1.5)
                                )
                        }
                    }
                }
                .padding(.horizontal, 16 * scale)
                .padding(.bottom, 18 * scale)
            }
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .allowsHitTesting(false)
        .animation(.easeInOut(duration: 0.20), value: session.reelPlatformStyle)
    }

    @ViewBuilder
    private func reelMetricIcon(systemName: String, label: String, scale: CGFloat) -> some View {
        VStack(spacing: 3 * scale) {
            Image(systemName: systemName)
                .font(.system(size: 20 * scale, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.35), radius: 3)
            Text(label)
                .font(.system(size: 10 * scale, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.35), radius: 2)
        }
    }
}

// MARK: - 2. Standalone Movable Crop Window View (Own `NSWindow` tied to Project Session)

public struct StandaloneCropWindowView: View {
    @Bindable var session: ProjectSession
    let onCloseWindow: () -> Void

    @State private var uncroppedScreenImage: NSImage?
    @State private var draftCrop01: Rect01
    @State private var dragStartCrop01: Rect01?

    public init(session: ProjectSession, onCloseWindow: @escaping () -> Void) {
        self.session = session
        self.onCloseWindow = onCloseWindow
        self._draftCrop01 = State(initialValue: session.document.canvas.cropRect01)
    }

    private var sourcePixelWidth: Double {
        Double(max(640, session.metadata.captureTarget.pixelSize.width)) / max(1.0, session.metadata.captureTarget.scaleFactor)
    }

    private var sourcePixelHeight: Double {
        Double(max(400, session.metadata.captureTarget.pixelSize.height)) / max(1.0, session.metadata.captureTarget.scaleFactor)
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Top Unified Header Bar (Left padding for native `NSWindow` traffic lights + Size W×H + Select Preset + Position X,Y + Reset)
            HStack(spacing: 12) {
                Spacer()
                    .frame(width: 68) // Space for native macOS traffic lights `🔴 🟡 🟢`

                Spacer()

                // Size W × H
                HStack(spacing: 6) {
                    Text("Size")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)

                    cropDimensionBadge("\(Int(round(draftCrop01.width * sourcePixelWidth)))")
                    Text("×")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
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
                    Button("9:16 Vertical") { applyAspectCrop(ratio: 9.0 / 16.0) }
                    Button("1:1 Square") { applyAspectCrop(ratio: 1.0) }
                    Button("4:3 Classic") { applyAspectCrop(ratio: 4.0 / 3.0) }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "rectangle.dashed")
                            .font(.system(size: 12))
                        Text("Select…")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                // Position X, Y
                HStack(spacing: 6) {
                    Text("Position")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)

                    cropDimensionBadge("\(Int(round(draftCrop01.x * sourcePixelWidth)))")
                    cropDimensionBadge("\(Int(round(draftCrop01.y * sourcePixelHeight)))")
                }

                // Reset Button
                Button {
                    withAnimation(.spring(response: 0.22, dampingFraction: 0.86)) {
                        draftCrop01 = .full
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "crop")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Reset")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(.white.opacity(draftCrop01 == .full ? 0.35 : 0.92))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .disabled(draftCrop01 == .full)

                Spacer()
            }
            .padding(.horizontal, 16)
            .frame(height: 52)

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
                    // Base Source Preview
                    Group {
                        if let img = uncroppedScreenImage {
                            Image(nsImage: img)
                                .resizable()
                                .interpolation(.high)
                        } else {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color(red: 0.08, green: 0.09, blue: 0.13))
                        }
                    }
                    .frame(width: fitted.width, height: fitted.height)
                    .position(x: fitted.midX, y: fitted.midY)

                    // Dimmed Outside Mask
                    Path { path in
                        path.addRect(fitted)
                        path.addRect(cropRect)
                    }
                    .fill(Color.black.opacity(0.62), style: FillStyle(eoFill: true))
                    .allowsHitTesting(false)

                    // Interactive Crop Box + Rule of Thirds Grid + 8 Handles
                    ZStack {
                        Canvas { context, size in
                            let strokeStyle = StrokeStyle(lineWidth: 1, dash: [4, 4])
                            for i in 1...2 {
                                let frac = CGFloat(i) / 3.0
                                var vPath = Path()
                                vPath.move(to: CGPoint(x: size.width * frac, y: 0))
                                vPath.addLine(to: CGPoint(x: size.width * frac, y: size.height))
                                context.stroke(vPath, with: .color(.white.opacity(0.28)), style: strokeStyle)

                                var hPath = Path()
                                hPath.move(to: CGPoint(x: 0, y: size.height * frac))
                                hPath.addLine(to: CGPoint(x: size.width, y: size.height * frac))
                                context.stroke(hPath, with: .color(.white.opacity(0.28)), style: strokeStyle)
                            }
                        }
                        .allowsHitTesting(false)

                        Rectangle()
                            .strokeBorder(Color.white.opacity(0.85), lineWidth: 1.5)
                            .background(Color.white.opacity(0.001))
                            .contentShape(Rectangle())
                            .gesture(
                                DragGesture(minimumDistance: 1, coordinateSpace: .named("cropModalSpace"))
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
                        cropHandle(fitted: fitted, xMode: -1, yMode: -1)
                            .position(x: 0, y: 0)
                        cropHandle(fitted: fitted, xMode: 0, yMode: -1)
                            .position(x: cropRect.width * 0.5, y: 0)
                        cropHandle(fitted: fitted, xMode: 1, yMode: -1)
                            .position(x: cropRect.width, y: 0)

                        cropHandle(fitted: fitted, xMode: -1, yMode: 0)
                            .position(x: 0, y: cropRect.height * 0.5)
                        cropHandle(fitted: fitted, xMode: 1, yMode: 0)
                            .position(x: cropRect.width, y: cropRect.height * 0.5)

                        cropHandle(fitted: fitted, xMode: -1, yMode: 1)
                            .position(x: 0, y: cropRect.height)
                        cropHandle(fitted: fitted, xMode: 0, yMode: 1)
                            .position(x: cropRect.width * 0.5, y: cropRect.height)
                        cropHandle(fitted: fitted, xMode: 1, yMode: 1)
                            .position(x: cropRect.width, y: cropRect.height)
                    }
                    .frame(width: cropRect.width, height: cropRect.height)
                    .position(x: cropRect.midX, y: cropRect.midY)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .coordinateSpace(name: "cropModalSpace")
            }
            .padding(.horizontal, 28)

            // Bottom Confirm / Discard Buttons
            HStack(spacing: 12) {
                Button {
                    session.mutate { doc in
                        doc.canvas.cropRect01 = draftCrop01.clamped()
                    }
                    onCloseWindow()
                } label: {
                    HStack(spacing: 6) {
                        Text("Confirm changes")
                            .font(.system(size: 13, weight: .semibold))
                        Image(systemName: "return")
                            .font(.system(size: 11, weight: .bold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(
                        Color(red: 0.40, green: 0.28, blue: 0.98),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)

                Button {
                    onCloseWindow()
                } label: {
                    Text("Discard changes")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.88))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(
                            Color.white.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }
            .padding(.vertical, 18)
        }
        .background(Color(red: 0.14, green: 0.14, blue: 0.17))
        .preferredColorScheme(.dark)
        .task {
            draftCrop01 = session.document.canvas.cropRect01
            uncroppedScreenImage = await session.extractRawSourceFrameNSImage()
        }
    }

    @ViewBuilder
    private func cropDimensionBadge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold).monospacedDigit())
            .foregroundStyle(.white)
            .frame(minWidth: 46)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
            )
    }

    @ViewBuilder
    private func cropHandle(fitted: CGRect, xMode: Int, yMode: Int) -> some View {
        Circle()
            .fill(Color(red: 0.16, green: 0.16, blue: 0.20))
            .frame(width: 11, height: 11)
            .overlay(Circle().stroke(Color.white, lineWidth: 2))
            .shadow(color: .black.opacity(0.45), radius: 2)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named("cropModalSpace"))
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
        let availW = max(120, container.width - 24)
        let availH = max(120, container.height - 16)
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

// MARK: - 3. CapCut-Style "Export still frames" Modal

public struct ExportStillFrameModalView: View {
    @Bindable var session: ProjectSession
    let onDismiss: () -> Void

    @State private var frameName: String = ""
    @State private var exportDirectoryURL: URL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
    @State private var selectedResolution: StillFrameResolution = .k2
    @State private var selectedFormat: StillFrameFormat = .png
    @State private var previewImage: NSImage?
    @State private var isExporting: Bool = false

    private let savedExportDirKey = "NativeScreen.StillFrame.ExportDir"

    public init(session: ProjectSession, onDismiss: @escaping () -> Void) {
        self.session = session
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Top Header Title
            Text("Export still frames")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white.opacity(0.92))
                .padding(.horizontal, 22)
                .padding(.vertical, 16)

            Divider()

            // Main Body: Left Live Frame Preview + Right Options Form
            HStack(alignment: .top, spacing: 28) {
                // Left: Composited Still Frame Preview
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.black.opacity(0.45))

                    if let img = previewImage {
                        Image(nsImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .padding(8)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                .frame(width: 240, height: 310)

                // Right: Options Form (Name, Export to, Resolution, Format)
                VStack(alignment: .leading, spacing: 18) {
                    // 1. Name
                    HStack(spacing: 16) {
                        Text("Name")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.85))
                            .frame(width: 96, alignment: .leading)

                        TextField("Frame name", text: $frameName)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                            )
                    }

                    // 2. Export to (Path + Folder Picker Button)
                    HStack(spacing: 16) {
                        Text("Export to")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.85))
                            .frame(width: 96, alignment: .leading)

                        HStack(spacing: 6) {
                            Text(exportDirectoryURL.path)
                                .font(.system(size: 12.5, weight: .regular))
                                .foregroundStyle(.white.opacity(0.85))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                                )

                            Button {
                                chooseExportDirectory()
                            } label: {
                                Image(systemName: "folder")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.9))
                                    .frame(width: 34, height: 32)
                                    .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    // 3. Resolution (`480P`, `720P`, `1080P`, `2K`, `4K`, `8K` — Clean dropdown matching Export Video's Frame rate menu!)
                    HStack(spacing: 16) {
                        Text("Resolution")
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(.white.opacity(0.85))
                            .frame(width: 96, alignment: .leading)

                        Menu {
                            ForEach(StillFrameResolution.allCases) { res in
                                Button {
                                    selectedResolution = res
                                } label: {
                                    HStack {
                                        if selectedResolution == res {
                                            Image(systemName: "checkmark")
                                        }
                                        Text(res.rawValue)
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Text(selectedResolution.rawValue)
                                    .font(.system(size: 13.5, weight: .regular).monospacedDigit())
                                    .foregroundStyle(.white.opacity(0.95))
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 10.5, weight: .regular))
                                    .foregroundStyle(.white.opacity(0.65))
                                    .padding(.leading, 4)
                            }
                            .padding(.horizontal, 14)
                            .frame(height: 36)
                            .background(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(Color.white.opacity(0.04))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                        .fixedSize()

                        Spacer()
                    }

                    // 4. Format (`PNG` | `JPEG` — 2 toggle pill buttons)
                    HStack(spacing: 16) {
                        Text("Format")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.85))
                            .frame(width: 96, alignment: .leading)

                        HStack(spacing: 6) {
                            ForEach(StillFrameFormat.allCases) { fmt in
                                let isSelected = (selectedFormat == fmt)
                                Button {
                                    withAnimation(.easeOut(duration: 0.14)) {
                                        selectedFormat = fmt
                                    }
                                } label: {
                                    Text(fmt.rawValue)
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(.white.opacity(isSelected ? 0.98 : 0.82))
                                        .padding(.horizontal, 18)
                                        .frame(height: 36)
                                        .background(
                                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                                .fill(Color.white.opacity(isSelected ? 0.08 : 0.035))
                                        )
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                                .strokeBorder(
                                                    isSelected
                                                        ? Color(red: 0.50, green: 0.44, blue: 0.78).opacity(0.88)
                                                        : Color.white.opacity(0.05),
                                                    lineWidth: 1.0
                                                )
                                        )
                                        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                                }
                                .buttonStyle(.plain)
                            }
                            Spacer()
                        }
                    }
                }
                .padding(.top, 10)
            }
            .padding(24)

            Spacer(minLength: 8)

            // Bottom Action Bar (`Cancel` + Theme Purple `Export`)
            HStack(spacing: 12) {
                Spacer()

                Button {
                    onDismiss()
                } label: {
                    Text("Cancel")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.88))
                        .frame(width: 88, height: 34)
                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)

                Button {
                    performExportStillFrame()
                } label: {
                    Text(isExporting ? "Exporting…" : "Export")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 92, height: 34)
                        .background(
                            Color(red: 0.302, green: 0.184, blue: 0.961),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
                .disabled(isExporting)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
        }
        .frame(width: 660, height: 460)
        .background(Color(red: 0.08, green: 0.08, blue: 0.10))
        .preferredColorScheme(.dark)
        .task {
            let totalSec = Int(session.effectivePreviewTimelineMs / 1000.0)
            frameName = "\(session.document.name)(\(totalSec)s)"

            if let savedPath = UserDefaults.standard.string(forKey: savedExportDirKey),
               FileManager.default.fileExists(atPath: savedPath) {
                exportDirectoryURL = URL(fileURLWithPath: savedPath, isDirectory: true)
            }

            if let cgImg = await session.renderCurrentCompositedCGImage(targetHeight: 900.0) {
                previewImage = NSImage(cgImage: cgImg, size: NSSize(width: cgImg.width, height: cgImg.height))
            }
        }
    }

    private func chooseExportDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = exportDirectoryURL
        panel.prompt = "Select Folder"

        if panel.runModal() == .OK, let url = panel.url {
            exportDirectoryURL = url
            UserDefaults.standard.set(url.path, forKey: savedExportDirKey)
        }
    }

    private func performExportStillFrame() {
        let cleanName = frameName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let finalBaseName = cleanName.isEmpty ? "\(session.document.name)-frame" : cleanName
        let outURL = exportDirectoryURL.appendingPathComponent("\(finalBaseName).\(selectedFormat.fileExtension)")

        // Prompt user before overwriting an existing file in the destination folder (matching NSSavePanel's native caution alert + destructive red Replace button!)
        if FileManager.default.fileExists(atPath: outURL.path) {
            let alert = NSAlert()
            alert.alertStyle = .critical
            if let cautionIcon = NSImage(named: NSImage.cautionName) {
                alert.icon = cautionIcon
            }
            alert.messageText = "“\(outURL.lastPathComponent)” already exists. Do you want to replace it?"
            let folderName = exportDirectoryURL.lastPathComponent
            alert.informativeText = folderName == "Desktop"
                ? "A file or folder with the same name already exists on the Desktop. Replacing it will overwrite its current contents."
                : "A file or folder with the same name already exists in the folder \(folderName). Replacing it will overwrite its current contents."
            let replaceBtn = alert.addButton(withTitle: "Replace")
            replaceBtn.hasDestructiveAction = true
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        isExporting = true
        let targetH = selectedResolution.pixelHeight
        let format = selectedFormat

        Task {
            if let cgImg = await session.renderCurrentCompositedCGImage(targetHeight: targetH) {
                let bitmap = NSBitmapImageRep(cgImage: cgImg)
                let data: Data?
                switch format {
                case .png:
                    data = bitmap.representation(using: .png, properties: [:])
                case .jpeg:
                    data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.92])
                }
                if let fileData = data {
                    try? fileData.write(to: outURL, options: .atomic)
                    NSWorkspace.shared.activateFileViewerSelecting([outURL])
                }
            }
            isExporting = false
            onDismiss()
        }
    }
}
