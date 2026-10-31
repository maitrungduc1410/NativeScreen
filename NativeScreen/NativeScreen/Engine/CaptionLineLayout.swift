import Foundation

/// Shared caption line grouping + word reveal rules used by BOTH the live preview overlay and the export compositor,
/// so exported captions always match what the editor shows (`Line by line` / `Word by word`, `Line growth`, `Word animation`).
///
/// Grouping the transcript into lines is O(n log n) over every word, so the result is memoized on the segment array
/// (Swift `Array ==` short-circuits on shared storage, which makes the per-frame cache check O(1) while nothing is edited).
enum CaptionLineLayout {
    struct Line: Equatable {
        let startMs: Double
        let endMs: Double
        let words: [CaptionSegment]
    }

    struct DisplayedWord: Equatable {
        let segment: CaptionSegment
        let opacity: Double
        let isSpokenNow: Bool
    }

    private static var cachedSegments: [CaptionSegment] = []
    private static var cachedLines: [Line] = []

    static func lines(for segments: [CaptionSegment]) -> [Line] {
        if segments == cachedSegments {
            return cachedLines
        }
        let words = segments.filter { !$0.isHidden }.sorted { $0.sourceStartMs < $1.sourceStartMs }
        var lines: [Line] = []
        var bucket: [CaptionSegment] = []

        func flush() {
            guard let f = bucket.first, let l = bucket.last else { return }
            lines.append(Line(startMs: f.sourceStartMs, endMs: l.sourceEndMs, words: bucket))
            bucket.removeAll()
        }

        for w in words {
            if let prev = bucket.last {
                let gap = w.sourceStartMs - prev.sourceEndMs
                let isSentenceEnd = prev.text.hasSuffix(".") || prev.text.hasSuffix("?") || prev.text.hasSuffix("!")
                if gap >= 750.0 || isSentenceEnd || bucket.count >= 6 {
                    flush()
                }
            }
            bucket.append(w)
        }
        flush()

        cachedSegments = segments
        cachedLines = lines
        return lines
    }

    static func activeLine(in config: CaptionsConfig, at timeMs: Double) -> Line? {
        let all = lines(for: config.segments)
        // Binary search for the last line starting before `timeMs + 140ms`, then check its visibility window.
        var lo = 0
        var hi = all.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if all[mid].startMs - 140.0 <= timeMs {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        var idx = lo - 1
        while idx >= 0 {
            let line = all[idx]
            if timeMs <= line.endMs + 320.0 {
                return line
            }
            if line.endMs + 320.0 < timeMs - 10_000.0 {
                break
            }
            idx -= 1
        }
        return nil
    }

    static func displayedWords(for line: Line, config: CaptionsConfig, at timeMs: Double) -> [DisplayedWord] {
        guard !line.words.isEmpty else { return [] }
        let segments: [CaptionSegment] = {
            switch config.wordsReveal {
            case .wordByWord:
                if let current = line.words.last(where: { $0.sourceStartMs <= timeMs }) ?? line.words.first {
                    return [current]
                }
                return []
            case .lineByLine:
                switch config.lineGrowth {
                case .fullLine:
                    return line.words
                case .expanding, .centered:
                    let spoken = line.words.filter { $0.sourceStartMs <= timeMs + 40.0 }
                    return spoken.isEmpty ? [line.words[0]] : spoken
                }
            }
        }()

        return segments.map { word in
            let isSpokenNow = (timeMs >= word.sourceStartMs && timeMs <= word.sourceEndMs + 120.0)
            let isFutureWord = (timeMs < word.sourceStartMs)
            let opacity: Double = {
                switch config.wordAnimation {
                case .appear: return isFutureWord ? 0.0 : 1.0
                case .fadeIn: return isFutureWord ? 0.38 : 1.0
                case .slideIn: return isFutureWord ? 0.25 : 1.0
                }
            }()
            return DisplayedWord(segment: word, opacity: opacity, isSpokenNow: isSpokenNow)
        }
    }
}
