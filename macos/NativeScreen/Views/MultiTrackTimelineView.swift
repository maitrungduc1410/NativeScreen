import SwiftUI
import AppKit

/// Multi-Track NLE Timeline:
/// - **Unified Continuous Playhead** (teardrop head + vertical stem drawn as a single connected shape with zero gap).
/// - **Ghost Playhead "Ducking" Animation** (when hovering near the main purple playhead, the grey ghost playhead head smoothly ducks down underneath it).
/// - **Ruler Dots & Clip Vertical Tick Lines** (major labels + minor dots, with matching vertical tick lines inside the Clip bar).
/// - **Audio Waveform Inside Clip** (smooth purple-tinted waveform rendered along the bottom of the Clip segment).
/// - **Edge-to-Edge Touching Segments** (zero artificial gap when segments touch).
/// - **Anchored Timeline Zoom** (buttons and pinch keep the playhead in place; Cmd + scroll keeps the point under the cursor).
/// - **Native Liquid Glass Right-Click Context Popovers**.
public struct MultiTrackTimelineView: View {
    @Bindable var session: ProjectSession
    @State private var pinchBaseZoom: Double?

    // Track scroll offsets & NSScrollView reference for playhead-anchored zooming
    @State private var horizontalScrollOffset: CGFloat = 0.0
    @State private var verticalScrollOffset: CGFloat = 0.0
    @State private var verticalContentHeight: CGFloat = 180.0
    @State private var horizontalScrollView: NSScrollView?
    @State private var horizontalScrollObserver = TimelineScrollObserver()
    @State private var verticalScrollObserver = TimelineScrollObserver()
    @State private var lastZoomForAnchor: Double = 1.0
    /// Set by Cmd + scroll: the x inside the track viewport that should stay put on the next zoom change.
    @State private var zoomAnchorViewportX: CGFloat?
    /// When the last scroll or pinch zoom step happened. A class so writing it does not re-render the timeline.
    @State private var zoomClock = TimelineZoomClock()
    @State private var zoomTrackHoverX: CGFloat? = nil
    @State private var cameraLayoutTrackHoverX: CGFloat? = nil
    @State private var maskTrackHoverX: [String: CGFloat] = [:]
    @State private var captionTrackHoverX: [String: CGFloat] = [:]
    @State private var shortcutTrackHoverX: [String: CGFloat] = [:]

    private let labelColumnWidth: CGFloat = 126
    private let trackHorizontalInset: CGFloat = 20
    private let rulerHeight: CGFloat = 30
    private let clipRowHeight: CGFloat = 48
    private let zoomRowHeight: CGFloat = 48
    private let maskRowHeight: CGFloat = 34
    private let rowSpacing: CGFloat = 12

    @State private var snapController = TimelineSnapController()

    public init(session: ProjectSession) {
        self.session = session
    }

