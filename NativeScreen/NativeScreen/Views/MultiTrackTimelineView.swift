import SwiftUI

/// High-performance Multi-Track Non-Linear Editing Timeline with:
/// - Clip Slice Track (Split `⌘B`, Trim, Speed)
/// - Auto-Zoom Track (Add, Move, Resize, Toggle)
/// - Unlimited Parallel Blur & Spotlight Mask Tracks (Solving the single-track limitation)
public struct MultiTrackTimelineView: View {
    @Bindable var session: ProjectSession
    @State private var timelineZoom: Double = 1.0

    public var body: some View {
        VStack(spacing: 0) {
            // Timeline Action Bar
            HStack(spacing: 12) {
                Button {
                    session.splitSliceAtPlayhead()
                } label: {
                    Label("Split Clip", systemImage: "scissors")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .keyboardShortcut("b", modifiers: [.command])

                Button {
                    session.addZoomAtPlayhead()
                } label: {
                    Label("Add Zoom", systemImage: "plus.magnifyingglass")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    session.addMaskAtPlayhead(type: .blur, style: .gaussian)
                } label: {
                    Label("Add Blur Mask", systemImage: "eye.slash.fill")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.teal)

                Button {
                    session.addEmptyMaskTrack()
                } label: {
                    Label("+ Mask Track", systemImage: "rectangle.stack.badge.plus")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Spacer()

                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Slider(value: $timelineZoom, in: 1.0...4.0)
                        .frame(width: 90)
                        .controlSize(.mini)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            // Scrollable Multi-Track Area
            GeometryReader { outerGeo in
                let labelColumnWidth: CGFloat = 118
                let baseTrackWidth = max(320, outerGeo.size.width - labelColumnWidth - 28)
                let contentWidth = baseTrackWidth * CGFloat(timelineZoom)
                let totalTimelineMs = max(1000.0, session.timeMapper.totalTimelineDurationMs)
                let sourceDurationMs = max(1000.0, session.metadata.durationMs)

                ScrollView([.horizontal, .vertical], showsIndicators: true) {
                    ZStack(alignment: .topLeading) {
                        VStack(alignment: .leading, spacing: 6) {
                            // 1. Time Ruler Row
                            HStack(spacing: 0) {
                                Text("Timecode")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: labelColumnWidth, alignment: .leading)

                                TimeRulerTrackView(
                                    totalDurationMs: totalTimelineMs,
                                    width: contentWidth
                                ) { clickedMs in
                                    session.seek(toTimelineMs: clickedMs)
                                }
                            }
                            .frame(height: 22)

                            // 2. Video Clip Slices Track (Orange)
                            HStack(spacing: 0) {
                                Label("Screen Clips", systemImage: "film")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .frame(width: labelColumnWidth, alignment: .leading)

                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(Color.primary.opacity(0.05))

                                    ForEach(session.timeMapper.mappedSlices, id: \.slice.id) { mapped in
                                        let xStart = CGFloat(mapped.timelineStartMs / totalTimelineMs) * contentWidth
                                        let blockW = max(12.0, CGFloat((mapped.timelineEndMs - mapped.timelineStartMs) / totalTimelineMs) * contentWidth)
                                        let isSelected = (session.selectedSliceId == mapped.slice.id)

                                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                                            .fill(
                                                LinearGradient(
                                                    colors: [Color.orange.opacity(0.88), Color.orange.opacity(0.68)],
                                                    startPoint: .top,
                                                    endPoint: .bottom
                                                )
                                            )
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                                    .strokeBorder(isSelected ? Color.white : Color.white.opacity(0.25), lineWidth: isSelected ? 2 : 1)
                                            )
                                            .overlay(alignment: .leading) {
                                                HStack(spacing: 4) {
                                                    Text("Clip")
                                                        .font(.system(size: 10, weight: .bold))
                                                    if abs(mapped.slice.speed - 1.0) > 0.05 {
                                                        Text(String(format: "%.1fx", mapped.slice.speed))
                                                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                                            .padding(.horizontal, 4)
                                                            .background(.black.opacity(0.3), in: Capsule())
                                                    }
                                                }
                                                .foregroundStyle(.white)
                                                .padding(.leading, 8)
                                            }
                                            .frame(width: max(4, blockW - 2), height: 32)
                                            .offset(x: xStart + 1)
                                            .onTapGesture {
                                                session.selectedSliceId = mapped.slice.id
                                            }
                                    }
                                }
                                .frame(width: contentWidth, height: 34)
                            }

                            // 3. Auto-Zoom Track (Indigo / Purple)
                            HStack(spacing: 0) {
                                Label("Zoom", systemImage: "plus.magnifyingglass")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .frame(width: labelColumnWidth, alignment: .leading)

                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(Color.primary.opacity(0.05))

                                    ForEach(session.document.timeline.zooms) { zoom in
                                        let xStart = CGFloat(zoom.sourceStartMs / sourceDurationMs) * contentWidth
                                        let blockW = max(18.0, CGFloat((zoom.sourceEndMs - zoom.sourceStartMs) / sourceDurationMs) * contentWidth)
                                        let isSelected = (session.selectedZoomId == zoom.id)

                                        TimelineResizableBlockView(
                                            title: String(format: "🔍 %.1fx %@", zoom.scale, zoom.mode == .followCursor ? "Auto" : "Manual"),
                                            color: zoom.disabled ? .gray : .indigo,
                                            isSelected: isSelected,
                                            xOffset: xStart,
                                            width: blockW,
                                            totalWidth: contentWidth,
                                            totalDurationMs: sourceDurationMs,
                                            startMs: zoom.sourceStartMs,
                                            endMs: zoom.sourceEndMs,
                                            onSelect: {
                                                session.selectedZoomId = zoom.id
                                                session.selectedInspectorTab = .zoom
                                            },
                                            onChangeRange: { newStart, newEnd in
                                                session.mutate { doc in
                                                    if let idx = doc.timeline.zooms.firstIndex(where: { $0.id == zoom.id }) {
                                                        doc.timeline.zooms[idx].sourceStartMs = newStart
                                                        doc.timeline.zooms[idx].sourceEndMs = newEnd
                                                    }
                                                }
                                            }
                                        )
                                    }
                                }
                                .frame(width: contentWidth, height: 30)
                            }

                            // 4. Unlimited Parallel Mask / Blur Tracks (Teal)
                            ForEach(session.document.timeline.maskTracks) { track in
                                HStack(spacing: 0) {
                                    Label(track.name, systemImage: "eye.slash")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .frame(width: labelColumnWidth, alignment: .leading)

                                    ZStack(alignment: .leading) {
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(Color.primary.opacity(0.05))

                                        ForEach(track.items) { item in
                                            let xStart = CGFloat(item.sourceStartMs / sourceDurationMs) * contentWidth
                                            let blockW = max(18.0, CGFloat((item.sourceEndMs - item.sourceStartMs) / sourceDurationMs) * contentWidth)
                                            let isSelected = (session.selectedMaskId == item.id)

                                            TimelineResizableBlockView(
                                                title: "\(item.style.rawValue.capitalized) (\(Int(item.intensity)))",
                                                color: item.disabled ? .gray : .teal,
                                                isSelected: isSelected,
                                                xOffset: xStart,
                                                width: blockW,
                                                totalWidth: contentWidth,
                                                totalDurationMs: sourceDurationMs,
                                                startMs: item.sourceStartMs,
                                                endMs: item.sourceEndMs,
                                                onSelect: {
                                                    session.selectedMaskId = item.id
                                                    session.selectedInspectorTab = .masks
                                                },
                                                onChangeRange: { newStart, newEnd in
                                                    session.mutate { doc in
                                                        for tIdx in doc.timeline.maskTracks.indices {
                                                            if let mIdx = doc.timeline.maskTracks[tIdx].items.firstIndex(where: { $0.id == item.id }) {
                                                                doc.timeline.maskTracks[tIdx].items[mIdx].sourceStartMs = newStart
                                                                doc.timeline.maskTracks[tIdx].items[mIdx].sourceEndMs = newEnd
                                                            }
                                                        }
                                                    }
                                                }
                                            )
                                        }
                                    }
                                    .frame(width: contentWidth, height: 28)
                                }
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)

                        // Vertical Red Playhead Line + Scrub Handle
                        let playheadX = 14 + labelColumnWidth + CGFloat(session.playheadTimelineMs / totalTimelineMs) * contentWidth
                        VStack(spacing: 0) {
                            Capsule()
                                .fill(Color.red)
                                .frame(width: 10, height: 10)
                            Rectangle()
                                .fill(Color.red)
                                .frame(width: 2)
                        }
                        .frame(height: CGFloat(115 + session.document.timeline.maskTracks.count * 34))
                        .offset(x: playheadX - 5)
                        .allowsHitTesting(false)
                    }
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let localX = value.location.x - 14 - labelColumnWidth
                                let fraction = max(0.0, min(1.0, Double(localX / max(1.0, contentWidth))))
                                session.isPlaying = false
                                session.seek(toTimelineMs: fraction * totalTimelineMs)
                            }
                    )
                }
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}

// MARK: - Time Ruler & Resizable Timeline Block Subviews

private struct TimeRulerTrackView: View {
    let totalDurationMs: Double
    let width: CGFloat
    let onSeek: (Double) -> Void

