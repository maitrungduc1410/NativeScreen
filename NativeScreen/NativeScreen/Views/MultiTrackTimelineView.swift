import SwiftUI
import AppKit

/// NativeScreen-grade Multi-Track NLE Timeline:
/// - **Fixed Left Track Header Column** (never scrolls off-screen when scrolling horizontally).
/// - **Fixed Top Time Ruler** (never scrolls off-screen when scrolling vertically).
/// - **Slim 4pt Custom Pill Scrollbars** (replaces thick white default macOS scrollbars).
/// - **Taller Track Proportions** (`46pt` Clip, `40pt` Zoom, `30pt` Masks).
/// - **Live Hover Skimming** with translucent teardrop Ghost Playhead + Click anywhere to seek & select.
/// - **Universal Split Blade (`✂️`)** + Cross-track vertical drag for Masks + Auto-prune empty tracks.
public struct MultiTrackTimelineView: View {
    @Bindable var session: ProjectSession
    @State private var pinchBaseZoom: Double?

    // Track scroll offsets for synchronized Sticky Ruler & Slim 4pt Scrollbars
    @State private var horizontalScrollOffset: CGFloat = 0.0
    @State private var verticalScrollOffset: CGFloat = 0.0
    @State private var verticalContentHeight: CGFloat = 180.0

    private let labelColumnWidth: CGFloat = 104
    private let trackHorizontalInset: CGFloat = 12
    private let rulerHeight: CGFloat = 30
    private let clipRowHeight: CGFloat = 52
    private let zoomRowHeight: CGFloat = 46
    private let maskRowHeight: CGFloat = 34
    private let rowSpacing: CGFloat = 9

    public init(session: ProjectSession) {
        self.session = session
    }