    /// Right-click menu of a track label: hide or show, and delete for every track except the clip and zoom tracks.
    @ViewBuilder
    private func trackLabelMenu(isHidden: Bool, toggle: @escaping () -> Void, delete: (() -> Void)? = nil) -> some View {
        Button(isHidden ? "Show Track" : "Hide Track", systemImage: isHidden ? "eye" : "eye.slash", action: toggle)
        if let delete {
            Divider()
            Button("Delete Track", systemImage: "trash", role: .destructive, action: delete)
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            GeometryReader { outerGeo in
                let viewportWidth = max(300, outerGeo.size.width - labelColumnWidth)
                let viewportHeight = max(80, outerGeo.size.height - rulerHeight)
                let baseTrackWidth = max(260, viewportWidth - trackHorizontalInset * 2)
                let contentWidth = baseTrackWidth * CGFloat(session.timelineZoom)
                let totalDocumentWidth = contentWidth + trackHorizontalInset * 2
                // Freeze `totalTimelineMs` while resizing a clip
                // so the ruler ticks and timeline scale stay 100% stationary while dragging a clip handle!
                let totalTimelineMs = max(1000.0, session.frozenPlaybackDurationMs ?? session.timeMapper.totalTimelineDurationMs)
                let stepInfo = SmoothTimeRulerView.computeStepIntervals(totalDurationMs: totalTimelineMs, width: contentWidth)

                ZStack(alignment: .topLeading) {
                    VStack(spacing: 0) {
                        // A. FIXED TOP RULER BAR
                        HStack(spacing: 0) {
                            // Top-Left Corner Header
                            HStack {
                                Text("Tracks")
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .foregroundStyle(.ink.opacity(0.32))
                                    .padding(.leading, 14)
                                Spacer()
                            }
                            .frame(width: labelColumnWidth, height: rulerHeight)
                            .background(Color.surface(red: 0.04, green: 0.04, blue: 0.06))
                            .overlay(alignment: .trailing) {
                                Rectangle()
                                    .fill(Color.ink.opacity(0.06))
                                    .frame(width: 1)
                            }
                            .zIndex(20)

                                // Top-Right Horizontally Synced Time Ruler + Golden Split / Trim Teardrop Badges!
                                ZStack(alignment: .topLeading) {
                                    SmoothTimeRulerView(
                                        totalDurationMs: totalTimelineMs,
                                        width: contentWidth,
                                        majorStepSec: stepInfo.major,
                                        minorStepSec: stepInfo.minor
                                    )
                                    .offset(x: trackHorizontalInset)
                                    // VoiceOver: the ruler moves the playhead by a second (VO-Up / VO-Down). No value on
                                    // purpose: reading the playhead here would re-evaluate the timeline every frame; the
                                    // transport timecode carries it.
                                    .accessibilityElement(children: .ignore)
                                    .accessibilityLabel(Text("Playhead"))
                                    .accessibilityAdjustableAction { direction in
                                        let step: Double = direction == .increment ? 1000 : -1000
                                        session.isPlaying = false
                                        session.seek(toTimelineMs: max(0, min(totalTimelineMs, session.playheadTimelineMs + step)))
                                    }

                                    // Golden Teardrop Badges (`✂️` or `0.6s ✂️`) for Start Trim, Inter-Slice Cuts/Trims, and End Trim
                                    let badges = computeClipTrimAndCutBadges()
                                    ForEach(badges) { badge in
                                        let cutX = trackHorizontalInset + CGFloat(badge.timelineMs / totalTimelineMs) * contentWidth
                                        CutBoundaryTeardropBadgeView(
                                            trimmedDurationLabel: badge.trimmedDurationLabel,
                                            tooltipText: badge.tooltipText
                                        ) {
                                            badge.action()
                                        }
                                        .offset(x: cutX - 15.0, y: rulerHeight - 28.0)
                                        .zIndex(10)
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
                        .background(Color.surface(red: 0.04, green: 0.04, blue: 0.06))

                        // B. VERTICALLY SCROLLABLE BODY (Fixed Left Labels + Horizontally Scrollable Track Lanes)
                        let typingSuggestions = session.activeTypingSuggestions
                        let hasTypingSuggestions = !typingSuggestions.isEmpty
                        let hasCameraLayoutsTrack = !session.document.timeline.cameraLayouts.isEmpty
                        let hasVoiceoversTrack = !session.document.timeline.voiceovers.isEmpty || session.isRecordingVoiceover
                        let voiceoverTrackCount = max(
                            session.document.timeline.voiceovers.voiceoverTrackCount,
                            session.isRecordingVoiceover ? session.voiceoverRecordingTrackIndex + 1 : 0
                        )
                        let hasShortcutsTrack = !session.document.captions.shortcutTracks.isEmpty
                        let captionTracks = session.document.captions.captionTracks

                        ScrollViewReader { verticalScrollProxy in
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
                                                .foregroundStyle(.ink.opacity(0.65))
                                        }
                                        .padding(.leading, 14)
                                        .frame(width: labelColumnWidth, height: clipRowHeight, alignment: .leading)
                                        .id("track_clip")

                                        let zoomHidden = session.document.timeline.isZoomTrackHidden
                                        HStack(spacing: 6) {
                                            Button {
                                                session.toggleZoomTrackVisibility()
                                            } label: {
                                                Image(systemName: zoomHidden ? "eye.slash" : "eye")
                                                    .accessibilityLabel(Text((zoomHidden ? "Show Track" : "Hide Track").localizedUI))
                                                    .font(.system(size: 10, weight: .medium))
                                                    .foregroundStyle(Color.ink.opacity(zoomHidden ? 0.28 : 0.65))
                                                    .frame(width: 22, height: 22)
                                                    .contentShape(Rectangle())
                                            }
                                            .buttonStyle(.plain)

                                            Text("Zoom")
                                                .font(.system(size: 11, weight: .medium))
                                                .foregroundStyle(Color.ink.opacity(zoomHidden ? 0.30 : 0.65))
                                        }
                                        .padding(.leading, 10)
                                        .frame(width: labelColumnWidth, height: zoomRowHeight, alignment: .leading)
                                        .contentShape(Rectangle())
                                        .contextMenu { trackLabelMenu(isHidden: zoomHidden, toggle: { session.toggleZoomTrackVisibility() }) }
                                        .id("track_zoom")

                                        if hasCameraLayoutsTrack {
                                            let layoutsHidden = session.document.timeline.isCameraLayoutsTrackHidden
                                            HStack(spacing: 6) {
                                                Button {
                                                    session.toggleCameraLayoutsTrackVisibility()
                                                } label: {
                                                    Image(systemName: layoutsHidden ? "eye.slash" : "eye")
                                                        .accessibilityLabel(Text((layoutsHidden ? "Show Track" : "Hide Track").localizedUI))
                                                        .font(.system(size: 10, weight: .medium))
                                                        .foregroundStyle(Color.ink.opacity(layoutsHidden ? 0.28 : 0.65))
                                                        .frame(width: 22, height: 22)
                                                        .contentShape(Rectangle())
                                                }
                                                .buttonStyle(.plain)

                                                Text("Layouts")
                                                    .font(.system(size: 11, weight: .medium))
                                                    .foregroundStyle(Color.ink.opacity(layoutsHidden ? 0.30 : 0.65))
                                                    .lineLimit(1)
                                            }
                                            .padding(.leading, 10)
                                            .frame(width: labelColumnWidth, height: maskRowHeight, alignment: .leading)
                                            .contentShape(Rectangle())
                                            .contextMenu {
                                                trackLabelMenu(isHidden: layoutsHidden, toggle: { session.toggleCameraLayoutsTrackVisibility() }) {
                                                    session.deleteTimelineTrack(.cameraLayouts, displayName: "Layouts")
                                                }
                                            }
                                            .id("track_camera_layouts")
                                        }

                                        ForEach(session.document.timeline.maskTracks) { track in
                                            let maskHidden = track.isHidden
                                            HStack(spacing: 6) {
                                                Button {
                                                    session.toggleMaskTrackVisibility(trackId: track.id)
                                                } label: {
                                                    Image(systemName: maskHidden ? "eye.slash" : "eye")
                                                        .accessibilityLabel(Text((maskHidden ? "Show Track" : "Hide Track").localizedUI))
                                                        .font(.system(size: 10, weight: .medium))
                                                        .foregroundStyle(Color.ink.opacity(maskHidden ? 0.28 : 0.65))
                                                        .frame(width: 22, height: 22)
                                                        .contentShape(Rectangle())
                                                }
                                                .buttonStyle(.plain)

                                                Text(track.name.localizedTrackName)
                                                    .font(.system(size: 11, weight: .medium))
                                                    .foregroundStyle(Color.ink.opacity(maskHidden ? 0.30 : 0.65))
                                                    .lineLimit(1)
                                            }
                                            .padding(.leading, 10)
                                            .frame(width: labelColumnWidth, height: maskRowHeight, alignment: .leading)
                                            .contentShape(Rectangle())
                                            .contextMenu {
                                                trackLabelMenu(isHidden: maskHidden, toggle: { session.toggleMaskTrackVisibility(trackId: track.id) }) {
                                                    session.deleteTimelineTrack(.mask(id: track.id), displayName: track.name)
                                                }
                                            }
                                            .id("track_mask_\(track.id)")
                                        }

                                        ForEach(session.document.timeline.annotationTracks) { track in
                                            let annotationHidden = track.isHidden
                                            HStack(spacing: 6) {
                                                Button {
                                                    session.toggleAnnotationTrackVisibility(trackId: track.id)
                                                } label: {
                                                    Image(systemName: annotationHidden ? "eye.slash" : "eye")
                                                        .accessibilityLabel(Text((annotationHidden ? "Show Track" : "Hide Track").localizedUI))
                                                        .font(.system(size: 10, weight: .medium))
                                                        .foregroundStyle(Color.ink.opacity(annotationHidden ? 0.28 : 0.65))
                                                        .frame(width: 22, height: 22)
                                                        .contentShape(Rectangle())
                                                }
                                                .buttonStyle(.plain)

                                                Text(track.name.localizedTrackName)
                                                    .font(.system(size: 11, weight: .medium))
                                                    .foregroundStyle(Color.ink.opacity(annotationHidden ? 0.30 : 0.65))
                                                    .lineLimit(1)
                                                    .minimumScaleFactor(0.85)
                                            }
                                            .padding(.leading, 10)
                                            .frame(width: labelColumnWidth, height: maskRowHeight, alignment: .leading)
                                            .contentShape(Rectangle())
                                            .contextMenu {
                                                trackLabelMenu(isHidden: annotationHidden, toggle: { session.toggleAnnotationTrackVisibility(trackId: track.id) }) {
                                                    session.deleteTimelineTrack(.annotation(id: track.id), displayName: track.name)
                                                }
                                            }
                                            .id("track_annotation_\(track.id)")
                                        }

                                        if hasVoiceoversTrack {
                                            ForEach(0..<voiceoverTrackCount, id: \.self) { voTrack in
                                                let voHidden = session.document.timeline.isVoiceoverTrackHidden(voTrack)
                                                HStack(spacing: 6) {
                                                    Button {
                                                        session.toggleVoiceoverTrackVisibility(trackIndex: voTrack)
                                                    } label: {
                                                        Image(systemName: voHidden ? "eye.slash" : "eye")
                                                            .accessibilityLabel(Text((voHidden ? "Show Track" : "Hide Track").localizedUI))
                                                            .font(.system(size: 10, weight: .medium))
                                                            .foregroundStyle(Color.ink.opacity(voHidden ? 0.28 : 0.65))
                                                            .frame(width: 22, height: 22)
                                                            .contentShape(Rectangle())
                                                    }
                                                    .buttonStyle(.plain)

                                                    Text(voTrack == 0 ? "Voiceovers" : "Voiceovers \(voTrack + 1)")
                                                        .font(.system(size: 11, weight: .medium))
                                                        .foregroundStyle(Color.ink.opacity(voHidden ? 0.30 : 0.65))
                                                        .lineLimit(1)
                                                }
                                                .padding(.leading, 10)
                                                .frame(width: labelColumnWidth, height: maskRowHeight, alignment: .leading)
                                                .contentShape(Rectangle())
                                                .contextMenu {
                                                    trackLabelMenu(
                                                        isHidden: voHidden,
                                                        toggle: { session.toggleVoiceoverTrackVisibility(trackIndex: voTrack) },
                                                        delete: session.isRecordingVoiceover ? nil : {
                                                            let name = voTrack == 0
                                                                ? "Voiceovers".localizedUI
                                                                : String(format: "Voiceovers %lld".localizedUI, voTrack + 1)
                                                            session.deleteTimelineTrack(.voiceover(index: voTrack), displayName: name)
                                                        }
                                                    )
                                                }
                                                .id(voTrack == 0 ? "track_voiceovers" : "track_voiceovers_\(voTrack)")
                                            }
                                        }

                                        if hasShortcutsTrack {
                                            ForEach(Array(session.document.captions.shortcutTracks.enumerated()), id: \.element.id) { sIdx, sTrack in
                                                let isTrackHidden = sTrack.isHidden
                                                    || (sIdx == 0 && session.document.timeline.isShortcutsTrackHidden)
                                                    || !session.document.captions.showKeystrokes

                                                HStack(spacing: 6) {
                                                    Button {
                                                        session.toggleShortcutsTrackVisibility(trackId: sTrack.id)
                                                    } label: {
                                                        Image(systemName: isTrackHidden ? "eye.slash" : "eye")
                                                            .accessibilityLabel(Text((isTrackHidden ? "Show Track" : "Hide Track").localizedUI))
                                                            .font(.system(size: 10, weight: .medium))
                                                            .foregroundStyle(Color.ink.opacity(isTrackHidden ? 0.28 : 0.65))
                                                            .frame(width: 22, height: 22)
                                                            .contentShape(Rectangle())
                                                    }
                                                    .buttonStyle(.plain)

                                                    Button {
                                                        session.selectedShortcutId = nil
                                                        session.selectedInspectorTab = .shortcuts
                                                    } label: {
                                                        Text((session.document.captions.shortcutTracks.count > 1 ? sTrack.name : "Shortcuts").localizedTrackName)
                                                            .font(.system(size: 11, weight: .medium))
                                                            .foregroundStyle(Color.ink.opacity(isTrackHidden ? 0.30 : 0.65))
                                                            .lineLimit(1)
                                                            .minimumScaleFactor(0.85)
                                                            .frame(maxHeight: .infinity)
                                                            .contentShape(Rectangle())
                                                    }
                                                    .buttonStyle(.plain)
                                                }
                                                .padding(.leading, 10)
                                                .frame(width: labelColumnWidth, height: maskRowHeight, alignment: .leading)
                                                .contentShape(Rectangle())
                                                .contextMenu {
                                                    trackLabelMenu(isHidden: isTrackHidden, toggle: { session.toggleShortcutsTrackVisibility(trackId: sTrack.id) }) {
                                                        let name = session.document.captions.shortcutTracks.count > 1 ? sTrack.name : "Shortcuts"
                                                        session.deleteTimelineTrack(.shortcut(id: sTrack.id), displayName: name)
                                                    }
                                                }
                                                .id("track_shortcut_\(sTrack.id)")
                                            }
                                        }

                                        ForEach(captionTracks) { track in
                                            let isTrackHidden = track.isHidden || !session.document.captions.enabled

                                            HStack(spacing: 6) {
                                                Button {
                                                    session.toggleCaptionTrackVisibility(id: track.id)
                                                } label: {
                                                    Image(systemName: isTrackHidden ? "eye.slash" : "eye")
                                                        .accessibilityLabel(Text((isTrackHidden ? "Show Track" : "Hide Track").localizedUI))
                                                        .font(.system(size: 10, weight: .medium))
                                                        .foregroundStyle(Color.ink.opacity(isTrackHidden ? 0.28 : 0.65))
                                                        .frame(width: 22, height: 22)
                                                        .contentShape(Rectangle())
                                                }
                                                .buttonStyle(.plain)

                                                Button {
                                                    session.selectCaption(nil)
                                                    session.selectedInspectorTab = .captions
                                                } label: {
                                                    Text(track.name.localizedTrackName)
                                                        .font(.system(size: 11, weight: .medium))
                                                        .foregroundStyle(Color.ink.opacity(isTrackHidden ? 0.30 : 0.65))
                                                        .lineLimit(1)
                                                        .minimumScaleFactor(0.85)
                                                        .frame(maxHeight: .infinity)
                                                        .contentShape(Rectangle())
                                                }
                                                .buttonStyle(.plain)
                                            }
                                            .padding(.leading, 10)
                                            .frame(width: labelColumnWidth, height: maskRowHeight, alignment: .leading)
                                            .contentShape(Rectangle())
                                            .contextMenu {
                                                trackLabelMenu(isHidden: isTrackHidden, toggle: { session.toggleCaptionTrackVisibility(id: track.id) }) {
                                                    session.deleteTimelineTrack(.caption(id: track.id), displayName: track.name)
                                                }
                                            }
                                            .id("track_caption_\(track.id)")
                                        }
                                    }
                                    .padding(.vertical, 8)
                                    .background(Color.surface(red: 0.04, green: 0.04, blue: 0.06))
                                    .overlay(alignment: .trailing) {
                                        Rectangle()
                                            .fill(Color.ink.opacity(0.06))
                                            .frame(width: 1)
                                    }
                                    .zIndex(15)

                                    // B2. HORIZONTALLY SCROLLABLE TRACK LANES
                                    ScrollView(.horizontal, showsIndicators: false) {
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
                                                }

                                                // Lane 1: Screen Clips (`52pt` height, with Ruler Tick Lines + Audio Waveform)
                                                clipLaneView(
                                                    contentWidth: contentWidth,
                                                    totalTimelineMs: totalTimelineMs,
                                                    minorTickStepSec: stepInfo.minor
                                                )
                                                .modifier(splitWiggle(trackOrder: 0))

                                                // Lane 2: Auto-Zooms (`46pt` height, touching edge-to-edge)
                                                zoomLaneView(
                                                    contentWidth: contentWidth,
                                                    totalTimelineMs: totalTimelineMs
                                                )
                                                .modifier(splitWiggle(trackOrder: 1))

                                                // Lane 2B: Camera Layouts
                                                if hasCameraLayoutsTrack {
                                                    cameraLayoutsLaneView(
                                                        contentWidth: contentWidth,
                                                        totalTimelineMs: totalTimelineMs
                                                    )
                                                    .modifier(splitWiggle(trackOrder: 2))
                                                }

                                                // Lane 3+: Dynamic Mask Tracks (`34pt` height)
                                                let firstMaskOrder = hasCameraLayoutsTrack ? 3 : 2
                                                let firstAnnotationOrder = firstMaskOrder + session.document.timeline.maskTracks.count
                                                let firstVoiceoverOrder = firstAnnotationOrder + session.document.timeline.annotationTracks.count
                                                let firstShortcutOrder = firstVoiceoverOrder + voiceoverTrackCount
                                                ForEach(Array(session.document.timeline.maskTracks.enumerated()), id: \.element.id) { trackIdx, track in
                                                    maskLaneView(
                                                        track: track,
                                                        trackIndex: trackIdx,
                                                        contentWidth: contentWidth,
                                                        totalTimelineMs: totalTimelineMs
                                                    )
                                                    .modifier(splitWiggle(trackOrder: firstMaskOrder + trackIdx))
                                                }

                                                // Lane 3A: Annotation Tracks
                                                ForEach(Array(session.document.timeline.annotationTracks.enumerated()), id: \.element.id) { trackIdx, track in
                                                    annotationLaneView(
                                                        track: track,
                                                        trackIndex: trackIdx,
                                                        contentWidth: contentWidth,
                                                        totalTimelineMs: totalTimelineMs
                                                    )
                                                    .modifier(splitWiggle(trackOrder: firstAnnotationOrder + trackIdx))
                                                }

                                                // Lane 3B: Voiceovers Track
                                                if hasVoiceoversTrack {
                                                    ForEach(0..<voiceoverTrackCount, id: \.self) { voTrack in
                                                        voiceoversLaneView(
                                                            trackIndex: voTrack,
                                                            contentWidth: contentWidth,
                                                            totalTimelineMs: totalTimelineMs
                                                        )
                                                        .modifier(splitWiggle(trackOrder: firstVoiceoverOrder + voTrack))
                                                    }
                                                }

                                                // Lane 4+: Multi-Track Keyboard Shortcuts Lanes (`34pt` height)
                                                if hasShortcutsTrack {
                                                    ForEach(Array(session.document.captions.shortcutTracks.enumerated()), id: \.element.id) { sIdx, sTrack in
                                                        shortcutsLaneView(
                                                            track: sTrack,
                                                            trackIndex: sIdx,
                                                            clusters: session.shortcutClusters(forTrackId: sTrack.id),
                                                            contentWidth: contentWidth,
                                                            totalTimelineMs: totalTimelineMs
                                                        )
                                                        .modifier(splitWiggle(trackOrder: firstShortcutOrder + sIdx))
                                                    }
                                                }

                                                // Lane 5+: Caption Tracks
                                                let firstCaptionOrder = firstShortcutOrder + (hasShortcutsTrack ? session.document.captions.shortcutTracks.count : 0)
                                                ForEach(Array(captionTracks.enumerated()), id: \.element.id) { trackIdx, track in
                                                    captionLaneView(
                                                        track: track,
                                                        trackIndex: trackIdx,
                                                        contentWidth: contentWidth,
                                                        totalTimelineMs: totalTimelineMs
                                                    )
                                                    .modifier(splitWiggle(trackOrder: firstCaptionOrder + trackIdx))
                                                }
                                            }
                                            .padding(.vertical, 8)
                                            .padding(.horizontal, trackHorizontalInset)
                                            .background(
                                                HorizontalScrollViewIntrospector(
                                                    isSplitMode: session.isSplitModeActive,
                                                    alwaysShowScroller: EditorViewPreferences.shared.alwaysShowTimelineScrollbar
                                                ) { sv in
                                                    if horizontalScrollView !== sv {
                                                        horizontalScrollView = sv
                                                    }
                                                    if #unavailable(macOS 15.0) {
                                                        horizontalScrollObserver.observe(sv) { applyHorizontalScroll($0.contentOffset.x) }
                                                        if let vertical = sv.superview?.enclosingScrollView {
                                                            verticalScrollObserver.observe(vertical, onChange: applyVerticalScroll)
                                                        }
                                                    }
                                                }
                                            )
                                        }
                                        .frame(width: totalDocumentWidth)
                                        // As tall as the whole pane, so a segment dragged below the last track is not cut off.
                                        .frame(minHeight: max(0.0, outerGeo.size.height - rulerHeight), alignment: .topLeading)
                                        .coordinateSpace(name: "timelineContentSpace")
                                        .onContinuousHover(coordinateSpace: .named("timelineContentSpace")) { phase in
                                            switch phase {
                                            case .active(let pt):
                                                guard !session.isDraggingTimelineSegment && NSEvent.pressedMouseButtons == 0 else { return }
                                                // The content moves under a still cursor while zooming. Re-skimming the
                                                // preview on every step costs a seek per frame for no visible change.
                                                guard !zoomClock.isZooming else { return }
                                                if session.isSplitModeActive {
                                                    NSCursor.crosshair.set()
                                                }
                                                let localTrackX = pt.x - trackHorizontalInset
                                                let frac = max(0.0, min(1.0, Double(localTrackX / max(1.0, contentWidth))))
                                                session.setHoverSkimTimelineMs(frac * totalTimelineMs)
                                            case .ended:
                                                if !session.isDraggingTimelineSegment {
                                                    session.setHoverSkimTimelineMs(nil)
                                                }
                                                if session.isSplitModeActive {
                                                    NSCursor.arrow.set()
                                                }
                                            }
                                        }
                                        .simultaneousGesture(
                                            SpatialTapGesture(coordinateSpace: .named("timelineContentSpace"))
                                                .onEnded { event in
                                                    let localTrackX = event.location.x - trackHorizontalInset
                                                    let frac = max(0.0, min(1.0, Double(localTrackX / max(1.0, contentWidth))))
                                                    session.isPlaying = false
                                                    session.clearTimelineSelection()
                                                    session.seek(toTimelineMs: frac * totalTimelineMs)
                                                }
                                        )
                                    }
                                    .onTimelineScrollChange(of: \.contentOffset.x, action: applyHorizontalScroll)
                                }
                            }
                            .onTimelineScrollChange(of: \.self, action: applyVerticalScroll)
                            .onChange(of: session.scrollToTrackRevision) { _, _ in
                                guard let targetId = session.scrollToTrackTargetId else { return }
                                DispatchQueue.main.async {
                                    withAnimation(.spring(response: 0.30, dampingFraction: 0.86)) {
                                        verticalScrollProxy.scrollTo(targetId, anchor: .bottom)
                                    }
                                }
                            }
                        }
                    }

                    // C. UNIFIED CONTINUOUS GHOST PLAYHEAD + COMMITTED PLAYHEAD OVERLAY
                    // Isolated in its own `@Observable`-scoped `TimelinePlayheadsOverlayView` so 120Hz `playheadTimelineMs`
                    // and `hoverSkimTimelineMs` updates NEVER re-evaluate the timeline tracks or segments!
                    TimelinePlayheadsOverlayView(
                        session: session,
                        trackHorizontalInset: trackHorizontalInset,
                        contentWidth: contentWidth,
                        totalTimelineMs: totalTimelineMs,
                        horizontalScrollOffset: horizontalScrollOffset,
                        viewportWidth: viewportWidth,
                        totalHeight: outerGeo.size.height
                    )
                    .frame(width: viewportWidth, height: outerGeo.size.height, alignment: .topLeading)
                    .clipped()
                    .offset(x: labelColumnWidth)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .zIndex(25)

                    TimelineSnapGuideOverlayView(
                        snap: snapController,
                        trackHorizontalInset: trackHorizontalInset,
                        contentWidth: contentWidth,
                        totalTimelineMs: totalTimelineMs,
                        horizontalScrollOffset: horizontalScrollOffset,
                        viewportWidth: viewportWidth,
                        topInset: rulerHeight
                    )
                    .frame(width: viewportWidth, height: outerGeo.size.height, alignment: .topLeading)
                    .clipped()
                    .offset(x: labelColumnWidth)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .zIndex(24)

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
                                    .fill(Color.ink.opacity(0.24))
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
                                    .fill(Color.ink.opacity(0.24))
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
                        totalTimelineMs: totalTimelineMs,
                        anchorViewportX: zoomAnchorViewportX
                    )
                    zoomAnchorViewportX = nil
                }
                // Cmd + scroll wheel anywhere over the timeline (ruler, labels, tracks) zooms around the cursor.
                .background(
                    TimelineCommandScrollZoomCatcher { locationX, factor in
                        zoomClock.mark()
                        let viewportX = locationX - labelColumnWidth
                        zoomAnchorViewportX = viewportX >= 0 ? viewportX : nil
                        let newZoom = max(1.0, min(6.0, session.timelineZoom * factor))
                        if newZoom != session.timelineZoom {
                            session.timelineZoom = newZoom
                        } else {
                            zoomAnchorViewportX = nil
                        }
                    }
                )
                // Trackpad 2-Finger Pinch-to-Zoom Gesture
                .gesture(
                    MagnifyGesture()
                        .onChanged { value in
                            if pinchBaseZoom == nil {
                                pinchBaseZoom = session.timelineZoom
                            }
                            zoomClock.mark()
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
        .background(Color.surface(red: 0.04, green: 0.04, blue: 0.06))
        .environment(snapController)
        .onAppear { snapController.attach(session) }
    }

    /// Neighboring tracks move in opposite directions.
    private func splitWiggle(trackOrder: Int) -> SplitModeWiggle {
        SplitModeWiggle(isActive: session.isSplitModeActive, direction: trackOrder % 2 == 0 ? 1.0 : -1.0)
    }

    private func applyHorizontalScroll(_ offsetX: CGFloat) {
        horizontalScrollOffset = max(0, offsetX)
    }

    private func applyVerticalScroll(_ geometry: TimelineScrollGeometry) {
        verticalScrollOffset = max(0, geometry.contentOffset.y)
        verticalContentHeight = max(1, geometry.contentSize.height)
    }

    /// Adjusts the horizontal `NSScrollView` content offset whenever `timelineZoom` changes so the anchor stays
    /// at the same pixel on screen. The anchor is the playhead, or the cursor (`anchorViewportX`) for Cmd + scroll.
    private func anchorScrollOffsetAroundPlayhead(
        oldZoom: Double,
        newZoom: Double,
        baseTrackWidth: CGFloat,
        viewportWidth: CGFloat,
        totalTimelineMs: Double,
        anchorViewportX: CGFloat? = nil
    ) {
        guard let sv = horizontalScrollView else { return }
        let oldContentW = baseTrackWidth * CGFloat(oldZoom)
        let newContentW = baseTrackWidth * CGFloat(newZoom)
        let newTotalDocW = newContentW + trackHorizontalInset * 2

        let currentScrollX = sv.contentView.bounds.origin.x
        let anchorFrac: CGFloat
        let anchorX: CGFloat
        if let anchorViewportX {
            anchorX = anchorViewportX
            anchorFrac = max(0, min(1, (currentScrollX + anchorViewportX - trackHorizontalInset) / max(1, oldContentW)))
        } else {
            anchorFrac = CGFloat(session.playheadTimelineMs / max(1.0, totalTimelineMs))
            anchorX = trackHorizontalInset + anchorFrac * oldContentW - currentScrollX
        }

        let desiredNewScrollX = (trackHorizontalInset + anchorFrac * newContentW) - anchorX
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
            Color.clear
                .frame(width: contentWidth, height: clipRowHeight)
                .contentShape(Rectangle())

            ForEach(session.timeMapper.mappedSlices, id: \.slice.id) { mapped in
                let xStart = CGFloat(mapped.timelineStartMs / totalTimelineMs) * contentWidth
                let blockW = max(12.0, CGFloat((mapped.timelineEndMs - mapped.timelineStartMs) / totalTimelineMs) * contentWidth)
                let isSelected = (session.selectedSliceId == mapped.slice.id && session.selectedZoomId == nil && session.selectedMaskId == nil)
                let isOtherSliceSelected = (session.selectedSliceId != nil && session.selectedSliceId != mapped.slice.id && session.selectedZoomId == nil && session.selectedMaskId == nil)
                let isPlayedNow = session.playedTimelineItemIds.contains(mapped.slice.id)

                TimelineInteractiveSegmentView(
                    topTitle: "Clip",
                    subtitleContent: .clip(
                        durationText: formatClipDurationOnly(durationMs: mapped.slice.timelineDurationMs),
                        speedText: formatSpeedMultiplier(mapped.slice.speed)
                    ),
                    palette: .clip,
                    isSelected: isSelected,
                    isPlayed: isPlayedNow,
                    isDimmed: isOtherSliceSelected,
                    isDimmedBySelection: isOtherSliceSelected,
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
                        volumeScale: (mapped.slice.muted || session.document.audio.muteSystemAudio)
                            ? 0.0
                            : (mapped.slice.systemAudioVolume * session.document.audio.systemAudioVolume),
                        waveformSamples: session.audioWaveformSamples,
                        microphoneVolumeScale: (mapped.slice.muted || session.document.audio.muteMicrophone)
                            ? 0.0
                            : (mapped.slice.microphoneVolume * session.document.audio.microphoneVolume),
                        microphoneWaveformSamples: session.microphoneWaveformSamples
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
        let isMousePressed = (NSEvent.pressedMouseButtons != 0)
        let addPreview = (!session.isSplitModeActive && !session.isDraggingTimelineSegment && !isMousePressed && !isHidden)
            ? hoverAddZoomSpan(contentWidth: contentWidth, totalTimelineMs: totalTimelineMs)
            : nil

        ZStack(alignment: .leading) {
            Color.clear
                .frame(width: contentWidth, height: zoomRowHeight)
                .contentShape(Rectangle())

            // Empty-Track Prompt when no zooms exist and not hovering
            if session.document.timeline.zooms.isEmpty && addPreview == nil {
                Text("Click or drag to add zoom on cursor")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.ink.opacity(0.35))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color(red: 0.302, green: 0.184, blue: 0.961).opacity(0.08))
                    )
                    .allowsHitTesting(false)
            }

            // Hover `+` Ghost Add-Zoom Preview Block
            if let preview = addPreview {
                let previewX = CGFloat(preview.tStartMs / totalTimelineMs) * contentWidth
                let previewW = max(24.0, CGFloat((preview.tEndMs - preview.tStartMs) / totalTimelineMs) * contentWidth - 1.0)
                let palette = SegmentShaderPalette.zoom

                Button {
                    session.isPlaying = false
                    session.addZoomInRange(sourceStartMs: preview.srcStartMs, sourceEndMs: preview.srcEndMs)
                } label: {
                    ZStack {
                        SegmentBodyCanvas(
                            palette: palette,
                            isSelected: false,
                            isPlayed: false
                        )

                        Image(systemName: "plus")

                            .accessibilityLabel(Text("Add"))
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.ink.opacity(0.96))
                    }
                    .frame(width: previewW, height: zoomRowHeight)
                    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
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
                    let isOtherZoomSelected = (session.selectedZoomId != nil && session.selectedZoomId != zoom.id)
                    let isPlayedNow = session.playedTimelineItemIds.contains(zoom.id)

                    TimelineInteractiveSegmentView(
                        topTitle: zoom.presentation == .loupe ? "Loupe" : "Zoom",
                        subtitleContent: .zoom(
                            scaleText: formatSpeedMultiplier(zoom.scale),
                            modeText: zoom.mode == .followCursor ? "Auto" : "Manual"
                        ),
                        palette: .zoom,
                        isSelected: isSelected,
                        isPlayed: isPlayedNow,
                        isDimmed: isHidden || zoom.disabled || zoom.scale <= 1.01,
                        isDimmedBySelection: isOtherZoomSelected,
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
                        snapItemId: zoom.id,
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
                        onMoveBody: { desiredTimelineStartMs, constantTimelineDurMs in
                            let durMs = max(250.0, constantTimelineDurMs)
                            let clampedTimelineStart = max(0.0, min(totalTimelineMs - durMs, desiredTimelineStartMs))
                            let clampedTimelineEnd = clampedTimelineStart + durMs
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
                if session.isDraggingTimelineSegment || NSEvent.pressedMouseButtons != 0 {
                    zoomTrackHoverX = nil
                } else {
                    zoomTrackHoverX = max(0.0, min(contentWidth, pt.x))
                }
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

    // MARK: - 3. Mask Lane (`34pt` height, Touching Edge-to-Edge + Hover `+` Preview + Native NSMenu Liquid Glass Context Menu)

    @ViewBuilder
    private func maskLaneView(
        track: MaskTrack,
        trackIndex: Int,
        contentWidth: CGFloat,
        totalTimelineMs: Double
    ) -> some View {
        let isHidden = track.isHidden
        let isMousePressed = (NSEvent.pressedMouseButtons != 0)
        let addPreview = (!session.isSplitModeActive && !session.isDraggingTimelineSegment && !isMousePressed && maskTrackHoverX[track.id] != nil)
            ? hoverAddMaskSpan(track: track, contentWidth: contentWidth, totalTimelineMs: totalTimelineMs)
            : nil

        ZStack(alignment: .leading) {
            Color.clear
                .frame(width: contentWidth, height: maskRowHeight)
                .contentShape(Rectangle())

            // Hover `+` Ghost Add-Mask Preview Block 
            if let preview = addPreview {
                let previewX = CGFloat(preview.tStartMs / totalTimelineMs) * contentWidth
                let previewW = max(24.0, CGFloat((preview.tEndMs - preview.tStartMs) / totalTimelineMs) * contentWidth - 1.0)
                let palette = SegmentShaderPalette.mask

                Button {
                    session.isPlaying = false
                    session.seek(toTimelineMs: (preview.tStartMs + preview.tEndMs) * 0.5)
                    session.addMaskInRange(
                        trackId: track.id,
                        sourceStartMs: preview.srcStartMs,
                        sourceEndMs: preview.srcEndMs
                    )
                } label: {
                    ZStack {
                        SegmentBodyCanvas(
                            palette: palette,
                            isSelected: false,
                            isPlayed: false
                        )

                        Image(systemName: "plus")

                            .accessibilityLabel(Text("Add"))
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.ink.opacity(0.96))
                    }
                    .frame(width: previewW, height: maskRowHeight)
                    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .offset(x: previewX)
                .transition(.opacity.animation(.easeOut(duration: 0.12)))
                .zIndex(5)
            }

            ForEach(track.items) { item in
                if let (tStartMs, tEndMs) = timelineSpan(forSourceStartMs: item.sourceStartMs, sourceEndMs: item.sourceEndMs) {
                    let xStart = CGFloat(tStartMs / totalTimelineMs) * contentWidth
                    let blockW = max(18.0, CGFloat((tEndMs - tStartMs) / totalTimelineMs) * contentWidth)
                    let isSelected = (session.selectedMaskId == item.id)
                    let isOtherMaskSelected = (session.selectedMaskId != nil && session.selectedMaskId != item.id)
                    let isPlayedNow = session.playedTimelineItemIds.contains(item.id)

                    TimelineInteractiveSegmentView(
                        topTitle: "Mask",
                        subtitleContent: .mask(
                            text: item.type == .blur
                                ? "Sensitive data"
                                : String(format: String(localized: "Highlight %d%%"), Int(round(item.intensity)))
                        ),
                        palette: .mask,
                        isSelected: isSelected,
                        isPlayed: isPlayedNow,
                        isDimmed: isHidden || item.disabled,
                        isDimmedBySelection: isOtherMaskSelected,
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
                        snapItemId: item.id,
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
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let pt):
                if session.isDraggingTimelineSegment || NSEvent.pressedMouseButtons != 0 {
                    maskTrackHoverX.removeValue(forKey: track.id)
                } else {
                    maskTrackHoverX[track.id] = max(0.0, min(contentWidth, pt.x))
                }
            case .ended:
                maskTrackHoverX.removeValue(forKey: track.id)
            }
        }
    }

    private func hoverAddMaskSpan(
        track: MaskTrack,
        contentWidth: CGFloat,
        totalTimelineMs: Double
    ) -> (tStartMs: Double, tEndMs: Double, srcStartMs: Double, srcEndMs: Double)? {
        guard let hoverX = maskTrackHoverX[track.id], contentWidth > 10 else { return nil }
        let hoverTimelineMs = Double(hoverX / contentWidth) * totalTimelineMs

        var existingSpans: [(start: Double, end: Double)] = []
        for item in track.items {
            if let (ts, te) = timelineSpan(forSourceStartMs: item.sourceStartMs, sourceEndMs: item.sourceEndMs) {
                existingSpans.append((ts, te))
            }
        }
        existingSpans.sort { $0.start < $1.start }

        let marginMs = Double(4.0 / contentWidth) * totalTimelineMs
        for span in existingSpans {
            if hoverTimelineMs >= span.start - marginMs && hoverTimelineMs <= span.end + marginMs {
                return nil
            }
        }

        let availStart = existingSpans.last(where: { $0.end <= hoverTimelineMs })?.end ?? 0.0
        let availEnd = existingSpans.first(where: { $0.start >= hoverTimelineMs })?.start ?? totalTimelineMs
        guard availEnd - availStart >= 450.0 else { return nil }

        let desiredDur = min(2800.0, availEnd - availStart)
        let tStart = max(availStart, min(availEnd - desiredDur, hoverTimelineMs - desiredDur * 0.5))
        let tEnd = min(availEnd, tStart + desiredDur)

        let srcStart = session.timeMapper.sourceTime(forTimelineMs: tStart).sourceMs
        let srcEnd = session.timeMapper.sourceTime(forTimelineMs: tEnd).sourceMs
        guard srcEnd - srcStart >= 300.0 else { return nil }
        return (tStart, tEnd, srcStart, srcEnd)
    }

    // MARK: - Annotation Lane

    private func annotationLaneView(
        track: AnnotationTrack,
        trackIndex: Int,
        contentWidth: CGFloat,
        totalTimelineMs: Double
    ) -> some View {
        let isHidden = track.isHidden
        let stepNumbers = track.items.contains { $0.kind == .step } ? session.annotationStepNumbers : [:]
        let isMousePressed = (NSEvent.pressedMouseButtons != 0)
        let addPreview = (!session.isSplitModeActive && !session.isDraggingTimelineSegment && !isMousePressed && maskTrackHoverX[track.id] != nil)
            ? hoverAddSpan(
                trackId: track.id,
                sourceSpans: track.items.map { ($0.sourceStartMs, $0.sourceEndMs) },
                contentWidth: contentWidth,
                totalTimelineMs: totalTimelineMs
            )
            : nil

        return ZStack(alignment: .leading) {
            Color.clear
                .frame(width: contentWidth, height: maskRowHeight)
                .contentShape(Rectangle())

            if let preview = addPreview {
                let previewX = CGFloat(preview.tStartMs / totalTimelineMs) * contentWidth
                let previewW = max(24.0, CGFloat((preview.tEndMs - preview.tStartMs) / totalTimelineMs) * contentWidth - 1.0)
                Button {
                    session.isPlaying = false
                    session.seek(toTimelineMs: (preview.tStartMs + preview.tEndMs) * 0.5)
                    session.addAnnotationInRange(trackId: track.id, sourceStartMs: preview.srcStartMs, sourceEndMs: preview.srcEndMs)
                } label: {
                    ZStack {
                        SegmentBodyCanvas(palette: .annotation, isSelected: false, isPlayed: false)
                        Image(systemName: "plus")
                            .accessibilityLabel(Text("Add"))
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.ink.opacity(0.96))
                    }
                    .frame(width: previewW, height: maskRowHeight)
                    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .offset(x: previewX)
                .transition(.opacity.animation(.easeOut(duration: 0.12)))
                .zIndex(5)
            }

            ForEach(track.items) { item in
                if let (tStartMs, tEndMs) = timelineSpan(forSourceStartMs: item.sourceStartMs, sourceEndMs: item.sourceEndMs) {
                    let xStart = CGFloat(tStartMs / totalTimelineMs) * contentWidth
                    let blockW = max(18.0, CGFloat((tEndMs - tStartMs) / totalTimelineMs) * contentWidth)
                    let isSelected = (session.selectedAnnotationId == item.id)
                    let isOtherSelected = (session.selectedAnnotationId != nil && !isSelected)

                    let subtitle: String = {
                        switch item.kind {
                        case .text: return item.displayTitle
                        case .step: return stepNumbers[item.id].map { "#\($0)" } ?? "#"
                        default: return item.anchor == .screen ? "On screen".localizedUI : "On frame".localizedUI
                        }
                    }()
                    TimelineInteractiveSegmentView(
                        topTitle: item.kind.title,
                        subtitleContent: .annotation(icon: item.kind.systemImage, text: subtitle),
                        palette: .annotation,
                        isSelected: isSelected,
                        isPlayed: session.playedTimelineItemIds.contains(item.id),
                        isDimmed: isHidden || item.disabled,
                        isDimmedBySelection: isOtherSelected,
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
                        snapItemId: item.id,
                        clipDecoration: nil,
                        onClickAtLocalX: { localX in
                            let frac = max(0.0, min(1.0, Double(localX / max(1.0, blockW))))
                            let clickedTimelineMs = session.hoverSkimTimelineMs ?? (tStartMs + frac * (tEndMs - tStartMs))
                            session.isPlaying = false
                            session.seek(toTimelineMs: clickedTimelineMs)
                            if session.isSplitModeActive {
                                let splitSourceMs = session.timeMapper.sourceTime(forTimelineMs: clickedTimelineMs).sourceMs
                                session.splitAnnotation(id: item.id, atSourceMs: splitSourceMs)
                            } else {
                                session.selectAnnotation(item.id)
                            }
                        },
                        onRightClick: { pointInView, parentView in
                            session.selectAnnotation(item.id)
                            NativeSegmentContextMenuPresenter.shared.presentAnnotationContextMenu(
                                session: session,
                                annotationId: item.id,
                                at: pointInView,
                                in: parentView
                            )
                        },
                        onBeginInteractive: {
                            session.selectAnnotation(item.id)
                            session.beginInteractiveEdit()
                        },
                        onMoveBody: { desiredTimelineStartMs, constantTimelineDurMs in
                            let dur = max(AnnotationItem.minDurationMs, constantTimelineDurMs)
                            let clampedStart = max(0.0, min(totalTimelineMs - dur, desiredTimelineStartMs))
                            let newSrcStart = session.timeMapper.sourceTime(forTimelineMs: clampedStart).sourceMs
                            let newSrcEnd = max(
                                newSrcStart + AnnotationItem.minDurationMs,
                                session.timeMapper.sourceTime(forTimelineMs: clampedStart + dur).sourceMs
                            )
                            session.moveAnnotation(id: item.id, desiredStartMs: newSrcStart, durationMs: newSrcEnd - newSrcStart)
                        },
                        onResizeRange: { newTimelineStart, newTimelineEnd in
                            session.resizeAnnotation(
                                id: item.id,
                                newStartMs: session.timeMapper.sourceTime(forTimelineMs: newTimelineStart).sourceMs,
                                newEndMs: session.timeMapper.sourceTime(forTimelineMs: newTimelineEnd).sourceMs
                            )
                        },
                        onMoveVerticalTracks: { trackDelta in
                            session.moveAnnotationToTrack(id: item.id, targetTrackIndex: trackIndex + trackDelta)
                        },
                        onEndInteractive: {
                            session.endInteractiveEdit()
                        }
                    )
                }
            }
        }
        .frame(width: contentWidth, height: maskRowHeight)
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let pt):
                if session.isDraggingTimelineSegment || NSEvent.pressedMouseButtons != 0 {
                    maskTrackHoverX.removeValue(forKey: track.id)
                } else {
                    maskTrackHoverX[track.id] = max(0.0, min(contentWidth, pt.x))
                }
            case .ended:
                maskTrackHoverX.removeValue(forKey: track.id)
            }
        }
    }

    /// The empty span under the pointer on a track, for the hover `+` block. `maskTrackHoverX` is keyed by track id,
    /// which is unique across mask and annotation tracks.
    private func hoverAddSpan(
        trackId: String,
        sourceSpans: [(Double, Double)],
        contentWidth: CGFloat,
        totalTimelineMs: Double
    ) -> (tStartMs: Double, tEndMs: Double, srcStartMs: Double, srcEndMs: Double)? {
        guard let hoverX = maskTrackHoverX[trackId], contentWidth > 10 else { return nil }
        let hoverTimelineMs = Double(hoverX / contentWidth) * totalTimelineMs
        let spans = sourceSpans
            .compactMap { timelineSpan(forSourceStartMs: $0.0, sourceEndMs: $0.1) }
            .sorted { $0.0 < $1.0 }
        let marginMs = Double(4.0 / contentWidth) * totalTimelineMs
        if spans.contains(where: { hoverTimelineMs >= $0.0 - marginMs && hoverTimelineMs <= $0.1 + marginMs }) {
            return nil
        }
        let availStart = spans.last(where: { $0.1 <= hoverTimelineMs })?.1 ?? 0.0
        let availEnd = spans.first(where: { $0.0 >= hoverTimelineMs })?.0 ?? totalTimelineMs
        guard availEnd - availStart >= 450.0 else { return nil }
        let desiredDur = min(2800.0, availEnd - availStart)
        let tStart = max(availStart, min(availEnd - desiredDur, hoverTimelineMs - desiredDur * 0.5))
        let tEnd = min(availEnd, tStart + desiredDur)
        let srcStart = session.timeMapper.sourceTime(forTimelineMs: tStart).sourceMs
        let srcEnd = session.timeMapper.sourceTime(forTimelineMs: tEnd).sourceMs
        guard srcEnd - srcStart >= 300.0 else { return nil }
        return (tStart, tEnd, srcStart, srcEnd)
    }

    // MARK: - 0. Speed Up Typing Suggestion Lane

    @ViewBuilder
    private func typingSuggestionsLaneView(
        suggestions: [ProjectSession.TypingSuggestionRange],
        contentWidth: CGFloat,
        totalTimelineMs: Double
    ) -> some View {
        ZStack(alignment: .leading) {
            Color.clear
                .frame(width: contentWidth, height: 19)

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
        track: ShortcutTrackConfig,
        trackIndex: Int,
        clusters: [ProjectSession.ShortcutPressCluster],
        contentWidth: CGFloat,
        totalTimelineMs: Double
    ) -> some View {
        let trackHidden = track.isHidden
            || (trackIndex == 0 && session.document.timeline.isShortcutsTrackHidden)
            || !session.document.captions.showKeystrokes

        ZStack(alignment: .leading) {
            Color.clear
                .frame(width: contentWidth, height: maskRowHeight)
                .contentShape(Rectangle())

            // Hover `+` preview block on empty areas of the Shortcuts track (click to insert a custom shortcut!)
            if !session.isSplitModeActive,
               !session.isDraggingTimelineSegment,
               NSEvent.pressedMouseButtons == 0,
               let previewSpan = hoverAddShortcutSpan(trackId: track.id, clusters: clusters, contentWidth: contentWidth, totalTimelineMs: totalTimelineMs) {
                let pX = CGFloat(previewSpan.tStartMs / totalTimelineMs) * contentWidth
                let pW = max(24.0, CGFloat((previewSpan.tEndMs - previewSpan.tStartMs) / totalTimelineMs) * contentWidth)

                Button {
                    session.isPlaying = false
                    session.seek(toTimelineMs: (previewSpan.tStartMs + previewSpan.tEndMs) * 0.5)
                    session.addCustomShortcut(
                        trackId: track.id,
                        sourceStartMs: previewSpan.srcStartMs,
                        sourceEndMs: previewSpan.srcEndMs
                    )
                } label: {
                    ZStack {
                        SegmentBodyCanvas(palette: .shortcut, isSelected: false, isPlayed: false)
                        Image(systemName: "plus")
                            .accessibilityLabel(Text("Add"))
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.ink.opacity(0.96))
                    }
                    .frame(width: pW, height: maskRowHeight)
                    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .offset(x: pX)
                .zIndex(5)
            }

            ForEach(clusters) { cluster in
                if let (tStartMs, tEndMs) = timelineSpan(forSourceStartMs: cluster.displayStartMs, sourceEndMs: cluster.displayEndMs) {
                    let xStart = CGFloat(tStartMs / totalTimelineMs) * contentWidth
                    let blockW = max(2.0, CGFloat((tEndMs - tStartMs) / totalTimelineMs) * contentWidth)
                    let isItemHidden = trackHidden || session.isShortcutHidden(cluster)
                    let isSelected = (session.selectedShortcutId == cluster.id)
                    let isOtherSelected = (session.selectedShortcutId != nil && !isSelected)

                    ShortcutTimelineSegmentView(
                        session: session,
                        cluster: cluster,
                        trackIndex: trackIndex,
                        xOffset: xStart,
                        width: blockW,
                        height: maskRowHeight,
                        totalWidth: contentWidth,
                        trackTotalDurationMs: totalTimelineMs,
                        startMs: tStartMs,
                        endMs: tEndMs,
                        isSelected: isSelected,
                        isDimmedBySelection: isOtherSelected,
                        isHidden: isItemHidden
                    )
                }
            }
        }
        .frame(width: contentWidth, height: maskRowHeight)
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let pt):
                if session.isDraggingTimelineSegment || NSEvent.pressedMouseButtons != 0 {
                    shortcutTrackHoverX.removeValue(forKey: track.id)
                } else {
                    shortcutTrackHoverX[track.id] = max(0.0, min(contentWidth, pt.x))
                }
            case .ended:
                shortcutTrackHoverX.removeValue(forKey: track.id)
            }
        }
    }

    private func hoverAddShortcutSpan(
        trackId: String,
        clusters: [ProjectSession.ShortcutPressCluster],
        contentWidth: CGFloat,
        totalTimelineMs: Double
    ) -> (tStartMs: Double, tEndMs: Double, srcStartMs: Double, srcEndMs: Double)? {
        guard let hoverX = shortcutTrackHoverX[trackId], contentWidth > 10 else { return nil }
        let hoverTimelineMs = Double(hoverX / contentWidth) * totalTimelineMs

        var existingSpans: [(start: Double, end: Double)] = []
        for cluster in clusters {
            if let (ts, te) = timelineSpan(forSourceStartMs: cluster.displayStartMs, sourceEndMs: cluster.displayEndMs) {
                existingSpans.append((ts, te))
            }
        }
        existingSpans.sort { $0.start < $1.start }

        let marginMs = Double(6.0 / contentWidth) * totalTimelineMs
        for span in existingSpans {
            if hoverTimelineMs >= span.start - marginMs && hoverTimelineMs <= span.end + marginMs {
                return nil
            }
        }

        let availStart = existingSpans.last(where: { $0.end <= hoverTimelineMs })?.end ?? 0.0
        let availEnd = existingSpans.first(where: { $0.start >= hoverTimelineMs })?.start ?? totalTimelineMs
        guard availEnd - availStart >= 450.0 else { return nil }

        let desiredDur = min(1800.0, availEnd - availStart)
        let tStart = max(availStart, min(availEnd - desiredDur, hoverTimelineMs - desiredDur * 0.5))
        let tEnd = min(availEnd, tStart + desiredDur)

        let srcStart = session.timeMapper.sourceTime(forTimelineMs: tStart).sourceMs
        let srcEnd = session.timeMapper.sourceTime(forTimelineMs: tEnd).sourceMs
        guard srcEnd - srcStart >= 300.0 else { return nil }
        return (tStart, tEnd, srcStart, srcEnd)
    }

    // MARK: - Caption Track Lane

    @ViewBuilder
    private func captionLaneView(
        track: CaptionTrack,
        trackIndex: Int,
        contentWidth: CGFloat,
        totalTimelineMs: Double
    ) -> some View {
        let captions = session.document.captions
        let blocks = captions.captionBlocks.filter { $0.trackId == track.id }
        let isHidden = track.isHidden || !captions.enabled
        let addPreview = (!session.isSplitModeActive && !session.isDraggingTimelineSegment && NSEvent.pressedMouseButtons == 0)
            ? hoverAddCaptionSpan(trackId: track.id, blocks: blocks, contentWidth: contentWidth, totalTimelineMs: totalTimelineMs)
            : nil

        ZStack(alignment: .leading) {
            Color.clear
                .frame(width: contentWidth, height: maskRowHeight)
                .contentShape(Rectangle())

            if let preview = addPreview {
                let previewX = CGFloat(preview.tStartMs / totalTimelineMs) * contentWidth
                let previewW = max(24.0, CGFloat((preview.tEndMs - preview.tStartMs) / totalTimelineMs) * contentWidth - 1.0)

                Button {
                    session.isPlaying = false
                    session.seek(toTimelineMs: (preview.tStartMs + preview.tEndMs) * 0.5)
                    session.addCaption(trackId: track.id, sourceStartMs: preview.srcStartMs, sourceEndMs: preview.srcEndMs)
                } label: {
                    ZStack {
                        SegmentBodyCanvas(palette: .caption, isSelected: false, isPlayed: false)

                        Image(systemName: "plus")

                            .accessibilityLabel(Text("Add"))
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.ink.opacity(0.96))
                    }
                    .frame(width: previewW, height: maskRowHeight)
                    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .offset(x: previewX)
                .transition(.opacity.animation(.easeOut(duration: 0.12)))
                .zIndex(5)
            }

            ForEach(blocks) { block in
                if let (tStartMs, tEndMs) = timelineSpan(forSourceStartMs: block.sourceStartMs, sourceEndMs: block.sourceEndMs) {
                    let xStart = CGFloat(tStartMs / totalTimelineMs) * contentWidth
                    let blockW = max(18.0, CGFloat((tEndMs - tStartMs) / totalTimelineMs) * contentWidth)
                    let isSelected = (session.selectedCaptionId == block.id)
                    let isOtherSelected = (session.selectedCaptionId != nil && !isSelected)
                    let isPlayedNow = session.playedTimelineItemIds.contains(block.id)

                    TimelineInteractiveSegmentView(
                        topTitle: "Caption",
                        subtitleContent: .mask(text: CaptionLineLayout.displayText(of: block, in: captions)),
                        palette: .caption,
                        isSelected: isSelected,
                        isPlayed: isPlayedNow,
                        isDimmed: isHidden,
                        isDimmedBySelection: isOtherSelected,
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
                        snapItemId: block.id,
                        clipDecoration: nil,
                        onClickAtLocalX: { localX in
                            let frac = max(0.0, min(1.0, Double(localX / max(1.0, blockW))))
                            let clickedTimelineMs = session.hoverSkimTimelineMs
                                ?? (tStartMs + frac * (tEndMs - tStartMs))
                            session.isPlaying = false
                            session.seek(toTimelineMs: clickedTimelineMs)
                            if session.isSplitModeActive {
                                let splitSourceMs = session.timeMapper.sourceTime(forTimelineMs: clickedTimelineMs).sourceMs
                                session.splitCaption(id: block.id, atSourceMs: splitSourceMs)
                            } else {
                                session.selectCaption(block.id)
                            }
                        },
                        onRightClick: { pointInView, parentView in
                            session.selectCaption(block.id)
                            NativeSegmentContextMenuPresenter.shared.presentCaptionContextMenu(
                                session: session,
                                block: block,
                                at: pointInView,
                                in: parentView
                            )
                        },
                        onBeginInteractive: {
                            session.selectCaption(block.id)
                            session.beginInteractiveEdit()
                        },
                        onMoveBody: { desiredTimelineStartMs, constantTimelineDurMs in
                            let dur = max(220.0, constantTimelineDurMs)
                            let clampedTimelineStart = max(0.0, min(totalTimelineMs - dur, desiredTimelineStartMs))
                            let clampedTimelineEnd = clampedTimelineStart + dur
                            let newSrcStart = session.timeMapper.sourceTime(forTimelineMs: clampedTimelineStart).sourceMs
                            let newSrcEnd = max(newSrcStart + 220.0, session.timeMapper.sourceTime(forTimelineMs: clampedTimelineEnd).sourceMs)
                            session.moveCaption(id: block.id, desiredStartMs: newSrcStart, durationMs: newSrcEnd - newSrcStart)
                        },
                        onResizeRange: { newTimelineStart, newTimelineEnd in
                            let newSrcStart = session.timeMapper.sourceTime(forTimelineMs: newTimelineStart).sourceMs
                            let newSrcEnd = session.timeMapper.sourceTime(forTimelineMs: newTimelineEnd).sourceMs
                            session.resizeCaption(id: block.id, newStartMs: newSrcStart, newEndMs: newSrcEnd)
                        },
                        onMoveVerticalTracks: { trackDelta in
                            session.moveCaptionToTrack(id: block.id, targetTrackIndex: trackIndex + trackDelta)
                        },
                        onEndInteractive: {
                            session.endInteractiveEdit()
                        }
                    )
                }
            }
        }
        .frame(width: contentWidth, height: maskRowHeight)
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let pt):
                if session.isDraggingTimelineSegment || NSEvent.pressedMouseButtons != 0 {
                    captionTrackHoverX.removeValue(forKey: track.id)
                } else {
                    captionTrackHoverX[track.id] = max(0.0, min(contentWidth, pt.x))
                }
            case .ended:
                captionTrackHoverX.removeValue(forKey: track.id)
            }
        }
    }

    private func hoverAddCaptionSpan(
        trackId: String,
        blocks: [CaptionBlock],
        contentWidth: CGFloat,
        totalTimelineMs: Double
    ) -> (tStartMs: Double, tEndMs: Double, srcStartMs: Double, srcEndMs: Double)? {
        guard let hoverX = captionTrackHoverX[trackId], contentWidth > 10 else { return nil }
        let hoverTimelineMs = Double(hoverX / contentWidth) * totalTimelineMs

        let spans = blocks
            .compactMap { timelineSpan(forSourceStartMs: $0.sourceStartMs, sourceEndMs: $0.sourceEndMs) }
            .sorted { $0.0 < $1.0 }

        let marginMs = Double(6.0 / contentWidth) * totalTimelineMs
        if spans.contains(where: { hoverTimelineMs >= $0.0 - marginMs && hoverTimelineMs <= $0.1 + marginMs }) {
            return nil
        }

        let availStart = spans.last(where: { $0.1 <= hoverTimelineMs })?.1 ?? 0.0
        let availEnd = spans.first(where: { $0.0 >= hoverTimelineMs })?.0 ?? totalTimelineMs
        guard availEnd - availStart >= 450.0 else { return nil }

        let desiredDur = min(2000.0, availEnd - availStart)
        let tStart = max(availStart, min(availEnd - desiredDur, hoverTimelineMs - desiredDur * 0.5))
        let tEnd = min(availEnd, tStart + desiredDur)

        let srcStart = session.timeMapper.sourceTime(forTimelineMs: tStart).sourceMs
        let srcEnd = session.timeMapper.sourceTime(forTimelineMs: tEnd).sourceMs
        guard srcEnd - srcStart >= 300.0 else { return nil }
        return (tStart, tEnd, srcStart, srcEnd)
    }

    // MARK: - 2B. Camera Layouts Track Lane

    @ViewBuilder
    private func cameraLayoutsLaneView(contentWidth: CGFloat, totalTimelineMs: Double) -> some View {
        let isHidden = session.document.timeline.isCameraLayoutsTrackHidden
        let isMousePressed = (NSEvent.pressedMouseButtons != 0)
        let addPreview = (!session.isSplitModeActive && !session.isDraggingTimelineSegment && !isMousePressed && !isHidden)
            ? hoverAddCameraLayoutSpan(contentWidth: contentWidth, totalTimelineMs: totalTimelineMs)
            : nil

        ZStack(alignment: .leading) {
            Color.clear
                .frame(width: contentWidth, height: maskRowHeight)
                .contentShape(Rectangle())

            if let preview = addPreview {
                let previewX = CGFloat(preview.tStartMs / totalTimelineMs) * contentWidth
                let previewW = max(24.0, CGFloat((preview.tEndMs - preview.tStartMs) / totalTimelineMs) * contentWidth - 1.0)
                let palette = SegmentShaderPalette.cameraLayout

                Button {
                    session.isPlaying = false
                    session.seek(toTimelineMs: (preview.tStartMs + preview.tEndMs) * 0.5)
                    session.addCameraLayoutInRange(
                        sourceStartMs: preview.srcStartMs,
                        sourceEndMs: preview.srcEndMs,
                        type: .cameraOverlay
                    )
                } label: {
                    ZStack {
                        SegmentBodyCanvas(
                            palette: palette,
                            isSelected: false,
                            isPlayed: false
                        )

                        Image(systemName: "plus")

                            .accessibilityLabel(Text("Add"))
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.ink.opacity(0.96))
                    }
                    .frame(width: previewW, height: maskRowHeight)
                    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .offset(x: previewX)
                .transition(.opacity.animation(.easeOut(duration: 0.12)))
                .zIndex(5)
            }

            ForEach(session.document.timeline.cameraLayouts) { seg in
                if let (tStartMs, tEndMs) = timelineSpan(forSourceStartMs: seg.sourceStartMs, sourceEndMs: seg.sourceEndMs) {
                    let xStart = CGFloat(tStartMs / totalTimelineMs) * contentWidth
                    let blockW = max(18.0, CGFloat((tEndMs - tStartMs) / totalTimelineMs) * contentWidth)
                    let isSelected = (session.selectedCameraLayoutId == seg.id)
                    let isOtherSelected = (session.selectedCameraLayoutId != nil && session.selectedCameraLayoutId != seg.id)
                    let isPlayedNow = session.playedTimelineItemIds.contains(seg.id)

                    TimelineInteractiveSegmentView(
                        topTitle: "Layout",
                        subtitleContent: .mask(text: seg.layoutType.timelineSubtitle),
                        palette: .cameraLayout,
                        isSelected: isSelected,
                        isPlayed: isPlayedNow,
                        isDimmed: isHidden || seg.disabled,
                        isDimmedBySelection: isOtherSelected,
                        isSplitMode: session.isSplitModeActive,
                        xOffset: xStart,
                        width: blockW,
                        height: maskRowHeight,
                        totalWidth: contentWidth,
                        trackTotalDurationMs: totalTimelineMs,
                        startMs: tStartMs,
                        endMs: tEndMs,
                        allowDragMove: true,
                        allowVerticalTrackDrag: false,
                        snapItemId: seg.id,
                        clipDecoration: nil,
                        onClickAtLocalX: { localX in
                            let frac = max(0.0, min(1.0, Double(localX / max(1.0, blockW))))
                            let clickedTimelineMs = session.hoverSkimTimelineMs
                                ?? (tStartMs + frac * (tEndMs - tStartMs))
                            session.isPlaying = false
                            session.seek(toTimelineMs: clickedTimelineMs)
                            if session.isSplitModeActive {
                                let splitSourceMs = session.timeMapper.sourceTime(forTimelineMs: clickedTimelineMs).sourceMs
                                session.splitCameraLayout(id: seg.id, atSourceMs: splitSourceMs)
                            } else {
                                session.selectCameraLayout(seg.id)
                            }
                        },
                        onRightClick: { pointInView, parentView in
                            session.selectCameraLayout(seg.id)
                            NativeSegmentContextMenuPresenter.shared.presentCameraLayoutContextMenu(
                                session: session,
                                layoutId: seg.id,
                                at: pointInView,
                                in: parentView
                            )
                        },
                        onBeginInteractive: {
                            session.selectCameraLayout(seg.id)
                            session.beginInteractiveEdit()
                        },
                        onMoveBody: { desiredTimelineStartMs, constantTimelineDurMs in
                            let dur = max(250.0, constantTimelineDurMs)
                            let clampedTimelineStart = max(0.0, min(totalTimelineMs - dur, desiredTimelineStartMs))
                            let clampedTimelineEnd = clampedTimelineStart + dur
                            let newSrcStart = session.timeMapper.sourceTime(forTimelineMs: clampedTimelineStart).sourceMs
                            let newSrcEnd = max(newSrcStart + 250.0, session.timeMapper.sourceTime(forTimelineMs: clampedTimelineEnd).sourceMs)
                            session.moveCameraLayout(id: seg.id, desiredStartMs: newSrcStart, durationMs: newSrcEnd - newSrcStart)
                        },
                        onResizeRange: { newTimelineStart, newTimelineEnd in
                            let newSrcStart = session.timeMapper.sourceTime(forTimelineMs: newTimelineStart).sourceMs
                            let newSrcEnd = session.timeMapper.sourceTime(forTimelineMs: newTimelineEnd).sourceMs
                            session.resizeCameraLayout(id: seg.id, newStartMs: newSrcStart, newEndMs: newSrcEnd)
                        },
                        onMoveVerticalTracks: { _ in },
                        onEndInteractive: {
                            session.endInteractiveEdit()
                        }
                    )
                }
            }
        }
        .frame(width: contentWidth, height: maskRowHeight)
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let pt):
                if session.isDraggingTimelineSegment || NSEvent.pressedMouseButtons != 0 {
                    cameraLayoutTrackHoverX = nil
                } else {
                    cameraLayoutTrackHoverX = max(0.0, min(contentWidth, pt.x))
                }
            case .ended:
                cameraLayoutTrackHoverX = nil
            }
        }
    }

    private func hoverAddCameraLayoutSpan(
        contentWidth: CGFloat,
        totalTimelineMs: Double
    ) -> (tStartMs: Double, tEndMs: Double, srcStartMs: Double, srcEndMs: Double)? {
        guard let hoverX = cameraLayoutTrackHoverX, contentWidth > 10 else { return nil }
        let hoverTimelineMs = Double(hoverX / contentWidth) * totalTimelineMs

        var existingSpans: [(start: Double, end: Double)] = []
        for seg in session.document.timeline.cameraLayouts {
            if let (ts, te) = timelineSpan(forSourceStartMs: seg.sourceStartMs, sourceEndMs: seg.sourceEndMs) {
                existingSpans.append((ts, te))
            }
        }
        existingSpans.sort { $0.start < $1.start }

        let marginMs = Double(4.0 / contentWidth) * totalTimelineMs
        for span in existingSpans {
            if hoverTimelineMs >= span.start - marginMs && hoverTimelineMs <= span.end + marginMs {
                return nil
            }
        }

        let availStart = existingSpans.last(where: { $0.end <= hoverTimelineMs })?.end ?? 0.0
        let availEnd = existingSpans.first(where: { $0.start >= hoverTimelineMs })?.start ?? totalTimelineMs
        guard availEnd - availStart >= 450.0 else { return nil }

        let desiredDur = min(2800.0, availEnd - availStart)
        let tStart = max(availStart, min(availEnd - desiredDur, hoverTimelineMs - desiredDur * 0.5))
        let tEnd = min(availEnd, tStart + desiredDur)

        let srcStart = session.timeMapper.sourceTime(forTimelineMs: tStart).sourceMs
        let srcEnd = session.timeMapper.sourceTime(forTimelineMs: tEnd).sourceMs
        guard srcEnd - srcStart >= 350.0 else { return nil }
        return (tStart, tEnd, srcStart, srcEnd)
    }

    // MARK: - 3B. Voiceovers Track Lane

    @ViewBuilder
    private func voiceoversLaneView(trackIndex: Int, contentWidth: CGFloat, totalTimelineMs: Double) -> some View {
        let isHidden = session.document.timeline.isVoiceoverTrackHidden(trackIndex)

        ZStack(alignment: .leading) {
            Color.clear
                .frame(width: contentWidth, height: maskRowHeight)
                .contentShape(Rectangle())

            if session.isRecordingVoiceover && session.voiceoverRecordingTrackIndex == trackIndex {
                let startMs = session.timeMapper.timelineTime(forSourceMs: session.voiceoverRecordingStartSourceMs) ?? 0.0
                let curMs = max(startMs + 100.0, session.playheadTimelineMs)
                let recX = CGFloat(startMs / totalTimelineMs) * contentWidth
                let recW = max(24.0, CGFloat((curMs - startMs) / totalTimelineMs) * contentWidth)
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 7, height: 7)
                    Text("Recording voiceover...")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.ink)
                }
                .padding(.horizontal, 10)
                .frame(width: recW, height: maskRowHeight, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.red.opacity(0.32))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.red.opacity(0.85), lineWidth: 1.2)
                )
                .offset(x: recX)
            }

            ForEach(session.document.timeline.voiceovers.filter { $0.trackIndex == trackIndex }) { vo in
                if let (tStartMs, tEndMs) = timelineSpan(forSourceStartMs: vo.sourceStartMs, sourceEndMs: vo.sourceEndMs) {
                    let xStart = CGFloat(tStartMs / totalTimelineMs) * contentWidth
                    let blockW = max(18.0, CGFloat((tEndMs - tStartMs) / totalTimelineMs) * contentWidth)
                    let isSelected = (session.selectedVoiceoverId == vo.id)
                    let isOtherSelected = (session.selectedVoiceoverId != nil && session.selectedVoiceoverId != vo.id)
                    let isPlayedNow = session.playedTimelineItemIds.contains(vo.id)
                    let voSamples = session.voiceoverWaveformSamplesByID[vo.id] ?? []
                    let voVolumePct = "\(Int(round(vo.volume * 100)))%"
                    let voVolIcon = vo.volume <= 0.01 ? "speaker.slash.fill" : (vo.volume < 0.5 ? "speaker.wave.1.fill" : "speaker.wave.2.fill")

                    TimelineInteractiveSegmentView(
                        topTitle: "Voiceover",
                        subtitleContent: .voiceover(volumeText: voVolumePct, volumeIcon: voVolIcon),
                        palette: .mask,
                        isSelected: isSelected,
                        isPlayed: isPlayedNow,
                        isDimmed: isHidden || vo.disabled || vo.volume <= 0.001,
                        isDimmedBySelection: isOtherSelected,
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
                        snapItemId: vo.id,
                        clipDecoration: ClipSegmentDecoration(
                            timelineStartMs: tStartMs,
                            timelineEndMs: tEndMs,
                            totalTimelineMs: totalTimelineMs,
                            minorTickStepSec: 0.0,
                            sourceStartMs: vo.fileOffsetMs,
                            sourceEndMs: vo.fileOffsetMs + max(1.0, vo.durationMs),
                            totalSourceMs: session.voiceoverFileDurationMsByID[vo.id] ?? (vo.fileOffsetMs + max(1.0, vo.durationMs)),
                            volumeScale: 0.0,
                            waveformSamples: [],
                            microphoneVolumeScale: (isHidden || vo.disabled) ? 0.0 : vo.volume,
                            microphoneWaveformSamples: voSamples
                        ),
                        onClickAtLocalX: { localX in
                            let frac = max(0.0, min(1.0, Double(localX / max(1.0, blockW))))
                            let clickedTimelineMs = session.hoverSkimTimelineMs
                                ?? (tStartMs + frac * (tEndMs - tStartMs))
                            session.isPlaying = false
                            session.seek(toTimelineMs: clickedTimelineMs)
                            if session.isSplitModeActive {
                                let splitSourceMs = session.timeMapper.sourceTime(forTimelineMs: clickedTimelineMs).sourceMs
                                session.splitVoiceover(id: vo.id, atSourceMs: splitSourceMs)
                            } else {
                                session.selectVoiceover(vo.id)
                            }
                        },
                        onRightClick: { pointInView, parentView in
                            session.selectVoiceover(vo.id)
                            NativeSegmentContextMenuPresenter.shared.presentVoiceoverContextMenu(
                                session: session,
                                voiceoverId: vo.id,
                                at: pointInView,
                                in: parentView
                            )
                        },
                        onBeginInteractive: {
                            session.selectVoiceover(vo.id)
                            session.beginInteractiveEdit()
                        },
                        onMoveBody: { desiredTimelineStartMs, constantTimelineDurMs in
                            let dur = max(250.0, constantTimelineDurMs)
                            let clampedTimelineStart = max(0.0, min(totalTimelineMs - dur, desiredTimelineStartMs))
                            let clampedTimelineEnd = clampedTimelineStart + dur
                            let newSrcStart = session.timeMapper.sourceTime(forTimelineMs: clampedTimelineStart).sourceMs
                            let newSrcEnd = max(newSrcStart + 250.0, session.timeMapper.sourceTime(forTimelineMs: clampedTimelineEnd).sourceMs)
                            session.moveVoiceover(id: vo.id, desiredStartMs: newSrcStart, durationMs: newSrcEnd - newSrcStart)
                        },
                        onResizeRange: { newTimelineStart, newTimelineEnd in
                            let newSrcStart = session.timeMapper.sourceTime(forTimelineMs: newTimelineStart).sourceMs
                            let newSrcEnd = max(newSrcStart + 300.0, session.timeMapper.sourceTime(forTimelineMs: newTimelineEnd).sourceMs)
                            session.resizeVoiceover(id: vo.id, newStartMs: newSrcStart, newEndMs: newSrcEnd)
                        },
                        onMoveVerticalTracks: { trackDelta in
                            session.moveVoiceoverToTrack(id: vo.id, targetTrackIndex: trackIndex + trackDelta)
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
        session.timelineSpan(forSourceStartMs: sourceStartMs, sourceEndMs: sourceEndMs)
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

    private struct ClipTrimCutBadgeItem: Identifiable {
        let id: String
        let timelineMs: Double
        let trimmedDurationLabel: String?
        let tooltipText: String
        let action: () -> Void
    }

    /// Formats a playhead time for the trim badge:
    /// `< 1s` -> `0.6s`, `< 60s` -> `4s`, `< 60m` -> `2m`, else `1h`.
    private static func formatTrimmedDurationBadge(_ ms: Double) -> String {
        let sec = max(0.0, ms / 1000.0)
        if sec < 1.0 {
            return String(format: "%.1fs", sec)
        }
        if sec < 60.0 {
            return String(format: "%.0fs", sec)
        }
        let mins = Int(floor(sec / 60.0))
        if mins < 60 {
            return "\(mins)m"
        }
        return "\(mins / 60)h"
    }

    /// Badge placement:
    /// Computes golden teardrop badges for:
    /// 1. First slice's leading trim (`sourceStartMs > 1.0`).
    /// 2. Every inter-slice boundary (`next.sourceStartMs - curr.sourceEndMs`: if `> 1ms` -> `Undo trim` with duration label, else `Join clips`).
    /// 3. Last slice's trailing trim (`totalSourceMs - last.sourceEndMs > 1.0`).
    private func computeClipTrimAndCutBadges() -> [ClipTrimCutBadgeItem] {
        let slices = session.timeMapper.mappedSlices
        guard !slices.isEmpty else { return [] }
        let totalSourceMs = session.metadata.durationMs
        var items: [ClipTrimCutBadgeItem] = []

        // 1. Leading trim on the first slice
        let first = slices[0]
        if first.slice.sourceStartMs > 20.0 {
            let trimmedMs = first.slice.sourceStartMs
            let sliceId = first.slice.id
            items.append(
                ClipTrimCutBadgeItem(
                    id: "trim-start-\(sliceId)",
                    timelineMs: first.timelineStartMs,
                    trimmedDurationLabel: Self.formatTrimmedDurationBadge(trimmedMs),
                    tooltipText: "Undo trim",
                    action: {
                        session.removeSliceStartTrim(id: sliceId)
                    }
                )
            )
        }

        // 2. Inter-slice cut / trim boundaries
        if slices.count > 1 {
            for idx in 0..<(slices.count - 1) {
                let curr = slices[idx]
                let next = slices[idx + 1]
                let gapMs = max(0.0, next.slice.sourceStartMs - curr.slice.sourceEndMs)
                let isTrimmedGap = (gapMs > 20.0)
                let sliceId = curr.slice.id
                items.append(
                    ClipTrimCutBadgeItem(
                        id: "cut-\(curr.slice.id)-\(next.slice.id)",
                        timelineMs: curr.timelineEndMs,
                        trimmedDurationLabel: isTrimmedGap ? Self.formatTrimmedDurationBadge(gapMs) : nil,
                        tooltipText: isTrimmedGap ? "Undo trim" : "Join clips",
                        action: {
                            session.mergeSliceWithNext(id: sliceId)
                        }
                    )
                )
            }
        }

        // 3. Trailing trim on the last slice
        if let last = slices.last {
            let tailTrimMs = totalSourceMs - last.slice.sourceEndMs
            if tailTrimMs > 20.0 {
                let sliceId = last.slice.id
                items.append(
                    ClipTrimCutBadgeItem(
                        id: "trim-end-\(sliceId)",
                        timelineMs: last.timelineEndMs,
                        trimmedDurationLabel: Self.formatTrimmedDurationBadge(tailTrimMs),
                        tooltipText: "Undo trim",
                        action: {
                            session.removeSliceEndTrim(id: sliceId)
                        }
                    )
                )
            }
        }

        return items
    }
}

// MARK: - Unified Continuous Playhead Canvas & Golden Trim/Cut Teardrop Badge

private struct CutBoundaryTeardropBadgeView: View {
    let trimmedDurationLabel: String?
    let tooltipText: String
    let onMergeClick: () -> Void
    @State private var isHovered = false

    var body: some View {
        let hasLabel = (trimmedDurationLabel != nil)
        Button(action: onMergeClick) {
            ZStack {
                Canvas { context, size in
                    let centerX = size.width * 0.5
                    let radius: CGFloat = hasLabel ? 12.2 : 9.6
                    let circleCenterY: CGFloat = hasLabel ? 13.0 : 11.2
                    let tipY: CGFloat = size.height - 0.5

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
                        ? Color(red: 0.98, green: 0.68, blue: 0.18)
                        : Color(red: 0.91, green: 0.58, blue: 0.09)
                    context.fill(path, with: .color(fillColor))
                    context.stroke(
                        path,
                        with: .color(Color.black.opacity(0.32)),
                        lineWidth: 0.8
                    )
                }

                if let label = trimmedDurationLabel {
                    VStack(spacing: 1.0) {
                        Text(label.localizedUI)
                            .font(.system(size: 7.0, weight: .heavy).monospacedDigit())
                            .foregroundStyle(.black.opacity(0.90))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)

                        Image(systemName: "scissors")
                            .font(.system(size: 7.2, weight: .bold))
                            .foregroundStyle(.black.opacity(0.88))
                    }
                    .offset(y: -0.8)
                } else {
                    Image(systemName: "scissors")
                        .font(.system(size: 9.0, weight: .bold))
                        .foregroundStyle(.black.opacity(0.88))
                        .offset(y: -2.0)
                }
            }
            .frame(width: 30, height: 29)
            .scaleEffect(isHovered ? 1.07 : 1.0)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tooltipText.localizedUI)
        .accessibilityLabel(Text(tooltipText.localizedUI))
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
    }
}

private struct TimelinePlayheadsOverlayView: View {
    @Bindable var session: ProjectSession
    let trackHorizontalInset: CGFloat
    let contentWidth: CGFloat
    let totalTimelineMs: Double
    let horizontalScrollOffset: CGFloat
    let viewportWidth: CGFloat
    let totalHeight: CGFloat

    var body: some View {
        let playheadXInDoc = trackHorizontalInset + CGFloat(session.playheadTimelineMs / totalTimelineMs) * contentWidth
        let playheadXInViewport = playheadXInDoc - horizontalScrollOffset

        let hoverXInDoc: CGFloat? = (!session.isPlaying && session.hoverSkimTimelineMs != nil)
            ? (trackHorizontalInset + CGFloat(session.hoverSkimTimelineMs! / totalTimelineMs) * contentWidth)
            : nil
        let hoverXInViewport: CGFloat? = hoverXInDoc.map { $0 - horizontalScrollOffset }

        ZStack(alignment: .topLeading) {
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
                    totalHeight: totalHeight
                )
                .frame(width: 18, height: totalHeight)
                .offset(x: gx - 9.0)
            }

            if playheadXInViewport >= -8 && playheadXInViewport <= viewportWidth + 8 {
                UnifiedPlayheadCanvasView(
                    headColor: Color(red: 0.44, green: 0.30, blue: 1.0),
                    stemColor: Color(red: 0.44, green: 0.30, blue: 1.0).opacity(0.90),
                    headTopY: 1.5,
                    totalHeight: totalHeight
                )
                .frame(width: 18, height: totalHeight)
                .offset(x: playheadXInViewport - 9.0)
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

// MARK: - Split Mode Track Wiggle

/// Bobs a track up and down while Split Mode is on, then settles it.
/// The state lives here and only the two modifiers below read it, so a frame never re-evaluates a lane's body.
/// Nothing runs outside Split Mode: when the amplitude reaches zero the repeating animation is removed.
private struct SplitModeWiggle: ViewModifier {
    let isActive: Bool
    let direction: CGFloat

    @State private var cycle: CGFloat = 0.0
    @State private var strength: CGFloat = 0.0
    @State private var isRunning = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .modifier(SplitWiggleStrength(cycle: cycle, strength: strength, direction: direction))
            .onChange(of: isActive, initial: true) { _, active in
                // Reduce Motion: split mode is shown by the cursor and the button state only, the tracks stay still.
                if active && reduceMotion { return }
                if active {
                    isRunning = true
                    withAnimation(.easeOut(duration: 0.16)) {
                        cycle = 1.0
                        strength = 1.0
                    }
                } else if isRunning {
                    isRunning = false
                    withAnimation(.easeOut(duration: 0.16)) {
                        strength = 0.0
                    } completion: {
                        // Split Mode may have come back on during the settle.
                        guard !isRunning else { return }
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            cycle = 0.0
                        }
                    }
                }
            }
    }
}

/// Animates the amplitude with the caller's transaction and gives `cycle` its own repeating animation.
/// One transaction covers every state change in a tick, so the two curves cannot be set with two `withAnimation` calls:
/// the last one would drive both and end the repeat after a single beat.
private struct SplitWiggleStrength: ViewModifier, Animatable {
    let cycle: CGFloat
    var strength: CGFloat
    let direction: CGFloat

    var animatableData: CGFloat {
        get { strength }
        set { strength = newValue }
    }

    func body(content: Content) -> some View {
        content.animation(.linear(duration: 0.84).repeatForever(autoreverses: false)) {
            $0.modifier(SplitWiggleEffect(cycle: cycle, strength: strength, direction: direction))
        }
    }
}

private struct SplitWiggleEffect: GeometryEffect {
    private static let amplitude: CGFloat = 1.65

    var cycle: CGFloat
    let strength: CGFloat
    let direction: CGFloat

    var animatableData: CGFloat {
        get { cycle }
        set { cycle = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let y = Self.amplitude * direction * strength * sin(cycle * 2.0 * .pi)
        return ProjectionTransform(CGAffineTransform(translationX: 0.0, y: y))
    }
}

// MARK: - Smooth Fixed-Interval Time Ruler

private struct SmoothTimeRulerView: View {
    let totalDurationMs: Double
    let width: CGFloat
    let majorStepSec: Double
    let minorStepSec: Double

    /// Picks the ruler step for `pixelsPerPlaybackMs`:
    /// Picks the closest interval from `[0.5, 1.0, 2.5, 5.0, 10.0, 30.0, 60.0, 120.0, 300.0]` seconds
    /// so that adjacent ruler marks are spaced around ~100–200px apart.
    /// A tick gets a label when `timeMs % 1000 == 0`:
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
                context.fill(Path(ellipseIn: dotRect), with: .color(.ink.opacity(0.32)))

                // Draw time label ONLY when `timeMs % 1000 == 0`!
                if isWholeSecond && x >= 14 && x <= size.width - 14 {
                    let totalWholeSec = timeMsInt / 1000
                    let mins = totalWholeSec / 60
                    let secs = totalWholeSec % 60
                    let labelStr = String(format: "%d:%02d", mins, secs)

                    let text = Text(labelStr.localizedUI)
                        .font(.system(size: 11, weight: .semibold, design: .default).monospacedDigit())
                        .foregroundColor(.ink.opacity(0.34))
                    context.draw(text, at: CGPoint(x: x, y: dotY - 10))
                }

                stepIndex += 1
            }
        }
        .frame(width: width, height: 30)
    }
}