    var body: some View {
        Canvas { context, size in
            let tickCount = max(5, Int(size.width / 80))
            for i in 0...tickCount {
                let frac = CGFloat(i) / CGFloat(tickCount)
                let x = frac * size.width
                let sec = (Double(frac) * totalDurationMs) / 1000.0

                var path = Path()
                path.move(to: CGPoint(x: x, y: size.height - 6))
                path.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(path, with: .color(.secondary.opacity(0.6)), lineWidth: 1)

                let label = Text(String(format: "%d:%02d", Int(sec) / 60, Int(sec) % 60))
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
                context.draw(label, at: CGPoint(x: min(size.width - 18, max(16, x)), y: 7))
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

private struct TimelineResizableBlockView: View {
    let title: String
    let color: Color
    let isSelected: Bool
    let xOffset: CGFloat
    let width: CGFloat
    let totalWidth: CGFloat
    let totalDurationMs: Double
    let startMs: Double
    let endMs: Double
    let onSelect: () -> Void
    let onChangeRange: (Double, Double) -> Void

    @State private var dragStartMs: Double?
    @State private var dragEndMs: Double?

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(color.opacity(0.82))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(isSelected ? Color.white : Color.white.opacity(0.28), lineWidth: isSelected ? 2 : 1)
                )

            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 8)
        }
        .frame(width: width, height: 26)
        .offset(x: xOffset)
        .onTapGesture {
            onSelect()
        }
        .gesture(
            DragGesture()
                .onChanged { value in
                    onSelect()
                    if dragStartMs == nil {
                        dragStartMs = startMs
                        dragEndMs = endMs
                    }
                    guard let s0 = dragStartMs, let e0 = dragEndMs else { return }
                    let deltaMs = Double(value.translation.width / max(1.0, totalWidth)) * totalDurationMs
                    let span = e0 - s0
                    let clampedStart = max(0.0, min(totalDurationMs - span, s0 + deltaMs))
                    onChangeRange(clampedStart, clampedStart + span)
                }
                .onEnded { _ in
                    dragStartMs = nil
                    dragEndMs = nil
                }
        )
    }
}
