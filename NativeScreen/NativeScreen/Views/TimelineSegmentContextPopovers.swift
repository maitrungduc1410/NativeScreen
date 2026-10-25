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
