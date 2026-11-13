import Foundation

/// Springs run on edited time. Source-contiguous slices share history, real cuts start a fresh trajectory.
public struct PlaybackTrajectorySolver: Sendable {
    private struct Run: Sendable {
        let start: Double
        let end: Double
        let solver: SpringTrajectorySolver
    }
    private let mapper: NLETimeMapper
    private let runs: [Run]

    public init(durationMs: Double, cursorEvents: [CursorSampleEvent], clickEvents: [ClickEvent],
                document: ProjectDocument, pointSize: MotionPointSize,
                reusingCursorFrom previous: PlaybackTrajectorySolver? = nil) {
        let validSlices = document.timeline.slices.filter { $0.timelineDurationMs > 0 && $0.timelineDurationMs.isFinite }
        let slices = validSlices.isEmpty
            ? [ClipSlice(sourceStartMs: 0, sourceEndMs: max(1, durationMs))] : validSlices
        mapper = NLETimeMapper(slices: slices)
        // Expand recording-time pause holds before stretching time. Slow 60 Hz footage is still continuous motion.
        var expandedCursor: [CursorSampleEvent] = []
        expandedCursor.reserveCapacity(cursorEvents.count)
        for (index, event) in cursorEvents.enumerated() {
            if index > 0 {
                let previous = cursorEvents[index - 1]
                if event.t - previous.t > 48 {
                    expandedCursor.append(CursorSampleEvent(t: event.t - 16, x: previous.x, y: previous.y, c: previous.c))
                }
            }
            expandedCursor.append(event)
        }
        let cursorEvents = expandedCursor
        let firstRetainedCursor = CursorTelemetry.sample(cursorEvents, at: mapper.mappedSlices[0].slice.sourceStartMs, holdPauses: false)
        var groups: [[NLETimeMapper.MappedSlice]] = []
        for item in mapper.mappedSlices {
            if let last = groups.last?.last,
               abs(last.slice.sourceEndMs - item.slice.sourceStartMs) < 0.001 {
                groups[groups.count - 1].append(item)
            } else { groups.append([item]) }
        }
        var built: [Run] = []
        for (index, group) in groups.enumerated() {
            let start = group[0].timelineStartMs
            let end = group[group.count - 1].timelineEndMs
            var projectedCursor: [CursorSampleEvent] = []
            var projectedClicks: [ClickEvent] = []
            var projectedZooms: [ZoomBlock] = []
            // A retained run may begin while a button is held. Do not inherit its old spring state or ripple.
            var heldButtons: [String: ClickEvent] = [:]
            for click in clickEvents where click.t < group[0].slice.sourceStartMs {
                let button = click.button ?? "left"
                if click.type == "down" { heldButtons[button] = click }
                else if click.type == "up" { heldButtons.removeValue(forKey: button) }
            }
            for click in heldButtons.values {
                let position = CursorTelemetry.sample(cursorEvents, at: group[0].slice.sourceStartMs, holdPauses: false)
                projectedClicks.append(ClickEvent(t: 0, type: "held", button: click.button, x: position.x, y: position.y))
            }
            for (itemIndex, item) in group.enumerated() {
                let slice = item.slice
                func time(_ source: Double) -> Double {
                    item.timelineStartMs - start + (source - slice.sourceStartMs) / max(0.1, slice.speed)
                }
                var boundary = CursorTelemetry.sample(cursorEvents, at: slice.sourceStartMs, holdPauses: false)
                boundary.t = time(slice.sourceStartMs)
                projectedCursor.append(boundary)
                // Only project retained telemetry. Lookahead can never see discarded footage.
                var lo = 0, hi = cursorEvents.count
                while lo < hi {
                    let mid = (lo + hi) / 2
                    if cursorEvents[mid].t <= slice.sourceStartMs { lo = mid + 1 } else { hi = mid }
                }
                for event in cursorEvents[lo...] {
                    if event.t >= slice.sourceEndMs { break }
                    var projected = event
                    projected.t = time(event.t)
                    projectedCursor.append(projected)
                }
                boundary = CursorTelemetry.sample(cursorEvents, at: slice.sourceEndMs, holdPauses: false)
                boundary.t = time(slice.sourceEndMs)
                projectedCursor.append(boundary)
                for click in clickEvents where click.t >= slice.sourceStartMs
                    && (click.t < slice.sourceEndMs || (itemIndex == group.count - 1 && click.t == slice.sourceEndMs)) {
                    var projected = click
                    projected.t = time(click.t)
                    projectedClicks.append(projected)
                }
                for zoom in document.timeline.zooms {
                    let a = max(zoom.sourceStartMs, slice.sourceStartMs)
                    let b = min(zoom.sourceEndMs, slice.sourceEndMs)
                    guard b > a else { continue }
                    var projected = zoom
                    projected.sourceStartMs = time(a)
                    projected.sourceEndMs = time(b)
                    if let last = projectedZooms.last, last.id == projected.id,
                       abs(last.sourceEndMs - projected.sourceStartMs) < 0.001 {
                        projectedZooms[projectedZooms.count - 1].sourceEndMs = projected.sourceEndMs
                    } else { projectedZooms.append(projected) }
                }
            }
            projectedCursor.sort { $0.t < $1.t }
            projectedClicks.sort { $0.t < $1.t }
            var projectedDoc = document
            projectedDoc.timeline.zooms = projectedZooms.sorted { $0.sourceStartMs < $1.sourceStartMs }
            // Ending options belong to the edited movie, not to each cut.
            if index != groups.count - 1 {
                projectedDoc.cursor.stopMovementInLastPartMs = 0
                projectedDoc.cursor.loopBackToStartMs = nil
            }
            let reusable = previous.flatMap { old -> SpringTrajectorySolver? in
                guard index < old.runs.count, old.runs[index].start == start, old.runs[index].end == end else { return nil }
                return old.runs[index].solver
            }
            built.append(Run(start: start, end: end, solver: SpringTrajectorySolver(
                durationMs: end - start, cursorEvents: projectedCursor, clickEvents: projectedClicks,
                document: projectedDoc, pointSize: pointSize, reusingCursorStates: reusable?.cursorStates,
                reusingPlannedCursor: reusable?.plannedCursor,
                startsAtCut: index > 0 || group[0].slice.sourceStartMs > 0,
                loopTarget01: Point01(x: firstRetainedCursor.x, y: firstRetainedCursor.y),
                telemetryUsesPlaybackTime: true
            )))
        }
        runs = built
    }

    public func evaluate(atTimelineMs time: Double) -> (cursor: SpringTrajectorySolver.CursorFrameState, camera: SpringTrajectorySolver.CameraFrameState) {
        precondition(!runs.isEmpty)
        let t = max(0, min(mapper.totalTimelineDurationMs, time))
        var lo = 0, hi = runs.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if runs[mid].start <= t { lo = mid + 1 } else { hi = mid }
        }
        let run = runs[max(0, lo - 1)]
        return run.solver.evaluate(atSourceMs: t - run.start)
    }

    /// Source-only callers choose the first occurrence. Rendering must pass edited time for reused source ranges.
    public func evaluate(atSourceMs time: Double) -> (cursor: SpringTrajectorySolver.CursorFrameState, camera: SpringTrajectorySolver.CameraFrameState) {
        evaluate(atTimelineMs: mapper.timelineTime(forSourceMs: time) ?? 0)
    }

    public func isSameRun(_ a: Double, _ b: Double) -> Bool {
        runs.contains { a >= $0.start && a < $0.end && b >= $0.start && b < $0.end }
    }
}
