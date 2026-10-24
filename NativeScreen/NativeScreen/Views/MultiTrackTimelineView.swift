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
    @State private var timelineZoom: Double = 1.0
    @State private var pinchBaseZoom: Double?

    // Track scroll offsets for synchronized Sticky Ruler & Slim 4pt Scrollbars
    @State private var horizontalScrollOffset: CGFloat = 0.0
    @State private var verticalScrollOffset: CGFloat = 0.0
    @State private var verticalContentHeight: CGFloat = 180.0

    private let labelColumnWidth: CGFloat = 94
    private let rulerHeight: CGFloat = 26
    private let clipRowHeight: CGFloat = 46
    private let zoomRowHeight: CGFloat = 40
    private let maskRowHeight: CGFloat = 30
    private let rowSpacing: CGFloat = 8

    public init(session: ProjectSession) {
        self.session = session
    }

    public var body: some View {
        VStack(spacing: 0) {
            // 1. Sleek Icon-Only Action Bar with Instant Hover Tooltips
            HStack(spacing: 6) {
                InstantTooltipButton(
                    tooltip: session.isSplitModeActive ? "Exit Split Tool (ESC)" : "Split Tool (Click any Clip, Zoom, or Mask)",
                    edge: .trailing,
                    isActive: session.isSplitModeActive,
                    size: 28,
                    cornerRadius: 7
                ) {
                    session.isSplitModeActive.toggle()
                } label: {
                    Image(systemName: "scissors")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(session.isSplitModeActive ? .white : .secondary)
                }

                Divider()
                    .frame(height: 16)
                    .padding(.horizontal, 2)

                InstantTooltipButton(
                    tooltip: "Add Zoom at Playhead",
                    edge: .trailing,
                    size: 28,
                    cornerRadius: 7
                ) {
                    session.addZoomAtPlayhead()
                } label: {
                    Image(systemName: "plus.magnifyingglass")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }

                InstantTooltipButton(
                    tooltip: "Sensitive data mask",
                    edge: .trailing,
                    size: 28,
                    cornerRadius: 7
                ) {
                    session.addMaskAtPlayhead(type: .blur, style: .gaussian)
                } label: {
                    Image(systemName: "eye.slash")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }

                InstantTooltipButton(
                    tooltip: "Spotlight mask",
                    edge: .trailing,
                    size: 28,
                    cornerRadius: 7
                ) {
                    session.addMaskAtPlayhead(type: .spotlight, style: .dim)
                } label: {
                    Image(systemName: "viewfinder.rectangular")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }

                if session.selectedMaskId != nil || session.selectedZoomId != nil || (session.selectedSliceId != nil && session.document.timeline.slices.count > 1) {
                    InstantTooltipButton(
                        tooltip: "Delete Selected (Backspace)",
                        edge: .trailing,
                        size: 28,
                        cornerRadius: 7
                    ) {
                        session.deleteSelectedTimelineItem()
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.red.opacity(0.85))
                    }
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
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .background(Color(red: 0.05, green: 0.05, blue: 0.07))
            .zIndex(30)

            Divider()

            // 2. 2D Pinned Timeline Area:
            // - Left Column (`labelColumnWidth`) is fixed horizontally.
            // - Top Ruler (`rulerHeight`) is fixed vertically.
            // - Right Track Canvas scrolls both ways with slim 4pt scroll indicators.
            GeometryReader { outerGeo in
                let viewportWidth = max(300, outerGeo.size.width - labelColumnWidth)
                let viewportHeight = max(80, outerGeo.size.height - rulerHeight)
                let contentWidth = max(viewportWidth, (viewportWidth - 20) * CGFloat(timelineZoom))
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
                            ZStack(alignment: .topLeading) {
                                SmoothTimeRulerView(
                                    totalDurationMs: totalTimelineMs,
                                    width: contentWidth
                                )

                                // Ghost Hover Teardrop Cap in Ruler
                                if let hoverMs = session.hoverSkimTimelineMs, !session.isPlaying {
                                    let hoverX = CGFloat(hoverMs / totalTimelineMs) * contentWidth
                                    TeardropHeadShape()
                                        .fill(Color(red: 0.28, green: 0.30, blue: 0.38))
                                        .frame(width: 11, height: 13)
                                        .offset(x: hoverX - 5.5, y: 2)
                                        .allowsHitTesting(false)
                                }

                                // Committed Playhead Teardrop Cap in Ruler
                                let playheadX = CGFloat(session.playheadTimelineMs / totalTimelineMs) * contentWidth
                                TeardropHeadShape()
                                    .fill(Color(red: 0.46, green: 0.34, blue: 1.0))
                                    .frame(width: 11, height: 13)
                                    .offset(x: playheadX - 5.5, y: 2)
                                    .allowsHitTesting(false)
                            }
                            .offset(x: -horizontalScrollOffset)
                            .frame(width: viewportWidth, height: rulerHeight, alignment: .leading)
                            .clipped()
                            .contentShape(Rectangle())
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let pt):
                                    let absoluteX = pt.x + horizontalScrollOffset
                                    let frac = max(0.0, min(1.0, Double(absoluteX / max(1.0, contentWidth))))
                                    session.setHoverSkimTimelineMs(frac * totalTimelineMs)
                                case .ended:
                                    session.setHoverSkimTimelineMs(nil)
                                }
                            }
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { value in
                                        let absoluteX = value.location.x + horizontalScrollOffset
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

                                        // Ghost Hover Playhead Line across all lanes
                                        if let hoverMs = session.hoverSkimTimelineMs, !session.isPlaying {
                                            let hoverX = CGFloat(hoverMs / totalTimelineMs) * contentWidth
                                            Rectangle()
                                                .fill(Color.white.opacity(0.24))
                                                .frame(width: 1.5)
                                                .frame(maxHeight: .infinity)
                                                .offset(x: hoverX - 0.75)
                                                .allowsHitTesting(false)
                                        }

                                        // Committed Playhead Line across all lanes
                                        let playheadX = CGFloat(session.playheadTimelineMs / totalTimelineMs) * contentWidth
                                        Rectangle()
                                            .fill(Color(red: 0.46, green: 0.34, blue: 1.0))
                                            .frame(width: 1.5)
                                            .frame(maxHeight: .infinity)
                                            .offset(x: playheadX - 0.75)
                                            .allowsHitTesting(false)
                                    }
                                    .frame(width: contentWidth)
                                    .coordinateSpace(name: "timelineContentSpace")
                                    .onContinuousHover(coordinateSpace: .named("timelineContentSpace")) { phase in
                                        switch phase {
                                        case .active(let pt):
                                            let frac = max(0.0, min(1.0, Double(pt.x / max(1.0, contentWidth))))
                                            session.setHoverSkimTimelineMs(frac * totalTimelineMs)
                                        case .ended:
                                            session.setHoverSkimTimelineMs(nil)
                                        }
                                    }
                                    .simultaneousGesture(
                                        SpatialTapGesture(coordinateSpace: .named("timelineContentSpace"))
                                            .onEnded { event in
                                                let frac = max(0.0, min(1.0, Double(event.location.x / max(1.0, contentWidth))))
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
                    if contentWidth > viewportWidth + 4 {
                        let ratio = viewportWidth / contentWidth
                        let thumbW = max(36, viewportWidth * ratio)
                        let maxScroll = max(1, contentWidth - viewportWidth)
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
                    onChangeRange: { newStart, newEnd in
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
                            session.beginInteractiveEdit()
                        },
                        onChangeRange: { newStart, newEnd in
                            session.updateZoomRange(id: zoom.id, newStartMs: newStart, newEndMs: newEnd)
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
                            session.beginInteractiveEdit()
                        },
                        onChangeRange: { newStart, newEnd in
                            session.updateMaskRange(id: item.id, newStartMs: newStart, newEndMs: newEnd)
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
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.45))
                let clampedX = min(size.width - 18, max(16, x))
                context.draw(text, at: CGPoint(x: clampedX, y: 10))
                tMajor += majorStepSec
            }
        }
        .frame(width: width, height: 26)
    }
}

