import Foundation

/// Voiceover track rules: segments on one track never overlap, and tracks stay numbered 0..<count with no empty track.
/// Overlapping voiceovers are allowed, on different tracks, and are mixed together on playback and export.
public extension Array where Element == VoiceoverSegment {
    var voiceoverTrackCount: Int {
        (map(\.trackIndex).max() ?? -1) + 1
    }

    func isVoiceoverRangeFree(trackIndex: Int, startMs: Double, endMs: Double, ignoringId: String? = nil) -> Bool {
        !contains { segment in
            segment.id != ignoringId
                && segment.trackIndex == trackIndex
                && segment.sourceStartMs < endMs
                && startMs < segment.sourceEndMs
        }
    }

    /// The first track that has room for the range, or a new track after the last one.
    func firstFreeVoiceoverTrack(startMs: Double, endMs: Double) -> Int {
        let count = voiceoverTrackCount
        return (0..<count).first { isVoiceoverRangeFree(trackIndex: $0, startMs: startMs, endMs: endMs) } ?? count
    }

    /// The first track with nothing after `startMs`, so a recording of any length that starts there will fit.
    func firstVoiceoverTrackEmpty(after startMs: Double) -> Int {
        let count = voiceoverTrackCount
        return (0..<count).first { track in
            !contains { $0.trackIndex == track && $0.sourceEndMs > startMs }
        } ?? count
    }

    /// Sorted by start time, with overlaps moved to a free track. Segments that already fit keep their track, so the
    /// result is stable. Projects saved before tracks existed all load as track 0.
    fileprivate func resolvingVoiceoverOverlaps() -> [VoiceoverSegment] {
        var placed: [VoiceoverSegment] = []
        placed.reserveCapacity(count)
        for var segment in sorted(by: { $0.sourceStartMs < $1.sourceStartMs }) {
            if !placed.isVoiceoverRangeFree(
                trackIndex: segment.trackIndex,
                startMs: segment.sourceStartMs,
                endMs: segment.sourceEndMs
            ) {
                segment.trackIndex = placed.firstFreeVoiceoverTrack(
                    startMs: segment.sourceStartMs,
                    endMs: segment.sourceEndMs
                )
            }
            placed.append(segment)
        }
        return placed
    }
}

public extension TimelineConfig {
    /// Applies the track rules and closes up empty tracks, keeping each remaining track's hidden state.
    /// Projects saved with the single hide flag load with every track hidden.
    mutating func normalizeVoiceoverTracks() {
        let placed = voiceovers.resolvingVoiceoverOverlaps()
        let usedTracks = Set(placed.map(\.trackIndex)).sorted()
        if isVoiceoversTrackHidden {
            hiddenVoiceoverTracks = usedTracks
            isVoiceoversTrackHidden = false
        }
        hiddenVoiceoverTracks = hiddenVoiceoverTracks.compactMap { usedTracks.firstIndex(of: $0) }
        voiceovers = placed.map { segment in
            var compacted = segment
            compacted.trackIndex = usedTracks.firstIndex(of: segment.trackIndex) ?? 0
            return compacted
        }
    }

    func isVoiceoverTrackHidden(_ trackIndex: Int) -> Bool {
        hiddenVoiceoverTracks.contains(trackIndex)
    }

    mutating func setVoiceoverTrack(_ trackIndex: Int, hidden: Bool) {
        hiddenVoiceoverTracks.removeAll { $0 == trackIndex }
        if hidden {
            hiddenVoiceoverTracks.append(trackIndex)
        }
    }
}