// MARK: - Clip Segment Decoration (Ruler Tick Lines + Audio Waveform Curve, Equatable so Canvas never redraws on hover skim!)

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
    var microphoneVolumeScale: Double = 0.0
    var microphoneWaveformSamples: [Float] = []

    var body: some View {
        let showWaveform = EditorViewPreferences.shared.showAudioWaveform
        let smooth = EditorViewPreferences.shared.smoothWaveform
        ZStack {
            // A. Audio waveforms, drawn bottom-up: microphone first, system audio over it.
            if showWaveform && totalSourceMs > 1.0 && (!microphoneWaveformSamples.isEmpty || !waveformSamples.isEmpty) {
                ClipWaveformImageView(input: waveformInput(smooth: smooth))
            }
            tickLines
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .allowsHitTesting(false)
    }

    private func waveformInput(smooth: Bool) -> WaveformRasterInput {
        var layers: [WaveformLayer] = []
        if !microphoneWaveformSamples.isEmpty {
            layers.append(WaveformLayer(samples: microphoneWaveformSamples, volume: microphoneVolumeScale, rgb: (1, 1, 1), opacity: 0.35))
        }
        if !waveformSamples.isEmpty {
            layers.append(WaveformLayer(samples: waveformSamples, volume: volumeScale, rgb: (77.0 / 255, 47.0 / 255, 245.0 / 255), opacity: 0.5))
        }
        let startFrac = max(0.0, min(1.0, sourceStartMs / totalSourceMs))
        let endFrac = max(startFrac + 0.001, min(1.0, sourceEndMs / totalSourceMs))
        return WaveformRasterInput(layers: layers, sourceFracRange: startFrac...endFrac, smooth: smooth)
    }

    private var tickLines: some View {
        Canvas { context, size in
            // B. Vertical Ruler Tick Lines at every minor/major ruler dot
            if minorTickStepSec > 0.01 {
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
        }
    }

    struct WaveformLayer: Equatable, Sendable {
        let samples: [Float]
        let volume: Double
        let rgb: (Double, Double, Double)
        let opacity: Double

        static func == (a: Self, b: Self) -> Bool {
            a.volume == b.volume && a.opacity == b.opacity && a.rgb == b.rgb && a.samples == b.samples
        }
    }

    /// Rasterizes the slice waveforms into one premultiplied bitmap, per device pixel, so the look does not depend on
    /// path antialiasing. Each layer draws its volume-scaled wave over a `0.10` opacity copy of the full wave in the same
    /// color; the full wave only shows while the volume is below `0.999`, so a lowered clip shows how much quieter it is.
    /// Inside a column, opacity rises from half at the bottom to full at the crest of that column.
    /// See ADR-42 in `spec/06`.
    nonisolated static func rasterizeWaveforms(
        layers: [WaveformLayer],
        sourceFracRange: ClosedRange<Double>,
        size: CGSize,
        scale: CGFloat,
        smooth: Bool
    ) -> CGImage? {
        guard !layers.isEmpty, size.width >= 1, size.height >= 1 else { return nil }
        let widthPx = Int(ceil(size.width * scale))
        let heightPx = Int(ceil(size.height * scale))
        guard widthPx > 0, heightPx > 0, widthPx * heightPx <= 40_000_000 else { return nil }

        let maxWaveHeight = Double(min(size.height * 0.68, 32.0))
        let rowLimit = Double(size.height)
        let pxScale = Double(scale)
        let width = Double(size.width)
        let startFrac = sourceFracRange.lowerBound
        let spanFrac = sourceFracRange.upperBound - sourceFracRange.lowerBound
        let pyramids = layers.map { buildWaveformPyramid(from: $0.samples) }

        var pixels = [UInt8](repeating: 0, count: widthPx * heightPx * 4)
        var shapeHeights = [Double](repeating: 0, count: layers.count)
        var fullHeights = [Double](repeating: 0, count: layers.count)

        @inline(__always) func coverage(_ h: Double, _ fromBottom: Double) -> Double {
            min(1, max(0, (h - fromBottom) * pxScale + 0.5))
        }
        @inline(__always) func fade(_ h: Double, _ fromBottom: Double) -> Double {
            0.5 + 0.5 * min(1, max(0, fromBottom / max(h, 1)))
        }

        for x in 0..<widthPx {
            let xPt = (Double(x) + 0.5) / pxScale
            let localFrac: Double
            if smooth {
                localFrac = xPt / width
            } else {
                // `View > Smooth waveform` off: 2pt bars on a 3pt pitch, each sampled at its center.
                let column = floor(xPt / 3.0)
                if xPt - column * 3.0 >= 2.0 { continue }
                localFrac = (column * 3.0 + 1.0) / width
            }

            var topHeight = 0.0
            for (i, layer) in layers.enumerated() {
                // `pxPerBin = 11`: one envelope bin per ~11pt, splined in between (see `readWaveformEnvelope`).
                let baseCount = Double(layer.samples.count)
                let env = readWaveformEnvelope(
                    pyramid: pyramids[i],
                    samplePosition: (startFrac + localFrac * spanFrac) * baseCount,
                    samplesPerBin: max(1.0, (max(1.0, spanFrac * baseCount) / max(1.0, width)) * 11.0)
                )
                fullHeights[i] = min(rowLimit, env * maxWaveHeight)
                shapeHeights[i] = min(rowLimit, env * maxWaveHeight * max(0, layer.volume))
                topHeight = max(topHeight, fullHeights[i], shapeHeights[i])
            }
            guard topHeight > 0 else { continue }

            let rows = min(heightPx, Int(ceil(topHeight * pxScale)) + 1)
            for row in 0..<rows {
                let fromBottom = (Double(row) + 0.5) / pxScale
                var r = 0.0, g = 0.0, b = 0.0, a = 0.0
                for (i, layer) in layers.enumerated() {
                    let hs = shapeHeights[i]
                    let shapeA = hs > 0 ? layer.opacity * coverage(hs, fromBottom) * fade(hs, fromBottom) : 0
                    let hf = fullHeights[i]
                    let fullA = (layer.volume < 0.999 && hf > 0) ? 0.1 * coverage(hf, fromBottom) * fade(hf, fromBottom) : 0
                    let layerA = shapeA + fullA * (1 - shapeA)
                    guard layerA > 0 else { continue }
                    let keep = 1 - layerA
                    r = layer.rgb.0 * layerA + r * keep
                    g = layer.rgb.1 * layerA + g * keep
                    b = layer.rgb.2 * layerA + b * keep
                    a = layerA + a * keep
                }
                guard a > 0 else { continue }
                // BGRA (premultiplied first, little endian): the layout the compositor uses, so drawing needs no conversion.
                let index = ((heightPx - 1 - row) * widthPx + x) * 4
                pixels[index] = UInt8(min(255, b * 255 + 0.5))
                pixels[index + 1] = UInt8(min(255, g * 255 + 0.5))
                pixels[index + 2] = UInt8(min(255, r * 255 + 0.5))
                pixels[index + 3] = UInt8(min(255, a * 255 + 0.5))
            }
        }

        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: widthPx,
            height: heightPx,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: widthPx * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    // MARK: - Mip-Pyramid + Catmull-Rom Cubic Spline

    nonisolated private static func buildWaveformPyramid(from baseSamples: [Float]) -> [[Float]] {
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

    nonisolated private static func readLevelBin(_ level: [Float], index: Int) -> Double {
        guard !level.isEmpty else { return 0.0 }
        if index < 0 || index >= level.count {
            return 0.0
        }
        return Double(level[index])
    }

    /// Evaluates the 4-point Catmull-Rom Cubic Spline at `samplePosition` on `levelIndex`:
    /// `curve = left + 0.5 * t * (linearTerm + t * (quadraticTerm + t * cubicTerm))`
    nonisolated private static func readPyramidLevel(pyramid: [[Float]], levelIndex: Int, samplePosition: Double) -> Double {
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
    nonisolated private static func readWaveformEnvelope(pyramid: [[Float]], samplePosition: Double, samplesPerBin: Double) -> Double {
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
    /// Base `glow` (`color.darken(0.2).opacity(0.8)`)
    let innerEdgeGlow: Color
    /// `activeGlow` (`color.darken(0.2).opacity(0.5)`)
    let activeInnerEdgeGlow: Color
    /// `playedGlow` (`color.opacity(0.5)`)
    let playedInnerEdgeGlow: Color
    /// Base `ring` (`color.lightness(+40)`)
    let ringBorder: Color
    /// `playedRing` (`color.lightness(+15)`)
    let playedRingBorder: Color
    /// Outer selection ring
    let selectedOuterOutline: Color

    /// Clip (`#93610C`):
    /// - `fillTop`: `#93610C` (`0.576, 0.380, 0.047`)
    /// - `fillBottom` (`lightness(+15)`): `#DA9012` (`0.855, 0.565, 0.071`)
    /// - `glow` (`darken(0.2).opacity(0.8)`): `#764E0A` (`0.463, 0.306, 0.039, 0.80`)
    /// - `activeGlow` (`darken(0.2).opacity(0.5)`): `#764E0A` (`0.463, 0.306, 0.039, 0.50`)
    /// - `playedGlow` (`opacity(0.5)`): `#93610C` (`0.576, 0.380, 0.047, 0.50`)
    /// - `ring` (`lightness(+40)`): `#F4C677` (`0.957, 0.776, 0.467`)
    /// - `playedRing` (`lightness(+15)`): `#DA9012` (`0.855, 0.565, 0.071`)
    /// - `selectedOuterOutline` (`lightness(+20).opacity(0.8)`): `#EC9E18` (`0.925, 0.620, 0.094, 0.80`)
    static let clipDark = SegmentShaderPalette(
        fillTop: Color(red: 0.576, green: 0.380, blue: 0.047),
        fillBottom: Color(red: 0.855, green: 0.565, blue: 0.071),
        innerEdgeGlow: Color(red: 0.463, green: 0.306, blue: 0.039).opacity(0.80),
        activeInnerEdgeGlow: Color(red: 0.463, green: 0.306, blue: 0.039).opacity(0.50),
        playedInnerEdgeGlow: Color(red: 0.576, green: 0.380, blue: 0.047).opacity(0.50),
        ringBorder: Color(red: 0.957, green: 0.776, blue: 0.467),
        playedRingBorder: Color(red: 0.855, green: 0.565, blue: 0.071),
        selectedOuterOutline: Color(red: 0.925, green: 0.620, blue: 0.094).opacity(0.80)
    )

    /// Zoom (`#4D2FF5`):
    /// - `fillTop`: `#4D2FF5` (`0.302, 0.184, 0.961`)
    /// - `fillBottom` (`lightness(+15)`): `#8B78F9` (`0.545, 0.471, 0.976`)
    /// - `glow` (`darken(0.2).opacity(0.8)`): `#2B0BDF` (`0.169, 0.043, 0.875, 0.80`)
    /// - `activeGlow` (`darken(0.2).opacity(0.5)`): `#2B0BDF` (`0.169, 0.043, 0.875, 0.50`)
    /// - `playedGlow` (`opacity(0.5)`): `#4D2FF5` (`0.302, 0.184, 0.961, 0.50`)
    /// - `ring` (`lightness(+40)`): `#F4F2FE` (`0.957, 0.949, 0.996`)
    /// - `playedRing` (`lightness(+15)`): `#8B78F9` (`0.545, 0.471, 0.976`)
    /// - `selectedOuterOutline` (`lightness(+20).opacity(0.8)`): `#A091FA` (`0.627, 0.569, 0.980, 0.80`)
    static let zoomDark = SegmentShaderPalette(
        fillTop: Color(red: 0.302, green: 0.184, blue: 0.961),
        fillBottom: Color(red: 0.545, green: 0.471, blue: 0.976),
        innerEdgeGlow: Color(red: 0.169, green: 0.043, blue: 0.875).opacity(0.80),
        activeInnerEdgeGlow: Color(red: 0.169, green: 0.043, blue: 0.875).opacity(0.50),
        playedInnerEdgeGlow: Color(red: 0.302, green: 0.184, blue: 0.961).opacity(0.50),
        ringBorder: Color(red: 0.957, green: 0.949, blue: 0.996),
        playedRingBorder: Color(red: 0.545, green: 0.471, blue: 0.976),
        selectedOuterOutline: Color(red: 0.627, green: 0.569, blue: 0.980).opacity(0.80)
    )

    /// Mask (`#82345A`):
    /// - `fillTop`: `#82345A` (`0.510, 0.204, 0.353`)
    /// - `fillBottom` (`lightness(+15)`): `#B74B80` (`0.718, 0.294, 0.502`)
    /// - `glow` (`darken(0.2).opacity(0.8)`): `#682A48` (`0.408, 0.165, 0.282, 0.80`)
    /// - `activeGlow` (`darken(0.2).opacity(0.5)`): `#682A48` (`0.408, 0.165, 0.282, 0.50`)
    /// - `playedGlow` (`opacity(0.5)`): `#82345A` (`0.510, 0.204, 0.353, 0.50`)
    /// - `ring` (`lightness(+40)`): `#DCA6C0` (`0.863, 0.651, 0.753`)
    /// - `playedRing` (`lightness(+15)`): `#B74B80` (`0.718, 0.294, 0.502`)
    /// - `selectedOuterOutline` (`lightness(+20).opacity(0.8)`): `#C65D91` (`0.776, 0.365, 0.569, 0.80`)
    static let maskDark = SegmentShaderPalette(
        fillTop: Color(red: 0.510, green: 0.204, blue: 0.353),
        fillBottom: Color(red: 0.718, green: 0.294, blue: 0.502),
        innerEdgeGlow: Color(red: 0.408, green: 0.165, blue: 0.282).opacity(0.80),
        activeInnerEdgeGlow: Color(red: 0.408, green: 0.165, blue: 0.282).opacity(0.50),
        playedInnerEdgeGlow: Color(red: 0.510, green: 0.204, blue: 0.353).opacity(0.50),
        ringBorder: Color(red: 0.863, green: 0.651, blue: 0.753),
        playedRingBorder: Color(red: 0.718, green: 0.294, blue: 0.502),
        selectedOuterOutline: Color(red: 0.776, green: 0.365, blue: 0.569).opacity(0.80)
    )

    /// Caption:
    static let captionDark = SegmentShaderPalette(
        fillTop: Color(red: 0.086, green: 0.388, blue: 0.431),
        fillBottom: Color(red: 0.122, green: 0.561, blue: 0.620),
        innerEdgeGlow: Color(red: 0.067, green: 0.310, blue: 0.345).opacity(0.80),
        activeInnerEdgeGlow: Color(red: 0.067, green: 0.310, blue: 0.345).opacity(0.50),
        playedInnerEdgeGlow: Color(red: 0.086, green: 0.388, blue: 0.431).opacity(0.50),
        ringBorder: Color(red: 0.600, green: 0.871, blue: 0.906),
        playedRingBorder: Color(red: 0.122, green: 0.561, blue: 0.620),
        selectedOuterOutline: Color(red: 0.176, green: 0.690, blue: 0.757).opacity(0.80)
    )

    /// Camera Layout:
    static let cameraLayoutDark = SegmentShaderPalette(
        fillTop: Color(red: 0.396, green: 0.341, blue: 0.369),
        fillBottom: Color(red: 0.553, green: 0.486, blue: 0.518),
        innerEdgeGlow: Color(red: 0.310, green: 0.267, blue: 0.290).opacity(0.80),
        activeInnerEdgeGlow: Color(red: 0.310, green: 0.267, blue: 0.290).opacity(0.50),
        playedInnerEdgeGlow: Color(red: 0.396, green: 0.341, blue: 0.369).opacity(0.50),
        ringBorder: Color(red: 0.820, green: 0.784, blue: 0.804),
        playedRingBorder: Color(red: 0.553, green: 0.486, blue: 0.518),
        selectedOuterOutline: Color(red: 0.660, green: 0.596, blue: 0.627).opacity(0.80)
    )

    // Light mode: brighter, more saturated fills, and a softer edge glow in the fill's own hue. The dark palettes'
    // darkened edge glow reads as dirt on a light timeline.
    static let clipLight = SegmentShaderPalette(
        fillTop: Color(red: 0.851, green: 0.533, blue: 0.098),
        fillBottom: Color(red: 0.937, green: 0.663, blue: 0.231),
        innerEdgeGlow: Color(red: 0.710, green: 0.420, blue: 0.050).opacity(0.35),
        activeInnerEdgeGlow: Color(red: 0.710, green: 0.420, blue: 0.050).opacity(0.22),
        playedInnerEdgeGlow: Color(red: 0.851, green: 0.533, blue: 0.098).opacity(0.35),
        ringBorder: Color(red: 1.000, green: 0.875, blue: 0.655),
        playedRingBorder: Color(red: 0.937, green: 0.663, blue: 0.231),
        selectedOuterOutline: Color(red: 0.925, green: 0.580, blue: 0.100).opacity(0.85)
    )
    static let zoomLight = SegmentShaderPalette(
        fillTop: Color(red: 0.388, green: 0.290, blue: 0.973),
        fillBottom: Color(red: 0.596, green: 0.533, blue: 0.984),
        innerEdgeGlow: Color(red: 0.250, green: 0.150, blue: 0.850).opacity(0.35),
        activeInnerEdgeGlow: Color(red: 0.250, green: 0.150, blue: 0.850).opacity(0.22),
        playedInnerEdgeGlow: Color(red: 0.388, green: 0.290, blue: 0.973).opacity(0.35),
        ringBorder: Color(red: 0.902, green: 0.882, blue: 1.000),
        playedRingBorder: Color(red: 0.596, green: 0.533, blue: 0.984),
        selectedOuterOutline: Color(red: 0.553, green: 0.471, blue: 0.976).opacity(0.85)
    )
    static let maskLight = SegmentShaderPalette(
        fillTop: Color(red: 0.733, green: 0.310, blue: 0.522),
        fillBottom: Color(red: 0.851, green: 0.475, blue: 0.663),
        innerEdgeGlow: Color(red: 0.550, green: 0.200, blue: 0.380).opacity(0.35),
        activeInnerEdgeGlow: Color(red: 0.550, green: 0.200, blue: 0.380).opacity(0.22),
        playedInnerEdgeGlow: Color(red: 0.733, green: 0.310, blue: 0.522).opacity(0.35),
        ringBorder: Color(red: 0.980, green: 0.820, blue: 0.898),
        playedRingBorder: Color(red: 0.851, green: 0.475, blue: 0.663),
        selectedOuterOutline: Color(red: 0.800, green: 0.380, blue: 0.600).opacity(0.85)
    )
    static let captionLight = SegmentShaderPalette(
        fillTop: Color(red: 0.106, green: 0.561, blue: 0.616),
        fillBottom: Color(red: 0.231, green: 0.722, blue: 0.773),
        innerEdgeGlow: Color(red: 0.050, green: 0.400, blue: 0.450).opacity(0.35),
        activeInnerEdgeGlow: Color(red: 0.050, green: 0.400, blue: 0.450).opacity(0.22),
        playedInnerEdgeGlow: Color(red: 0.106, green: 0.561, blue: 0.616).opacity(0.35),
        ringBorder: Color(red: 0.700, green: 0.941, blue: 0.969),
        playedRingBorder: Color(red: 0.231, green: 0.722, blue: 0.773),
        selectedOuterOutline: Color(red: 0.180, green: 0.690, blue: 0.757).opacity(0.85)
    )
    static let cameraLayoutLight = SegmentShaderPalette(
        fillTop: Color(red: 0.533, green: 0.478, blue: 0.510),
        fillBottom: Color(red: 0.690, green: 0.643, blue: 0.667),
        innerEdgeGlow: Color(red: 0.400, green: 0.350, blue: 0.380).opacity(0.35),
        activeInnerEdgeGlow: Color(red: 0.400, green: 0.350, blue: 0.380).opacity(0.22),
        playedInnerEdgeGlow: Color(red: 0.533, green: 0.478, blue: 0.510).opacity(0.35),
        ringBorder: Color(red: 0.918, green: 0.890, blue: 0.906),
        playedRingBorder: Color(red: 0.690, green: 0.643, blue: 0.667),
        selectedOuterOutline: Color(red: 0.620, green: 0.561, blue: 0.600).opacity(0.85)
    )

    static let clip = adaptive(dark: clipDark, light: clipLight)
    static let zoom = adaptive(dark: zoomDark, light: zoomLight)
    static let mask = adaptive(dark: maskDark, light: maskLight)
    static let caption = adaptive(dark: captionDark, light: captionLight)
    static let cameraLayout = adaptive(dark: cameraLayoutDark, light: cameraLayoutLight)
    static let annotation = adaptive(dark: annotationDark, light: annotationLight)
    static let shortcut = adaptive(dark: shortcutDark, light: shortcutLight)

    /// Shortcut (`#1C6B47`, emerald): a hue no other track uses. The keycaps in the video keep their own color.
    static let shortcutDark = SegmentShaderPalette(
        fillTop: Color(red: 0.110, green: 0.420, blue: 0.278),
        fillBottom: Color(red: 0.165, green: 0.600, blue: 0.400),
        innerEdgeGlow: Color(red: 0.086, green: 0.336, blue: 0.222).opacity(0.80),
        activeInnerEdgeGlow: Color(red: 0.086, green: 0.336, blue: 0.222).opacity(0.50),
        playedInnerEdgeGlow: Color(red: 0.110, green: 0.420, blue: 0.278).opacity(0.50),
        ringBorder: Color(red: 0.600, green: 0.906, blue: 0.761),
        playedRingBorder: Color(red: 0.165, green: 0.600, blue: 0.400),
        selectedOuterOutline: Color(red: 0.200, green: 0.700, blue: 0.470).opacity(0.80)
    )
    static let shortcutLight = SegmentShaderPalette(
        fillTop: Color(red: 0.180, green: 0.620, blue: 0.416),
        fillBottom: Color(red: 0.310, green: 0.765, blue: 0.553),
        innerEdgeGlow: Color(red: 0.090, green: 0.450, blue: 0.280).opacity(0.35),
        activeInnerEdgeGlow: Color(red: 0.090, green: 0.450, blue: 0.280).opacity(0.22),
        playedInnerEdgeGlow: Color(red: 0.180, green: 0.620, blue: 0.416).opacity(0.35),
        ringBorder: Color(red: 0.760, green: 0.957, blue: 0.863),
        playedRingBorder: Color(red: 0.310, green: 0.765, blue: 0.553),
        selectedOuterOutline: Color(red: 0.220, green: 0.700, blue: 0.470).opacity(0.85)
    )

    /// Annotation (`#A6422A`, coral): the color an arrow is by default.
    static let annotationDark = SegmentShaderPalette(
        fillTop: Color(red: 0.651, green: 0.259, blue: 0.165),
        fillBottom: Color(red: 0.851, green: 0.380, blue: 0.255),
        innerEdgeGlow: Color(red: 0.520, green: 0.200, blue: 0.125).opacity(0.80),
        activeInnerEdgeGlow: Color(red: 0.520, green: 0.200, blue: 0.125).opacity(0.50),
        playedInnerEdgeGlow: Color(red: 0.651, green: 0.259, blue: 0.165).opacity(0.50),
        ringBorder: Color(red: 0.980, green: 0.780, blue: 0.720),
        playedRingBorder: Color(red: 0.851, green: 0.380, blue: 0.255),
        selectedOuterOutline: Color(red: 0.900, green: 0.450, blue: 0.320).opacity(0.80)
    )
    static let annotationLight = SegmentShaderPalette(
        fillTop: Color(red: 0.894, green: 0.420, blue: 0.290),
        fillBottom: Color(red: 0.957, green: 0.565, blue: 0.447),
        innerEdgeGlow: Color(red: 0.700, green: 0.280, blue: 0.170).opacity(0.35),
        activeInnerEdgeGlow: Color(red: 0.700, green: 0.280, blue: 0.170).opacity(0.22),
        playedInnerEdgeGlow: Color(red: 0.894, green: 0.420, blue: 0.290).opacity(0.35),
        ringBorder: Color(red: 1.000, green: 0.860, blue: 0.810),
        playedRingBorder: Color(red: 0.957, green: 0.565, blue: 0.447),
        selectedOuterOutline: Color(red: 0.920, green: 0.470, blue: 0.330).opacity(0.85)
    )

    private static func adaptive(dark: SegmentShaderPalette, light: SegmentShaderPalette) -> SegmentShaderPalette {
        SegmentShaderPalette(
            fillTop: .adaptive(dark: dark.fillTop, light: light.fillTop),
            fillBottom: .adaptive(dark: dark.fillBottom, light: light.fillBottom),
            innerEdgeGlow: .adaptive(dark: dark.innerEdgeGlow, light: light.innerEdgeGlow),
            activeInnerEdgeGlow: .adaptive(dark: dark.activeInnerEdgeGlow, light: light.activeInnerEdgeGlow),
            playedInnerEdgeGlow: .adaptive(dark: dark.playedInnerEdgeGlow, light: light.playedInnerEdgeGlow),
            ringBorder: .adaptive(dark: dark.ringBorder, light: light.ringBorder),
            playedRingBorder: .adaptive(dark: dark.playedRingBorder, light: light.playedRingBorder),
            selectedOuterOutline: .adaptive(dark: dark.selectedOuterOutline, light: light.selectedOuterOutline)
        )
    }
}

/// Renders the `shadeBody`
/// with a smooth, continuous normal-CDF inner glow feather (`box-shadow: inset 0px 0px 15px 3px glowColor`) and zero sharp concentric rings!
private struct SegmentBodyCanvas: View, Equatable {
    let palette: SegmentShaderPalette
    let isSelected: Bool
    let isPlayed: Bool

    var body: some View {
        let glowColor: Color = isSelected
            ? palette.activeInnerEdgeGlow
            : (isPlayed ? palette.playedInnerEdgeGlow : palette.innerEdgeGlow)
        let ringColor: Color = isSelected
            ? Color.white
            : (isPlayed ? palette.playedRingBorder : palette.ringBorder)

        ZStack {
            // 1. Vertical LinearGradient (`fillTop` -> `fillBottom`)
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [palette.fillTop, palette.fillBottom],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            // 2. Smooth 4-edge Gaussian-CDF inner vignette (`GLOW_SPREAD_PX = 3`, `GLOW_SIGMA_PX = 7.5`)
            //    Using 4 edge-aligned multi-stop `LinearGradient`s produces a 100% smooth, continuous fade from the edges
            //    with ZERO sharp step boundaries and ZERO offscreen blur buffer allocations during resize!
            GeometryReader { geo in
                let w = max(1.0, geo.size.width)
                let h = max(1.0, geo.size.height)
                let fadeDepthY = min(h * 0.48, 18.0)
                let fadeDepthX = min(w * 0.45, 20.0)
                let yFrac1 = min(0.48, (fadeDepthY * 0.22) / h)
                let yFrac2 = min(0.49, (fadeDepthY * 0.55) / h)
                let yFrac3 = min(0.50, fadeDepthY / h)
                let xFrac1 = min(0.48, (fadeDepthX * 0.22) / w)
                let xFrac2 = min(0.49, (fadeDepthX * 0.55) / w)
                let xFrac3 = min(0.50, fadeDepthX / w)

                ZStack {
                    // Top & Bottom smooth Gaussian-CDF falloff
                    LinearGradient(
                        stops: [
                            .init(color: glowColor.opacity(0.72), location: 0.0),
                            .init(color: glowColor.opacity(0.42), location: yFrac1),
                            .init(color: glowColor.opacity(0.14), location: yFrac2),
                            .init(color: .clear, location: yFrac3),
                            .init(color: .clear, location: 1.0 - yFrac3),
                            .init(color: glowColor.opacity(0.14), location: 1.0 - yFrac2),
                            .init(color: glowColor.opacity(0.42), location: 1.0 - yFrac1),
                            .init(color: glowColor.opacity(0.72), location: 1.0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )

                    // Left & Right smooth Gaussian-CDF falloff
                    LinearGradient(
                        stops: [
                            .init(color: glowColor.opacity(0.68), location: 0.0),
                            .init(color: glowColor.opacity(0.38), location: xFrac1),
                            .init(color: glowColor.opacity(0.12), location: xFrac2),
                            .init(color: .clear, location: xFrac3),
                            .init(color: .clear, location: 1.0 - xFrac3),
                            .init(color: glowColor.opacity(0.12), location: 1.0 - xFrac2),
                            .init(color: glowColor.opacity(0.38), location: 1.0 - xFrac1),
                            .init(color: glowColor.opacity(0.68), location: 1.0)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .allowsHitTesting(false)

            // 3. Crisp 1px inner ring
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    ringColor.opacity(isSelected ? 0.95 : 0.72),
                    lineWidth: 1.0
                )
        }
    }
}

// MARK: - Interactive Segment Block with Shader Look, Waveform, Inset Handles & Icon Labels

private enum SegmentSubtitleContent: Equatable {
    case clip(durationText: String, speedText: String)
    case zoom(scaleText: String, modeText: String)
    case mask(text: String)
    case annotation(icon: String, text: String)
    case voiceover(volumeText: String, volumeIcon: String)
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
    var isDimmedBySelection: Bool = false
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
    /// Item id used to leave the item out of its own snap targets; `nil` turns snapping off (clips).
    var snapItemId: String? = nil
    let clipDecoration: ClipSegmentDecoration?
    let onClickAtLocalX: (CGFloat) -> Void
    let onRightClick: (NSPoint, NSView) -> Void
    let onBeginInteractive: () -> Void
    let onMoveBody: (Double, Double) -> Void
    let onResizeRange: (Double, Double) -> Void
    let onMoveVerticalTracks: (Int) -> Void
    let onEndInteractive: () -> Void

    @State private var isHovered = false
    @State private var isEdgeHovered = false
    @State private var activeDragMode: SegmentDragMode? = nil
    @State private var pressLocalX: CGFloat = 0.0
    @State private var hasExceededClickSlop = false
    @State private var dragInitialStartMs: Double?
    @State private var dragInitialEndMs: Double?
    @State private var dragInitialSegWidth: CGFloat = 60.0
    @State private var verticalDragOffset: CGFloat = 0.0
    @Environment(TimelineSnapController.self) private var snap

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let edgeHandleHitWidth: CGFloat = 13.0
    /// Clears the resize handles (they reach about 10 pt in), so a label goes before a handle touches it.
    private let labelInset: CGFloat = 16.0
    /// Every label fits at this width, so wide segments skip measuring text.
    private let alwaysFitsLabelWidth: CGFloat = 220.0
    /// Captions and mask names shorter than this show in full or not at all. Longer ones truncate down to this width,
    /// so a long caption stays readable without a stub like "New ca...".
    private let shortestTruncatedTextWidth: CGFloat = 96.0

    var body: some View {
        // 1px visual gap between adjacent touching segments
        let segWidth = max(6.0, width - 1.0)
        // Adaptive edge hit width: up to `13pt` on wide segments, and at least ~1/3 of `segWidth` (`>= 5.5pt`) on narrow segments
        // so even a minimum-width segment always has a left resize zone, a center move zone, and a right resize zone!
        let edgeHitWidth = min(edgeHandleHitWidth, max(5.5, segWidth * 0.34))
        // Hover: `.track-item.is-hovered & { opacity: 1; transform: scaleY(1); }`
        // Resize handles appear on hover or during an active resize drag, including on narrow segments!
        let showHandles = !isSplitMode
            && (isHovered || activeDragMode == .resizeLeft || activeDragMode == .resizeRight)
        let handleBarWidth: CGFloat = segWidth < 24 ? 2.4 : 3.0
        let handleHorizontalInset: CGFloat = min(6.5, max(2.2, (segWidth - handleBarWidth * 2.0 - 3.5) * 0.5))
        let labelRoom = segWidth - labelInset * 2.0
        let showsTitle = labelRoom >= titleLabelWidth(whenRoomIs: labelRoom)
        let showsSubtitle = showsTitle && labelRoom >= subtitleLabelWidth(whenRoomIs: labelRoom)

        // opacity rules (`0.50` when disabled, `0.30` when dimmed by another open item on the same track)
        let bodyOpacity: Double = (isDimmed ? 0.50 : 1.0) * (isDimmedBySelection ? 0.30 : 1.0)

        ZStack(alignment: .leading) {
            // 1. `shadeBody` (`radiusPx = 10`, smooth Gaussian-CDF inner glow + 1px ring)
            EquatableView(
                content: SegmentBodyCanvas(
                    palette: palette,
                    isSelected: isSelected,
                    isPlayed: isPlayed
                )
            )
            .opacity(bodyOpacity)

            // 2. Clip-Specific Decoration: Audio Waveform along Bottom + Ruler Vertical Tick Lines from Top (Equatable so it never redraws during hover skimming!)
            if let deco = clipDecoration {
                EquatableView(content: deco)
                    .opacity(isDimmedBySelection ? 0.30 : 1.0)
            }

            // 3. Outer 1px Selection Outline
            if isSelected {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(palette.selectedOuterOutline, lineWidth: 1.0)
                    .padding(-1.5)
                    .allowsHitTesting(false)
            }

            // 4. Centered title and subtitle. As the segment narrows the subtitle goes first, the title slides to the
            //    vertical center, then the title goes too, so a segment can be resized down to almost nothing.
            VStack(spacing: 1.5) {
                if showsTitle {
                    Text(topTitle.localizedUI)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                        .transition(.opacity)
                }

                if showsSubtitle {
                    subtitleRowView
                        .transition(.opacity)
                }
            }
            .opacity(bodyOpacity)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, labelInset)
            .padding(.bottom, 1)
            .allowsHitTesting(false)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: showsTitle)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: showsSubtitle)

            // 5. Left & Right Edge Resize Bars
            if !isSplitMode && segWidth >= 10 {
                HStack(spacing: 0) {
                    Capsule()
                        .fill(Color.white.opacity(0.95))
                        .frame(width: handleBarWidth, height: max(8, height - 18))
                        .scaleEffect(x: 1.0, y: showHandles ? 1.0 : 0.95)
                        .padding(.leading, handleHorizontalInset)

                    Spacer(minLength: 2)

                    Capsule()
                        .fill(Color.white.opacity(0.95))
                        .frame(width: handleBarWidth, height: max(8, height - 18))
                        .scaleEffect(x: 1.0, y: showHandles ? 1.0 : 0.95)
                        .padding(.trailing, handleHorizontalInset)
                }
                .opacity(showHandles ? 1.0 : 0.0)
                .animation(.easeInOut(duration: 0.16), value: showHandles)
                .allowsHitTesting(false)
            }
        }
        .frame(width: segWidth, height: height)
        .overlay(
            RightClickDetectorView(
                isSplitMode: isSplitMode,
                isEdgeHovered: isEdgeHovered && !isSplitMode
            ) { pointInView, parentView in
                onRightClick(pointInView, parentView)
            }
        )
        .contentShape(Rectangle().inset(by: -3.0))
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let pt):
                guard activeDragMode == nil && NSEvent.pressedMouseButtons == 0 else { return }
                // Crucial: because `.offset(x: xOffset)` is applied AFTER `.onContinuousHover(coordinateSpace: .local)`,
                // SwiftUI passes `pt.x` in the parent `ZStack` coordinate space (`xOffset .. xOffset + segWidth`).
                // Subtracting `xOffset` gives the true `[0 .. segWidth]` local coordinate!
                let localX = (pt.x >= xOffset - 6 && pt.x <= xOffset + segWidth + 6) ? (pt.x - xOffset) : pt.x
                let clampedLocalX = max(0, min(segWidth, localX))
                let onEdge = (clampedLocalX <= edgeHitWidth || clampedLocalX >= segWidth - edgeHitWidth)
                if !isHovered {
                    isHovered = true
                }
                if isEdgeHovered != onEdge {
                    isEdgeHovered = onEdge
                }
                if isSplitMode {
                    NSCursor.crosshair.set()
                } else if onEdge {
                    NSCursor.resizeLeftRight.set()
                } else {
                    NSCursor.arrow.set()
                }
            case .ended:
                guard activeDragMode == nil && NSEvent.pressedMouseButtons == 0 else { return }
                isHovered = false
                isEdgeHovered = false
                if isSplitMode {
                    NSCursor.crosshair.set()
                } else {
                    NSCursor.arrow.set()
                }
            }
        }
        // VoiceOver: one button per segment. Pressing it does what a click in its middle does (select, or split in split mode).
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: accessibilityName))
        .accessibilityValue(Text(verbatim: AccessibilityText.range(startMs: startMs, endMs: endMs)))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default) { onClickAtLocalX(segWidth * 0.5) }
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

                        if !isSplitMode && localX <= edgeHitWidth {
                            activeDragMode = .resizeLeft
                            NSCursor.resizeLeftRight.set()
                        } else if !isSplitMode && localX >= segWidth - edgeHitWidth {
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
                        if let snapItemId {
                            snap.begin(excludingItemId: snapItemId, pointsPerMs: Double(totalWidth) / max(1.0, trackTotalDurationMs))
                        }
                        onBeginInteractive()
                    }

                    guard let s0 = dragInitialStartMs,
                          let e0 = dragInitialEndMs,
                          let mode = activeDragMode else { return }

                    let deltaMs = Double(value.translation.width / max(1.0, totalWidth)) * trackTotalDurationMs

                    switch mode {
                    case .resizeLeft:
                        let rawStart = s0 + deltaMs
                        let newStart = max(0.0, min(e0 - 250.0, snapItemId == nil ? rawStart : snap.snapEdge(rawStart)))
                        onResizeRange(newStart, e0)

                    case .resizeRight:
                        let rawEnd = e0 + deltaMs
                        let newEnd = max(s0 + 250.0, snapItemId == nil ? rawEnd : snap.snapEdge(rawEnd))
                        onResizeRange(s0, newEnd)

                    case .moveBody:
                        guard allowDragMove else { return }
                        let constantDurationMs = e0 - s0
                        let rawStart = s0 + deltaMs
                        let start = snapItemId == nil ? rawStart : snap.snapMove(startMs: rawStart, durationMs: constantDurationMs)
                        onMoveBody(start, constantDurationMs)

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
                        snap.end()
                        onEndInteractive()
                    } else {
                        onClickAtLocalX(localX)
                    }

                    activeDragMode = nil
                    hasExceededClickSlop = false
                    dragInitialStartMs = nil
                    dragInitialEndMs = nil
                    verticalDragOffset = 0.0
                    if isSplitMode {
                        NSCursor.crosshair.set()
                    } else {
                        NSCursor.arrow.set()
                    }
                }
        )
    }

    private func textWidth(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight)]).width)
    }

    private func titleLabelWidth(whenRoomIs room: CGFloat) -> CGFloat {
        room >= alwaysFitsLabelWidth ? 0.0 : textWidth(topTitle.localizedUI, size: 11.5, weight: .semibold)
    }

    /// Width of `subtitleRowView` when nothing in it is cut off. Matches its fonts and spacing; icons are about 13 pt.
    private func subtitleLabelWidth(whenRoomIs room: CGFloat) -> CGFloat {
        guard room < alwaysFitsLabelWidth else { return 0.0 }
        let iconWidth: CGFloat = 13.0
        switch subtitleContent {
        case .clip(let durationText, let speedText):
            return textWidth(durationText, size: 12.0) + 6.0 + iconWidth + 3.0 + textWidth(speedText, size: 12.0)
        case .zoom(let scaleText, let modeText):
            return iconWidth + 3.5 + textWidth(scaleText, size: 12.0) + 8.0 + iconWidth + 3.5 + textWidth(modeText, size: 12.0)
        case .mask(let text):
            return 11.0 + 5.0 + min(textWidth(text.localizedUI, size: 11.5), shortestTruncatedTextWidth)
        case .annotation(_, let text):
            return iconWidth + 4.0 + min(textWidth(text, size: 11.5), shortestTruncatedTextWidth)
        case .voiceover(let volumeText, _):
            return iconWidth + 3.5 + textWidth("Microphone".localizedUI, size: 11.5) + 7.0
                + iconWidth + 3.0 + textWidth(volumeText, size: 11.5)
        }
    }

    /// Title plus what the subtitle row shows, translated, e.g. "Zoom, 1.6×, Auto".
    private var accessibilityName: String {
        var parts = [topTitle.localizedUI]
        switch subtitleContent {
        case .clip(let durationText, let speedText):
            parts += [durationText, speedText]
        case .zoom(let scaleText, let modeText):
            parts += [scaleText, modeText.localizedUI]
        case .mask(let text):
            parts.append(text.localizedUI)
        case .annotation(_, let text):
            parts.append(text)
        case .voiceover(let volumeText, _):
            parts += ["Microphone".localizedUI, volumeText]
        }
        if isDimmed { parts.append("Disabled".localizedUI) }
        return parts.filter { !$0.isEmpty }.joined(separator: ", ")
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
                    Text(modeText.localizedUI)
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
                Text(text.localizedUI)
                    .font(.system(size: 11.5, weight: .regular))
                    .foregroundStyle(.white.opacity(0.96))
            }
            .lineLimit(1)

        case .annotation(let icon, let text):
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10.5, weight: .semibold))
                Text(text)
                    .font(.system(size: 11.5, weight: .regular))
            }
            .foregroundStyle(.white.opacity(0.96))
            .lineLimit(1)

        case .voiceover(let volumeText, let volumeIcon):
            // Voiceover label (`microphone` + `Microphone` + speaker icon + `100%`)
            HStack(spacing: 7) {
                HStack(spacing: 3.5) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 10.0, weight: .regular))
                    Text("Microphone")
                        .font(.system(size: 11.5, weight: .regular))
                }
                HStack(spacing: 3.0) {
                    Image(systemName: volumeIcon)
                        .font(.system(size: 10.0, weight: .regular))
                    Text(volumeText)
                        .font(.system(size: 11.5, weight: .regular).monospacedDigit())
                }
            }
            .foregroundStyle(.white.opacity(0.96))
            .lineLimit(1)
        }
    }
}

