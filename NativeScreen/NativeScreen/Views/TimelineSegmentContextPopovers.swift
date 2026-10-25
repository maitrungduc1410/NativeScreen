import SwiftUI
import AppKit

// MARK: - 1. Clip Slice Liquid Glass Context Popover

public struct ClipSliceContextPopoverView: View {
    @Bindable var session: ProjectSession
    let sliceId: String
    let onDismiss: () -> Void

    @State private var showSpeedOptions = false

    private var slice: ClipSlice? {
        session.document.timeline.slices.first(where: { $0.id == sliceId })
    }

    private var canMergeWithNext: Bool {
        guard let idx = session.document.timeline.slices.firstIndex(where: { $0.id == sliceId }) else { return false }
        return idx + 1 < session.document.timeline.slices.count
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let currentSlice = slice {
                PopoverMenuRow(title: "Split at current time", shortcut: "C") {
                    session.splitSlice(id: sliceId, atTimelineMs: session.effectivePreviewTimelineMs)
                    onDismiss()
                }

                PopoverMenuRow(title: "Merge with next", isDisabled: !canMergeWithNext) {
                    session.mergeSliceWithNext(id: sliceId)
                    onDismiss()
                }

                PopoverMenuRow(title: "Reset trim") {
                    session.resetSliceTrim(id: sliceId)
                    onDismiss()
                }

                Divider()
                    .padding(.vertical, 3)

                // Set speed expandable row
                PopoverMenuRow(
                    title: "Set speed",
                    shortcut: String(format: "%.2gx ›", currentSlice.speed)
                ) {
                    withAnimation(.easeOut(duration: 0.14)) {
                        showSpeedOptions.toggle()
                    }
                }

                if showSpeedOptions {
                    HStack(spacing: 4) {
                        ForEach([0.5, 1.0, 1.25, 1.5, 2.0, 4.0], id: \.self) { spd in
                            let isSelected = abs(currentSlice.speed - spd) < 0.03
                            Button {
                                session.setSliceSpeed(id: sliceId, speed: spd)
                                onDismiss()
                            } label: {
                                Text(String(format: "%.2gx", spd))
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(isSelected ? .white : .secondary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 5)
                                    .background(
                                        isSelected ? Color.blue : Color.white.opacity(0.06),
                                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)
                }

                Divider()
                    .padding(.vertical, 3)

                // System audio volume slider right inside the popover
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("System audio volume")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.92))
                        Spacer()
                        Text("\(Int(round(session.document.audio.systemAudioVolume * 100)))%")
                            .font(.system(size: 13, weight: .medium).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    Slider(
                        value: Binding(
                            get: { session.document.audio.systemAudioVolume },
                            set: { v in session.mutate { $0.audio.systemAudioVolume = v } }
                        ),
                        in: 0.0...1.5
                    ) { editing in
                        if editing { session.beginInteractiveEdit() } else { session.endInteractiveEdit() }
                    }
                    .tint(.blue)
                    .controlSize(.small)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)

                Divider()
                    .padding(.vertical, 3)

                PopoverMenuRow(
                    title: currentSlice.hideCursor ? "Show mouse cursor" : "Hide mouse cursor",
                    shortcut: currentSlice.hideCursor ? "✓" : nil
                ) {
                    session.toggleSliceHideCursor(id: sliceId)
                    onDismiss()
                }

                PopoverMenuRow(
                    title: currentSlice.disableSmoothCursor ? "Enable smooth mouse movement" : "Disable smooth mouse movement",
                    shortcut: currentSlice.disableSmoothCursor ? "✓" : nil
                ) {
                    session.toggleSliceDisableSmoothCursor(id: sliceId)
                    onDismiss()
                }

                Divider()
                    .padding(.vertical, 3)

                PopoverMenuRow(
                    title: "Remove",
                    trailingSymbol: "delete.left",
                    isDestructive: true,
                    isDisabled: session.document.timeline.slices.count <= 1
                ) {
                    session.selectSlice(sliceId)
                    session.deleteSelectedSlice()
                    onDismiss()
                }

                PopoverMenuRow(
                    title: "Reset trims and cuts for all slices",
                    isDestructive: true
                ) {
                    session.resetAllSlicesTrimAndCuts()
                    onDismiss()
                }
            }
        }
        .padding(8)
        .frame(width: 268)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - 4. Output Aspect Ratio Liquid Glass Dropdown Popover ( & 4!)

public struct AspectRatioLiquidGlassPopoverView: View {
    @Bindable var session: ProjectSession
    let onDismiss: () -> Void

    private let presets: [AspectRatioPreset] = [
        .widescreen16x9,
        .square1x1,
        .classic4x3,
        .vertical9x16,
        .tall3x4,
        .portrait4x5
    ]

    public init(session: ProjectSession, onDismiss: @escaping () -> Void) {
        self.session = session
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            // 1. "Auto" Option
            let isAuto = (session.document.canvas.aspectRatioMode == .auto)
            AspectRatioOptionRow(
                title: "Auto",
                ratioText: nil,
                iconSize: nil,
                isSelected: isAuto
            ) {
                session.mutate { $0.canvas.aspectRatioMode = .auto }
                onDismiss()
            }

            Divider()
                .padding(.vertical, 3)

            // 2. Preset Options with Custom Proportional Aspect Ratio Icons
            ForEach(presets) { preset in
                let isSelected = (session.document.canvas.aspectRatioMode == .preset && session.document.canvas.aspectRatioPreset == preset)
                AspectRatioOptionRow(
                    title: preset.titleName,
                    ratioText: preset.ratioString,
                    iconSize: preset.iconSize,
                    isSelected: isSelected
                ) {
                    session.mutate {
                        $0.canvas.aspectRatioMode = .preset
                        $0.canvas.aspectRatioPreset = preset
                    }
                    onDismiss()
                }
            }
        }
        .padding(8)
        .frame(width: 196)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct AspectRatioOptionRow: View {
    let title: String
    let ratioText: String?
    let iconSize: CGSize?
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let size = iconSize {
                    ZStack {
                        RoundedRectangle(cornerRadius: 2.2, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.88), lineWidth: 1.4)
                            .frame(width: size.width, height: size.height)
                    }
                    .frame(width: 18, height: 16)
                }

                HStack(spacing: 5) {
                    Text(title)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(.white.opacity(0.95))

                    if let ratioText = ratioText {
                        Text(ratioText)
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(.white.opacity(isHovered ? 0.85 : 0.45))
                    }
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isHovered ? Color.white.opacity(0.14) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - 5. Reel Mode Liquid Glass Dropdown Popover ( from previous turn!)

public struct ReelModeLiquidGlassPopoverView: View {
    @Bindable var session: ProjectSession
    let onDismiss: () -> Void

    public init(session: ProjectSession, onDismiss: @escaping () -> Void) {
        self.session = session
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ReelOptionRow(
                title: "Disable",
                isSelected: !session.isReelModeActive
            ) {
                withAnimation(.easeInOut(duration: 0.22)) {
                    session.isReelModeActive = false
                }
                onDismiss()
            }

            Divider()
                .padding(.vertical, 3)

            ReelOptionRow(
                title: "Instagram",
                isSelected: session.isReelModeActive && session.reelPlatformStyle == .instagramReels
            ) {
                withAnimation(.easeInOut(duration: 0.22)) {
                    session.reelPlatformStyle = .instagramReels
                    session.isReelModeActive = true
                    session.mutate {
                        $0.canvas.aspectRatioMode = .preset
                        $0.canvas.aspectRatioPreset = .vertical9x16
                    }
                }
                onDismiss()
            }

            ReelOptionRow(
                title: "TikTok",
                isSelected: session.isReelModeActive && session.reelPlatformStyle == .tiktok
            ) {
                withAnimation(.easeInOut(duration: 0.22)) {
                    session.reelPlatformStyle = .tiktok
                    session.isReelModeActive = true
                    session.mutate {
                        $0.canvas.aspectRatioMode = .preset
                        $0.canvas.aspectRatioPreset = .vertical9x16
                    }
                }
                onDismiss()
            }
        }
        .padding(8)
        .frame(width: 156)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct ReelOptionRow: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 14)
                } else {
                    Color.clear
                        .frame(width: 14, height: 12)
                }

                Text(title)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.white.opacity(0.95))

                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isHovered ? Color.white.opacity(0.14) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - 6. Custom Aspect Ratio Icon & Reel Mode Phone Icon

public struct AspectIconView: View {
    public init() {}

    public var body: some View {
        Canvas { context, size in
            let outerRect = CGRect(x: 1, y: 2, width: size.width - 2, height: size.height - 4)
            let outerPath = Path(roundedRect: outerRect, cornerRadius: 2.2)
            context.stroke(outerPath, with: .color(.white.opacity(0.92)), lineWidth: 1.4)

            // Inner nested ratio lines in bottom-left corner Aspect Ratio icon!)
            var inner1 = Path()
            inner1.move(to: CGPoint(x: outerRect.minX, y: outerRect.minY + outerRect.height * 0.42))
            inner1.addLine(to: CGPoint(x: outerRect.minX + outerRect.width * 0.68, y: outerRect.minY + outerRect.height * 0.42))
            inner1.addLine(to: CGPoint(x: outerRect.minX + outerRect.width * 0.68, y: outerRect.maxY))
            context.stroke(inner1, with: .color(.white.opacity(0.85)), lineWidth: 1.2)

            var inner2 = Path()
            inner2.move(to: CGPoint(x: outerRect.minX + outerRect.width * 0.44, y: outerRect.minY + outerRect.height * 0.42))
            inner2.addLine(to: CGPoint(x: outerRect.minX + outerRect.width * 0.44, y: outerRect.maxY))
            context.stroke(inner2, with: .color(.white.opacity(0.85)), lineWidth: 1.2)
        }
        .frame(width: 16, height: 15)
    }
}

public struct ReelPhoneIconView: View {
    public var isActive: Bool

    public init(isActive: Bool) {
        self.isActive = isActive
    }

    public var body: some View {
        let color = isActive ? Color(red: 0.58, green: 0.52, blue: 1.0) : Color.white.opacity(0.88)
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                .strokeBorder(color, lineWidth: 1.4)
                .frame(width: 11, height: 15)

            RoundedRectangle(cornerRadius: 1.0, style: .continuous)
                .fill(color)
                .frame(width: 7, height: 3.5)
                .padding(.bottom, 2.2)
        }
        .frame(width: 14, height: 15)
    }
}

// MARK: - 2. Zoom Block Liquid Glass Context Popover

public struct ZoomBlockContextPopoverView: View {
    @Bindable var session: ProjectSession
    let zoomId: String
    let onDismiss: () -> Void

