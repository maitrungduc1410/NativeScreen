import Foundation
import Observation

/// Segment snapping on the timeline. While an item is dragged or trimmed, its edges stick to nearby edges of items on
/// every other track, clip boundaries, the playhead and both ends of the timeline. See ADR-43 in `spec/06`.
@Observable
@MainActor
public final class TimelineSnapController {
    /// Edges within this many points of a target snap to it.
    public static let thresholdPoints: Double = 8.0

    /// Timeline time of the guide line drawn while an edge is snapped, `nil` otherwise.
    public private(set) var guideTimelineMs: Double?

    @ObservationIgnored private weak var session: ProjectSession?
    @ObservationIgnored private var targets: [Double] = []
    @ObservationIgnored private var thresholdMs: Double = 0

    public init() {}

    public func attach(_ session: ProjectSession) {
        self.session = session
    }

    /// Collects targets once per drag, so moving the dragged item never feeds back into its own targets.
    public func begin(excludingItemId itemId: String, pointsPerMs: Double) {
        guard EditorViewPreferences.shared.snapToSegments, let session, pointsPerMs > 0 else {
            targets = []
            thresholdMs = 0
            return
        }
        targets = session.snapTargetsTimelineMs(excludingItemId: itemId)
        thresholdMs = Self.thresholdPoints / pointsPerMs
    }

    /// Shifts a moved item so whichever of its edges is closer to a target lands on it.
    public func snapMove(startMs: Double, durationMs: Double) -> Double {
        let start = nearest(to: startMs)
        let end = nearest(to: startMs + durationMs)
        switch (start, end) {
        case let (s?, e?):
            if abs(s - startMs) <= abs(e - (startMs + durationMs)) {
                return show(s, result: s)
            }
            return show(e, result: e - durationMs)
        case let (s?, nil):
            return show(s, result: s)
        case let (nil, e?):
            return show(e, result: e - durationMs)
        default:
            guideTimelineMs = nil
            return startMs
        }
    }

    /// Snaps one trimmed edge.
    public func snapEdge(_ ms: Double) -> Double {
        guard let target = nearest(to: ms) else {
            guideTimelineMs = nil
            return ms
        }
        return show(target, result: target)
    }

    public func end() {
        targets = []
        guideTimelineMs = nil
    }

    private func show(_ guide: Double, result: Double) -> Double {
        if guideTimelineMs != guide { guideTimelineMs = guide }
        return result
    }

    private func nearest(to ms: Double) -> Double? {
        guard thresholdMs > 0 else { return nil }
        var best: Double?
        var bestDistance = thresholdMs
        for target in targets {
            let distance = abs(target - ms)
            if distance <= bestDistance {
                best = target
                bestDistance = distance
            }
        }
        return best
    }
}

extension ProjectSession {
    /// Timeline range covered by a source range, across every slice that shows part of it.
    public func timelineSpan(forSourceStartMs sourceStartMs: Double, sourceEndMs: Double) -> (Double, Double)? {
        var earliest: Double?
        var latest: Double?
        for mapped in timeMapper.mappedSlices {
            let overlapStart = max(sourceStartMs, mapped.slice.sourceStartMs)
            let overlapEnd = min(sourceEndMs, mapped.slice.sourceEndMs)
            guard overlapEnd > overlapStart else { continue }
            let speed = max(0.1, mapped.slice.speed)
            let t0 = mapped.timelineStartMs + (overlapStart - mapped.slice.sourceStartMs) / speed
            let t1 = mapped.timelineStartMs + (overlapEnd - mapped.slice.sourceStartMs) / speed
            earliest = min(earliest ?? t0, t0)
            latest = max(latest ?? t1, t1)
        }
        if let t0 = earliest, let t1 = latest, t1 > t0 { return (t0, t1) }
        return nil
    }

    /// Every edge an item can snap to, in timeline time, leaving out the item being dragged.
    public func snapTargetsTimelineMs(excludingItemId itemId: String) -> [Double] {
        var targets: [Double] = [0, timeMapper.totalTimelineDurationMs, playheadTimelineMs]
        for mapped in timeMapper.mappedSlices {
            targets.append(mapped.timelineStartMs)
            targets.append(mapped.timelineEndMs)
        }
        func add(_ id: String, _ start: Double, _ end: Double) {
            guard id != itemId, let (t0, t1) = timelineSpan(forSourceStartMs: start, sourceEndMs: end) else { return }
            targets.append(t0)
            targets.append(t1)
        }
        let timeline = document.timeline
        for zoom in timeline.zooms { add(zoom.id, zoom.sourceStartMs, zoom.sourceEndMs) }
        for track in timeline.maskTracks {
            for item in track.items { add(item.id, item.sourceStartMs, item.sourceEndMs) }
        }
        for layout in timeline.cameraLayouts { add(layout.id, layout.sourceStartMs, layout.sourceEndMs) }
        for voiceover in timeline.voiceovers {
            add(voiceover.id, voiceover.sourceStartMs, voiceover.sourceStartMs + voiceover.durationMs)
        }
        for block in document.captions.captionBlocks { add(block.id, block.sourceStartMs, block.sourceEndMs) }
        for cluster in detectedShortcutClusters { add(cluster.id, cluster.displayStartMs, cluster.displayEndMs) }
        return targets
    }
}