// MARK: - AppKit Helpers for Right-Click Popover Trigger & NSScrollView Introspection

private struct RightClickDetectorView: NSViewRepresentable {
    var isSplitMode: Bool = false
    var isEdgeHovered: Bool = false
    let onRightClick: (NSPoint, NSView) -> Void

    func makeNSView(context: Context) -> RightClickCatcherNSView {
        let v = RightClickCatcherNSView()
        v.isSplitMode = isSplitMode
        v.isEdgeHovered = isEdgeHovered
        v.onRightClick = onRightClick
        return v
    }

    func updateNSView(_ nsView: RightClickCatcherNSView, context: Context) {
        let modeChanged = (nsView.isSplitMode != isSplitMode) || (nsView.isEdgeHovered != isEdgeHovered)
        nsView.isSplitMode = isSplitMode
        nsView.isEdgeHovered = isEdgeHovered
        nsView.onRightClick = onRightClick
        if modeChanged {
            nsView.window?.invalidateCursorRects(for: nsView)
        }
    }

    // AppKit can keep a detached NSView alive after its window closes; drop the closure so it stops holding the session.
    static func dismantleNSView(_ nsView: RightClickCatcherNSView, coordinator: ()) {
        nsView.onRightClick = nil
    }

    final class RightClickCatcherNSView: NSView {
        var isSplitMode: Bool = false
        var isEdgeHovered: Bool = false
        var onRightClick: ((NSPoint, NSView) -> Void)?

