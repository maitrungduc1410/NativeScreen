import SwiftUI
import AppKit

/// NativeScreen-grade Multi-Track NLE Timeline:
/// - **Unified Continuous Playhead** (teardrop head + vertical stem drawn as a single connected shape with zero gap).
/// - **Ghost Playhead "Ducking" Animation** (when hovering near the main purple playhead, the grey ghost playhead head smoothly ducks down underneath it).
/// - **Ruler Dots & Clip Vertical Tick Lines** (major labels + minor dots, with matching vertical tick lines inside the Clip bar).
/// - **Audio Waveform Inside Clip** (smooth purple-tinted waveform rendered along the bottom of the Clip segment).
/// - **Edge-to-Edge Touching Segments** (zero artificial gap when segments touch).
/// - **Playhead-Anchored Timeline Zoom** (zooming keeps the playhead stationary at its current screen position).
/// - **Native Liquid Glass Right-Click Context Popovers**.
public struct MultiTrackTimelineView: View {
    @Bindable var session: ProjectSession
    @State private var pinchBaseZoom: Double?

    // Track scroll offsets & NSScrollView reference for playhead-anchored zooming
    @State private var horizontalScrollOffset: CGFloat = 0.0
    @State private var verticalScrollOffset: CGFloat = 0.0
    @State private var verticalContentHeight: CGFloat = 180.0
    @State private var horizontalScrollView: NSScrollView?
    @State private var lastZoomForAnchor: Double = 1.0

    private let labelColumnWidth: CGFloat = 104
    private let trackHorizontalInset: CGFloat = 20
    private let rulerHeight: CGFloat = 30
    private let clipRowHeight: CGFloat = 52
    private let zoomRowHeight: CGFloat = 46
    private let maskRowHeight: CGFloat = 34
    private let rowSpacing: CGFloat = 8

    public init(session: ProjectSession) {
        self.session = session
    }

