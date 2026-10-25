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
    @State private var splitWigglePhase: Bool = false
    @State private var zoomTrackHoverX: CGFloat? = nil

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

                                // Top-Right Horizontally Synced Time Ruler + Golden Split Teardrop Badges at Cut Boundaries!
                                ZStack(alignment: .topLeading) {
                                    SmoothTimeRulerView(
                                        totalDurationMs: totalTimelineMs,
                                        width: contentWidth,
                                        majorStepSec: stepInfo.major,
                                        minorStepSec: stepInfo.minor
                                    )
                                    .offset(x: trackHorizontalInset)

                                    // Golden Split Teardrop Badges (`✂️`) at every cut boundary between adjacent ClipSlices (Matches Screenshot!)
                                    if session.timeMapper.mappedSlices.count > 1 {
                                        ForEach(Array(session.timeMapper.mappedSlices.dropLast().enumerated()), id: \.element.slice.id) { idx, mapped in
                                            let cutX = trackHorizontalInset + CGFloat(mapped.timelineEndMs / totalTimelineMs) * contentWidth
                                            let nextSliceId = session.timeMapper.mappedSlices[idx + 1].slice.id
                                            CutBoundaryTeardropBadgeView {
                                                // Clicking the golden scissors badge merges the two split slices back together!
                                                session.mergeSliceWithNext(id: mapped.slice.id)
                                            }
                                            .offset(x: cutX - 10.0, y: rulerHeight - 22.0)
                                            .help("Merge cut slices (\(mapped.slice.id.prefix(4)) + \(nextSliceId.prefix(4)))")
                                        }
                                    }
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
                        let typingSuggestions = session.activeTypingSuggestions
                        let hasTypingSuggestions = !typingSuggestions.isEmpty
                        let shortcutClusters = session.detectedShortcutClusters
                        let hasShortcutsTrack = !shortcutClusters.isEmpty

                        ScrollView(.vertical, showsIndicators: false) {
                            HStack(alignment: .top, spacing: 0) {
                                // B1. FIXED LEFT TRACK LABELS COLUMN
                                VStack(alignment: .leading, spacing: rowSpacing) {
                                    if hasTypingSuggestions {
                                        Color.clear
                                            .frame(width: labelColumnWidth, height: 19)
                                            .padding(.bottom, -4)
                                    }

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

                                    if hasShortcutsTrack {
                                        let shortcutsHidden = session.document.timeline.isShortcutsTrackHidden || !session.document.captions.showKeystrokes
                                        HStack(spacing: 6) {
                                            Button {
                                                session.toggleShortcutsTrackVisibility()
                                            } label: {
                                                Image(systemName: shortcutsHidden ? "eye.slash" : "eye")
                                                    .font(.system(size: 10, weight: .medium))
                                                    .foregroundStyle(Color.white.opacity(shortcutsHidden ? 0.28 : 0.65))
                                            }
                                            .buttonStyle(.plain)

                                            Text("Shortcuts")
                                                .font(.system(size: 11, weight: .medium))
                                                .foregroundStyle(Color.white.opacity(shortcutsHidden ? 0.30 : 0.65))
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
                                    TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !session.isSplitModeActive)) { timelineCtx in
                                        let baseWiggleY: CGFloat = session.isSplitModeActive
                                            ? CGFloat(sin(timelineCtx.date.timeIntervalSinceReferenceDate * (2.0 * .pi / 0.70))) * 1.0
                                            : 0.0

                                        ZStack(alignment: .topLeading) {
                                            VStack(alignment: .leading, spacing: rowSpacing) {
                                                // Lane 0 (Optional): Speed up typing suggestion bars right above Clip
                                                if hasTypingSuggestions {
                                                    typingSuggestionsLaneView(
                                                        suggestions: typingSuggestions,
                                                        contentWidth: contentWidth,
                                                        totalTimelineMs: totalTimelineMs
                                                    )
                                                    .padding(.bottom, -4)
                                                    .offset(y: baseWiggleY)
                                                }

                                                // Lane 1: Screen Clips (`52pt` height, with Ruler Tick Lines + Audio Waveform)
                                                clipLaneView(
                                                    contentWidth: contentWidth,
                                                    totalTimelineMs: totalTimelineMs,
                                                    minorTickStepSec: stepInfo.minor
                                                )
                                                .offset(y: baseWiggleY)

                                                // Lane 2: Auto-Zooms (`46pt` height, touching edge-to-edge)
                                                zoomLaneView(
                                                    contentWidth: contentWidth,
                                                    totalTimelineMs: totalTimelineMs
                                                )
                                                .offset(y: -baseWiggleY)

                                                // Lane 3+: Dynamic Mask Tracks (`34pt` height)
                                                ForEach(Array(session.document.timeline.maskTracks.enumerated()), id: \.element.id) { trackIdx, track in
                                                    let dir: CGFloat = ((2 + trackIdx) % 2 == 0) ? 1.0 : -1.0
                                                    maskLaneView(
                                                        track: track,
                                                        trackIndex: trackIdx,
                                                        contentWidth: contentWidth,
                                                        totalTimelineMs: totalTimelineMs
                                                    )
                                                    .offset(y: baseWiggleY * dir)
                                                }

                                                // Lane 4+: Keyboard Shortcuts Track (`34pt` height)
                                                if hasShortcutsTrack {
                                                    let dir: CGFloat = ((2 + session.document.timeline.maskTracks.count) % 2 == 0) ? 1.0 : -1.0
                                                    shortcutsLaneView(
                                                        clusters: shortcutClusters,
                                                        contentWidth: contentWidth,
                                                        totalTimelineMs: totalTimelineMs
                                                    )
                                                    .offset(y: baseWiggleY * dir)
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
                                    }
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
                        // 1. Ghost Hover Playhead (Smoothly ducks its teardrop head well below the main purple playhead!
                        //    When Split Tool `isSplitModeActive` is ON, its vertical stem turns RED!)
                        if let gx = hoverXInViewport, gx >= -8 && gx <= viewportWidth + 8 {
                            let distToMain = abs(gx - playheadXInViewport)
                            let proximity01 = max(0.0, min(1.0, 1.0 - (distToMain / 26.0)))
                            let duckYOffset = 22.0 * proximity01 * (2.0 - proximity01)

                            UnifiedPlayheadCanvasView(
                                headColor: Color(red: 0.25, green: 0.27, blue: 0.34).opacity(0.92),
                                stemColor: session.isSplitModeActive
                                    ? Color(red: 0.94, green: 0.32, blue: 0.26).opacity(0.90)
                                    : Color(red: 0.25, green: 0.27, blue: 0.34).opacity(0.65),
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
                let isPlayed = (session.effectivePreviewTimelineMs >= mapped.timelineStartMs && session.effectivePreviewTimelineMs <= mapped.timelineEndMs)

                TimelineInteractiveSegmentView(
                    topTitle: "Clip",
                    subtitleContent: .clip(
                        durationText: formatClipDurationOnly(durationMs: mapped.slice.timelineDurationMs),
                        speedText: formatSpeedMultiplier(mapped.slice.speed)
                    ),
                    palette: .clip,
                    isSelected: isSelected,
                    isPlayed: isPlayed,
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
                        let clickedTimelineMs = session.hoverSkimTimelineMs
                            ?? (mapped.timelineStartMs + frac * (mapped.timelineEndMs - mapped.timelineStartMs))
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
        let addPreview = (!session.isSplitModeActive && !isHidden)
            ? hoverAddZoomSpan(contentWidth: contentWidth, totalTimelineMs: totalTimelineMs)
            : nil

        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.018))

            // Empty-Track Prompt when no zooms exist and not hovering
            if session.document.timeline.zooms.isEmpty && addPreview == nil {
                Text("Click or drag to add zoom on cursor")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.white.opacity(0.35))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(red: 0.302, green: 0.184, blue: 0.961).opacity(0.08))
                    )
                    .allowsHitTesting(false)
            }

            // Hover `+` Ghost Add-Zoom Preview Block (`Screenshot_2026-10-25_at_11.39.25_PM.png`!)
            if let preview = addPreview {
                let previewX = CGFloat(preview.tStartMs / totalTimelineMs) * contentWidth
                let previewW = max(24.0, CGFloat((preview.tEndMs - preview.tStartMs) / totalTimelineMs) * contentWidth - 1.0)
                let palette = SegmentShaderPalette.zoom

                Button {
                    session.isPlaying = false
                    session.addZoomInRange(sourceStartMs: preview.srcStartMs, sourceEndMs: preview.srcEndMs)
                } label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [palette.fillTop, palette.fillBottom],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )

                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(palette.innerEdgeGlow, lineWidth: 7.0)
                            .blur(radius: 4.5)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(palette.ringBorder.opacity(0.82), lineWidth: 1.0)

                        Image(systemName: "plus")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.white.opacity(0.96))
                    }
                    .frame(width: previewW, height: zoomRowHeight)
                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .offset(x: previewX)
                .transition(.opacity.animation(.easeOut(duration: 0.12)))
            }

            ForEach(session.document.timeline.zooms) { zoom in
                if let (tStartMs, tEndMs) = timelineSpan(forSourceStartMs: zoom.sourceStartMs, sourceEndMs: zoom.sourceEndMs) {
                    let xStart = CGFloat(tStartMs / totalTimelineMs) * contentWidth
                    let blockW = max(18.0, CGFloat((tEndMs - tStartMs) / totalTimelineMs) * contentWidth)
                    let isSelected = (session.selectedZoomId == zoom.id)
                    let isPlayed = (session.effectivePreviewTimelineMs >= tStartMs && session.effectivePreviewTimelineMs <= tEndMs)
                    let timelineDurationMs = max(250.0, tEndMs - tStartMs)

                    TimelineInteractiveSegmentView(
                        topTitle: zoom.presentation == .loupe ? "Loupe" : "Zoom",
                        subtitleContent: .zoom(
                            scaleText: formatSpeedMultiplier(zoom.scale),
                            modeText: zoom.mode == .followCursor ? "Auto" : "Manual"
                        ),
                        palette: .zoom,
                        isSelected: isSelected,
                        isPlayed: isPlayed,
                        isDimmed: isHidden || zoom.disabled || zoom.scale <= 1.01,
                        isSplitMode: session.isSplitModeActive,
                        xOffset: xStart,
                        width: blockW,
                        height: zoomRowHeight,
                        totalWidth: contentWidth,
                        trackTotalDurationMs: totalTimelineMs,
                        startMs: tStartMs,
                        endMs: tEndMs,
                        allowDragMove: true,
                        allowVerticalTrackDrag: false,
                        clipDecoration: nil,
                        onClickAtLocalX: { localX in
                            let frac = max(0.0, min(1.0, Double(localX / max(1.0, blockW))))
                            let clickedTimelineMs = session.hoverSkimTimelineMs
                                ?? (tStartMs + frac * (tEndMs - tStartMs))
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
                        onMoveBody: { desiredTimelineStartMs, _ in
                            let clampedTimelineStart = max(0.0, min(totalTimelineMs - timelineDurationMs, desiredTimelineStartMs))
                            let clampedTimelineEnd = clampedTimelineStart + timelineDurationMs
                            let newSrcStart = session.timeMapper.sourceTime(forTimelineMs: clampedTimelineStart).sourceMs
                            let newSrcEnd = max(newSrcStart + 250.0, session.timeMapper.sourceTime(forTimelineMs: clampedTimelineEnd).sourceMs)
                            session.moveZoom(id: zoom.id, desiredStartMs: newSrcStart, durationMs: newSrcEnd - newSrcStart)
                        },
                        onResizeRange: { newTimelineStart, newTimelineEnd in
                            let newSrcStart = session.timeMapper.sourceTime(forTimelineMs: newTimelineStart).sourceMs
                            let newSrcEnd = session.timeMapper.sourceTime(forTimelineMs: newTimelineEnd).sourceMs
                            session.resizeZoom(id: zoom.id, newStartMs: newSrcStart, newEndMs: newSrcEnd)
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
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let pt):
                zoomTrackHoverX = max(0.0, min(contentWidth, pt.x))
            case .ended:
                zoomTrackHoverX = nil
            }
        }
    }

    private func hoverAddZoomSpan(
        contentWidth: CGFloat,
        totalTimelineMs: Double
    ) -> (tStartMs: Double, tEndMs: Double, srcStartMs: Double, srcEndMs: Double)? {
        guard let hoverX = zoomTrackHoverX, contentWidth > 10 else { return nil }
        let hoverTimelineMs = Double(hoverX / contentWidth) * totalTimelineMs

        // Build sorted existing zoom timeline spans
        var existingSpans: [(start: Double, end: Double)] = []
        for zoom in session.document.timeline.zooms {
            if let (ts, te) = timelineSpan(forSourceStartMs: zoom.sourceStartMs, sourceEndMs: zoom.sourceEndMs) {
                existingSpans.append((ts, te))
            }
        }
        existingSpans.sort { $0.start < $1.start }

        // If cursor is inside (or within 4pt of) an existing zoom segment, do NOT show the `+` preview
        let marginMs = Double(4.0 / contentWidth) * totalTimelineMs
        for span in existingSpans {
            if hoverTimelineMs >= span.start - marginMs && hoverTimelineMs <= span.end + marginMs {
                return nil
            }
        }

        let availStart = existingSpans.last(where: { $0.end <= hoverTimelineMs })?.end ?? 0.0
        let availEnd = existingSpans.first(where: { $0.start >= hoverTimelineMs })?.start ?? totalTimelineMs
        guard availEnd - availStart >= 500.0 else { return nil }

        let desiredDur = min(2800.0, availEnd - availStart)
        let tStart = max(availStart, min(availEnd - desiredDur, hoverTimelineMs - desiredDur * 0.5))
        let tEnd = min(availEnd, tStart + desiredDur)

        let srcStart = session.timeMapper.sourceTime(forTimelineMs: tStart).sourceMs
        let srcEnd = session.timeMapper.sourceTime(forTimelineMs: tEnd).sourceMs
        guard srcEnd - srcStart >= 350.0 else { return nil }
        return (tStart, tEnd, srcStart, srcEnd)
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
                    let isPlayed = (session.effectivePreviewTimelineMs >= tStartMs && session.effectivePreviewTimelineMs <= tEndMs)
                    let timelineDurationMs = max(220.0, tEndMs - tStartMs)

                    TimelineInteractiveSegmentView(
                        topTitle: "Mask",
                        subtitleContent: .mask(
                            text: item.type == .blur
                                ? "Sensitive data"
                                : String(format: "Highlight %d%%", Int(round(item.intensity)))
                        ),
                        palette: .mask,
                        isSelected: isSelected,
                        isPlayed: isPlayed,
                        isDimmed: isHidden || item.disabled,
                        isSplitMode: session.isSplitModeActive,
                        xOffset: xStart,
                        width: blockW,
                        height: maskRowHeight,
                        totalWidth: contentWidth,
                        trackTotalDurationMs: totalTimelineMs,
                        startMs: tStartMs,
                        endMs: tEndMs,
                        allowDragMove: true,
                        allowVerticalTrackDrag: true,
                        clipDecoration: nil,
                        onClickAtLocalX: { localX in
                            let frac = max(0.0, min(1.0, Double(localX / max(1.0, blockW))))
                            let clickedTimelineMs = session.hoverSkimTimelineMs
                                ?? (tStartMs + frac * (tEndMs - tStartMs))
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
                        onMoveBody: { desiredTimelineStartMs, constantTimelineDurMs in
                            let dur = max(220.0, constantTimelineDurMs)
                            let clampedTimelineStart = max(0.0, min(totalTimelineMs - dur, desiredTimelineStartMs))
                            let clampedTimelineEnd = clampedTimelineStart + dur
                            let newSrcStart = session.timeMapper.sourceTime(forTimelineMs: clampedTimelineStart).sourceMs
                            let newSrcEnd = max(newSrcStart + 220.0, session.timeMapper.sourceTime(forTimelineMs: clampedTimelineEnd).sourceMs)
                            session.moveMask(id: item.id, desiredStartMs: newSrcStart, durationMs: newSrcEnd - newSrcStart)
                        },
                        onResizeRange: { newTimelineStart, newTimelineEnd in
                            let newSrcStart = session.timeMapper.sourceTime(forTimelineMs: newTimelineStart).sourceMs
                            let newSrcEnd = session.timeMapper.sourceTime(forTimelineMs: newTimelineEnd).sourceMs
                            session.resizeMask(id: item.id, newStartMs: newSrcStart, newEndMs: newSrcEnd)
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

    // MARK: - 0. Speed Up Typing Suggestion Lane

    @ViewBuilder
    private func typingSuggestionsLaneView(
        suggestions: [ProjectSession.TypingSuggestionRange],
        contentWidth: CGFloat,
        totalTimelineMs: Double
    ) -> some View {
        ZStack(alignment: .leading) {
            ForEach(suggestions) { suggestion in
                if let (tStartMs, tEndMs) = timelineSpan(forSourceStartMs: suggestion.sourceStartMs, sourceEndMs: suggestion.sourceEndMs) {
                    let xStart = CGFloat(tStartMs / totalTimelineMs) * contentWidth
                    let blockW = max(24.0, CGFloat((tEndMs - tStartMs) / totalTimelineMs) * contentWidth - 1.0)

                    SpeedUpTypingSuggestionChipView(
                        session: session,
                        suggestion: suggestion,
                        width: blockW
                    )
                    .offset(x: xStart)
                }
            }
        }
        .frame(width: contentWidth, height: 19)
    }

    // MARK: - 4. Keyboard Shortcuts Track Lane

    @ViewBuilder
    private func shortcutsLaneView(
        clusters: [ProjectSession.ShortcutPressCluster],
        contentWidth: CGFloat,
        totalTimelineMs: Double
    ) -> some View {
        let trackHidden = session.document.timeline.isShortcutsTrackHidden || !session.document.captions.showKeystrokes

        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.015))

            ForEach(clusters) { cluster in
                if let (tStartMs, tEndMs) = timelineSpan(forSourceStartMs: cluster.displayStartMs, sourceEndMs: cluster.displayEndMs) {
                    let xStart = CGFloat(tStartMs / totalTimelineMs) * contentWidth
                    let blockW = max(22.0, CGFloat((tEndMs - tStartMs) / totalTimelineMs) * contentWidth - 1.0)
                    let isItemHidden = trackHidden || session.isShortcutHidden(cluster)

                    ShortcutTimelineSegmentView(
                        session: session,
                        cluster: cluster,
                        width: blockW,
                        height: maskRowHeight,
                        isHidden: isItemHidden
                    )
                    .offset(x: xStart)
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

    private func formatClipDurationOnly(durationMs: Double) -> String {
        let totalSec = Int(round(durationMs / 1000.0))
        let mins = totalSec / 60
        let secs = totalSec % 60
        return mins > 0 ? "\(mins)m \(secs)s" : "\(secs)s"
    }

    private func formatSpeedMultiplier(_ val: Double) -> String {
        let rounded = (val * 10.0).rounded() / 10.0
        if abs(rounded - rounded.rounded()) < 0.05 {
            return String(format: "%.0f×", rounded)
        }
        return String(format: "%.1f×", rounded)
    }
}

// MARK: - Unified Continuous Playhead Canvas (Zero-Overlap Single-Path Teardrop + Stem)

private struct CutBoundaryTeardropBadgeView: View {
    let onMergeClick: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onMergeClick) {
            ZStack {
                Canvas { context, size in
                    let centerX = size.width * 0.5
                    let radius: CGFloat = 8.5
                    let circleCenterY: CGFloat = 9.0
                    let tipY: CGFloat = 21.5

                    var path = Path()
                    path.addArc(
                        center: CGPoint(x: centerX, y: circleCenterY),
                        radius: radius,
                        startAngle: .degrees(142),
                        endAngle: .degrees(38),
                        clockwise: false
                    )
                    path.addLine(to: CGPoint(x: centerX, y: tipY))
                    path.closeSubpath()

                    let fillColor = isHovered
                        ? Color(red: 1.0, green: 0.72, blue: 0.22)
                        : Color(red: 0.95, green: 0.64, blue: 0.14)
                    context.fill(path, with: .color(fillColor))
                }

                Image(systemName: "scissors")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(.black.opacity(0.88))
                    .offset(y: -2.0)
            }
            .frame(width: 20, height: 22)
            .scaleEffect(isHovered ? 1.08 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
    }
}

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

// MARK: - Smooth Fixed-Interval Time Ruler

private struct SmoothTimeRulerView: View {
    let totalDurationMs: Double
    let width: CGFloat
    let majorStepSec: Double
    let minorStepSec: Double

    /// `Bf(pixelsPerPlaybackMs)`:
    /// Picks the closest interval from `[0.5, 1.0, 2.5, 5.0, 10.0, 30.0, 60.0, 120.0, 300.0]` seconds
    /// so that adjacent ruler marks are spaced around ~100–200px apart.
    /// In `Jp({timeMs})`, `let hasLabel = (timeMs % 1000 == 0)`:
    /// - When `markIntervalSec` is `0.5s` or `2.5s`, every other dot (`0.5s`, `2.5s`, `7.5s`, `12.5s`) is a half-second (`% 1000 != 0`) -> **dot only, no label**, while whole seconds (`1.0s`, `5.0s`, `10.0s`, `15.0s`) have **both dot + time label**!
    /// - When `markIntervalSec` is `1.0s`, `5.0s`, `10.0s`, `30.0s`, `60.0s`, every dot is an exact whole second (`% 1000 == 0`) -> **every dot has a time label**!
    static func computeStepIntervals(totalDurationMs: Double, width: CGFloat) -> (major: Double, minor: Double) {
        let totalMs = max(1000.0, totalDurationMs)
        let pxPerMs = max(0.001, Double(width) / totalMs)

        let targetPx: Double = 200.0
        var num = 1.0
        var den = 1.0
        var intervalMs = 1000.0
        for _ in 0..<500 {
            intervalMs = 1000.0 / (num / den)
            let spanPx = intervalMs * pxPerMs
            if spanPx > targetPx {
                num += 1.0
                continue
            }
            if spanPx < targetPx * 0.5 {
                den += 1.0
                continue
            }
            break
        }

        let candidatesSec: [Double] = [0.5, 1.0, 2.5, 5.0, 10.0, 30.0, 60.0, 120.0, 300.0, 600.0]
        let idealSec = intervalMs / 1000.0
        let chosenSec = candidatesSec.min(by: { abs($0 - idealSec) < abs($1 - idealSec) }) ?? 5.0
        return (chosenSec, chosenSec)
    }

    var body: some View {
        Canvas { context, size in
            let totalSec = max(1.0, totalDurationMs / 1000.0)
            let markStepSec = max(0.25, minorStepSec)
            let dotY = size.height - 6.0

            var stepIndex = 1 // filters `timeMs > 0 && timeMs < endMs`
            while true {
                let tSec = Double(stepIndex) * markStepSec
                if tSec >= totalSec - 0.001 { break }

                let x = CGFloat(tSec / totalSec) * size.width
                let timeMsInt = Int(round(tSec * 1000.0))
                let isWholeSecond = (timeMsInt % 1000 == 0)

                // Crisp circular dot (`4px` diameter -> radius `2.0pt`, `opacity: 0.30`)
                let dotRadius: CGFloat = 1.8
                let dotRect = CGRect(x: x - dotRadius, y: dotY - dotRadius, width: dotRadius * 2, height: dotRadius * 2)
                context.fill(Path(ellipseIn: dotRect), with: .color(.white.opacity(0.32)))

                // Draw time label ONLY when `timeMs % 1000 == 0`!
                if isWholeSecond && x >= 14 && x <= size.width - 14 {
                    let totalWholeSec = timeMsInt / 1000
                    let mins = totalWholeSec / 60
                    let secs = totalWholeSec % 60
                    let labelStr = String(format: "%d:%02d", mins, secs)

                    let text = Text(labelStr)
                        .font(.system(size: 11, weight: .semibold, design: .default).monospacedDigit())
                        .foregroundColor(.white.opacity(0.34))
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
            // A. Smooth Catmull-Rom Cubic Spline + Mip-Pyramid Audio Waveform
            if !waveformSamples.isEmpty && totalSourceMs > 1.0 && volumeScale > 0.005 {
                let startFrac = max(0.0, min(1.0, sourceStartMs / totalSourceMs))
                let endFrac = max(startFrac + 0.001, min(1.0, sourceEndMs / totalSourceMs))
                let clampedVol = CGFloat(min(1.5, max(0.0, volumeScale)))

                // Build multi-resolution max-reduction mipmap pyramid (plus slight neighbor smoothing so bins have organic continuity)
                let pyramid = Self.buildWaveformPyramid(from: waveformSamples)
                let baseCount = Double(waveformSamples.count)
                let sliceSampleSpan = max(1.0, (endFrac - startFrac) * baseCount)

                // `pxPerBin = 5.0` (`Wg = 5` when `enableSmoothWaveform` is enabled):
                // Each control bin spans ~11px on screen, and Catmull-Rom cubic spline (`readPyramidLevel`)
                // evaluates every 1.5px between bins to form rolling mountain-dune peaks & valleys!
                let pxPerBin: Double = 11.0
                let samplesPerBin = max(1.0, (sliceSampleSpan / Double(max(1.0, size.width))) * pxPerBin)
                let maxWaveHeightPx: CGFloat = min(size.height * 0.68, 32.0)

                let stepPx: CGFloat = 1.5
                let pointCount = max(4, Int(ceil(size.width / stepPx)))

                var wavePath = Path()
                wavePath.move(to: CGPoint(x: 0, y: size.height))

                for i in 0...pointCount {
                    let localFrac = Double(i) / Double(pointCount)
                    let globalFrac = startFrac + localFrac * (endFrac - startFrac)
                    let samplePos = globalFrac * baseCount

                    let env01 = Self.readWaveformEnvelope(
                        pyramid: pyramid,
                        samplePosition: samplePos,
                        samplesPerBin: samplesPerBin
                    )
                    let x = CGFloat(localFrac) * size.width
                    let waveH = min(size.height * 0.82, CGFloat(env01) * maxWaveHeightPx * clampedVol)
                    wavePath.addLine(to: CGPoint(x: x, y: size.height - waveH))
                }

                wavePath.addLine(to: CGPoint(x: size.width, y: size.height))
                wavePath.closeSubpath()

                // `fillUnder` + `system-audio` color (`#4D2FF5`, top opacity `0.50` -> bottom opacity `0.25`)
                // Blended over the golden Clip gradient, this produces the exact rich purple-to-warm-lavender gradient in
                context.fill(
                    wavePath,
                    with: .linearGradient(
                        Gradient(colors: [
                            Color(red: 0.302, green: 0.184, blue: 0.961).opacity(0.52),
                            Color(red: 0.302, green: 0.184, blue: 0.961).opacity(0.25)
                        ]),
                        startPoint: CGPoint(x: 0, y: size.height - maxWaveHeightPx),
                        endPoint: CGPoint(x: 0, y: size.height)
                    )
                )

                // When slice volume < 100%, also draws a subtle ghost outline of the 100% waveform (`outlineColor` with `opacity: 0.10`)
                if clampedVol < 0.99 {
                    var unscaledPath = Path()
                    unscaledPath.move(to: CGPoint(x: 0, y: size.height))
                    for i in 0...pointCount {
                        let localFrac = Double(i) / Double(pointCount)
                        let globalFrac = startFrac + localFrac * (endFrac - startFrac)
                        let samplePos = globalFrac * baseCount
                        let env01 = Self.readWaveformEnvelope(
                            pyramid: pyramid,
                            samplePosition: samplePos,
                            samplesPerBin: samplesPerBin
                        )
                        let x = CGFloat(localFrac) * size.width
                        let waveH = min(size.height * 0.82, CGFloat(env01) * maxWaveHeightPx)
                        unscaledPath.addLine(to: CGPoint(x: x, y: size.height - waveH))
                    }
                    unscaledPath.addLine(to: CGPoint(x: size.width, y: size.height))
                    unscaledPath.closeSubpath()
                    context.fill(
                        unscaledPath,
                        with: .color(Color(red: 0.302, green: 0.184, blue: 0.961).opacity(0.12))
                    )
                }
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
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .allowsHitTesting(false)
    }

    // MARK: - Exact Mip-Pyramid + Catmull-Rom Cubic Spline

    private static func buildWaveformPyramid(from baseSamples: [Float]) -> [[Float]] {
        guard !baseSamples.isEmpty else { return [] }
        var levels: [[Float]] = [baseSamples]
        while let last = levels.last, last.count > 2 {
            let nextCount = (last.count + 1) / 2
            var nextLevel = [Float](repeating: 0, count: nextCount)
            for i in 0..<nextCount {
                let left = last[i * 2]
                let right = last[min(last.count - 1, i * 2 + 1)]
                nextLevel[i] = max(left, right)
            }
            levels.append(nextLevel)
        }
        return levels
    }

    private static func readLevelBin(_ level: [Float], index: Int) -> Double {
        guard !level.isEmpty else { return 0.0 }
        if index < 0 || index >= level.count {
            return 0.0
        }
        return Double(level[index])
    }

    /// Evaluates the 4-point Catmull-Rom Cubic Spline at `samplePosition` on `levelIndex`:
    /// `curve = left + 0.5 * t * (linearTerm + t * (quadraticTerm + t * cubicTerm))`
    private static func readPyramidLevel(pyramid: [[Float]], levelIndex: Int, samplePosition: Double) -> Double {
        guard levelIndex >= 0 && levelIndex < pyramid.count else { return 0.0 }
        let level = pyramid[levelIndex]
        let scale = pow(2.0, Double(levelIndex))
        let binPosition = (samplePosition / scale) - 0.5
        let leftPosition = floor(binPosition)
        let t = binPosition - leftPosition
        let leftIndex = Int(leftPosition)

        let before = readLevelBin(level, index: leftIndex - 1)
        let left   = readLevelBin(level, index: leftIndex)
        let right  = readLevelBin(level, index: leftIndex + 1)
        let after  = readLevelBin(level, index: leftIndex + 2)

        let linearTerm = right - before
        let quadraticTerm = 2.0 * before - 5.0 * left + 4.0 * right - after
        let cubicTerm = 3.0 * (left - right) + after - before

        let curve = left + 0.5 * t * (linearTerm + t * (quadraticTerm + t * cubicTerm))
        return min(1.0, max(0.0, curve))
    }

    /// Trilinearly blends between `lowerLevel` and `upperLevel` of the Catmull-Rom pyramid based on `log2(samplesPerBin)`.
    private static func readWaveformEnvelope(pyramid: [[Float]], samplePosition: Double, samplesPerBin: Double) -> Double {
        guard !pyramid.isEmpty else { return 0.0 }
        let maxLevel = Double(pyramid.count - 1)
        let level = min(maxLevel, max(0.0, log2(max(1.0, samplesPerBin))))
        let lowerFloor = floor(level)
        let lowerLevel = Int(lowerFloor)
        let upperLevel = min(pyramid.count - 1, lowerLevel + 1)
        let frac = level - lowerFloor

        let lowVal = readPyramidLevel(pyramid: pyramid, levelIndex: lowerLevel, samplePosition: samplePosition)
        if lowerLevel == upperLevel || frac <= 0.0001 {
            return lowVal
        }
        let highVal = readPyramidLevel(pyramid: pyramid, levelIndex: upperLevel, samplePosition: samplePosition)
        return lowVal + (highVal - lowVal) * frac
    }
}

// MARK: - Segment Shader Palette

private struct SegmentShaderPalette: Equatable {
    let fillTop: Color
    let fillBottom: Color
    let innerEdgeGlow: Color
    let playedInnerEdgeGlow: Color
    let ringBorder: Color
    let playedRingBorder: Color

    /// Clip (`#93610C`):
    /// - `fillTop`: `#93610C` (`0.576, 0.380, 0.047`)
    /// - `fillBottom` (`lightness(+15)`): `#DA9012` (`0.855, 0.565, 0.071`)
    /// - `glow` (`darken(0.2).opacity(0.8)`): `#764E0A` (`0.463, 0.306, 0.039, 0.80`)
    /// - `ring` (`lightness(+40)`): `#F4C677` (`0.957, 0.776, 0.467`)
    /// - `playedRing` (`lightness(+15)`): `#DA9012` (`0.855, 0.565, 0.071`)
    static let clip = SegmentShaderPalette(
        fillTop: Color(red: 0.576, green: 0.380, blue: 0.047),
        fillBottom: Color(red: 0.855, green: 0.565, blue: 0.071),
        innerEdgeGlow: Color(red: 0.463, green: 0.306, blue: 0.039).opacity(0.80),
        playedInnerEdgeGlow: Color(red: 0.576, green: 0.380, blue: 0.047).opacity(0.50),
        ringBorder: Color(red: 0.957, green: 0.776, blue: 0.467),
        playedRingBorder: Color(red: 0.855, green: 0.565, blue: 0.071)
    )

    /// Zoom (`#4D2FF5`):
    /// - `fillTop`: `#4D2FF5` (`0.302, 0.184, 0.961`)
    /// - `fillBottom` (`lightness(+15)`): `#8B78F9` (`0.545, 0.471, 0.976`)
    /// - `glow` (`darken(0.2).opacity(0.8)`): `#2B0BDF` (`0.169, 0.043, 0.875, 0.80`)
    /// - `ring` (`lightness(+40)`): `#F4F2FE` (`0.957, 0.949, 0.996`)
    /// - `playedRing` (`lightness(+15)`): `#8B78F9` (`0.545, 0.471, 0.976`)
    static let zoom = SegmentShaderPalette(
        fillTop: Color(red: 0.302, green: 0.184, blue: 0.961),
        fillBottom: Color(red: 0.545, green: 0.471, blue: 0.976),
        innerEdgeGlow: Color(red: 0.169, green: 0.043, blue: 0.875).opacity(0.80),
        playedInnerEdgeGlow: Color(red: 0.302, green: 0.184, blue: 0.961).opacity(0.50),
        ringBorder: Color(red: 0.957, green: 0.949, blue: 0.996),
        playedRingBorder: Color(red: 0.545, green: 0.471, blue: 0.976)
    )

    /// Mask (`#82345A`):
    /// - `fillTop`: `#82345A` (`0.510, 0.204, 0.353`)
    /// - `fillBottom` (`lightness(+15)`): `#B74B80` (`0.718, 0.294, 0.502`)
    /// - `glow` (`darken(0.2).opacity(0.8)`): `#682A48` (`0.408, 0.165, 0.282, 0.80`)
    /// - `ring` (`lightness(+40)`): `#DCA6C0` (`0.863, 0.651, 0.753`)
    /// - `playedRing` (`lightness(+15)`): `#B74B80` (`0.718, 0.294, 0.502`)
    static let mask = SegmentShaderPalette(
        fillTop: Color(red: 0.510, green: 0.204, blue: 0.353),
        fillBottom: Color(red: 0.718, green: 0.294, blue: 0.502),
        innerEdgeGlow: Color(red: 0.408, green: 0.165, blue: 0.282).opacity(0.80),
        playedInnerEdgeGlow: Color(red: 0.510, green: 0.204, blue: 0.353).opacity(0.50),
        ringBorder: Color(red: 0.863, green: 0.651, blue: 0.753),
        playedRingBorder: Color(red: 0.718, green: 0.294, blue: 0.502)
    )
}

// MARK: - Interactive Segment Block with Shader Look, Waveform, Inset Handles & Normal-Weight Icon Labels

private enum SegmentSubtitleContent: Equatable {
    case clip(durationText: String, speedText: String)
    case zoom(scaleText: String, modeText: String)
    case mask(text: String)
}

private struct TimelineInteractiveSegmentView: View {
    private enum SegmentDragMode {
        case resizeLeft
        case resizeRight
        case moveBody
    }

    let topTitle: String
    let subtitleContent: SegmentSubtitleContent
    let palette: SegmentShaderPalette
    let isSelected: Bool
    let isPlayed: Bool
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
    @State private var dragInitialSegWidth: CGFloat = 60.0
    @State private var verticalDragOffset: CGFloat = 0.0

    private let edgeHandleHitWidth: CGFloat = 11.0

    var body: some View {
        // 1px visual gap between adjacent touching segments
        let segWidth = max(6.0, width - 1.0)
        let edgeHitWidth = min(edgeHandleHitWidth, max(5.0, segWidth * 0.22))
        let showHandles = !isSplitMode && segWidth >= 28 && (isSelected || isHovered)
        // Always keep the segment colors and border 100% vibrant (do NOT darken when mouse leaves!)
        let outerRingColor: Color = isSelected ? Color.white : palette.ringBorder

        ZStack(alignment: .leading) {
            // 1. `shadeBody` Vertical LinearGradient (`fillTop` -> `fillBottom`) + Inner Edge Blurred Glow (`glowColor * glowAlpha`)
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [palette.fillTop, palette.fillBottom],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(palette.innerEdgeGlow, lineWidth: 7.0)
                    .blur(radius: 4.5)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            // When `isDimmed` (e.g. Zoom = `1x` or disabled), the `shadeBody` multiplies body opacity by `disabledOpacity = Xm = 0.50`!
            .opacity(isDimmed ? 0.50 : 1.0)

            // 2. Clip-Specific Decoration: Audio Waveform along Bottom + Ruler Vertical Tick Lines from Top (Equatable so it never redraws during hover skimming!)
            if let deco = clipDecoration {
                EquatableView(content: deco)
            }

            // 3. Crisp 1px Outer Ring Border ( when dimmed at 1x zoom!)
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    outerRingColor.opacity(isSelected ? 0.98 : (isDimmed ? 0.44 : 0.84)),
                    lineWidth: 1.0
                )

            // 4. Centered Title & Icon Subtitle (Matches Images 2, 5, 6, 7 — Regular/Normal weight!)
            if segWidth > 42 {
                VStack(spacing: 1.5) {
                    Text(topTitle)
                        .font(.system(size: 11.0, weight: .regular))
                        .foregroundStyle(.white.opacity(isDimmed ? 0.34 : 0.48))
                        .lineLimit(1)

                    if segWidth > 64 {
                        subtitleRowView
                            .opacity(isDimmed ? 0.62 : 1.0)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 10)
                .allowsHitTesting(false)
            }

            // 5. Left & Right Edge Resize Bars (Inset 6.5pt inside the segment, smooth fade in/out)
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
                // Crucial: because `.offset(x: xOffset)` is applied AFTER `.onContinuousHover(coordinateSpace: .local)`,
                // SwiftUI passes `pt.x` in the parent `ZStack` coordinate space (`xOffset .. xOffset + segWidth`).
                // Subtracting `xOffset` gives the true `[0 .. segWidth]` local coordinate!
                let localX = (pt.x >= xOffset - 2 && pt.x <= xOffset + segWidth + 2) ? (pt.x - xOffset) : pt.x
                lastHoverLocalX = max(0, min(segWidth, localX))
                if !isHovered {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isHovered = true
                    }
                }
                if isSplitMode {
                    NSCursor.crosshair.set()
                } else {
                    if segWidth >= 28 && (lastHoverLocalX <= edgeHitWidth || lastHoverLocalX >= segWidth - edgeHitWidth) {
                        NSCursor.resizeLeftRight.set()
                    } else {
                        NSCursor.arrow.set()
                    }
                }
            case .ended:
                withAnimation(.easeInOut(duration: 0.15)) {
                    isHovered = false
                }
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
                        let localX = min(max(0, computedLocalX), segWidth)

                        pressLocalX = localX
                        hasExceededClickSlop = false
                        dragInitialStartMs = startMs
                        dragInitialEndMs = endMs
                        dragInitialSegWidth = max(12.0, width)

                        if !isSplitMode && segWidth >= 32 && localX <= edgeHitWidth {
                            activeDragMode = .resizeLeft
                            NSCursor.resizeLeftRight.set()
                        } else if !isSplitMode && segWidth >= 32 && localX >= segWidth - edgeHitWidth {
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
                        let newEnd = max(s0 + 250.0, e0 + deltaMs)
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

    @ViewBuilder
    private var subtitleRowView: some View {
        switch subtitleContent {
        case .clip(let durationText, let speedText):
            HStack(spacing: 6) {
                Text(durationText)
                    .font(.system(size: 12.0, weight: .regular))
                HStack(spacing: 3) {
                    Image(systemName: "gauge.with.dots.needle.67percent")
                        .font(.system(size: 10.5, weight: .regular))
                    Text(speedText)
                        .font(.system(size: 12.0, weight: .regular))
                }
            }
            .foregroundStyle(.white.opacity(0.96))
            .lineLimit(1)

        case .zoom(let scaleText, let modeText):
            // (`magnifyingglass` + `1.6×` + `computermouse.fill` + `Auto`)
            HStack(spacing: 8) {
                HStack(spacing: 3.5) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10.5, weight: .semibold))
                    Text(scaleText)
                        .font(.system(size: 12.0, weight: .regular))
                }
                HStack(spacing: 3.5) {
                    Image(systemName: "computermouse.fill")
                        .font(.system(size: 10.5, weight: .regular))
                    Text(modeText)
                        .font(.system(size: 12.0, weight: .regular))
                }
            }
            .foregroundStyle(.white.opacity(0.96))
            .lineLimit(1)

        case .mask(let text):
            // Matches Images 6 & 7 (White solid rounded rectangle chip icon + `Sensitive data` or `Highlight 50%`)
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 2.2, style: .continuous)
                    .fill(Color.white.opacity(0.96))
                    .frame(width: 11.0, height: 8.0)
                Text(text)
                    .font(.system(size: 11.5, weight: .regular))
                    .foregroundStyle(.white.opacity(0.96))
            }
            .lineLimit(1)
        }
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

// MARK: - Speed Up Typing Suggestion Chip & Popover

private struct SpeedUpTypingSuggestionChipView: View {
    @Bindable var session: ProjectSession
    let suggestion: ProjectSession.TypingSuggestionRange
    let width: CGFloat

    @State private var isHovered = false
    @State private var isShowingPopover = false
    @State private var anchorNSView: NSView?
    @AppStorage("NativeScreen.TypingSuggestionPreferredSpeed") private var preferredSpeed: Double = 3.0

    var body: some View {
        Button {
            SharedFloatingTooltipWindowController.shared.hideTooltip(ifOwnedBy: anchorNSView)
            isShowingPopover = true
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.40, green: 0.27, blue: 0.04),
                                Color(red: 0.56, green: 0.37, blue: 0.05)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                    .strokeBorder(
                        (isHovered || isShowingPopover)
                            ? Color.white.opacity(0.95)
                            : Color(red: 0.94, green: 0.76, blue: 0.44).opacity(0.72),
                        lineWidth: 1.0
                    )

                Image(systemName: "keyboard")
                    .font(.system(size: 10.5, weight: .regular))
                    .foregroundStyle(.white.opacity(0.95))
            }
            .frame(width: width, height: 17)
            .background(
                TooltipScreenRectProbe { v in
                    anchorNSView = v
                }
            )
            .contentShape(RoundedRectangle(cornerRadius: 5.5, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovered = hovering
            }
            if hovering && !isShowingPopover, let v = anchorNSView, let win = v.window {
                let rectInWin = v.convert(v.bounds, to: nil)
                let screenRect = win.convertToScreen(rectInWin)
                SharedFloatingTooltipWindowController.shared.showTooltip(
                    text: "Speed up typing",
                    edge: .top,
                    forButtonScreenRect: screenRect,
                    ownerView: v
                )
            } else {
                SharedFloatingTooltipWindowController.shared.hideTooltip(ifOwnedBy: anchorNSView)
            }
        }
        .popover(isPresented: $isShowingPopover, arrowEdge: .top) {
            SpeedUpTypingPopoverView(
                preferredSpeed: $preferredSpeed,
                onApplySingle: {
                    session.applyTypingSuggestion(suggestion, speed: preferredSpeed)
                    isShowingPopover = false
                },
                onApplyAll: {
                    session.applyAllTypingSuggestions(speed: preferredSpeed)
                    isShowingPopover = false
                },
                onRemove: {
                    session.dismissTypingSuggestion(suggestion)
                    isShowingPopover = false
                }
            )
        }
    }
}

private struct SpeedUpTypingPopoverView: View {
    @Binding var preferredSpeed: Double
    let onApplySingle: () -> Void
    let onApplyAll: () -> Void
    let onRemove: () -> Void

    var body: some View {
        let isModified = abs(preferredSpeed - 3.0) > 0.05

        VStack(alignment: .leading, spacing: 14) {
            // 1. Header (`⌨️ Speed up typing`)
            HStack(spacing: 8) {
                Image(systemName: "keyboard")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
                Text("Speed up typing")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.96))
                Spacer()
                Text(String(format: "%.1f×", preferredSpeed))
                    .font(.system(size: 12.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.55))
            }

            // 2. Description
            Text("You are typing during this part of the recording. Speed it up using options below.")
                .font(.system(size: 12.5, weight: .regular))
                .foregroundStyle(.white.opacity(0.46))
                .fixedSize(horizontal: false, vertical: true)

            // 3. Purple Slider (`1.5× ... 8.0×`, reset value `3.0×`) + Reset Button
            HStack(spacing: 12) {
                Slider(
                    value: Binding(
                        get: { preferredSpeed },
                        set: { preferredSpeed = ($0 * 2.0).rounded() / 2.0 }
                    ),
                    in: 1.5...8.0
                )
                .tint(Color(red: 0.44, green: 0.34, blue: 0.98))
                .controlSize(.regular)

                Button {
                    withAnimation(.easeOut(duration: 0.14)) {
                        preferredSpeed = 3.0
                    }
                } label: {
                    Text("Reset")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(isModified ? .white.opacity(0.95) : .white.opacity(0.28))
                        .frame(width: 64, height: 30)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.white.opacity(isModified ? 0.07 : 0.03))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Color.white.opacity(isModified ? 0.14 : 0.06), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .disabled(!isModified)
            }

            // 4. Action Buttons (`Apply all suggestions ⌘ ↵` & `Apply suggestion ↵`)
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Button(action: onApplyAll) {
                        HStack(spacing: 6) {
                            Text("Apply all suggestions")
                                .font(.system(size: 12.5, weight: .medium))
                            Text("⌘ ↵")
                                .font(.system(size: 11.5, weight: .medium))
                                .opacity(0.75)
                        }
                        .foregroundStyle(Color(red: 0.65, green: 0.56, blue: 1.0))
                        .frame(maxWidth: .infinity)
                        .frame(height: 34)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.white.opacity(0.04))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.return, modifiers: [.command])

                    Button(action: onApplySingle) {
                        HStack(spacing: 6) {
                            Text("Apply suggestion")
                                .font(.system(size: 12.5, weight: .semibold))
                            Text("↵")
                                .font(.system(size: 11.5, weight: .semibold))
                                .opacity(0.90)
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 34)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color(red: 0.302, green: 0.184, blue: 0.961))
                        )
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.return, modifiers: [])
                }

                // 5. Remove suggestion
                Button(action: onRemove) {
                    Text("Remove suggestion")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.90))
                        .frame(maxWidth: .infinity)
                        .frame(height: 34)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.white.opacity(0.04))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(18)
        .frame(width: 356)
        .background(Color(red: 0.07, green: 0.07, blue: 0.09))
        .preferredColorScheme(.dark)
    }
}

// MARK: - Keyboard Shortcut Timeline Segment

private struct ShortcutTimelineSegmentView: View {
    @Bindable var session: ProjectSession
    let cluster: ProjectSession.ShortcutPressCluster
    let width: CGFloat
    let height: CGFloat
    let isHidden: Bool

    @State private var isHovered = false
    @State private var anchorNSView: NSView?

    private let primaryPurple = Color(red: 0.302, green: 0.184, blue: 0.961) // `#4D2FF5`

    var body: some View {
        let tooltipText: String = {
            if !session.document.captions.showKeystrokes {
                return "Enable shortcuts"
            }
            return isHidden ? "Show shortcut" : "Hide shortcut"
        }()

        Button {
            SharedFloatingTooltipWindowController.shared.hideTooltip(ifOwnedBy: anchorNSView)
            session.toggleShortcutHidden(cluster)
        } label: {
            ZStack {
                // 1. `W_` Gradient (`primary.opacity(0.4) -> primary.opacity(0.0)`)
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                primaryPurple.opacity(isHidden ? 0.14 : 0.42),
                                primaryPurple.opacity(isHidden ? 0.03 : 0.08)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                // 2. Inner bottom glow (`W_:before`: `inset: 4px 2px; opacity: 0.3; linear-gradient(to top, primary.opacity(0.4), transparent)`)
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                primaryPurple.opacity(isHidden ? 0.05 : 0.22),
                                Color.clear
                            ],
                            startPoint: .bottom,
                            endPoint: .top
                        )
                    )
                    .padding(.vertical, 4)
                    .padding(.horizontal, 2)

                // 3. Outer 1px Outline (`outline: 1px solid primary`)
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(
                        primaryPurple.opacity(isHidden ? (isHovered ? 0.45 : 0.22) : (isHovered ? 0.95 : 0.85)),
                        lineWidth: 1.0
                    )

                // 4. Centered Shortcut Label (`⌥ ⌃ Space`, `⌘ A`, `⌫`, `⌘ →`, `D`)
                if width >= 22 {
                    Text(cluster.compactTimelineLabel)
                        .font(.system(size: 12.0, weight: .semibold))
                        .foregroundStyle(.white.opacity(isHidden ? 0.38 : 0.96))
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                }
            }
            .frame(width: width, height: height)
            .shadow(
                color: isHidden ? .clear : primaryPurple.opacity(isHovered ? 0.32 : 0.18),
                radius: 6
            )
            .background(
                TooltipScreenRectProbe { v in
                    anchorNSView = v
                }
            )
            .overlay(
                RightClickDetectorView { pointInView, parentView in
                    NativeSegmentContextMenuPresenter.shared.presentShortcutContextMenu(
                        session: session,
                        cluster: cluster,
                        at: pointInView,
                        in: parentView
                    )
                }
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovered = hovering
            }
            if hovering, let v = anchorNSView, let win = v.window {
                let rectInWin = v.convert(v.bounds, to: nil)
                let screenRect = win.convertToScreen(rectInWin)
                SharedFloatingTooltipWindowController.shared.showTooltip(
                    text: tooltipText,
                    edge: .top,
                    forButtonScreenRect: screenRect,
                    ownerView: v
                )
            } else {
                SharedFloatingTooltipWindowController.shared.hideTooltip(ifOwnedBy: anchorNSView)
            }
        }
        .onChange(of: isHidden) { _, _ in
            if isHovered, let v = anchorNSView, let win = v.window {
                let rectInWin = v.convert(v.bounds, to: nil)
                let screenRect = win.convertToScreen(rectInWin)
                let newText = !session.document.captions.showKeystrokes
                    ? "Enable shortcuts"
                    : (isHidden ? "Show shortcut" : "Hide shortcut")
                SharedFloatingTooltipWindowController.shared.showTooltip(
                    text: newText,
                    edge: .top,
                    forButtonScreenRect: screenRect,
                    ownerView: v
                )
            }
        }
    }
}