        override func resetCursorRects() {
            super.resetCursorRects()
            let cursor: NSCursor = isSplitMode
                ? .crosshair
                : (isEdgeHovered ? .resizeLeftRight : .arrow)
            addCursorRect(bounds, cursor: cursor)
        }

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

private struct TimelineScrollGeometry: Equatable {
    let contentOffset: CGPoint
    let contentSize: CGSize
}

private extension View {
    /// `onScrollGeometryChange` from macOS 15. On macOS 14 it does nothing and `TimelineScrollObserver` reports instead.
    @ViewBuilder
    func onTimelineScrollChange<Value: Equatable>(
        of value: @escaping (TimelineScrollGeometry) -> Value,
        action: @escaping (Value) -> Void
    ) -> some View {
        if #available(macOS 15.0, *) {
            onScrollGeometryChange(for: Value.self) { geometry in
                value(TimelineScrollGeometry(contentOffset: geometry.contentOffset, contentSize: geometry.contentSize))
            } action: { _, newValue in
                action(newValue)
            }
        } else {
            self
        }
    }
}

/// Reports the offset and content size of an `NSScrollView`, for macOS 14, which has no `onScrollGeometryChange`.
@MainActor
private final class TimelineScrollObserver {
    private weak var scrollView: NSScrollView?
    private nonisolated(unsafe) var tokens: [NSObjectProtocol] = []

