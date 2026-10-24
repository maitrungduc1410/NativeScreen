import SwiftUI
import AppKit

public enum ReelPlatformStyle: String, CaseIterable, Identifiable, Sendable {
    case tiktok = "TikTok"
    case instagramReels = "Reels"

    public var id: String { rawValue }
}

// MARK: - 1. Reel Mode Safe-Zone Preview Overlay (TikTok & Instagram Reels & 2)

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
            .allowsHitTesting(false)

            // Main Overlay UI
            VStack(spacing: 0) {
                // Dynamic Island Pill
                Capsule()
                    .fill(Color.black)
                    .frame(width: 96 * scale, height: 26 * scale)
                    .padding(.top, 12 * scale)
                    .allowsHitTesting(false)

                // Top Header Bar (Switchable between TikTok & Instagram Reels)
                if session.reelPlatformStyle == .tiktok {
                    HStack {
                        Image(systemName: "play.tv")
                            .font(.system(size: 16 * scale, weight: .semibold))
                            .foregroundStyle(.white)

                        Spacer()

                        HStack(spacing: 14 * scale) {
                            Button {
                                session.reelPlatformStyle = .instagramReels
                            } label: {
                                Text("Following")
                                    .font(.system(size: 13 * scale, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.65))
                            }
                            .buttonStyle(.plain)
                            .help("Switch to Instagram Reels overlay")

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
                        Button {
                            session.reelPlatformStyle = .tiktok
                        } label: {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 16 * scale, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                        .help("Switch to TikTok overlay")

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
                    // Bottom-Left Creator Info
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
                    .allowsHitTesting(false)

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

                            // Vinyl disc
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
                    .allowsHitTesting(false)
                }
                .padding(.horizontal, 16 * scale)
                .padding(.bottom, 18 * scale)
            }
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
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

// MARK: - 2. Interactive Crop Modal Editor

public struct InteractiveCropModalOverlayView: View {
    @Bindable var session: ProjectSession
    let uncroppedScreenImage: NSImage?

    @State private var draftCrop01: Rect01
    @State private var dragStartCrop01: Rect01?

    public init(session: ProjectSession, uncroppedScreenImage: NSImage?) {
        self.session = session
        self.uncroppedScreenImage = uncroppedScreenImage
        self._draftCrop01 = State(initialValue: session.document.canvas.cropRect01)
    }

    private var sourcePixelWidth: Double {
        Double(max(640, session.metadata.captureTarget.pixelSize.width)) / max(1.0, session.metadata.captureTarget.scaleFactor)
    }

    private var sourcePixelHeight: Double {
        Double(max(400, session.metadata.captureTarget.pixelSize.height)) / max(1.0, session.metadata.captureTarget.scaleFactor)
    }

    public var body: some View {
        ZStack {
            Color.black.opacity(0.65)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Top Control Bar (Red Close Dot + Size W×H + Select Preset + Position X,Y + Reset)
                HStack(spacing: 12) {
                    // Traffic light dots (Red closes modal)
                    HStack(spacing: 7) {
                        Button {
                            session.isCropModalActive = false
                        } label: {
                            Circle()
                                .fill(Color(red: 1.0, green: 0.37, blue: 0.34))
                                .frame(width: 12, height: 12)
                        }
                        .buttonStyle(.plain)

                        Circle()
                            .fill(Color.white.opacity(0.14))
                            .frame(width: 12, height: 12)
                        Circle()
                            .fill(Color.white.opacity(0.14))
                            .frame(width: 12, height: 12)
                    }

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
                .padding(.horizontal, 18)
                .padding(.vertical, 14)

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
                            // Rule of Thirds Grid Lines (Dashed like)
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
                        session.isCropModalActive = false
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
                        session.isCropModalActive = false
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
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(red: 0.14, green: 0.14, blue: 0.17))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.65), radius: 30, y: 12)
            .padding(24)
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