    public var body: some View {
        VStack(spacing: 0) {
            // 2D Pinned Timeline Area:
            // - Left Column (`labelColumnWidth`) is fixed horizontally.
            // - Top Ruler (`rulerHeight`) is fixed vertically.
            // - Right Track Canvas scrolls both ways with slim 4pt scroll indicators.
            GeometryReader { outerGeo in
                let viewportWidth = max(300, outerGeo.size.width - labelColumnWidth)
                let viewportHeight = max(80, outerGeo.size.height - rulerHeight)
                let baseTrackWidth = max(260, viewportWidth - trackHorizontalInset * 2)
                let contentWidth = baseTrackWidth * CGFloat(session.timelineZoom)
                let totalDocumentWidth = contentWidth + trackHorizontalInset * 2
                let totalTimelineMs = max(1000.0, session.timeMapper.totalTimelineDurationMs)

                ZStack(alignment: .bottomTrailing) {
                    VStack(spacing: 0) {
                        // A. FIXED TOP RULER BAR
                        HStack(spacing: 0) {
                            // Top-Left Corner Header
                            HStack {
                                Text("Tracks")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.32))
                                    .padding(.leading, 14)
                                Spacer()
                            }
                            .frame(width: labelColumnWidth, height: rulerHeight)
                            .background(Color(red: 0.04, green: 0.04, blue: 0.06))
                            .overlay(alignment: .trailing) {
                                Rectangle()
                                    .fill(Color.white.opacity(0.06))
                                    .frame(width: 1)
                            }
                            .zIndex(20)

                            // Top-Right Horizontally Synced Time Ruler + Playhead Teardrop Caps
                            // `trackHorizontalInset` (10pt) guarantees that at 0.00s and at end duration,
                            // the 11pt teardrop playhead cap is 100% visible and never clipped!
                            ZStack(alignment: .topLeading) {
                                SmoothTimeRulerView(
                                    totalDurationMs: totalTimelineMs,
                                    width: contentWidth
                                )
                                .offset(x: trackHorizontalInset)

                                // Ghost Hover Teardrop Cap in Ruler
                                if let hoverMs = session.hoverSkimTimelineMs, !session.isPlaying {
                                    let hoverX = trackHorizontalInset + CGFloat(hoverMs / totalTimelineMs) * contentWidth
                                    TeardropHeadShape()
                                        .fill(Color(red: 0.28, green: 0.30, blue: 0.38))
                                        .frame(width: 11, height: 13)
                                        .offset(x: hoverX - 5.5, y: 2)
                                        .allowsHitTesting(false)
                                }

                                // Committed Playhead Teardrop Cap in Ruler
                                let playheadX = trackHorizontalInset + CGFloat(session.playheadTimelineMs / totalTimelineMs) * contentWidth
                                TeardropHeadShape()
                                    .fill(Color(red: 0.46, green: 0.34, blue: 1.0))
                                    .frame(width: 11, height: 13)
                                    .offset(x: playheadX - 5.5, y: 2)
                                    .allowsHitTesting(false)
                            }
                            .frame(width: totalDocumentWidth, height: rulerHeight, alignment: .leading)
                            .offset(x: -horizontalScrollOffset)
                            .frame(width: viewportWidth, height: rulerHeight, alignment: .leading)
                            .clipped()
                            .contentShape(Rectangle())
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let pt):
                                    let absoluteX = pt.x + horizontalScrollOffset - trackHorizontalInset
                                    let frac = max(0.0, min(1.0, Double(absoluteX / max(1.0, contentWidth))))
                                    session.setHoverSkimTimelineMs(frac * totalTimelineMs)
                                case .ended:
                                    session.setHoverSkimTimelineMs(nil)
                                }
                            }
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { value in
                                        let absoluteX = value.location.x + horizontalScrollOffset - trackHorizontalInset
                                        let frac = max(0.0, min(1.0, Double(absoluteX / max(1.0, contentWidth))))
                                        session.isPlaying = false
                                        session.seek(toTimelineMs: frac * totalTimelineMs)
                                    }
                            )
                        }
                        .frame(height: rulerHeight)
                        .background(Color(red: 0.04, green: 0.04, blue: 0.06))
                        .overlay(alignment: .bottom) {
                            Rectangle()
                                .fill(Color.white.opacity(0.06))
                                .frame(height: 1)
                        }

                        // B. VERTICALLY SCROLLABLE BODY (Fixed Left Labels + Horizontally Scrollable Track Lanes)
                        ScrollView(.vertical, showsIndicators: false) {
                            HStack(alignment: .top, spacing: 0) {
                                // B1. FIXED LEFT TRACK LABELS COLUMN (Never moves horizontally!)
                                VStack(alignment: .leading, spacing: rowSpacing) {
                                    // Clip Label
                                    HStack(spacing: 6) {
                                        Text("Clip")
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundStyle(.white.opacity(0.65))
                                    }
                                    .padding(.leading, 14)
                                    .frame(width: labelColumnWidth, height: clipRowHeight, alignment: .leading)

                                    // Zoom Label + Visibility Eye Toggle
                                    let zoomHidden = session.document.timeline.isZoomTrackHidden
                                    HStack(spacing: 6) {
                                        Button {
                                            session.toggleZoomTrackVisibility()
                                        } label: {
                                            Image(systemName: zoomHidden ? "eye.slash" : "eye")
                                                .font(.system(size: 10, weight: .medium))
                                                .foregroundStyle(Color.white.opacity(zoomHidden ? 0.28 : 0.65))
                                        }
                                        .buttonStyle(.plain)

                                        Text("Zoom")
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundStyle(Color.white.opacity(zoomHidden ? 0.30 : 0.65))
                                    }
                                    .padding(.leading, 14)
                                    .frame(width: labelColumnWidth, height: zoomRowHeight, alignment: .leading)

                                    // Dynamic Mask Track Labels + Visibility Eye Toggles
                                    ForEach(session.document.timeline.maskTracks) { track in
                                        let maskHidden = track.isHidden
                                        HStack(spacing: 6) {
                                            Button {
                                                session.toggleMaskTrackVisibility(trackId: track.id)
                                            } label: {
                                                Image(systemName: maskHidden ? "eye.slash" : "eye")
                                                    .font(.system(size: 10, weight: .medium))
                                                    .foregroundStyle(Color.white.opacity(maskHidden ? 0.28 : 0.65))
                                            }
                                            .buttonStyle(.plain)

                                            Text(track.name)
                                                .font(.system(size: 11, weight: .medium))
                                                .foregroundStyle(Color.white.opacity(maskHidden ? 0.30 : 0.65))
                                                .lineLimit(1)
                                        }
                                        .padding(.leading, 14)
                                        .frame(width: labelColumnWidth, height: maskRowHeight, alignment: .leading)
                                        .contextMenu {
                                            Button(maskHidden ? "Show Track" : "Hide Track") {
                                                session.toggleMaskTrackVisibility(trackId: track.id)
                                            }
                                            Button("Delete Track", role: .destructive) {
                                                session.deleteMaskTrack(trackId: track.id)
                                            }
                                        }
                                    }
                                }
                                .padding(.vertical, 10)
                                .background(Color(red: 0.04, green: 0.04, blue: 0.06))
                                .overlay(alignment: .trailing) {
                                    Rectangle()
                                        .fill(Color.white.opacity(0.06))
                                        .frame(width: 1)
                                }
                                .zIndex(15)

                                // B2. HORIZONTALLY SCROLLABLE TRACK LANES
                                ScrollView(.horizontal, showsIndicators: false) {
                                    ZStack(alignment: .topLeading) {
                                        VStack(alignment: .leading, spacing: rowSpacing) {
                                            // Lane 1: Screen Clips (`46pt` height)
                                            clipLaneView(
                                                contentWidth: contentWidth,
                                                totalTimelineMs: totalTimelineMs
                                            )

                                            // Lane 2: Auto-Zooms (`40pt` height)
                                            zoomLaneView(
                                                contentWidth: contentWidth,
                                                totalTimelineMs: totalTimelineMs
                                            )

                                            // Lane 3+: Dynamic Mask Tracks (`30pt` height)
                                            ForEach(Array(session.document.timeline.maskTracks.enumerated()), id: \.element.id) { trackIdx, track in
                                                maskLaneView(
                                                    track: track,
                                                    trackIndex: trackIdx,
                                                    contentWidth: contentWidth,
                                                    totalTimelineMs: totalTimelineMs
                                                )
                                            }
                                        }
                                        .padding(.vertical, 10)
                                        .padding(.horizontal, trackHorizontalInset)

                                        // Ghost Hover Playhead Line across all lanes
                                        if let hoverMs = session.hoverSkimTimelineMs, !session.isPlaying {
                                            let hoverX = trackHorizontalInset + CGFloat(hoverMs / totalTimelineMs) * contentWidth
                                            Rectangle()
                                                .fill(Color.white.opacity(0.24))
                                                .frame(width: 1.5)
                                                .frame(maxHeight: .infinity)
                                                .offset(x: hoverX - 0.75)
                                                .allowsHitTesting(false)
                                        }

                                        // Committed Playhead Line across all lanes
                                        let playheadX = trackHorizontalInset + CGFloat(session.playheadTimelineMs / totalTimelineMs) * contentWidth
                                        Rectangle()
                                            .fill(Color(red: 0.46, green: 0.34, blue: 1.0))
                                            .frame(width: 1.5)
                                            .frame(maxHeight: .infinity)
                                            .offset(x: playheadX - 0.75)
                                            .allowsHitTesting(false)
                                    }
                                    .frame(width: totalDocumentWidth)
                                    .coordinateSpace(name: "timelineContentSpace")
                                    .onContinuousHover(coordinateSpace: .named("timelineContentSpace")) { phase in
                                        switch phase {
                                        case .active(let pt):
                                            let localTrackX = pt.x - trackHorizontalInset
                                            let frac = max(0.0, min(1.0, Double(localTrackX / max(1.0, contentWidth))))
                                            session.setHoverSkimTimelineMs(frac * totalTimelineMs)
                                        case .ended:
                                            session.setHoverSkimTimelineMs(nil)
                                        }
                                    }
                                    .simultaneousGesture(
                                        SpatialTapGesture(coordinateSpace: .named("timelineContentSpace"))
                                            .onEnded { event in
                                                let localTrackX = event.location.x - trackHorizontalInset
                                                let frac = max(0.0, min(1.0, Double(localTrackX / max(1.0, contentWidth))))
                                                session.isPlaying = false
                                                session.seek(toTimelineMs: frac * totalTimelineMs)
                                            }
                                    )
                                }
                                .onScrollGeometryChange(for: CGFloat.self) { geo in
                                    geo.contentOffset.x
                                } action: { _, newX in
                                    horizontalScrollOffset = max(0, newX)
                                }
                            }
                        }
                        .onScrollGeometryChange(for: ScrollMetrics.self) { geo in
                            ScrollMetrics(offsetY: geo.contentOffset.y, contentHeight: geo.contentSize.height)
                        } action: { _, metrics in
                            verticalScrollOffset = max(0, metrics.offsetY)
                            verticalContentHeight = max(1, metrics.contentHeight)
                        }
                    }

                    // C. SLIM 4pt HORIZONTAL SCROLLBAR PILL (Only shown when zoomed > 1.0x)
                    if totalDocumentWidth > viewportWidth + 4 {
                        let ratio = viewportWidth / totalDocumentWidth
                        let thumbW = max(36, viewportWidth * ratio)
                        let maxScroll = max(1, totalDocumentWidth - viewportWidth)
                        let scrollFrac = min(1, max(0, horizontalScrollOffset / maxScroll))
                        let thumbX = labelColumnWidth + scrollFrac * (viewportWidth - thumbW - 8)

                        HStack {
                            Capsule()
                                .fill(Color.white.opacity(0.24))
                                .frame(width: thumbW, height: 4)
                                .offset(x: thumbX)
                            Spacer()
                        }
                        .padding(.bottom, 3)
                        .allowsHitTesting(false)
                    }

                    // D. SLIM 4pt VERTICAL SCROLLBAR PILL (Only shown when tracks overflow vertically)
                    if verticalContentHeight > viewportHeight + 4 {
                        let ratio = viewportHeight / verticalContentHeight
                        let thumbH = max(24, viewportHeight * ratio)
                        let maxScroll = max(1, verticalContentHeight - viewportHeight)
                        let scrollFrac = min(1, max(0, verticalScrollOffset / maxScroll))
                        let thumbY = rulerHeight + scrollFrac * (viewportHeight - thumbH - 8)

                        VStack {
                            Capsule()
                                .fill(Color.white.opacity(0.24))
                                .frame(width: 4, height: thumbH)
                                .offset(y: thumbY)
                            Spacer()
                        }
                        .padding(.trailing, 3)
                        .allowsHitTesting(false)
                    }
                }
                // Trackpad 2-Finger Pinch-to-Zoom Gesture
                .gesture(
                    MagnifyGesture()
                        .onChanged { value in
                            if pinchBaseZoom == nil {
                                pinchBaseZoom = session.timelineZoom
                            }
                            if let base = pinchBaseZoom {
                                session.timelineZoom = max(1.0, min(6.0, base * Double(value.magnification)))
                            }
                        }
                        .onEnded { _ in
                            pinchBaseZoom = nil
                        }
                )
            }
        }
        .background(Color(red: 0.04, green: 0.04, blue: 0.06))
    }

    private struct ScrollMetrics: Equatable {
        let offsetY: CGFloat
        let contentHeight: CGFloat
    }

    // MARK: - 1. Screen Clips Lane (`46pt` height)

    @ViewBuilder
    private func clipLaneView(contentWidth: CGFloat, totalTimelineMs: Double) -> some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.018))

            ForEach(session.timeMapper.mappedSlices, id: \.slice.id) { mapped in
                let xStart = CGFloat(mapped.timelineStartMs / totalTimelineMs) * contentWidth
                let blockW = max(12.0, CGFloat((mapped.timelineEndMs - mapped.timelineStartMs) / totalTimelineMs) * contentWidth)
                let isSelected = (session.selectedSliceId == mapped.slice.id && session.selectedZoomId == nil && session.selectedMaskId == nil)

                TimelineInteractiveSegmentView(
                    topTitle: "Clip",
                    subtitle: formatClipSubtitle(durationMs: mapped.slice.timelineDurationMs, speed: mapped.slice.speed),
                    gradientColors: [
                        Color(red: 0.74, green: 0.47, blue: 0.09),
                        Color(red: 0.59, green: 0.36, blue: 0.05)
                    ],
                    isSelected: isSelected,
                    isDimmed: false,
                    isSplitMode: session.isSplitModeActive,
                    xOffset: xStart,
                    width: blockW,
                    height: clipRowHeight,
                    totalWidth: contentWidth,
                    trackTotalDurationMs: mapped.slice.sourceDurationMs / max(0.001, (mapped.timelineEndMs - mapped.timelineStartMs) / totalTimelineMs),
                    startMs: mapped.slice.sourceStartMs,
                    endMs: mapped.slice.sourceEndMs,
                    allowDragMove: false,
                    allowVerticalTrackDrag: false,
                    onClickAtLocalX: { localX in
                        let frac = max(0.0, min(1.0, Double(localX / max(1.0, blockW))))
                        let clickedTimelineMs = mapped.timelineStartMs + frac * (mapped.timelineEndMs - mapped.timelineStartMs)
                        session.isPlaying = false
                        session.seek(toTimelineMs: clickedTimelineMs)
                        if session.isSplitModeActive {
                            session.splitSlice(id: mapped.slice.id, atTimelineMs: clickedTimelineMs)
                        } else {
                            session.selectSlice(mapped.slice.id)
                        }
                    },
                    onBeginInteractive: {
                        session.beginInteractiveEdit()
                    },
                    onMoveBody: { _, _ in },
                    onResizeRange: { newStart, newEnd in
                        session.updateSliceSourceRange(
                            id: mapped.slice.id,
                            newSourceStartMs: newStart,
                            newSourceEndMs: newEnd
                        )
                    },
                    onMoveVerticalTracks: { _ in },
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
        .frame(width: contentWidth, height: clipRowHeight)
    }

    // MARK: - 2. Zoom Lane (`40pt` height)

    @ViewBuilder
    private func zoomLaneView(contentWidth: CGFloat, totalTimelineMs: Double) -> some View {
        let isHidden = session.document.timeline.isZoomTrackHidden

        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.018))

            ForEach(session.document.timeline.zooms) { zoom in
                if let (tStartMs, tEndMs) = timelineSpan(forSourceStartMs: zoom.sourceStartMs, sourceEndMs: zoom.sourceEndMs) {
                    let xStart = CGFloat(tStartMs / totalTimelineMs) * contentWidth
                    let blockW = max(18.0, CGFloat((tEndMs - tStartMs) / totalTimelineMs) * contentWidth)
                    let isSelected = (session.selectedZoomId == zoom.id)

                    TimelineInteractiveSegmentView(
                        topTitle: "Zoom",
                        subtitle: String(format: "🔍 %.1fx  %@", zoom.scale, zoom.mode == .followCursor ? "Auto" : "Manual"),
                        gradientColors: [
                            Color(red: 0.42, green: 0.30, blue: 0.96),
                            Color(red: 0.34, green: 0.23, blue: 0.84)
                        ],
                        isSelected: isSelected,
                        isDimmed: isHidden || zoom.disabled,
                        isSplitMode: session.isSplitModeActive,
                        xOffset: xStart,
                        width: blockW,
                        height: zoomRowHeight,
                        totalWidth: contentWidth,
                        trackTotalDurationMs: totalTimelineMs,
                        startMs: zoom.sourceStartMs,
                        endMs: zoom.sourceEndMs,
                        allowDragMove: true,
                        allowVerticalTrackDrag: false,
                        onClickAtLocalX: { localX in
                            let frac = max(0.0, min(1.0, Double(localX / max(1.0, blockW))))
                            let clickedTimelineMs = tStartMs + frac * (tEndMs - tStartMs)
                            session.isPlaying = false
                            session.seek(toTimelineMs: clickedTimelineMs)
                            if session.isSplitModeActive {
                                let splitSourceMs = session.timeMapper.sourceTime(forTimelineMs: clickedTimelineMs).sourceMs
                                session.splitZoom(id: zoom.id, atSourceMs: splitSourceMs)
                            } else {
                                session.selectZoom(zoom.id)
                            }
                        },
                        onBeginInteractive: {
                            session.selectZoom(zoom.id)
                            session.beginInteractiveEdit()
                        },
                        onMoveBody: { desiredStartMs, durationMs in
                            session.moveZoom(id: zoom.id, desiredStartMs: desiredStartMs, durationMs: durationMs)
                        },
                        onResizeRange: { newStart, newEnd in
                            session.resizeZoom(id: zoom.id, newStartMs: newStart, newEndMs: newEnd)
                        },
                        onMoveVerticalTracks: { _ in },
                        onEndInteractive: {
                            session.endInteractiveEdit()
                        },
                        onDelete: {
                            session.deleteZoom(zoomId: zoom.id)
                        }
                    )
                }
            }
        }
        .frame(width: contentWidth, height: zoomRowHeight)
    }

    // MARK: - 3. Mask Lane (`30pt` height)

    @ViewBuilder
    private func maskLaneView(
        track: MaskTrack,
        trackIndex: Int,
        contentWidth: CGFloat,
        totalTimelineMs: Double
    ) -> some View {
        let isHidden = track.isHidden

        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.015))

            ForEach(track.items) { item in
                if let (tStartMs, tEndMs) = timelineSpan(forSourceStartMs: item.sourceStartMs, sourceEndMs: item.sourceEndMs) {
                    let xStart = CGFloat(tStartMs / totalTimelineMs) * contentWidth
                    let blockW = max(18.0, CGFloat((tEndMs - tStartMs) / totalTimelineMs) * contentWidth)
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
                        isDimmed: isHidden || item.disabled,
                        isSplitMode: session.isSplitModeActive,
                        xOffset: xStart,
                        width: blockW,
                        height: maskRowHeight,
                        totalWidth: contentWidth,
                        trackTotalDurationMs: totalTimelineMs,
                        startMs: item.sourceStartMs,
                        endMs: item.sourceEndMs,
                        allowDragMove: true,
                        allowVerticalTrackDrag: true,
                        onClickAtLocalX: { localX in
                            let frac = max(0.0, min(1.0, Double(localX / max(1.0, blockW))))
                            let clickedTimelineMs = tStartMs + frac * (tEndMs - tStartMs)
                            session.isPlaying = false
                            session.seek(toTimelineMs: clickedTimelineMs)
                            if session.isSplitModeActive {
                                let splitSourceMs = session.timeMapper.sourceTime(forTimelineMs: clickedTimelineMs).sourceMs
                                session.splitMask(id: item.id, atSourceMs: splitSourceMs)
                            } else {
                                session.selectMask(item.id)
                            }
                        },
                        onBeginInteractive: {
                            session.selectMask(item.id)
                            session.beginInteractiveEdit()
                        },
                        onMoveBody: { desiredStartMs, durationMs in
                            session.moveMask(id: item.id, desiredStartMs: desiredStartMs, durationMs: durationMs)
                        },
                        onResizeRange: { newStart, newEnd in
                            session.resizeMask(id: item.id, newStartMs: newStart, newEndMs: newEnd)
                        },
                        onMoveVerticalTracks: { trackDelta in
                            let targetIdx = trackIndex + trackDelta
                            session.moveMaskToTrack(maskId: item.id, targetTrackIndex: targetIdx)
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
        }
        .frame(width: contentWidth, height: maskRowHeight)
    }

    private func timelineSpan(forSourceStartMs sourceStartMs: Double, sourceEndMs: Double) -> (Double, Double)? {
        var earliestTimelineMs: Double?
        var latestTimelineMs: Double?

        for mapped in session.timeMapper.mappedSlices {
            let overlapStart = max(sourceStartMs, mapped.slice.sourceStartMs)
            let overlapEnd = min(sourceEndMs, mapped.slice.sourceEndMs)
            if overlapEnd > overlapStart {
                let t0 = mapped.timelineStartMs + (overlapStart - mapped.slice.sourceStartMs) / max(0.1, mapped.slice.speed)
                let t1 = mapped.timelineStartMs + (overlapEnd - mapped.slice.sourceStartMs) / max(0.1, mapped.slice.speed)
                earliestTimelineMs = min(earliestTimelineMs ?? t0, t0)
                latestTimelineMs = max(latestTimelineMs ?? t1, t1)
            }
        }

        if let t0 = earliestTimelineMs, let t1 = latestTimelineMs, t1 > t0 {
            return (t0, t1)
        }
        return nil
    }

    private func formatClipSubtitle(durationMs: Double, speed: Double) -> String {
        let totalSec = Int(round(durationMs / 1000.0))
        let mins = totalSec / 60
        let secs = totalSec % 60
        let timeStr = mins > 0 ? "\(mins)m \(secs)s" : "\(secs)s"
        if abs(speed - 1.0) > 0.05 {
            return String(format: "%@  ⏱ %.1fx", timeStr, speed)
        }
        return "\(timeStr)  ⏱ 1x"
    }
}