    deinit {
        tokens.forEach(NotificationCenter.default.removeObserver)
    }

    func observe(_ scrollView: NSScrollView, onChange: @escaping (TimelineScrollGeometry) -> Void) {
        guard self.scrollView !== scrollView, let document = scrollView.documentView else { return }
        tokens.forEach(NotificationCenter.default.removeObserver)
        tokens = []
        self.scrollView = scrollView

        let clip = scrollView.contentView
        let report = { [weak clip, weak document] in
            guard let clip, let document else { return }
            let y = document.isFlipped ? clip.bounds.minY : document.frame.height - clip.bounds.height - clip.bounds.minY
            onChange(TimelineScrollGeometry(contentOffset: CGPoint(x: clip.bounds.minX, y: y), contentSize: document.frame.size))
        }
        clip.postsBoundsChangedNotifications = true
        document.postsFrameChangedNotifications = true
        for (name, object) in [(NSView.boundsDidChangeNotification, clip as NSView), (NSView.frameDidChangeNotification, document)] {
            tokens.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { _ in
                MainActor.assumeIsolated { report() }
            })
        }
        report()
    }
}

private struct HorizontalScrollViewIntrospector: NSViewRepresentable {
    var isSplitMode: Bool = false
    var alwaysShowScroller: Bool = false
    let onFound: (NSScrollView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let sv = view.enclosingScrollView {
                sv.documentCursor = isSplitMode ? .crosshair : nil
                onFound(sv)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let splitMode = isSplitMode
        let alwaysShowScroller = self.alwaysShowScroller
        DispatchQueue.main.async {
            if let sv = nsView.enclosingScrollView {
                // `View > Always show timeline scrollbar`: a legacy scroller stays visible; overlay scrollers auto-hide.
                let style: NSScroller.Style = alwaysShowScroller ? .legacy : .overlay
                if sv.scrollerStyle != style {
                    sv.scrollerStyle = style
                    sv.autohidesScrollers = !alwaysShowScroller
                }
                let targetCursor: NSCursor? = splitMode ? .crosshair : nil
                if sv.documentCursor !== targetCursor {
                    sv.documentCursor = targetCursor
                    sv.window?.invalidateCursorRects(for: sv.contentView)
                }
                onFound(sv)
            }
        }
    }
}

// MARK: - Waveform Bitmap (cached, re-rasterized off the main thread after a zoom)

private struct WaveformRasterInput: Equatable, Sendable {
    let layers: [ClipSegmentDecoration.WaveformLayer]
    let sourceFracRange: ClosedRange<Double>
    let smooth: Bool
}

private struct WaveformRasterKey: Equatable, Sendable {
    let input: WaveformRasterInput
    let widthPx: Int
    let heightPx: Int
    let scale: CGFloat
}

/// Holds the last waveform bitmap. A reference type so the `Canvas` renderer can fill it without a state change.
@MainActor
private final class WaveformRasterCache {
    var key: WaveformRasterKey?
    var image: CGImage?
}

/// Draws the slice waveform bitmap from `ClipSegmentDecoration.rasterizeWaveforms`.
///
/// Rasterizing is per device pixel over the whole slice width, which at 6x zoom is tens of thousands of pixels: far
/// too slow to redo on every zoom step. When only the width changed (zoom, window resize), the last bitmap is drawn
/// stretched to the new width, which the GPU does for free, and a sharp one is rasterized on a background thread
/// once the width has held still for 90 ms. Any other change (trim, volume, samples, height) rasterizes right away,
/// as before, so edits never show a stale wave. See ADR-46 in `spec/06`.
private struct ClipWaveformImageView: View {
    let input: WaveformRasterInput