    private var zoom: ZoomBlock? {
        session.document.timeline.zooms.first(where: { $0.id == zoomId })
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let currentZoom = zoom {
                // Top 2-Card Presentation Selector: Classic vs Loupe
                HStack(spacing: 6) {
                    modeCardButton(
                        title: "Classic",
                        systemImage: "plus.magnifyingglass",
                        isSelected: currentZoom.presentation == .screen
                    ) {
                        session.setZoomPresentation(id: zoomId, presentation: .screen)
                    }

                    modeCardButton(
                        title: "Loupe",
                        systemImage: "sparkle.magnifyingglass",
                        isSelected: currentZoom.presentation == .loupe
                    ) {
                        session.setZoomPresentation(id: zoomId, presentation: .loupe)
                    }
                }
                .padding(.horizontal, 4)
                .padding(.top, 4)
                .padding(.bottom, 2)

                Divider()
                    .padding(.vertical, 3)

                // Interactive Zoom Level Slider (`100%` - `350%`)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Zoom level")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.92))
                        Spacer()
                        Text("\(Int(round(currentZoom.scale * 100)))%")
                            .font(.system(size: 13, weight: .medium).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    Slider(
                        value: Binding(
                            get: { currentZoom.scale },
                            set: { v in session.setZoomScale(id: zoomId, scale: v) }
                        ),
                        in: 1.1...3.5
                    ) { editing in
                        if editing { session.beginInteractiveEdit() } else { session.endInteractiveEdit() }
                    }
                    .tint(.blue)
                    .controlSize(.small)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)

                PopoverMenuRow(title: "Apply zoom level to all other zooms") {
                    session.applyZoomLevelToAllOtherZooms(fromId: zoomId)
                    onDismiss()
                }

                Divider()
                    .padding(.vertical, 3)

                PopoverMenuRow(title: "Split zoom at current time", shortcut: "C") {
                    session.splitZoom(id: zoomId, atSourceMs: session.currentSourceTimeMs)
                    onDismiss()
                }

                PopoverMenuRow(title: "Duplicate", shortcut: "⌘ D") {
                    session.duplicateZoom(id: zoomId)
                    onDismiss()
                }

                PopoverMenuRow(title: currentZoom.disabled ? "Enable" : "Disable", shortcut: "D") {
                    session.toggleZoomDisabled(id: zoomId)
                    onDismiss()
                }

                Divider()
                    .padding(.vertical, 3)

                PopoverMenuRow(title: "Copy zoom range", shortcut: "⌘ C") {
                    session.copyZoomToClipboard(id: zoomId)
                    onDismiss()
                }

                PopoverMenuRow(title: "Cut to clipboard", shortcut: "⌘ X") {
                    session.cutZoomToClipboard(id: zoomId)
                    onDismiss()
                }

                Divider()
                    .padding(.vertical, 3)

                PopoverMenuRow(
                    title: "Remove",
                    trailingSymbol: "delete.left",
                    isDestructive: true
                ) {
                    session.deleteZoom(zoomId: zoomId)
                    onDismiss()
                }
            }
        }
        .padding(8)
        .frame(width: 268)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private func modeCardButton(
        title: String,
        systemImage: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .semibold))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(isSelected ? Color(red: 0.35, green: 0.65, blue: 1.0) : .white.opacity(0.85))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                isSelected
                    ? Color.blue.opacity(0.24)
                    : Color.white.opacity(0.05),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 3. Mask Block Liquid Glass Context Popover

public struct MaskBlockContextPopoverView: View {
    @Bindable var session: ProjectSession
    let maskId: String
    let onDismiss: () -> Void

