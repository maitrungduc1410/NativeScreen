import SwiftUI
import AppKit

/// NativeScreen-grade Multi-Track NLE Timeline:
/// - Universal Interactive Split Tool (`✂️` splits Clips, Zooms, AND Blur/Spotlight Masks at cursor position)
/// - Left & Right Edge Resize Handles (`NSCursor.resizeLeftRight`) on every block
/// - Non-overlapping neighbor clamping on Zoom and Mask tracks
/// - Fixed-interval jitter-free Time Ruler + Trackpad Pinch-to-Zoom (`MagnifyGesture`)
/// - Icon-only toolbar with tooltips + `Delete`/`Backspace` & `ESC` hotkeys + Context Menus
public struct MultiTrackTimelineView: View {
    @Bindable var session: ProjectSession
    @State private var timelineZoom: Double = 1.0
    @State private var pinchBaseZoom: Double?

    public init(session: ProjectSession) {
        self.session = session
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Sleek Icon-Only Action Bar (style)
            HStack(spacing: 8) {
                // 1. Universal Split / Blade Tool Toggle (`✂️`)
                Button {
                    session.isSplitModeActive.toggle()
                } label: {
                    Image(systemName: "scissors")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(session.isSplitModeActive ? .white : .secondary)
                        .frame(width: 28, height: 26)
                        .background(
                            session.isSplitModeActive
                                ? Color(red: 0.48, green: 0.38, blue: 0.96)
                                : Color.white.opacity(0.05),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
                .help("Split Tool (Click any Clip, Zoom, or Mask block to split • Press ESC to exit)")

                Divider()
                    .frame(height: 16)

                // 2. Add Zoom Block Icon Button
                iconActionButton(
                    systemImage: "plus.magnifyingglass",
                    tooltip: "Add Zoom at Playhead"
                ) {
                    session.addZoomAtPlayhead()
                }

                // 3. Add Blur Mask Icon Button
                iconActionButton(
                    systemImage: "eye.slash.fill",
                    tooltip: "Add Blur Mask at Playhead"
                ) {
                    session.addMaskAtPlayhead(type: .blur, style: .gaussian)
                }

                // 4. Add Spotlight Mask Icon Button
                iconActionButton(
                    systemImage: "flashlight.on.fill",
                    tooltip: "Add Spotlight Mask at Playhead"
                ) {
                    session.addMaskAtPlayhead(type: .spotlight, style: .dim)
                }

                // 5. Add Parallel Mask Track Row Icon Button
                iconActionButton(
                    systemImage: "rectangle.stack.badge.plus",
                    tooltip: "Add New Parallel Mask Track"
                ) {
                    session.addEmptyMaskTrack()
                }

                // 6. Delete Selected Item Icon Button
                if session.selectedMaskId != nil || session.selectedZoomId != nil || (session.selectedSliceId != nil && session.document.timeline.slices.count > 1) {
                    iconActionButton(
                        systemImage: "trash",
                        tooltip: "Delete Selected Item (Delete / Backspace)"
                    ) {
                        session.deleteSelectedTimelineItem()
                    }
                }

                if session.isSplitModeActive {
                    Text("Split Mode Active — Click any Clip, Zoom, or Mask block to cut (ESC to exit)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color(red: 0.65, green: 0.56, blue: 1.0))
                        .padding(.leading, 6)
                }

                Spacer()

                // Timeline Zoom Slider (`1x` - `6x`)
                HStack(spacing: 6) {
                    Text(String(format: "%.1fx", timelineZoom))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)

                    Slider(value: $timelineZoom, in: 1.0...6.0)
                        .frame(width: 96)
                        .controlSize(.mini)
                        .help("Timeline Zoom (or pinch with 2 fingers on trackpad)")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(Color(red: 0.06, green: 0.06, blue: 0.08))

            Divider()

            // Main Multi-Track Canvas Area
            GeometryReader { outerGeo in
                let labelColumnWidth: CGFloat = 86
                let baseTrackWidth = max(320, outerGeo.size.width - labelColumnWidth - 28)
                let contentWidth = baseTrackWidth * CGFloat(timelineZoom)
                let totalTimelineMs = max(1000.0, session.timeMapper.totalTimelineDurationMs)
                let sourceDurationMs = max(1000.0, session.metadata.durationMs)

                ScrollView([.horizontal, .vertical], showsIndicators: true) {
                    ZStack(alignment: .topLeading) {
                        VStack(alignment: .leading, spacing: 7) {
                            // 1. Smooth Fixed-Interval Time Ruler
                            HStack(spacing: 0) {
                                Color.clear
                                    .frame(width: labelColumnWidth, height: 22)

                                SmoothTimeRulerView(
                                    totalDurationMs: totalTimelineMs,
                                    width: contentWidth
                                ) { seekMs in
                                    session.isPlaying = false
                                    session.seek(toTimelineMs: seekMs)
                                }
                            }
                            .frame(height: 22)

                            // 2. Screen Clip Track (Warm Amber-Gold
                            HStack(spacing: 0) {
                                Text("Clip")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(.secondary.opacity(0.8))
                                    .frame(width: labelColumnWidth, alignment: .leading)

                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .fill(Color.white.opacity(0.025))

                                    ForEach(session.timeMapper.mappedSlices, id: \.slice.id) { mapped in
                                        let xStart = CGFloat(mapped.timelineStartMs / totalTimelineMs) * contentWidth
                                        let blockW = max(16.0, CGFloat((mapped.timelineEndMs - mapped.timelineStartMs) / totalTimelineMs) * contentWidth)
                                        let isSelected = (session.selectedSliceId == mapped.slice.id && session.selectedZoomId == nil && session.selectedMaskId == nil)

                                        TimelineInteractiveSegmentView(
                                            topTitle: "Clip",
                                            subtitle: formatClipSubtitle(durationMs: mapped.slice.timelineDurationMs, speed: mapped.slice.speed),
                                            gradientColors: [
                                                Color(red: 0.85, green: 0.53, blue: 0.16),
                                                Color(red: 0.70, green: 0.40, blue: 0.09)
                                            ],
                                            isSelected: isSelected,
                                            isSplitMode: session.isSplitModeActive,
                                            xOffset: xStart,
                                            width: blockW,
                                            height: 36,
                                            totalWidth: contentWidth,
                                            totalDurationMs: sourceDurationMs,
                                            startMs: mapped.slice.sourceStartMs,
                                            endMs: mapped.slice.sourceEndMs,
                                            allowDragMove: false,
                                            onSelect: {
                                                session.selectSlice(mapped.slice.id)
                                            },
                                            onSplitAtFraction: { localFraction in
                                                let clickedTimelineMs = mapped.timelineStartMs + localFraction * (mapped.timelineEndMs - mapped.timelineStartMs)
                                                session.splitSlice(id: mapped.slice.id, atTimelineMs: clickedTimelineMs)
                                            },
                                            onBeginInteractive: {
                                                session.beginInteractiveEdit()
                                            },
                                            onChangeRange: { newStart, newEnd in
                                                session.updateSliceSourceRange(
                                                    id: mapped.slice.id,
                                                    newSourceStartMs: newStart,
                                                    newSourceEndMs: newEnd
                                                )
                                            },
                                            onEndInteractive: {
                                                session.endInteractiveEdit()
                                            },
                                            onDelete: {
                                                session.selectSlice(mapped.slice.id)
                                                session.deleteSelectedSlice()
                                            }
                                        )
                                    }
                                }
                                .frame(width: contentWidth, height: 36)
                            }

                            // 3. Auto-Zoom Track (Electric Violet
                            HStack(spacing: 0) {
                                Text("Zoom")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(.secondary.opacity(0.8))
                                    .frame(width: labelColumnWidth, alignment: .leading)

                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .fill(Color.white.opacity(0.025))

                                    ForEach(session.document.timeline.zooms) { zoom in
                                        let xStart = CGFloat(zoom.sourceStartMs / sourceDurationMs) * contentWidth
                                        let blockW = max(18.0, CGFloat((zoom.sourceEndMs - zoom.sourceStartMs) / sourceDurationMs) * contentWidth)
                                        let isSelected = (session.selectedZoomId == zoom.id)

                                        TimelineInteractiveSegmentView(
                                            topTitle: "Zoom",
                                            subtitle: String(format: "🔍 %.1fx  %@", zoom.scale, zoom.mode == .followCursor ? "Auto" : "Manual"),
                                            gradientColors: zoom.disabled
                                                ? [Color.gray.opacity(0.45), Color.gray.opacity(0.35)]
                                                : [
                                                    Color(red: 0.45, green: 0.35, blue: 0.92),
                                                    Color(red: 0.36, green: 0.26, blue: 0.78)
                                                ],
                                            isSelected: isSelected,
                                            isSplitMode: session.isSplitModeActive,
                                            xOffset: xStart,
                                            width: blockW,
                                            height: 34,
                                            totalWidth: contentWidth,
                                            totalDurationMs: sourceDurationMs,
                                            startMs: zoom.sourceStartMs,
                                            endMs: zoom.sourceEndMs,
                                            allowDragMove: true,
                                            onSelect: {
                                                session.selectZoom(zoom.id)
                                            },
                                            onSplitAtFraction: { localFraction in
                                                let splitSourceMs = zoom.sourceStartMs + localFraction * (zoom.sourceEndMs - zoom.sourceStartMs)
                                                session.splitZoom(id: zoom.id, atSourceMs: splitSourceMs)
                                            },
                                            onBeginInteractive: {
                                                session.beginInteractiveEdit()
                                            },
                                            onChangeRange: { newStart, newEnd in
                                                session.updateZoomRange(id: zoom.id, newStartMs: newStart, newEndMs: newEnd)
                                            },
                                            onEndInteractive: {
                                                session.endInteractiveEdit()
                                            },
                                            onDelete: {
                                                session.deleteZoom(zoomId: zoom.id)
                                            }
                                        )
                                    }
                                }
                                .frame(width: contentWidth, height: 34)
                            }

                            // 4. Unlimited Parallel Mask Tracks (Rose-Plum / Teal Pills)
                            ForEach(Array(session.document.timeline.maskTracks.enumerated()), id: \.element.id) { index, track in
                                HStack(spacing: 0) {
                                    HStack(spacing: 4) {
                                        Text(index == 0 ? "Masks" : "Masks \(index + 1)")
                                            .font(.system(size: 10, weight: .medium))
                                            .foregroundStyle(.secondary.opacity(0.8))
                                            .lineLimit(1)

                                        if session.document.timeline.maskTracks.count > 1 || !track.items.isEmpty {
                                            Button {
                                                session.deleteMaskTrack(trackId: track.id)
                                            } label: {
                                                Image(systemName: "xmark.circle.fill")
                                                    .font(.system(size: 10))
                                                    .foregroundStyle(.secondary.opacity(0.5))
                                            }
                                            .buttonStyle(.plain)
                                            .help("Remove Mask Track")
                                        }
                                    }
                                    .frame(width: labelColumnWidth, alignment: .leading)
                                    .contextMenu {
                                        Button("Add Blur Mask to Track") {
                                            session.addMaskAtPlayhead(type: .blur, style: .gaussian)
                                        }
                                        Button("Delete Track", role: .destructive) {
                                            session.deleteMaskTrack(trackId: track.id)
                                        }
                                    }

                                    ZStack(alignment: .leading) {
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .fill(Color.white.opacity(0.02))

                                        ForEach(track.items) { item in
                                            let xStart = CGFloat(item.sourceStartMs / sourceDurationMs) * contentWidth
                                            let blockW = max(18.0, CGFloat((item.sourceEndMs - item.sourceStartMs) / sourceDurationMs) * contentWidth)
                                            let isSelected = (session.selectedMaskId == item.id)

                                            TimelineInteractiveSegmentView(
                                                topTitle: item.type == .blur ? item.style.rawValue.capitalized : "Spotlight",
                                                subtitle: nil,
                                                gradientColors: item.type == .blur
                                                    ? [
                                                        Color(red: 0.56, green: 0.22, blue: 0.39),
                                                        Color(red: 0.44, green: 0.16, blue: 0.30)
                                                    ]
                                                    : [
                                                        Color(red: 0.16, green: 0.52, blue: 0.54),
                                                        Color(red: 0.12, green: 0.38, blue: 0.40)
                                                    ],
                                                isSelected: isSelected,
                                                isSplitMode: session.isSplitModeActive,
                                                xOffset: xStart,
                                                width: blockW,
                                                height: 24,
                                                totalWidth: contentWidth,
                                                totalDurationMs: sourceDurationMs,
                                                startMs: item.sourceStartMs,
                                                endMs: item.sourceEndMs,
                                                allowDragMove: true,
                                                onSelect: {
                                                    session.selectMask(item.id)
                                                },
                                                onSplitAtFraction: { localFraction in
                                                    let splitSourceMs = item.sourceStartMs + localFraction * (item.sourceEndMs - item.sourceStartMs)
                                                    session.splitMask(id: item.id, atSourceMs: splitSourceMs)
                                                },
                                                onBeginInteractive: {
                                                    session.beginInteractiveEdit()
                                                },
                                                onChangeRange: { newStart, newEnd in
                                                    session.updateMaskRange(id: item.id, newStartMs: newStart, newEndMs: newEnd)
                                                },
                                                onEndInteractive: {
                                                    session.endInteractiveEdit()
                                                },
                                                onDelete: {
                                                    session.deleteMask(maskId: item.id)
                                                }
                                            )
                                        }
                                    }
                                    .frame(width: contentWidth, height: 24)
                                }
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)

                        // Sleek Purple/Indigo Playhead (style)
                        let playheadX = 14 + labelColumnWidth + CGFloat(session.playheadTimelineMs / totalTimelineMs) * contentWidth
                        VStack(spacing: 0) {
                            Circle()
                                .fill(Color(red: 0.48, green: 0.38, blue: 0.98))
                                .frame(width: 9, height: 9)
                            Rectangle()
                                .fill(Color(red: 0.48, green: 0.38, blue: 0.98))
                                .frame(width: 1.5)
                        }
                        .frame(height: CGFloat(120 + session.document.timeline.maskTracks.count * 31))
                        .offset(x: playheadX - 4.5, y: 4)
                        .allowsHitTesting(false)
                    }
                    // Trackpad 2-Finger Pinch-to-Zoom Gesture on Timeline
                    .gesture(
                        MagnifyGesture()
                            .onChanged { value in
                                if pinchBaseZoom == nil {
                                    pinchBaseZoom = timelineZoom
                                }
                                if let base = pinchBaseZoom {
                                    timelineZoom = max(1.0, min(6.0, base * Double(value.magnification)))
                                }
                            }
                            .onEnded { _ in
                                pinchBaseZoom = nil
                            }
                    )
                }
            }
        }
        .background(Color(red: 0.05, green: 0.05, blue: 0.07))
    }

    @ViewBuilder
    private func iconActionButton(systemImage: String, tooltip: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 26)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(tooltip)
    }

    private func formatClipSubtitle(durationMs: Double, speed: Double) -> String {
        let totalSec = Int(round(durationMs / 1000.0))
        let mins = totalSec / 60
        let secs = totalSec % 60
        let timeStr = mins > 0 ? "\(mins)m \(secs)s" : "\(secs)s"
        if abs(speed - 1.0) > 0.05 {
            return String(format: "%@ • %.1fx", timeStr, speed)
        }
        return "\(timeStr) • 1x"
    }
}

// MARK: - Smooth Fixed-Interval Time Ruler (Zero Jitter When Zooming)

private struct SmoothTimeRulerView: View {
    let totalDurationMs: Double
    let width: CGFloat
    let onSeek: (Double) -> Void