    @Environment(\.displayScale) private var displayScale
    @State private var cache = WaveformRasterCache()
    @State private var size: CGSize = .zero
    @State private var redraw = 0

    var body: some View {
        let scale = max(1.0, displayScale)
        Canvas { context, canvasSize in
            _ = redraw
            guard let key = Self.key(input: input, size: canvasSize, scale: scale) else { return }
            if cache.key != key {
                let onlyWidthChanged = cache.key.map {
                    $0.input == key.input && $0.heightPx == key.heightPx && $0.scale == key.scale
                } ?? false
                if !onlyWidthChanged || cache.image == nil {
                    cache.image = ClipSegmentDecoration.rasterizeWaveforms(
                        layers: input.layers, sourceFracRange: input.sourceFracRange,
                        size: canvasSize, scale: scale, smooth: input.smooth
                    )
                    cache.key = key
                }
            }
            guard let image = cache.image else { return }
            let drawHeight = CGFloat(image.height) / scale
            context.draw(
                Image(decorative: image, scale: scale),
                in: CGRect(x: 0, y: canvasSize.height - drawHeight, width: canvasSize.width, height: drawHeight)
            )
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
        .task(id: Self.key(input: input, size: size, scale: scale)) {
            guard let key = Self.key(input: input, size: size, scale: scale), cache.key != key else { return }
            try? await Task.sleep(for: .milliseconds(90))
            guard !Task.isCancelled else { return }
            let input = self.input, rasterSize = size
            let image = await Task.detached(priority: .userInitiated) {
                ClipSegmentDecoration.rasterizeWaveforms(
                    layers: input.layers, sourceFracRange: input.sourceFracRange,
                    size: rasterSize, scale: scale, smooth: input.smooth
                )
            }.value
            guard !Task.isCancelled else { return }
            cache.image = image
            cache.key = key
            redraw &+= 1
        }
    }

    private static func key(input: WaveformRasterInput, size: CGSize, scale: CGFloat) -> WaveformRasterKey? {
        guard size.width >= 1, size.height >= 1 else { return nil }
        return WaveformRasterKey(
            input: input,
            widthPx: Int(ceil(size.width * scale)),
            heightPx: Int(ceil(size.height * scale)),
            scale: scale
        )
    }
}

// MARK: - Cmd + Scroll Zoom

@MainActor
private final class TimelineZoomClock {
    private var lastStep: CFTimeInterval = 0
    func mark() { lastStep = CACurrentMediaTime() }
    var isZooming: Bool { CACurrentMediaTime() - lastStep < 0.15 }
}

/// Catches Cmd + scroll wheel over its own frame and reports the cursor x (in its coordinates, left to right) with a
/// zoom factor. A local monitor rather than `scrollWheel(with:)` because the track lanes' `NSScrollView` gets the
/// event first; the monitor consumes it so the timeline does not also scroll. Plain scrolling is left alone.
private struct TimelineCommandScrollZoomCatcher: NSViewRepresentable {
    let onZoom: (CGFloat, Double) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onZoom = onZoom
        return view
    }