    private var mask: MaskItem? {
        for track in session.document.timeline.maskTracks {
            if let found = track.items.first(where: { $0.id == maskId }) {
                return found
            }
        }
        return nil
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let currentMask = mask {
                // Top 2-Card Mask Type Selector: Highlight vs Sensitive data
                HStack(spacing: 6) {
                    maskTypeCardButton(
                        title: "Highlight",
                        systemImage: "viewfinder.rectangular",
                        isSelected: currentMask.type == .spotlight
                    ) {
                        session.setMaskType(id: maskId, type: .spotlight)
                    }

                    maskTypeCardButton(
                        title: "Sensitive data",
                        systemImage: "eye.slash",
                        isSelected: currentMask.type == .blur
                    ) {
                        session.setMaskType(id: maskId, type: .blur)
                    }
                }
                .padding(.horizontal, 4)
                .padding(.top, 4)
                .padding(.bottom, 2)

                Divider()
                    .padding(.vertical, 3)

                PopoverMenuRow(title: "Split mask at current time", shortcut: "C") {
                    session.splitMask(id: maskId, atSourceMs: session.currentSourceTimeMs)
                    onDismiss()
                }

                PopoverMenuRow(title: currentMask.disabled ? "Enable" : "Disable", shortcut: "D") {
                    session.toggleMaskDisabled(id: maskId)
                    onDismiss()
                }

                Divider()
                    .padding(.vertical, 3)

                PopoverMenuRow(title: "Copy mask", shortcut: "⌘ C") {
                    session.copyMaskToClipboard(id: maskId)
                    onDismiss()
                }

                PopoverMenuRow(title: "Cut to clipboard", shortcut: "⌘ X") {
                    session.cutMaskToClipboard(id: maskId)
                    onDismiss()
                }

                Divider()
                    .padding(.vertical, 3)

                PopoverMenuRow(
                    title: "Remove",
                    trailingSymbol: "delete.left",
                    isDestructive: true
                ) {
                    session.deleteMask(maskId: maskId)
                    onDismiss()
                }
            }
        }
        .padding(8)
        .frame(width: 256)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private func maskTypeCardButton(
        title: String,
        systemImage: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .semibold))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(isSelected ? Color(red: 0.35, green: 0.65, blue: 1.0) : .white.opacity(0.85))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                isSelected
                    ? Color.blue.opacity(0.24)
                    : Color.white.opacity(0.05),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Shared Hover-Highlighting Menu Row

private struct PopoverMenuRow: View {
    let title: String
    var shortcut: String? = nil
    var trailingSymbol: String? = nil
    var isDestructive: Bool = false
    var isDisabled: Bool = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(textColor)

                Spacer()

                if let shortcut = shortcut {
                    Text(shortcut)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(isHovered && !isDisabled ? .white.opacity(0.9) : .secondary)
                }

                if let symbol = trailingSymbol {
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(isHovered && !isDisabled ? .white : .secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isHovered && !isDisabled ? (isDestructive ? Color.red.opacity(0.85) : Color.blue) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.40 : 1.0)
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private var textColor: Color {
        if isHovered && !isDisabled {
            return .white
        }
        return isDestructive ? Color(red: 1.0, green: 0.36, blue: 0.36) : .white.opacity(0.92)
    }
}