    var body: some View {
        Canvas { context, size in
            let totalSec = max(1.0, totalDurationMs / 1000.0)
            let pxPerSec = Double(size.width) / totalSec

            // Choose a clean fixed time interval so labels are ~70-130px apart and NEVER jump weirdly
            let candidateStepsSec: [Double] = [0.5, 1.0, 2.0, 5.0, 10.0, 15.0, 30.0, 60.0, 120.0]
            let majorStepSec = candidateStepsSec.first(where: { $0 * pxPerSec >= 68.0 }) ?? 60.0
            let minorStepSec = majorStepSec / 2.0

            // Draw minor subdivision dots
            var tMinor = 0.0
            while tMinor <= totalSec {
                let x = CGFloat(tMinor / totalSec) * size.width
                let dotRect = CGRect(x: x - 1, y: size.height - 4, width: 2, height: 2)
                context.fill(Path(ellipseIn: dotRect), with: .color(.white.opacity(0.18)))
                tMinor += minorStepSec
            }

            // Draw major timecode labels (`0:05`, `0:10`, `0:15`...)
            var tMajor = 0.0
            while tMajor <= totalSec + 0.001 {
                let x = CGFloat(tMajor / totalSec) * size.width
                let mins = Int(tMajor) / 60
                let secs = Int(tMajor) % 60
                let labelStr: String
                if majorStepSec < 1.0 {
                    let tenths = Int(round((tMajor - floor(tMajor)) * 10))
                    labelStr = String(format: "%d:%02d.%d", mins, secs, tenths)
                } else {
                    labelStr = String(format: "%d:%02d", mins, secs)
                }

                let text = Text(labelStr)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.45))
                let clampedX = min(size.width - 16, max(14, x))
                context.draw(text, at: CGPoint(x: clampedX, y: 8))
                tMajor += majorStepSec
            }
        }
        .frame(width: width, height: 22)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let frac = max(0.0, min(1.0, Double(value.location.x / max(1.0, width))))
                    onSeek(frac * totalDurationMs)
                }
        )
    }
}