    func updateNSView(_ nsView: CatcherView, context: Context) {
        nsView.onZoom = onZoom
    }

    static func dismantleNSView(_ nsView: CatcherView, coordinator: ()) {
        nsView.removeMonitor()
        nsView.onZoom = nil
    }

    final class CatcherView: NSView {
        var onZoom: ((CGFloat, Double) -> Void)?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, let window = self.window, event.modifierFlags.contains(.command) else { return event }
                // Go by the window under the cursor: a window-less event carries a screen location.
                let screenPoint = event.window.map { $0.convertPoint(toScreen: event.locationInWindow) } ?? event.locationInWindow
                guard NSWindow.windowNumber(at: screenPoint, belowWindowWithWindowNumber: 0) == window.windowNumber else { return event }
                let point = self.convert(window.convertPoint(fromScreen: screenPoint), from: nil)
                guard self.bounds.contains(point) else { return event }
                // Wheel away from you (or two fingers up) zooms in, whatever the natural scrolling setting is.
                var delta = event.scrollingDeltaY
                if event.isDirectionInvertedFromDevice { delta = -delta }
                if delta == 0 { return nil }
                let factor = event.hasPreciseScrollingDeltas
                    ? exp(Double(delta) * 0.01)
                    : pow(1.15, Double(max(-4, min(4, delta))))
                self.onZoom?(point.x, factor)
                return nil
            }
        }

        func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}

// MARK: - Speed Up Typing Suggestion Chip & Popover

private struct SpeedUpTypingSuggestionChipView: View {
    @Bindable var session: ProjectSession
    let suggestion: ProjectSession.TypingSuggestionRange
    let width: CGFloat

    @Environment(\.isTooltipAndHoverBlocked) private var isTooltipAndHoverBlocked
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
                                .adaptive(dark: Color(red: 0.40, green: 0.27, blue: 0.04), light: Color(red: 0.80, green: 0.49, blue: 0.08)),
                                .adaptive(dark: Color(red: 0.56, green: 0.37, blue: 0.05), light: Color(red: 0.90, green: 0.60, blue: 0.17))
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
        .accessibilityLabel(Text("Speed up typing"))
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovered = hovering
            }
            if hovering && !isShowingPopover && !isTooltipAndHoverBlocked, let v = anchorNSView, let win = v.window {
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
                    .foregroundStyle(.ink.opacity(0.92))
                Text("Speed up typing")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.ink.opacity(0.96))
                Spacer()
                Text(String(format: "%.1f×", preferredSpeed))
                    .font(.system(size: 12.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(.ink.opacity(0.55))
            }

            // 2. Description
            Text("You are typing during this part of the recording. Speed it up using options below.")
                .font(.system(size: 12.5, weight: .regular))
                .foregroundStyle(.ink.opacity(0.46))
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
                .accessibilityLabel(Text("Speed"))
                .accessibilityValue(Text(verbatim: String(format: "%g×", preferredSpeed)))
                .tint(Color(red: 0.44, green: 0.34, blue: 0.98))
                .controlSize(.regular)

                Button {
                    withAnimation(.easeOut(duration: 0.14)) {
                        preferredSpeed = 3.0
                    }
                } label: {
                    Text("Reset")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(isModified ? .ink.opacity(0.95) : .ink.opacity(0.28))
                        .frame(width: 64, height: 30)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.ink.opacity(isModified ? 0.07 : 0.03))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Color.ink.opacity(isModified ? 0.14 : 0.06), lineWidth: 1)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
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
                                .fill(Color.ink.opacity(0.04))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Color.ink.opacity(0.10), lineWidth: 1)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
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
                        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.return, modifiers: [])
                }

                // 5. Remove suggestion
                Button(action: onRemove) {
                    Text("Remove suggestion")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.ink.opacity(0.90))
                        .frame(maxWidth: .infinity)
                        .frame(height: 34)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.ink.opacity(0.04))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Color.ink.opacity(0.10), lineWidth: 1)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(18)
        .frame(width: 356)
        .background(Color.surface(red: 0.07, green: 0.07, blue: 0.09))
    }
}

// MARK: - Keyboard Shortcut Timeline Segment

private struct ShortcutTimelineSegmentView: View {
    @Bindable var session: ProjectSession
    let cluster: ProjectSession.ShortcutPressCluster
    let trackIndex: Int
    let xOffset: CGFloat
    let width: CGFloat
    let height: CGFloat
    let totalWidth: CGFloat
    let trackTotalDurationMs: Double
    let startMs: Double
    let endMs: Double
    let isSelected: Bool
    /// Another shortcut is selected; drawn like the other tracks' items (`TimelineInteractiveSegmentView`).
    let isDimmedBySelection: Bool
    let isHidden: Bool
    @Environment(TimelineSnapController.self) private var snap

    private enum DragMode {
        case moveBody
        case resizeLeft
        case resizeRight
    }

    @State private var isHovered = false
    @State private var activeDragMode: DragMode?
    @State private var dragInitialStartMs: Double?
    @State private var dragInitialEndMs: Double?
    @State private var hasExceededClickSlop = false
    @State private var pressLocalX: CGFloat = 0.0
    @State private var verticalDragOffset: CGFloat = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let edgeHitWidth: CGFloat = 9.0
    /// Matches `TimelineInteractiveSegmentView.labelInset`.
    private let labelInset: CGFloat = 16.0

    var body: some View {
        let segWidth = max(12.0, width)
        let adaptiveEdgeHitWidth = min(edgeHitWidth, max(5.0, segWidth * 0.34))
        let showHandles = (isHovered || activeDragMode == .resizeLeft || activeDragMode == .resizeRight) && segWidth >= 10
        let handleBarWidth: CGFloat = segWidth < 24 ? 2.2 : 3.0
        let handleHorizontalInset: CGFloat = min(5.0, max(2.0, (segWidth - handleBarWidth * 2.0 - 3.0) * 0.5))
        let labelWidth = ceil((cluster.compactTimelineLabel as NSString).size(
            withAttributes: [.font: NSFont.systemFont(ofSize: 12.0, weight: .semibold)]
        ).width)
        let showsLabel = segWidth - labelInset * 2.0 >= labelWidth
        // Same rules as `TimelineInteractiveSegmentView`: `0.50` when hidden, `0.30` when another shortcut is selected.
        let bodyOpacity: Double = (isHidden ? 0.50 : 1.0) * (isDimmedBySelection ? 0.30 : 1.0)

        ZStack {
            // 1. The same shaded body as every other track, in the shortcut palette.
            EquatableView(
                content: SegmentBodyCanvas(
                    palette: .shortcut,
                    isSelected: isSelected,
                    isPlayed: session.playedTimelineItemIds.contains(cluster.id)
                )
            )
            .opacity(bodyOpacity)

            // 2. Outer 1px selection outline, as on the other tracks.
            if isSelected {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(SegmentShaderPalette.shortcut.selectedOuterOutline, lineWidth: 1.0)
                    .padding(-1.5)
                    .allowsHitTesting(false)
            }

            // 3. Centered Shortcut Label (`⌥ ⌃ Space`, `⌘ A`, `⌫`, `⌘ →`, `D`)
            if showsLabel {
                Text(cluster.compactTimelineLabel)
                    .font(.system(size: 12.0, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.96))
                    .lineLimit(1)
                    .fixedSize()
                    .opacity(bodyOpacity)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }

            // 5. Left & Right Resize Handles on Hover
            if showHandles {
                HStack(spacing: 0) {
                    Capsule()
                        .fill(Color.white.opacity(0.88))
                        .frame(width: handleBarWidth, height: max(8, height - 14))
                        .padding(.leading, handleHorizontalInset)
                    Spacer(minLength: 2)
                    Capsule()
                        .fill(Color.white.opacity(0.88))
                        .frame(width: handleBarWidth, height: max(8, height - 14))
                        .padding(.trailing, handleHorizontalInset)
                }
                .allowsHitTesting(false)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: showsLabel)
        .frame(width: segWidth, height: height)
        .overlay(
            RightClickDetectorView { pointInView, parentView in
                session.selectShortcut(cluster.id)
                NativeSegmentContextMenuPresenter.shared.presentShortcutContextMenu(
                    session: session,
                    cluster: cluster,
                    at: pointInView,
                    in: parentView
                )
            }
        )
        .contentShape(Rectangle().inset(by: -3.0))
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let pt):
                guard activeDragMode == nil && NSEvent.pressedMouseButtons == 0 else { return }
                let localX = (pt.x >= xOffset - 6 && pt.x <= xOffset + segWidth + 6) ? (pt.x - xOffset) : pt.x
                if !isHovered {
                    isHovered = true
                }
                if session.isSplitModeActive {
                    NSCursor.crosshair.set()
                } else if localX <= adaptiveEdgeHitWidth || localX >= segWidth - adaptiveEdgeHitWidth {
                    NSCursor.resizeLeftRight.set()
                } else {
                    NSCursor.arrow.set()
                }
            case .ended:
                guard activeDragMode == nil && NSEvent.pressedMouseButtons == 0 else { return }
                isHovered = false
                if session.isSplitModeActive {
                    NSCursor.crosshair.set()
                } else {
                    NSCursor.arrow.set()
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "Shortcut".localizedUI + ", " + cluster.compactTimelineLabel))
        .accessibilityValue(Text(verbatim: AccessibilityText.range(startMs: startMs, endMs: endMs)))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default) {
            session.isPlaying = false
            session.seek(toTimelineMs: (startMs + endMs) * 0.5)
            session.selectShortcut(cluster.id)
        }
        .offset(x: xOffset, y: verticalDragOffset)
        .zIndex(activeDragMode != nil ? 60 : (isSelected ? 40 : (isHovered ? 30 : 1)))
        .highPriorityGesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named("timelineContentSpace"))
                .onChanged { value in
                    if activeDragMode == nil {
                        let startInLane = value.startLocation.x - 20.0
                        let computedLocalX = startInLane - xOffset
                        let localX = min(max(0, computedLocalX), segWidth)

                        pressLocalX = localX
                        hasExceededClickSlop = false
                        dragInitialStartMs = startMs
                        dragInitialEndMs = endMs

                        if localX <= adaptiveEdgeHitWidth {
                            activeDragMode = .resizeLeft
                            NSCursor.resizeLeftRight.set()
                        } else if localX >= segWidth - adaptiveEdgeHitWidth {
                            activeDragMode = .resizeRight
                            NSCursor.resizeLeftRight.set()
                        } else {
                            activeDragMode = .moveBody
                        }
                    }

                    let dragDist = hypot(value.translation.width, value.translation.height)
                    if !hasExceededClickSlop {
                        guard dragDist >= 2.5 else { return }
                        hasExceededClickSlop = true
                        session.selectShortcut(cluster.id)
                        snap.begin(excludingItemId: cluster.id, pointsPerMs: Double(totalWidth) / max(1.0, trackTotalDurationMs))
                        session.beginInteractiveEdit()
                    }

                    guard let s0 = dragInitialStartMs,
                          let e0 = dragInitialEndMs,
                          let mode = activeDragMode else { return }

                    let deltaMs = Double(value.translation.width / max(1.0, totalWidth)) * trackTotalDurationMs

                    switch mode {
                    case .resizeLeft:
                        let newTimelineStart = max(0.0, min(e0 - 220.0, snap.snapEdge(s0 + deltaMs)))
                        let newSrcStart = session.timeMapper.sourceTime(forTimelineMs: newTimelineStart).sourceMs
                        let newSrcEnd = session.timeMapper.sourceTime(forTimelineMs: e0).sourceMs
                        session.resizeShortcut(cluster, newStartMs: newSrcStart, newEndMs: newSrcEnd)

                    case .resizeRight:
                        let newTimelineEnd = max(s0 + 220.0, min(trackTotalDurationMs, snap.snapEdge(e0 + deltaMs)))
                        let newSrcStart = session.timeMapper.sourceTime(forTimelineMs: s0).sourceMs
                        let newSrcEnd = session.timeMapper.sourceTime(forTimelineMs: newTimelineEnd).sourceMs
                        session.resizeShortcut(cluster, newStartMs: newSrcStart, newEndMs: newSrcEnd)

                    case .moveBody:
                        let dur = max(220.0, e0 - s0)
                        let snappedStart = snap.snapMove(startMs: s0 + deltaMs, durationMs: dur)
                        let clampedTimelineStart = max(0.0, min(trackTotalDurationMs - dur, snappedStart))
                        let clampedTimelineEnd = clampedTimelineStart + dur
                        let newSrcStart = session.timeMapper.sourceTime(forTimelineMs: clampedTimelineStart).sourceMs
                        let newSrcEnd = max(newSrcStart + 220.0, session.timeMapper.sourceTime(forTimelineMs: clampedTimelineEnd).sourceMs)
                        session.moveShortcut(cluster, desiredStartMs: newSrcStart, durationMs: newSrcEnd - newSrcStart)

                        if session.document.captions.shortcutTracks.count > 1 {
                            verticalDragOffset = value.translation.height
                        }
                    }
                }
                .onEnded { value in
                    let wasDrag = hasExceededClickSlop
                    let localX = pressLocalX

                    if wasDrag {
                        if activeDragMode == .moveBody && session.document.captions.shortcutTracks.count > 1 {
                            let rowDelta = Int(round(value.translation.height / 42.0))
                            verticalDragOffset = 0.0
                            if rowDelta != 0 {
                                session.moveShortcutToTrack(cluster, targetTrackIndex: trackIndex + rowDelta)
                            }
                        }
                        snap.end()
                        session.endInteractiveEdit()
                    } else {
                        // Single Left-Click selects the Shortcut Segment and opens the Shortcut Editor in the Inspector!
                        let frac = max(0.0, min(1.0, Double(localX / max(1.0, segWidth))))
                        let clickedTimelineMs = session.hoverSkimTimelineMs ?? (startMs + frac * (endMs - startMs))
                        session.isPlaying = false
                        session.seek(toTimelineMs: clickedTimelineMs)
                        session.selectShortcut(cluster.id)
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

// MARK: - Snap Guide

/// Vertical theme-colored line at the edge a dragged item snapped to. Its own view, so guide changes never
/// re-evaluate the tracks.
private struct TimelineSnapGuideOverlayView: View {
    let snap: TimelineSnapController
    let trackHorizontalInset: CGFloat
    let contentWidth: CGFloat
    let totalTimelineMs: Double
    let horizontalScrollOffset: CGFloat
    let viewportWidth: CGFloat
    let topInset: CGFloat

    var body: some View {
        if let guideMs = snap.guideTimelineMs {
            let x = trackHorizontalInset + CGFloat(guideMs / max(1.0, totalTimelineMs)) * contentWidth - horizontalScrollOffset
            if x >= -2 && x <= viewportWidth + 2 {
                Rectangle()
                    .fill(Color(red: 0.44, green: 0.30, blue: 1.0).opacity(0.9))
                    .frame(width: 1)
                    .padding(.top, topInset)
                    .offset(x: x - 0.5)
            }
        }
    }
}