// MARK: - Interactive Segment Block with Smooth Fade Edge Resize Handles, Split Blade, & Vertical Track Drag

private struct TimelineInteractiveSegmentView: View {
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
    let onChangeRange: (Double, Double) -> Void
    let onMoveVerticalTracks: (Int) -> Void
    let onEndInteractive: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false
    @State private var dragInitialStartMs: Double?
    @State private var dragInitialEndMs: Double?
    @State private var verticalDragOffset: CGFloat = 0.0
    @State private var hoverSplitX: CGFloat?

    private let edgeHandleWidth: CGFloat = 10.0

    var body: some View {
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
            if width > 42 {
                VStack(spacing: 2) {
                    Text(topTitle)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.88))
                        .lineLimit(1)

                    if let sub = subtitle, width > 78 {
                        Text(sub)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.88))
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 10)
                .allowsHitTesting(false)
            }

            // Interactive Split Mode Cut Line Indicator
            if isSplitMode, let splitX = hoverSplitX {
                Rectangle()
                    .fill(Color.white.opacity(0.92))
                    .frame(width: 1.5, height: height)
                    .offset(x: splitX)
                    .allowsHitTesting(false)
            }

            // Left & Right Edge Resize Handles (Smoothly fade in/out on hover or selection!)
            if !isSplitMode && width >= 26 {
                let showHandles = isSelected || isHovered
                HStack(spacing: 0) {
                    // Left Resize Handle
                    Rectangle()
                        .fill(Color.white.opacity(0.001))
                        .frame(width: edgeHandleWidth, height: height)
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(Color.white.opacity(0.78))
                                .frame(width: 3, height: max(8, height - 14))
                                .padding(.leading, 3.5)
                                .opacity(showHandles ? 1.0 : 0.0)
                                .animation(.easeInOut(duration: 0.16), value: showHandles)
                        }
                        .onHover { inside in
                            if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                        }
                        .highPriorityGesture(
                            DragGesture(minimumDistance: 1, coordinateSpace: .named("timelineContentSpace"))
                                .onChanged { value in
                                    if dragInitialStartMs == nil {
                                        onBeginInteractive()
                                        dragInitialStartMs = startMs
                                        dragInitialEndMs = endMs
                                    }
                                    guard let s0 = dragInitialStartMs, let e0 = dragInitialEndMs else { return }
                                    let deltaMs = Double(value.translation.width / max(1.0, totalWidth)) * trackTotalDurationMs
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
                            Capsule()
                                .fill(Color.white.opacity(0.78))
                                .frame(width: 3, height: max(8, height - 14))
                                .padding(.trailing, 3.5)
                                .opacity(showHandles ? 1.0 : 0.0)
                                .animation(.easeInOut(duration: 0.16), value: showHandles)
                        }
                        .onHover { inside in
                            if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                        }
                        .highPriorityGesture(
                            DragGesture(minimumDistance: 1, coordinateSpace: .named("timelineContentSpace"))
                                .onChanged { value in
                                    if dragInitialStartMs == nil {
                                        onBeginInteractive()
                                        dragInitialStartMs = startMs
                                        dragInitialEndMs = endMs
                                    }
                                    guard let s0 = dragInitialStartMs, let e0 = dragInitialEndMs else { return }
                                    let deltaMs = Double(value.translation.width / max(1.0, totalWidth)) * trackTotalDurationMs
                                    let newEnd = max(s0 + 300.0, min(trackTotalDurationMs, e0 + deltaMs))
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
        .offset(x: xOffset, y: verticalDragOffset)
        .zIndex(verticalDragOffset != 0 ? 50 : 1)
        .onContinuousHover { phase in
            switch phase {
            case .active(let pt):
                if !isHovered {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isHovered = true
                    }
                }
                if isSplitMode {
                    hoverSplitX = max(2, min(width - 2, pt.x))
                    NSCursor.crosshair.set()
                } else {
                    hoverSplitX = nil
                }
            case .ended:
                withAnimation(.easeInOut(duration: 0.15)) {
                    isHovered = false
                }
                hoverSplitX = nil
                if isSplitMode {
                    NSCursor.arrow.set()
                }
            }
        }
        .simultaneousGesture(
            SpatialTapGesture(coordinateSpace: .local)
                .onEnded { event in
                    onClickAtLocalX(event.location.x)
                }
        )
        .gesture(
            DragGesture(minimumDistance: 3, coordinateSpace: .named("timelineContentSpace"))
                .onChanged { value in
                    guard allowDragMove, !isSplitMode else { return }
                    if dragInitialStartMs == nil {
                        onBeginInteractive()
                        dragInitialStartMs = startMs
                        dragInitialEndMs = endMs
                    }
                    guard let s0 = dragInitialStartMs, let e0 = dragInitialEndMs else { return }
                    let deltaMs = Double(value.translation.width / max(1.0, totalWidth)) * trackTotalDurationMs
                    let span = e0 - s0
                    let newStart = max(0.0, min(trackTotalDurationMs - span, s0 + deltaMs))
                    onChangeRange(newStart, newStart + span)

                    if allowVerticalTrackDrag {
                        verticalDragOffset = value.translation.height
                    }
                }
                .onEnded { value in
                    guard allowDragMove, !isSplitMode else { return }
                    if allowVerticalTrackDrag {
                        let rowDelta = Int(round(value.translation.height / 38.0))
                        verticalDragOffset = 0.0
                        if rowDelta != 0 {
                            onMoveVerticalTracks(rowDelta)
                        }
                    }
                    dragInitialStartMs = nil
                    dragInitialEndMs = nil
                    onEndInteractive()
                }
        )
        .contextMenu {
            Button {
                onClickAtLocalX(width * 0.5)
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