// MARK: - NativeScreen-Style Teardrop Playhead Cap Shape

private struct TeardropHeadShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let r = rect.width * 0.5
        path.addArc(
            center: CGPoint(x: rect.midX, y: r),
            radius: r,
            startAngle: .degrees(150),
            endAngle: .degrees(30),
            clockwise: false
        )
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

// MARK: - Smooth Fixed-Interval Time Ruler

private struct SmoothTimeRulerView: View {
    let totalDurationMs: Double
    let width: CGFloat

    var body: some View {
        Canvas { context, size in
            let totalSec = max(1.0, totalDurationMs / 1000.0)
            let pxPerSec = Double(size.width) / totalSec

            let candidateStepsSec: [Double] = [0.5, 1.0, 2.0, 5.0, 10.0, 15.0, 30.0, 60.0, 120.0]
            let majorStepSec = candidateStepsSec.first(where: { $0 * pxPerSec >= 68.0 }) ?? 60.0
            let minorStepSec = majorStepSec / 2.0

            var tMinor = 0.0
            while tMinor <= totalSec {
                let x = CGFloat(tMinor / totalSec) * size.width
                let dotRect = CGRect(x: x - 1.2, y: size.height - 5, width: 2.4, height: 2.4)
                context.fill(Path(ellipseIn: dotRect), with: .color(.white.opacity(0.22)))
                tMinor += minorStepSec
            }

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
                    .font(.system(size: 11.5, weight: .medium, design: .default).monospacedDigit())
                    .foregroundColor(.white.opacity(0.62))
                let clampedX = min(size.width - 20, max(16, x))
                context.draw(text, at: CGPoint(x: clampedX, y: 11))
                tMajor += majorStepSec
            }
        }
        .frame(width: width, height: 30)
    }
}

