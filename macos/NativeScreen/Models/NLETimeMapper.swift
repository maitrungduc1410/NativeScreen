import Foundation

/// Bidirectional mapper between edited Timeline Time (`timelineMs`) and immutable Source Recording Time (`sourceMs`).
public struct NLETimeMapper: Sendable {
    public struct MappedSlice: Sendable {
        public let slice: ClipSlice
        public let timelineStartMs: Double
        public let timelineEndMs: Double
    }

    public let mappedSlices: [MappedSlice]
    public let totalTimelineDurationMs: Double

    public init(slices: [ClipSlice]) {
        var currentTimelineMs = 0.0
        var built: [MappedSlice] = []
        built.reserveCapacity(slices.count)

        for slice in slices {
            let duration = slice.timelineDurationMs
            guard duration > 0.0 else { continue }
            let endMs = currentTimelineMs + duration
            built.append(
                MappedSlice(
                    slice: slice,
                    timelineStartMs: currentTimelineMs,
                    timelineEndMs: endMs
                )
            )
            currentTimelineMs = endMs
        }

        self.mappedSlices = built
        self.totalTimelineDurationMs = max(1.0, currentTimelineMs)
    }

    /// Maps a timeline playhead position (`timelineMs`) to the corresponding source video timestamp (`sourceMs`) and active slice.
    public func sourceTime(forTimelineMs timelineMs: Double) -> (sourceMs: Double, slice: ClipSlice?) {
        guard !mappedSlices.isEmpty else {
            return (max(0.0, timelineMs), nil)
        }

        let clamped = max(0.0, min(totalTimelineDurationMs, timelineMs))
        for item in mappedSlices {
            if clamped >= item.timelineStartMs && clamped <= item.timelineEndMs {
                let offsetInTimeline = clamped - item.timelineStartMs
                let sourceMs = item.slice.sourceStartMs + offsetInTimeline * item.slice.speed
                return (min(item.slice.sourceEndMs, sourceMs), item.slice)
            }
        }

        if let last = mappedSlices.last {
            return (last.slice.sourceEndMs, last.slice)
        }
        return (0.0, nil)
    }

    /// Maps `sourceMs` to timeline time, but only inside the slice that contains `referenceTimelineMs`
    /// (used to follow the decoder clock during playback without jumping to another slice that reuses the same source range).
    public func timelineTime(forSourceMs sourceMs: Double, withinSliceAtTimelineMs referenceTimelineMs: Double) -> Double? {
        guard let item = mappedSlices.first(where: { referenceTimelineMs >= $0.timelineStartMs && referenceTimelineMs < $0.timelineEndMs }),
              sourceMs >= item.slice.sourceStartMs && sourceMs <= item.slice.sourceEndMs else {
            return nil
        }
        return item.timelineStartMs + (sourceMs - item.slice.sourceStartMs) / max(0.1, item.slice.speed)
    }

    /// Maps a source video timestamp (`sourceMs`) to the first matching timeline timestamp (`timelineMs`).
    public func timelineTime(forSourceMs sourceMs: Double) -> Double? {
        for item in mappedSlices {
            if sourceMs >= item.slice.sourceStartMs && sourceMs <= item.slice.sourceEndMs {
                let sourceOffset = sourceMs - item.slice.sourceStartMs
                return item.timelineStartMs + (sourceOffset / max(0.1, item.slice.speed))
            }
        }
        return nil
    }
}