    public var body: some View {
        VStack(spacing: 0) {
            GeometryReader { outerGeo in
                let viewportWidth = max(300, outerGeo.size.width - labelColumnWidth)
                let viewportHeight = max(80, outerGeo.size.height - rulerHeight)
                let baseTrackWidth = max(260, viewportWidth - trackHorizontalInset * 2)
                let contentWidth = baseTrackWidth * CGFloat(session.timelineZoom)
                let totalDocumentWidth = contentWidth + trackHorizontalInset * 2
                let totalTimelineMs = max(1000.0, session.timeMapper.totalTimelineDurationMs)
                let stepInfo = SmoothTimeRulerView.computeStepIntervals(totalDurationMs: totalTimelineMs, width: contentWidth)

                let playheadXInDoc = trackHorizontalInset + CGFloat(session.playheadTimelineMs / totalTimelineMs) * contentWidth
                let playheadXInViewport = playheadXInDoc - horizontalScrollOffset

                let hoverXInDoc: CGFloat? = (!session.isPlaying && session.hoverSkimTimelineMs != nil)
                    ? (trackHorizontalInset + CGFloat(session.hoverSkimTimelineMs! / totalTimelineMs) * contentWidth)
                    : nil
                let hoverXInViewport: CGFloat? = hoverXInDoc.map { $0 - horizontalScrollOffset }

                ZStack(alignment: .topLeading) {
                    VStack(spacing: 0) {
                        // A. FIXED TOP RULER BAR
                        HStack(spacing: 0) {
                            // Top-Left Corner Header
                            HStack {
                                Text("Tracks")
                                    .font(.system(size: 10.5, weight: .semibold))
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

                            // Top-Right Horizontally Synced Time Ruler
                            ZStack(alignment: .topLeading) {
                                SmoothTimeRulerView(
                                    totalDurationMs: totalTimelineMs,
                                    width: contentWidth,
                                    majorStepSec: stepInfo.major,
                                    minorStepSec: stepInfo.minor
                                )
                                .offset(x: trackHorizontalInset)
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

                        // B. VERTICALLY SCROLLABLE BODY (Fixed Left Labels + Horizontally Scrollable Track Lanes)
                        ScrollView(.vertical, showsIndicators: false) {
                            HStack(alignment: .top, spacing: 0) {
                                // B1. FIXED LEFT TRACK LABELS COLUMN
                                VStack(alignment: .leading, spacing: rowSpacing) {
                                    HStack(spacing: 6) {
                                        Text("Clip")
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundStyle(.white.opacity(0.65))
                                    }
                                    .padding(.leading, 14)
                                    .frame(width: labelColumnWidth, height: clipRowHeight, alignment: .leading)

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
                                    }
                                }
                                .padding(.vertical, 8)
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
                                            // Lane 1: Screen Clips (`52pt` height, with Ruler Tick Lines + Audio Waveform)
                                            clipLaneView(
                                                contentWidth: contentWidth,
                                                totalTimelineMs: totalTimelineMs,
                                                minorTickStepSec: stepInfo.minor
                                            )

                                            // Lane 2: Auto-Zooms (`46pt` height, touching edge-to-edge)
                                            zoomLaneView(
                                                contentWidth: contentWidth,
                                                totalTimelineMs: totalTimelineMs
                                            )

                                            // Lane 3+: Dynamic Mask Tracks (`34pt` height)
                                            ForEach(Array(session.document.timeline.maskTracks.enumerated()), id: \.element.id) { trackIdx, track in
                                                maskLaneView(
                                                    track: track,
                                                    trackIndex: trackIdx,
                                                    contentWidth: contentWidth,
                                                    totalTimelineMs: totalTimelineMs
                                                )
                                            }
                                        }
                                        .padding(.vertical, 8)
                                        .padding(.horizontal, trackHorizontalInset)
                                        .background(
                                            HorizontalScrollViewIntrospector { sv in
                                                if horizontalScrollView !== sv {
                                                    horizontalScrollView = sv
                                                }
                                            }
                                        )
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

                    // C. UNIFIED CONTINUOUS GHOST PLAYHEAD + COMMITTED PLAYHEAD OVERLAY
                    // Spans seamlessly from the top of the Ruler through all tracks with zero gap between head and line!
                    ZStack(alignment: .topLeading) {
                        // 1. Ghost Hover Playhead (Smoothly ducks its teardrop head well below the main purple playhead!)
                        if let gx = hoverXInViewport, gx >= -8 && gx <= viewportWidth + 8 {
                            let distToMain = abs(gx - playheadXInViewport)
                            let proximity01 = max(0.0, min(1.0, 1.0 - (distToMain / 26.0)))
                            let duckYOffset = 22.0 * proximity01 * (2.0 - proximity01)

                            UnifiedPlayheadCanvasView(
                                headColor: Color(red: 0.25, green: 0.27, blue: 0.34).opacity(0.92),
                                stemColor: Color(red: 0.25, green: 0.27, blue: 0.34).opacity(0.65),
                                headTopY: 1.5 + duckYOffset,
                                totalHeight: outerGeo.size.height
                            )
                            .frame(width: 18, height: outerGeo.size.height)
                            .offset(x: gx - 9.0)
                        }

                        // 2. Main Committed Purple Playhead (100% connected single-path teardrop + vertical stem)
                        if playheadXInViewport >= -8 && playheadXInViewport <= viewportWidth + 8 {
                            UnifiedPlayheadCanvasView(
                                headColor: Color(red: 0.44, green: 0.30, blue: 1.0),
                                stemColor: Color(red: 0.44, green: 0.30, blue: 1.0).opacity(0.90),
                                headTopY: 1.5,
                                totalHeight: outerGeo.size.height
                            )
                            .frame(width: 18, height: outerGeo.size.height)
                            .offset(x: playheadXInViewport - 9.0)
                        }
                    }
                    .frame(width: viewportWidth, height: outerGeo.size.height, alignment: .topLeading)
                    .clipped()
                    .offset(x: labelColumnWidth)
                    .allowsHitTesting(false)
                    .zIndex(25)

                    // D. SLIM 4pt HORIZONTAL SCROLLBAR PILL
                    if totalDocumentWidth > viewportWidth + 4 {
                        let ratio = viewportWidth / totalDocumentWidth
                        let thumbW = max(36, viewportWidth * ratio)
                        let maxScroll = max(1, totalDocumentWidth - viewportWidth)
                        let scrollFrac = min(1, max(0, horizontalScrollOffset / maxScroll))
                        let thumbX = labelColumnWidth + scrollFrac * (viewportWidth - thumbW - 8)

                        VStack {
                            Spacer()
                            HStack {
                                Capsule()
                                    .fill(Color.white.opacity(0.24))
                                    .frame(width: thumbW, height: 4)
                                    .offset(x: thumbX)
                                Spacer()
                            }
                            .padding(.bottom, 3)
                        }
                        .allowsHitTesting(false)
                    }

                    // E. SLIM 4pt VERTICAL SCROLLBAR PILL
                    if verticalContentHeight > viewportHeight + 4 {
                        let ratio = viewportHeight / verticalContentHeight
                        let thumbH = max(24, viewportHeight * ratio)
                        let maxScroll = max(1, verticalContentHeight - viewportHeight)
                        let scrollFrac = min(1, max(0, verticalScrollOffset / maxScroll))
                        let thumbY = rulerHeight + scrollFrac * (viewportHeight - thumbH - 8)

                        HStack {
                            Spacer()
                            VStack {
                                Capsule()
                                    .fill(Color.white.opacity(0.24))
                                    .frame(width: 4, height: thumbH)
                                    .offset(y: thumbY)
                                Spacer()
                            }
                            .padding(.trailing, 3)
                        }
                        .allowsHitTesting(false)
                    }
                }
                // Keep Playhead stationary in the viewport when `session.timelineZoom` changes!
                .onChange(of: session.timelineZoom) { oldZoom, newZoom in
                    anchorScrollOffsetAroundPlayhead(
                        oldZoom: oldZoom,
                        newZoom: newZoom,
                        baseTrackWidth: baseTrackWidth,
                        viewportWidth: viewportWidth,
                        totalTimelineMs: totalTimelineMs
                    )
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

    /// Adjusts the horizontal `NSScrollView` content offset whenever `timelineZoom` changes so the Playhead stays
    /// at the exact same pixel coordinate on screen!
    private func anchorScrollOffsetAroundPlayhead(
        oldZoom: Double,
        newZoom: Double,
        baseTrackWidth: CGFloat,
        viewportWidth: CGFloat,
        totalTimelineMs: Double
    ) {
        guard let sv = horizontalScrollView else { return }
        let playheadFrac = CGFloat(session.playheadTimelineMs / max(1.0, totalTimelineMs))
        let oldContentW = baseTrackWidth * CGFloat(oldZoom)
        let newContentW = baseTrackWidth * CGFloat(newZoom)
        let newTotalDocW = newContentW + trackHorizontalInset * 2

        let currentScrollX = sv.contentView.bounds.origin.x
        let playheadViewportX = trackHorizontalInset + playheadFrac * oldContentW - currentScrollX

        let desiredNewScrollX = (trackHorizontalInset + playheadFrac * newContentW) - playheadViewportX
        let maxScrollX = max(0.0, newTotalDocW - viewportWidth)
        let clampedScrollX = max(0.0, min(maxScrollX, desiredNewScrollX))

        sv.contentView.scroll(to: NSPoint(x: clampedScrollX, y: sv.contentView.bounds.origin.y))
        sv.reflectScrolledClipView(sv.contentView)
        horizontalScrollOffset = clampedScrollX
    }

    // MARK: - 1. Screen Clips Lane (`52pt` height, with Ruler Tick Lines + Audio Waveform + Liquid Glass Popover)

    @ViewBuilder
    private func clipLaneView(contentWidth: CGFloat, totalTimelineMs: Double, minorTickStepSec: Double) -> some View {
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
                        Color(red: 0.78, green: 0.49, blue: 0.08),
                        Color(red: 0.68, green: 0.41, blue: 0.05),
                        Color(red: 0.88, green: 0.56, blue: 0.14)
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
                    clipDecoration: ClipSegmentDecoration(
                        timelineStartMs: mapped.timelineStartMs,
                        timelineEndMs: mapped.timelineEndMs,
                        totalTimelineMs: totalTimelineMs,
                        minorTickStepSec: minorTickStepSec,
                        sourceStartMs: mapped.slice.sourceStartMs,
                        sourceEndMs: mapped.slice.sourceEndMs,
                        totalSourceMs: session.metadata.durationMs,
                        volumeScale: mapped.slice.muted ? 0.0 : mapped.slice.systemAudioVolume,
                        waveformSamples: session.audioWaveformSamples
                    ),
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
                    onRightClick: { pointInView, parentView in
                        session.selectSlice(mapped.slice.id)
                        NativeSegmentContextMenuPresenter.shared.presentClipContextMenu(
                            session: session,
                            sliceId: mapped.slice.id,
                            at: pointInView,
                            in: parentView
                        )
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
                    }
                )
            }
        }
        .frame(width: contentWidth, height: clipRowHeight)
    }

    // MARK: - 2. Zoom Lane (`46pt` height, Touching Edge-to-Edge + Native NSMenu Liquid Glass Context Menu)

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
                        topTitle: zoom.presentation == .loupe ? "Loupe" : "Zoom",
                        subtitle: String(format: "🔍 %.1fx  %@", zoom.scale, zoom.mode == .followCursor ? "Auto" : "Manual"),
                        gradientColors: [
                            Color(red: 0.42, green: 0.28, blue: 0.99),
                            Color(red: 0.36, green: 0.23, blue: 0.96),
                            Color(red: 0.54, green: 0.43, blue: 1.00)
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
                        clipDecoration: nil,
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
                        onRightClick: { pointInView, parentView in
                            session.selectZoom(zoom.id)
                            NativeSegmentContextMenuPresenter.shared.presentZoomContextMenu(
                                session: session,
                                zoomId: zoom.id,
                                at: pointInView,
                                in: parentView
                            )
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
                        }
                    )
                }
            }
        }
        .frame(width: contentWidth, height: zoomRowHeight)
    }

    // MARK: - 3. Mask Lane (`34pt` height, Touching Edge-to-Edge + Native NSMenu Liquid Glass Context Menu)

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
                        topTitle: item.type == .blur ? item.style.rawValue.capitalized : "Highlight",
                        subtitle: nil,
                        gradientColors: item.type == .blur
                            ? [
                                Color(red: 0.55, green: 0.20, blue: 0.38),
                                Color(red: 0.48, green: 0.16, blue: 0.33),
                                Color(red: 0.65, green: 0.26, blue: 0.46)
                            ]
                            : [
                                Color(red: 0.18, green: 0.54, blue: 0.58),
                                Color(red: 0.14, green: 0.44, blue: 0.48),
                                Color(red: 0.24, green: 0.64, blue: 0.68)
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
                        clipDecoration: nil,
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
                        onRightClick: { pointInView, parentView in
                            session.selectMask(item.id)
                            NativeSegmentContextMenuPresenter.shared.presentMaskContextMenu(
                                session: session,
                                maskId: item.id,
                                at: pointInView,
                                in: parentView
                            )
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

// MARK: - Unified Continuous Playhead Canvas (Zero-Overlap Single-Path Teardrop + Stem)

private struct UnifiedPlayheadCanvasView: View {
    let headColor: Color
    let stemColor: Color
    let headTopY: CGFloat
    let totalHeight: CGFloat

    var body: some View {
        Canvas { context, size in
            let centerX = size.width * 0.5
            let radius: CGFloat = 6.6
            let circleCenterY = headTopY + radius
            let tipY = circleCenterY + radius * 1.65

            // 1. Continuous Teardrop Head (ends cleanly at `tipY`)
            var headPath = Path()
            headPath.addArc(
                center: CGPoint(x: centerX, y: circleCenterY),
                radius: radius,
                startAngle: .degrees(145),
                endAngle: .degrees(35),
                clockwise: false
            )
            headPath.addLine(to: CGPoint(x: centerX, y: tipY))
            headPath.closeSubpath()
            context.fill(headPath, with: .color(headColor))

            // 2. Vertical Stem starting at `tipY` (ZERO overlap with the teardrop tip so translucent playheads never show a bright overlap artifact!)
            let stemRect = CGRect(
                x: centerX - 0.75,
                y: tipY,
                width: 1.5,
                height: max(10, totalHeight - tipY)
            )
            context.fill(Path(stemRect), with: .color(stemColor))
        }
    }
}

// MARK: - Smooth Fixed-Interval Time Ruler (Major Labels + Minor Dots & 5)

private struct SmoothTimeRulerView: View {
    let totalDurationMs: Double
    let width: CGFloat
    let majorStepSec: Double
    let minorStepSec: Double

    static func computeStepIntervals(totalDurationMs: Double, width: CGFloat) -> (major: Double, minor: Double) {
        let totalSec = max(1.0, totalDurationMs / 1000.0)
        let pxPerSec = Double(width) / totalSec
        let candidateStepsSec: [Double] = [1.0, 2.0, 4.0, 5.0, 10.0, 15.0, 20.0, 30.0, 60.0, 120.0]
        let major = candidateStepsSec.first(where: { $0 * pxPerSec >= 76.0 }) ?? 60.0
        return (major, major / 2.0)
    }

    var body: some View {
        Canvas { context, size in
            let totalSec = max(1.0, totalDurationMs / 1000.0)
            let dotY = size.height - 6.0

            // Draw dots at every `minorStepSec`, and draw timecode text ONLY at `majorStepSec` ticks
            var stepIndex = 0
            while true {
                let tSec = Double(stepIndex) * minorStepSec
                if tSec > totalSec + 0.001 { break }

                let x = CGFloat(tSec / totalSec) * size.width
                let isMajor = (stepIndex % 2 == 0)

                // Crisp dot on every minor & major tick
                let dotRadius: CGFloat = 1.4
                let dotRect = CGRect(x: x - dotRadius, y: dotY - dotRadius, width: dotRadius * 2, height: dotRadius * 2)
                context.fill(Path(ellipseIn: dotRect), with: .color(.white.opacity(isMajor ? 0.34 : 0.24)))

                // Draw time label above major dots (skipping `t == 0` so 0:00 is never clipped at the left edge!)
                if isMajor && stepIndex > 0 && x <= size.width - 14 {
                    let mins = Int(round(tSec)) / 60
                    let secs = Int(round(tSec)) % 60
                    let labelStr = String(format: "%d:%02d", mins, secs)

                    let text = Text(labelStr)
                        .font(.system(size: 11, weight: .medium, design: .default).monospacedDigit())
                        .foregroundColor(.white.opacity(0.48))
                    context.draw(text, at: CGPoint(x: x, y: dotY - 10))
                }

                stepIndex += 1
            }
        }
        .frame(width: width, height: 30)
    }
}

// MARK: - Clip Segment Decoration (Ruler Tick Lines + Audio Waveform Curve — Equatable so Canvas never redraws on hover skim!)

private struct ClipSegmentDecoration: Equatable, View {
    let timelineStartMs: Double
    let timelineEndMs: Double
    let totalTimelineMs: Double
    let minorTickStepSec: Double
    let sourceStartMs: Double
    let sourceEndMs: Double
    let totalSourceMs: Double
    let volumeScale: Double
    let waveformSamples: [Float]

    var body: some View {
        Canvas { context, size in
            // A. Audio Waveform along bottom of Clip (Scaled per-segment by `volumeScale`!)
            if !waveformSamples.isEmpty && totalSourceMs > 1.0 && volumeScale > 0.005 {
                let startFrac = max(0.0, min(1.0, sourceStartMs / totalSourceMs))
                let endFrac = max(startFrac + 0.001, min(1.0, sourceEndMs / totalSourceMs))
                let totalBuckets = waveformSamples.count
                let clampedVol = CGFloat(min(1.5, max(0.0, volumeScale)))

                let stepPx: CGFloat = 4.0
                let pointCount = max(2, min(320, Int(size.width / stepPx)))
                var wavePath = Path()
                wavePath.move(to: CGPoint(x: 0, y: size.height))

                for i in 0...pointCount {
                    let localFrac = Double(i) / Double(pointCount)
                    let globalFrac = startFrac + localFrac * (endFrac - startFrac)
                    let exactBucket = globalFrac * Double(totalBuckets - 1)
                    let b0 = max(0, min(totalBuckets - 1, Int(exactBucket)))
                    let b1 = min(totalBuckets - 1, b0 + 1)
                    let t = Float(exactBucket - Double(b0))
                    let amp = waveformSamples[b0] * (1.0 - t) + waveformSamples[b1] * t

                    let x = CGFloat(localFrac) * size.width
                    let waveH = min(size.height * 0.72, CGFloat(amp) * (size.height * 0.44) * clampedVol)
                    wavePath.addLine(to: CGPoint(x: x, y: size.height - waveH))
                }
                wavePath.addLine(to: CGPoint(x: size.width, y: size.height))
                wavePath.closeSubpath()

                context.fill(
                    wavePath,
                    with: .linearGradient(
                        Gradient(colors: [
                            Color(red: 0.56, green: 0.38, blue: 0.68).opacity(0.62),
                            Color(red: 0.45, green: 0.28, blue: 0.54).opacity(0.45)
                        ]),
                        startPoint: CGPoint(x: 0, y: size.height * 0.5),
                        endPoint: CGPoint(x: 0, y: size.height)
                    )
                )
            }

            // B. Vertical Ruler Tick Lines at every minor/major ruler dot
            let stepMs = minorTickStepSec * 1000.0
            let sliceSpanMs = max(1.0, timelineEndMs - timelineStartMs)
            var tickMs = ceil(timelineStartMs / stepMs) * stepMs
            while tickMs < timelineEndMs {
                let localX = CGFloat((tickMs - timelineStartMs) / sliceSpanMs) * size.width
                if localX > 4 && localX < size.width - 4 {
                    let tickRect = CGRect(x: localX - 0.5, y: 0, width: 1.0, height: size.height * 0.65)
                    context.fill(
                        Path(tickRect),
                        with: .linearGradient(
                            Gradient(colors: [
                                Color.white.opacity(0.18),
                                Color.white.opacity(0.0)
                            ]),
                            startPoint: CGPoint(x: localX, y: 0),
                            endPoint: CGPoint(x: localX, y: size.height * 0.65)
                        )
                    )
                }
                tickMs += stepMs
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .allowsHitTesting(false)
    }
}

// MARK: - Interactive Segment Block with Top-to-Bottom Gradient, Waveform, Inset Handles & Golden Split Badge

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
    let clipDecoration: ClipSegmentDecoration?
    let onClickAtLocalX: (CGFloat) -> Void
    let onRightClick: (NSPoint, NSView) -> Void
    let onBeginInteractive: () -> Void
    let onMoveBody: (Double, Double) -> Void
    let onResizeRange: (Double, Double) -> Void
    let onMoveVerticalTracks: (Int) -> Void
    let onEndInteractive: () -> Void

    @State private var isHovered = false
    @State private var lastHoverLocalX: CGFloat = 0.0
    @State private var activeDragMode: SegmentDragMode? = nil
    @State private var pressLocalX: CGFloat = 0.0
    @State private var hasExceededClickSlop = false
    @State private var dragInitialStartMs: Double?
    @State private var dragInitialEndMs: Double?
    @State private var verticalDragOffset: CGFloat = 0.0
    @State private var hoverSplitX: CGFloat?

    private let edgeHandleHitWidth: CGFloat = 13.0

    var body: some View {
        // 1px visual gap between adjacent touching segments
        let segWidth = max(6.0, width - 1.0)
        let showHandles = !isSplitMode && segWidth >= 28 && (isSelected || isHovered)

        ZStack(alignment: .leading) {
            // 1. Rich Vibrant Pill Body + Inner Specular Top/Bottom Edge Glow (style!)
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
                        .fill(
                            RadialGradient(
                                colors: [Color.white.opacity(0.16), Color.clear],
                                center: .center,
                                startRadius: 2,
                                endRadius: max(30, segWidth * 0.55)
                            )
                        )
                )

            // 2. Clip-Specific Decoration: Audio Waveform along Bottom + Ruler Vertical Tick Lines from Top (Equatable so it never redraws during hover skimming!)
            if let deco = clipDecoration {
                EquatableView(content: deco)
            }

            // 3. Crisp Specular Inner Rim & Selection Border
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(
                    isSelected
                        ? Color.white.opacity(0.85)
                        : (isHovered ? Color.white.opacity(0.45) : Color.white.opacity(0.28)),
                    lineWidth: isSelected ? 1.5 : 1.0
                )

            // 4. Centered Title & Subtitle
            if segWidth > 42 {
                VStack(spacing: 1.5) {
                    Text(topTitle)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(subtitle != nil ? 0.55 : 0.92))
                        .lineLimit(1)

                    if let sub = subtitle, segWidth > 76 {
                        Text(sub)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.95))
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 12)
                .allowsHitTesting(false)
            }

            // 5. Interactive Split Mode Cut Line + Golden Teardrop Badge (`2s ✂️` — Positioned inside the top of the segment so it is NEVER clipped by the scroll view!)
            if isSplitMode, let splitX = hoverSplitX {
                let cutOffsetSec = Int(round((Double(splitX / max(1, segWidth)) * (endMs - startMs)) / 1000.0))
                ZStack(alignment: .top) {
                    Rectangle()
                        .fill(Color.white.opacity(0.92))
                        .frame(width: 1.5, height: height)

                    // Golden Split Teardrop Badge right at the top of the cut line (never clipped!)
                    VStack(spacing: 1) {
                        Text("\(cutOffsetSec)s")
                            .font(.system(size: 9.5, weight: .bold).monospacedDigit())
                        Image(systemName: "scissors")
                            .font(.system(size: 8.5, weight: .bold))
                    }
                    .foregroundStyle(.black.opacity(0.88))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3.5)
                    .background(
                        Color(red: 0.90, green: 0.65, blue: 0.24),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                    .offset(y: 2)
                }
                .offset(x: splitX)
                .allowsHitTesting(false)
            }

            // 6. Left & Right Edge Resize Bars (Inset 6.5pt inside the segment, smooth fade in/out)
            if !isSplitMode && segWidth >= 28 {
                HStack(spacing: 0) {
                    Capsule()
                        .fill(Color.white.opacity(0.92))
                        .frame(width: 3.5, height: max(8, height - 14))
                        .padding(.leading, 6.5)

                    Spacer(minLength: 4)

                    Capsule()
                        .fill(Color.white.opacity(0.92))
                        .frame(width: 3.5, height: max(8, height - 14))
                        .padding(.trailing, 6.5)
                }
                .opacity(showHandles ? 1.0 : 0.0)
                .animation(.easeInOut(duration: 0.15), value: showHandles)
                .allowsHitTesting(false)
            }
        }
        .opacity(isDimmed ? 0.35 : 1.0)
        .frame(width: segWidth, height: height)
        .overlay(
            RightClickDetectorView { pointInView, parentView in
                onRightClick(pointInView, parentView)
            }
        )
        .contentShape(Rectangle())
        .onContinuousHover(coordinateSpace: .local) { phase in
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
                    if segWidth >= 28 && (pt.x <= edgeHandleHitWidth || pt.x >= segWidth - edgeHandleHitWidth) {
                        NSCursor.resizeLeftRight.set()
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
        .offset(x: xOffset, y: verticalDragOffset)
        .zIndex(activeDragMode != nil ? 60 : (isHovered ? 30 : 1))
        .highPriorityGesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named("timelineContentSpace"))
                .onChanged { value in
                    if activeDragMode == nil {
                        let startInLane = value.startLocation.x - 20.0 // subtract `trackHorizontalInset`
                        let computedLocalX = startInLane - xOffset
                        let localX = (computedLocalX >= -4 && computedLocalX <= segWidth + 4)
                            ? max(0, min(segWidth, computedLocalX))
                            : lastHoverLocalX

                        pressLocalX = localX
                        hasExceededClickSlop = false
                        dragInitialStartMs = startMs
                        dragInitialEndMs = endMs

                        if !isSplitMode && segWidth >= 28 && localX <= edgeHandleHitWidth {
                            activeDragMode = .resizeLeft
                            NSCursor.resizeLeftRight.set()
                        } else if !isSplitMode && segWidth >= 28 && localX >= segWidth - edgeHandleHitWidth {
                            activeDragMode = .resizeRight
                            NSCursor.resizeLeftRight.set()
                        } else {
                            activeDragMode = .moveBody
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
                        let newStart = max(0.0, min(e0 - 250.0, s0 + deltaMs))
                        onResizeRange(newStart, e0)

                    case .resizeRight:
                        let newEnd = max(s0 + 250.0, s0 + (e0 - s0) + deltaMs)
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
                            let rowDelta = Int(round(value.translation.height / 42.0))
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
    }
}

// MARK: - AppKit Helpers for Right-Click Popover Trigger & NSScrollView Introspection

private struct RightClickDetectorView: NSViewRepresentable {
    let onRightClick: (NSPoint, NSView) -> Void

    func makeNSView(context: Context) -> RightClickCatcherNSView {
        let v = RightClickCatcherNSView()
        v.onRightClick = onRightClick
        return v
    }

    func updateNSView(_ nsView: RightClickCatcherNSView, context: Context) {
        nsView.onRightClick = onRightClick
    }

    final class RightClickCatcherNSView: NSView {
        var onRightClick: ((NSPoint, NSView) -> Void)?

        // Crucial: return `nil` from `hitTest` for normal left-clicks/drags/hovers so SwiftUI gestures work 100% normally,
        // and ONLY intercept right-clicks (or Control + Left Click)!
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard bounds.contains(point), let event = NSApp.currentEvent else {
                return nil
            }
            if event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control)) {
                return self
            }
            return nil
        }

        override func rightMouseDown(with event: NSEvent) {
            let localPt = convert(event.locationInWindow, from: nil)
            onRightClick?(localPt, self)
        }

        override func mouseDown(with event: NSEvent) {
            if event.modifierFlags.contains(.control) {
                let localPt = convert(event.locationInWindow, from: nil)
                onRightClick?(localPt, self)
            } else {
                super.mouseDown(with: event)
            }
        }
    }
}

private struct HorizontalScrollViewIntrospector: NSViewRepresentable {
    let onFound: (NSScrollView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let sv = view.enclosingScrollView {
                onFound(sv)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let sv = nsView.enclosingScrollView {
                onFound(sv)
            }
        }
    }
}