// MARK: - Interactive Segment Block with Strictly Separated Edge Resize vs. Body Move

private struct TimelineInteractiveSegmentView: View {
    private enum SegmentDragMode {
        case resizeLeft
        case resizeRight
        case moveBody
    }

    let topTitle: String
    let subtitle: String?
    let gradientColors: [Color]
    let isSelected: Bool
    let isDimmed: Bool
    let isSplitMode: Bool
    let xOffset: CGFloat
    let width: CGFloat
    let height: CGFloat
    let totalWidth: CGFloat
    let trackTotalDurationMs: Double
    let startMs: Double
    let endMs: Double
    let allowDragMove: Bool
    let allowVerticalTrackDrag: Bool
    let onClickAtLocalX: (CGFloat) -> Void
    let onBeginInteractive: () -> Void
    let onMoveBody: (Double, Double) -> Void
    let onResizeRange: (Double, Double) -> Void
    let onMoveVerticalTracks: (Int) -> Void
    let onEndInteractive: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false
    @State private var lastHoverLocalX: CGFloat = 0.0
    @State private var activeDragMode: SegmentDragMode? = nil
    @State private var pressLocalX: CGFloat = 0.0
    @State private var hasExceededClickSlop = false
    @State private var dragInitialStartMs: Double?
    @State private var dragInitialEndMs: Double?
    @State private var verticalDragOffset: CGFloat = 0.0
    @State private var hoverSplitX: CGFloat?

