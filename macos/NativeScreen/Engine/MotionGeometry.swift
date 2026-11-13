import Foundation

/// Recording coordinates stay unchanged; only camera targets and drawn overlays enter crop space.
enum MotionGeometry {
    static func cropped(_ point: Point01, by crop: Rect01) -> Point01 {
        Point01(x: (point.x - crop.x) / max(0.0001, crop.width),
                y: (point.y - crop.y) / max(0.0001, crop.height))
    }
}

/// Size of the capture in points (logical pixels). Cursor tolerances, shake filtering and rotation use points, so a
/// Retina recording behaves like the same motion on a standard display.
public struct MotionPointSize: Equatable, Sendable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = max(1, width)
        self.height = max(1, height)
    }

    public init(_ target: CaptureTargetMetadata) {
        let scale = max(1, target.scaleFactor)
        let w = target.logicalBounds.width > 0 ? target.logicalBounds.width : Double(target.pixelSize.width) / scale
        let h = target.logicalBounds.height > 0 ? target.logicalBounds.height : Double(target.pixelSize.height) / scale
        self.init(width: w, height: h)
    }

    public static let reference = MotionPointSize(width: 1600, height: 900)

    func distance(_ a: Point01, _ b: Point01) -> Double {
        hypot((a.x - b.x) * width, (a.y - b.y) * height)
    }
}

/// Recorded cursor telemetry helpers.
enum CursorTelemetry {
    /// Linear position at `time`. With `holdPauses`, a gap over 48 ms holds until 16 ms before the next sample.
    static func sample(_ events: [CursorSampleEvent], at time: Double, holdPauses: Bool = true) -> CursorSampleEvent {
        guard let first = events.first else { return CursorSampleEvent(t: time, x: 0.5, y: 0.5, c: "arrow") }
        if time <= first.t { return first }
        var lo = 0, hi = events.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if events[mid].t <= time { lo = mid + 1 } else { hi = mid }
        }
        let a = events[lo - 1]
        guard lo < events.count else { return a }
        let b = events[lo]
        let start = holdPauses && b.t - a.t > 48 ? b.t - 16 : a.t
        let f = max(0, min(1, (time - start) / max(0.001, b.t - start)))
        return CursorSampleEvent(t: time, x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f, c: a.c)
    }

    /// Replaces samples at a click's time with the click's own position. The click log, not a decimated cursor sample,
    /// owns the tip at the interaction. A click further than `maxDistancePt` from the recorded cursor is not a refinement
    /// of it (synthetic or inconsistent data) and is left out, so the path never darts to it.
    static func insertingClicks(_ clicks: [ClickEvent], into events: [CursorSampleEvent], holdPauses: Bool,
                                pointSize: MotionPointSize, maxDistancePt: Double = 16) -> [CursorSampleEvent] {
        let anchors = clicks.filter { $0.type == "down" || $0.type == "up" }.sorted { $0.t < $1.t }
        guard !anchors.isEmpty else { return events }
        var result: [CursorSampleEvent] = []
        result.reserveCapacity(events.count + anchors.count)
        var i = 0
        for anchor in anchors {
            while i < events.count && events[i].t < anchor.t { result.append(events[i]); i += 1 }
            while i < events.count && events[i].t == anchor.t { i += 1 }
            let recorded = sample(events, at: anchor.t, holdPauses: holdPauses)
            // Interpolating across a cursor warp can land far from both samples, so the bracketing samples count too.
            let click = Point01(x: anchor.x, y: anchor.y)
            let candidates = [recorded] + (i > 0 ? [events[i - 1]] : []) + (i < events.count ? [events[i]] : [])
            let near = events.isEmpty || candidates.contains { pointSize.distance(Point01(x: $0.x, y: $0.y), click) <= maxDistancePt }
            result.append(near ? CursorSampleEvent(t: anchor.t, x: anchor.x, y: anchor.y, c: recorded.c) : recorded)
        }
        result.append(contentsOf: events[i...])
        return result
    }

    /// Button-held intervals. `held` marks a button already down when a trimmed run starts.
    static func heldIntervals(_ clicks: [ClickEvent], endMs: Double) -> [(start: Double, end: Double)] {
        var down: [String: Double] = [:]
        var intervals: [(start: Double, end: Double)] = []
        for click in clicks.sorted(by: { $0.t < $1.t }) {
            let button = click.button ?? "left"
            if click.type == "down" || click.type == "held" {
                down[button] = down[button] ?? click.t
            } else if click.type == "up", let start = down.removeValue(forKey: button) {
                intervals.append((start, click.t))
            }
        }
        for start in down.values { intervals.append((start, max(start, endMs))) }
        var merged: [(start: Double, end: Double)] = []
        for interval in intervals.sorted(by: { $0.start < $1.start }) {
            if let last = merged.last, interval.start <= last.end {
                merged[merged.count - 1].end = max(last.end, interval.end)
            } else { merged.append(interval) }
        }
        return merged
    }
}

/// Recordings made before telemetry was anchored to the first video frame (2026-10-26) started their clock when
/// telemetry started, before capture. Every event is late by the startup delay. The recorder now always writes a
/// sample at exactly `t = 0`; older ones only wrote on movement.
enum LegacyTelemetryEpoch {
    /// The startup delay in ms, or 0 for current recordings. Telemetry and capture stopped together, so the delay is
    /// how far the last event runs past the video. It cannot exceed the first cursor sample (made after capture began).
    static func offsetMs(cursor: [CursorSampleEvent], clicks: [ClickEvent], keys: [KeyStrokeEvent], durationMs: Double) -> Double {
        guard let first = cursor.first?.t, first > 0.5 else { return 0 }
        let last = max(cursor.last?.t ?? 0, clicks.last?.t ?? 0, keys.last?.t ?? 0)
        let offset = min(first, max(0, last - durationMs))
        return offset >= 20 ? offset : 0
    }

    /// Moves events onto the video clock. Events from before capture began are dropped; the cursor keeps its last
    /// position from then as the sample at `t = 0`.
    static func corrected(cursor: [CursorSampleEvent], clicks: [ClickEvent], keys: [KeyStrokeEvent], offsetMs: Double)
        -> (cursor: [CursorSampleEvent], clicks: [ClickEvent], keys: [KeyStrokeEvent]) {
        guard offsetMs > 0 else { return (cursor, clicks, keys) }
        var shiftedCursor: [CursorSampleEvent] = []
        shiftedCursor.reserveCapacity(cursor.count)
        var before: CursorSampleEvent?
        for var e in cursor {
            e.t -= offsetMs
            if e.t < 0 { before = e; continue }
            if shiftedCursor.isEmpty, e.t > 0, var start = before { start.t = 0; shiftedCursor.append(start) }
            shiftedCursor.append(e)
        }
        if shiftedCursor.isEmpty, var start = before { start.t = 0; shiftedCursor.append(start) }
        let shiftedClicks = clicks.compactMap { c -> ClickEvent? in var c = c; c.t -= offsetMs; return c.t >= 0 ? c : nil }
        let shiftedKeys = keys.compactMap { k -> KeyStrokeEvent? in var k = k; k.t -= offsetMs; return k.t >= 0 ? k : nil }
        return (shiftedCursor, shiftedClicks, shiftedKeys)
    }
}