// MARK: - Interactive Segment Block with Left/Right Edge Resizing, Split Mode Blade & Context Menu

private struct TimelineInteractiveSegmentView: View {
    let topTitle: String
    let subtitle: String?
    let gradientColors: [Color]
    let isSelected: Bool
    let isSplitMode: Bool
    let xOffset: CGFloat
    let width: CGFloat
    let height: CGFloat
    let totalWidth: CGFloat
    let totalDurationMs: Double
    let startMs: Double
    let endMs: Double
    let allowDragMove: Bool
    let onSelect: () -> Void
    let onSplitAtFraction: (Double) -> Void
    let onBeginInteractive: () -> Void
    let onChangeRange: (Double, Double) -> Void
    let onEndInteractive: () -> Void
    let onDelete: () -> Void

    @State private var dragInitialStartMs: Double?
    @State private var dragInitialEndMs: Double?
    @State private var hoverSplitX: CGFloat?

    private let edgeHandleWidth: CGFloat = 9.0

    var body: some View {
        ZStack(alignment: .leading) {
            // Segment Pill Body (Zero ugly white border on unselected blocks!)
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: gradientColors,
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(
                            isSelected ? Color.white.opacity(0.75) : Color.white.opacity(0.08),
                            lineWidth: isSelected ? 1.5 : 0.5
                        )
                )

            // Centered Title & Subtitle (style)
            if width > 42 {
                VStack(spacing: 1) {
                    Text(topTitle)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(1)

                    if let sub = subtitle, width > 78 {
                        Text(sub)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.white.opacity(0.72))
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 10)
            }

            // Interactive Split Mode Cut Line Indicator
            if isSplitMode, let splitX = hoverSplitX {
                Rectangle()
                    .fill(Color.white)
                    .frame(width: 2, height: height)
                    .offset(x: splitX)
                    .allowsHitTesting(false)
            }

            // Left & Right Edge Resize Handles (when not in Split Mode)
            if !isSplitMode && width >= 26 {
                HStack(spacing: 0) {
                    // Left Resize Handle
                    Rectangle()
                        .fill(Color.white.opacity(0.001))
                        .frame(width: edgeHandleWidth, height: height)
                        .overlay(alignment: .leading) {
                            if isSelected {
                                Capsule()
                                    .fill(Color.white.opacity(0.65))
                                    .frame(width: 3, height: max(8, height - 12))
                                    .padding(.leading, 3)
                            }
                        }
                        .onHover { inside in
                            if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                        }
                        .gesture(
                            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                                .onChanged { value in
                                    onSelect()
                                    if dragInitialStartMs == nil {
                                        onBeginInteractive()
                                        dragInitialStartMs = startMs
                                        dragInitialEndMs = endMs
                                    }
                                    guard let s0 = dragInitialStartMs, let e0 = dragInitialEndMs else { return }
                                    let deltaMs = Double(value.translation.width / max(1.0, totalWidth)) * totalDurationMs
                                    let newStart = max(0.0, min(e0 - 300.0, s0 + deltaMs))
                                    onChangeRange(newStart, e0)
                                }
                                .onEnded { _ in
                                    dragInitialStartMs = nil
                                    dragInitialEndMs = nil
                                    onEndInteractive()
                                }
                        )

                    Spacer(minLength: 4)

                    // Right Resize Handle
                    Rectangle()
                        .fill(Color.white.opacity(0.001))
                        .frame(width: edgeHandleWidth, height: height)
                        .overlay(alignment: .trailing) {
                            if isSelected {
                                Capsule()
                                    .fill(Color.white.opacity(0.65))
                                    .frame(width: 3, height: max(8, height - 12))
                                    .padding(.trailing, 3)
                            }
                        }
                        .onHover { inside in
                            if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                        }
                        .gesture(
                            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                                .onChanged { value in
                                    onSelect()
                                    if dragInitialStartMs == nil {
                                        onBeginInteractive()
                                        dragInitialStartMs = startMs
                                        dragInitialEndMs = endMs
                                    }
                                    guard let s0 = dragInitialStartMs, let e0 = dragInitialEndMs else { return }
                                    let deltaMs = Double(value.translation.width / max(1.0, totalWidth)) * totalDurationMs
                                    let newEnd = max(s0 + 300.0, min(totalDurationMs, e0 + deltaMs))
                                    onChangeRange(s0, newEnd)
                                }
                                .onEnded { _ in
                                    dragInitialStartMs = nil
                                    dragInitialEndMs = nil
                                    onEndInteractive()
                                }
                        )
                }
            }
        }
        .frame(width: max(6, width - 1.5), height: height)
        .offset(x: xOffset)
        .onContinuousHover { phase in
            switch phase {
            case .active(let pt):
                if isSplitMode {
                    hoverSplitX = max(4, min(width - 4, pt.x))
                    NSCursor.crosshair.set()
                } else {
                    hoverSplitX = nil
                }
            case .ended:
                hoverSplitX = nil
                if isSplitMode {
                    NSCursor.arrow.set()
                }
            }
        }
        .simultaneousGesture(
            SpatialTapGesture()
                .onEnded { event in
                    if isSplitMode {
                        let frac = max(0.05, min(0.95, Double(event.location.x / max(1.0, width))))
                        onSplitAtFraction(frac)
                    } else {
                        onSelect()
                    }
                }
        )
        .gesture(
            DragGesture(minimumDistance: 3, coordinateSpace: .global)
                .onChanged { value in
                    guard allowDragMove, !isSplitMode else { return }
                    onSelect()
                    if dragInitialStartMs == nil {
                        onBeginInteractive()
                        dragInitialStartMs = startMs
                        dragInitialEndMs = endMs
                    }
                    guard let s0 = dragInitialStartMs, let e0 = dragInitialEndMs else { return }
                    let deltaMs = Double(value.translation.width / max(1.0, totalWidth)) * totalDurationMs
                    let span = e0 - s0
                    let newStart = max(0.0, min(totalDurationMs - span, s0 + deltaMs))
                    onChangeRange(newStart, newStart + span)
                }
                .onEnded { _ in
                    guard allowDragMove, !isSplitMode else { return }
                    dragInitialStartMs = nil
                    dragInitialEndMs = nil
                    onEndInteractive()
                }
        )
        .contextMenu {
            Button {
                onSplitAtFraction(0.5)
            } label: {
                Label("Split in Half", systemImage: "scissors")
            }

            Divider()

            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}