    private let edgeHandleWidth: CGFloat = 11.0

    var body: some View {
        let segWidth = max(6, width - 1.5)
        let showHandles = !isSplitMode && segWidth >= 26 && (isSelected || isHovered)

        ZStack(alignment: .leading) {
            // Segment Pill Body
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: gradientColors,
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(
                            isSelected
                                ? Color.white.opacity(0.65)
                                : (isHovered ? Color.white.opacity(0.28) : Color.white.opacity(0.10)),
                            lineWidth: isSelected ? 1.4 : 0.8
                        )
                )
                .opacity(isDimmed ? 0.35 : 1.0)

            // Centered Title & Subtitle
            if segWidth > 42 {
                VStack(spacing: 2) {
                    Text(topTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(1)

                    if let sub = subtitle, segWidth > 78 {
                        Text(sub)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.88))
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 10)
            }

            // Interactive Split Mode Cut Line Indicator
            if isSplitMode, let splitX = hoverSplitX {
                Rectangle()
                    .fill(Color.white.opacity(0.92))
                    .frame(width: 1.5, height: height)
                    .offset(x: splitX)
            }

            // Left & Right Edge Resize Visual Indicators (Smoothly fade in/out on hover or selection)
            if !isSplitMode && segWidth >= 26 {
                HStack(spacing: 0) {
                    Capsule()
                        .fill(Color.white.opacity(0.82))
                        .frame(width: 3, height: max(8, height - 14))
                        .padding(.leading, 4)

                    Spacer(minLength: 4)

                    Capsule()
                        .fill(Color.white.opacity(0.82))
                        .frame(width: 3, height: max(8, height - 14))
                        .padding(.trailing, 4)
                }
                .opacity(showHandles ? 1.0 : 0.0)
                .animation(.easeInOut(duration: 0.15), value: showHandles)
            }
        }
        .frame(width: segWidth, height: height)
        .contentShape(Rectangle())
        .offset(x: xOffset, y: verticalDragOffset)
        .zIndex(activeDragMode != nil ? 60 : 1)
        .onContinuousHover { phase in
            switch phase {
            case .active(let pt):
                lastHoverLocalX = pt.x
                if !isHovered {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isHovered = true
                    }
                }
                if isSplitMode {
                    hoverSplitX = max(2, min(segWidth - 2, pt.x))
                    NSCursor.crosshair.set()
                } else {
                    hoverSplitX = nil
                    if segWidth >= 26 && (pt.x <= edgeHandleWidth || pt.x >= segWidth - edgeHandleWidth) {
                        NSCursor.resizeLeftRight.set()
                    } else if allowDragMove {
                        NSCursor.openHand.set()
                    } else {
                        NSCursor.arrow.set()
                    }
                }
            case .ended:
                withAnimation(.easeInOut(duration: 0.15)) {
                    isHovered = false
                }
                hoverSplitX = nil
                if activeDragMode == nil {
                    NSCursor.arrow.set()
                }
            }
        }
        // Single Unified High-Priority Gesture:
        // - Determines whether the user grabbed the Left Handle (`.resizeLeft`), Right Handle (`.resizeRight`), or Center Body (`.moveBody`).
        // - `.moveBody` ONLY moves the segment and NEVER resizes it.
        // - `.resizeLeft` / `.resizeRight` ONLY resize the grabbed edge.
        .highPriorityGesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named("timelineContentSpace"))
                .onChanged { value in
                    if activeDragMode == nil {
                        // Compute local X inside this segment at the exact moment of mouse-down
                        let startInLane = value.startLocation.x - 12.0 // subtract `trackHorizontalInset`
                        let computedLocalX = startInLane - xOffset
                        let localX = (computedLocalX >= -4 && computedLocalX <= segWidth + 4)
                            ? max(0, min(segWidth, computedLocalX))
                            : lastHoverLocalX

                        pressLocalX = localX
                        hasExceededClickSlop = false
                        dragInitialStartMs = startMs
                        dragInitialEndMs = endMs

                        if !isSplitMode && segWidth >= 26 && localX <= edgeHandleWidth {
                            activeDragMode = .resizeLeft
                            NSCursor.resizeLeftRight.set()
                        } else if !isSplitMode && segWidth >= 26 && localX >= segWidth - edgeHandleWidth {
                            activeDragMode = .resizeRight
                            NSCursor.resizeLeftRight.set()
                        } else {
                            activeDragMode = .moveBody
                            if allowDragMove && !isSplitMode {
                                NSCursor.closedHand.set()
                            }
                        }
                    }

                    let dragDist = hypot(value.translation.width, value.translation.height)
                    if !hasExceededClickSlop {
                        guard dragDist >= 2.5, !isSplitMode else { return }
                        hasExceededClickSlop = true
                        onBeginInteractive()
                    }

                    guard let s0 = dragInitialStartMs,
                          let e0 = dragInitialEndMs,
                          let mode = activeDragMode else { return }

                    let deltaMs = Double(value.translation.width / max(1.0, totalWidth)) * trackTotalDurationMs

                    switch mode {
                    case .resizeLeft:
                        let newStart = max(0.0, min(e0 - 300.0, s0 + deltaMs))
                        onResizeRange(newStart, e0)

                    case .resizeRight:
                        let newEnd = max(s0 + 300.0, s0 + (e0 - s0) + deltaMs)
                        onResizeRange(s0, newEnd)

                    case .moveBody:
                        guard allowDragMove else { return }
                        let constantDurationMs = e0 - s0
                        onMoveBody(s0 + deltaMs, constantDurationMs)

                        if allowVerticalTrackDrag {
                            verticalDragOffset = value.translation.height
                        }
                    }
                }
                .onEnded { value in
                    let wasDrag = hasExceededClickSlop
                    let localX = pressLocalX

                    if wasDrag {
                        if activeDragMode == .moveBody && allowVerticalTrackDrag {
                            let rowDelta = Int(round(value.translation.height / 38.0))
                            verticalDragOffset = 0.0
                            if rowDelta != 0 {
                                onMoveVerticalTracks(rowDelta)
                            }
                        }
                        onEndInteractive()
                    } else {
                        onClickAtLocalX(localX)
                    }

                    activeDragMode = nil
                    hasExceededClickSlop = false
                    dragInitialStartMs = nil
                    dragInitialEndMs = nil
                    verticalDragOffset = 0.0
                    NSCursor.arrow.set()
                }
        )
        .contextMenu {
            Button {
                onClickAtLocalX(segWidth * 0.5)
            } label: {
                Label("Seek Here", systemImage: "arrow.down.to.line")
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
