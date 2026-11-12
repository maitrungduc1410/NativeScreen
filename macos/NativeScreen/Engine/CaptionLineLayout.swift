import Foundation
import AppKit

/// Caption timing and animation shared by the preview and the export: both draw the frames returned by `frames(in:at:stageSize:)`.
///
/// Every animated value follows a stiff, clamped spring toward a target that only depends on the time. The state at any time is
/// found by simulating the last moments on a fixed grid, so a frame looks the same when playing, scrubbing or exporting.
enum CaptionLineLayout {
    struct Word: Equatable {
        let text: String
        let startMs: Double
        let endMs: Double
    }

    struct Line: Equatable {
        let blockId: String
        let startMs: Double
        let endMs: Double
        let words: [Word]
        let style: CaptionStyle
        /// When the line starts fading out: `exitLeadMs` before its end, so nothing is left once the playhead leaves
        /// the block. A line followed right away by the next one keeps its end (the box moves on instead).
        var fadeOutStartMs: Double

        init(blockId: String, startMs: Double, endMs: Double, words: [Word], style: CaptionStyle) {
            self.blockId = blockId
            self.startMs = startMs
            self.endMs = endMs
            self.words = words
            self.style = style
            self.fadeOutStartMs = endMs
        }
    }

    /// Longer than the springs take to fade from 1 to 0 (about 108 ms), so a line is gone on its block's end.
    private static let exitLeadMs = 150.0

    struct DrawnWord: Equatable {
        let text: String
        /// Top-left origin, in stage units.
        let rect: CGRect
        let opacity: Double
        let isSpokenNow: Bool
        /// A dimmed `Fade in` word is at rest, so it must not pick up the fade-out blur.
        let isDimmedAtRest: Bool
    }

    struct TrackFrame: Equatable {
        let blockId: String
        let style: CaptionStyle
        let fontSize: CGFloat
        /// The line's box including its padding. Top-left origin, in stage units.
        let boxRect: CGRect
        let boxOpacity: Double
        let words: [DrawnWord]
    }

    // MARK: Grouping

    /// Splits a transcript into lines at sentence ends, long pauses and every 6 words.
    static func groupWordsIntoLines(_ segments: [CaptionSegment]) -> [[CaptionSegment]] {
        let words = segments.sorted { $0.sourceStartMs < $1.sourceStartMs }
        var lines: [[CaptionSegment]] = []
        var bucket: [CaptionSegment] = []
        for word in words {
            if let prev = bucket.last {
                let gap = word.sourceStartMs - prev.sourceEndMs
                let isSentenceEnd = prev.text.hasSuffix(".") || prev.text.hasSuffix("?") || prev.text.hasSuffix("!")
                if gap >= 750.0 || isSentenceEnd || bucket.count >= 6 {
                    lines.append(bucket)
                    bucket.removeAll()
                }
            }
            bucket.append(word)
        }
        if !bucket.isEmpty {
            lines.append(bucket)
        }
        return lines
    }

    /// The caption's text as shown on the timeline and in the inspector.
    static func displayText(of block: CaptionBlock, in config: CaptionsConfig) -> String {
        if let custom = block.customText { return custom }
        let byId = Dictionary(uniqueKeysWithValues: config.segments.map { ($0.id, $0) })
        return block.wordIds.compactMap { byId[$0] }.filter { !$0.isHidden }.map(\.text).joined(separator: " ")
    }

    private static func makeLine(
        block: CaptionBlock,
        style: CaptionStyle,
        wordsById: [String: CaptionSegment]
    ) -> Line? {
        let duration = max(1.0, block.sourceEndMs - block.sourceStartMs)
        var words: [Word] = []

        if let custom = block.customText {
            // No spoken timing: each word gets time in proportion to its length.
            let parts = custom.split(whereSeparator: \.isWhitespace).map(String.init)
            let total = max(1, parts.reduce(0) { $0 + $1.count + 1 })
            var cursor = block.sourceStartMs
            for part in parts {
                let span = duration * Double(part.count + 1) / Double(total)
                words.append(Word(text: part, startMs: cursor, endMs: cursor + span))
                cursor += span
            }
        } else {
            let spoken = block.wordIds.compactMap { wordsById[$0] }
            guard let first = spoken.first, let last = spoken.last else { return nil }
            let spokenStart = first.sourceStartMs
            let spokenSpan = max(1.0, last.sourceEndMs - spokenStart)
            let scale = duration / spokenSpan
            for word in spoken where !word.isHidden {
                words.append(Word(
                    text: word.text,
                    startMs: block.sourceStartMs + (word.sourceStartMs - spokenStart) * scale,
                    endMs: block.sourceStartMs + (word.sourceEndMs - spokenStart) * scale
                ))
            }
        }
        guard let first = words.first, let last = words.last else { return nil }
        return Line(blockId: block.id, startMs: first.startMs, endMs: last.endMs, words: words, style: style)
    }

    // MARK: Line cache

    private struct LinesCacheKey: Equatable {
        let segments: [CaptionSegment]
        let tracks: [CaptionTrack]
        let blocks: [CaptionBlock]
    }

    private static let cacheLock = NSLock()
    /// A few entries, because several open projects can render at once (one exporting, another playing).
    private static var cachedLines: [(key: LinesCacheKey, lines: [(track: CaptionTrack, lines: [Line])])] = []
    private static let maxCachedLines = 4

    /// Only recomputed when the captions change (`Array ==` is O(1) on shared storage). Hidden tracks are left out.
    static func linesByTrack(in config: CaptionsConfig) -> [(track: CaptionTrack, lines: [Line])] {
        let key = LinesCacheKey(segments: config.segments, tracks: config.captionTracks, blocks: config.captionBlocks)
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let hit = cachedLines.first(where: { $0.key == key }) {
            return hit.lines
        }
        let wordsById = Dictionary(config.segments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let result: [(track: CaptionTrack, lines: [Line])] = config.captionTracks.filter { !$0.isHidden }.map { track in
            var lines = config.captionBlocks
                .filter { $0.trackId == track.id }
                .sorted { $0.sourceStartMs < $1.sourceStartMs }
                .compactMap { makeLine(block: $0, style: $0.styleOverride ?? track.style, wordsById: wordsById) }
            for i in lines.indices {
                let handsOver = i + 1 < lines.count && lines[i + 1].startMs - lines[i].endMs <= 1.0
                if !handsOver {
                    let lead = min(exitLeadMs, (lines[i].endMs - lines[i].startMs) * 0.5)
                    lines[i].fadeOutStartMs = lines[i].endMs - lead
                }
            }
            return (track, lines)
        }
        cachedLines.append((key, result))
        if cachedLines.count > maxCachedLines {
            cachedLines.removeFirst()
        }
        return result
    }

    // MARK: Text metrics

    private struct MetricsKey: Hashable {
        let text: String
        let fontStyle: CaptionFontStyle
        let fontSize: CGFloat
    }

    private static var cachedMetrics: [MetricsKey: CGSize] = [:]

    static func font(style: CaptionFontStyle, size: CGFloat) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: .medium)
        let design: NSFontDescriptor.SystemDesign
        switch style {
        case .sansSerif: return base
        case .serif: design = .serif
        case .mono: design = .monospaced
        }
        guard let descriptor = base.fontDescriptor.withDesign(design) else { return base }
        return NSFont(descriptor: descriptor, size: size) ?? base
    }

    private static func measure(_ text: String, style: CaptionFontStyle, size: CGFloat) -> CGSize {
        let key = MetricsKey(text: text, fontStyle: style, fontSize: size)
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let hit = cachedMetrics[key] {
            return hit
        }
        if cachedMetrics.count > 2048 {
            cachedMetrics.removeAll()
        }
        let measured = NSAttributedString(string: text, attributes: [.font: font(style: style, size: size)]).size()
        cachedMetrics[key] = measured
        return measured
    }

    // MARK: Geometry

    /// Margin kept between a line and the canvas edge, as a share of the shortest side.
    private static let stageMarginRatio: CGFloat = 0.06
    /// Box padding around the words, as a share of the font size.
    private static let boxPaddingXRatio: CGFloat = 0.5
    private static let boxPaddingYRatio: CGFloat = 0.25
    /// How far a `Slide in` word starts from its place, as a share of the font size.
    private static let slideInDistanceRatio: CGFloat = 0.75
    /// Opacity of a `Fade in` word that has not been spoken yet.
    private static let dimmedWordOpacity = 0.5

    private struct LineGeometry {
        let line: Line
        let fontSize: CGFloat
        let sizes: [CGSize]
        let offsets: [CGFloat]
        let totalWidth: CGFloat
        let height: CGFloat
        let available: CGRect

        init(line: Line, stageSize: CGSize) {
            self.line = line
            let shortest = min(stageSize.width, stageSize.height)
            let margin = shortest * stageMarginRatio
            available = CGRect(origin: .zero, size: stageSize).insetBy(dx: margin, dy: margin)

            var size = max(8.0, shortest * CGFloat(line.style.fontSizeRatio))
            var widths = CaptionLineLayout.layOut(line: line, fontSize: size)
            // A line wider than the canvas shrinks to fit.
            let usable = available.width - size * boxPaddingXRatio * 2.0
            if widths.total > usable, widths.total > 0 {
                size = max(8.0, size * usable / widths.total)
                widths = CaptionLineLayout.layOut(line: line, fontSize: size)
            }
            fontSize = size
            sizes = widths.sizes
            offsets = widths.offsets
            totalWidth = widths.total
            height = widths.sizes.map(\.height).max() ?? size
        }

        func fitted(width: CGFloat, height fittedHeight: CGFloat) -> CGRect {
            let anchor = line.style.position01
            return CGRect(
                x: available.minX + (available.width - width) * CGFloat(max(0.0, min(1.0, anchor.x))),
                y: available.minY + (available.height - fittedHeight) * CGFloat(max(0.0, min(1.0, anchor.y))),
                width: width,
                height: fittedHeight
            )
        }

        func widthOfFirstWords(_ count: Int) -> CGFloat {
            guard count > 0, !sizes.isEmpty else { return 1.0 }
            let last = min(count, sizes.count) - 1
            return offsets[last] + sizes[last].width
        }
    }

    private static func layOut(line: Line, fontSize: CGFloat) -> (sizes: [CGSize], offsets: [CGFloat], total: CGFloat) {
        let space = measure(" ", style: line.style.fontStyle, size: fontSize).width
        var sizes: [CGSize] = []
        var offsets: [CGFloat] = []
        var cursor: CGFloat = 0.0
        for word in line.words {
            let size = measure(word.text, style: line.style.fontStyle, size: fontSize)
            sizes.append(size)
            offsets.append(cursor)
            cursor += size.width + space
        }
        return (sizes, offsets, max(1.0, cursor - space))
    }

    /// `-1` before the span, `0` inside, `1` after.
    private static func progress(_ timeMs: Double, _ startMs: Double, _ endMs: Double) -> Int {
        timeMs < startMs ? -1 : (timeMs > endMs ? 1 : 0)
    }

    private static func presentWordCount(_ line: Line, at timeMs: Double) -> Int {
        line.words.reduce(0) { $0 + ($1.startMs <= timeMs ? 1 : 0) }
    }

    /// Where the line's words sit at this time, without its padding.
    private static func targetContentRect(_ geo: LineGeometry, at timeMs: Double) -> CGRect {
        let style = geo.line.style
        let count = presentWordCount(geo.line, at: timeMs)

        if style.wordsReveal == .wordByWord {
            let current = geo.sizes[max(0, count - 1)]
            return geo.fitted(width: current.width, height: current.height)
        }

        let full = geo.fitted(width: geo.totalWidth, height: geo.height)
        // Dimmed upcoming words need the whole box from the start.
        let growth: CaptionLineGrowth = style.wordAnimation == .fadeIn ? .fullLine : style.lineGrowth
        switch growth {
        case .fullLine:
            return full
        case .expanding:
            return CGRect(x: full.minX, y: full.minY, width: geo.widthOfFirstWords(count), height: full.height)
        case .centered:
            return geo.fitted(width: geo.widthOfFirstWords(count), height: geo.height)
        }
    }

    /// A word's place relative to its line's content origin.
    private static func targetWordOffset(_ geo: LineGeometry, index: Int, at timeMs: Double) -> CGFloat {
        let word = geo.line.words[index]
        let style = geo.line.style

        if style.wordsReveal == .wordByWord {
            // The current word stays until the next one pushes it out, also through a short gap between words.
            let current = presentWordCount(geo.line, at: timeMs) - 1
            if timeMs > geo.line.endMs || index < current {
                return -geo.sizes[index].width
            }
            return index == current ? 0.0 : geo.sizes[max(0, current)].width
        }

        let offset = geo.offsets[index]
        if style.wordAnimation == .slideIn, timeMs < word.startMs {
            return offset + geo.fontSize * slideInDistanceRatio
        }
        return offset
    }

    private static func targetWordOpacity(_ geo: LineGeometry, index: Int, at timeMs: Double) -> Double {
        guard progress(timeMs, geo.line.startMs, geo.line.fadeOutStartMs) == 0 else { return 0.0 }
        if geo.line.style.wordsReveal == .wordByWord {
            return index == presentWordCount(geo.line, at: timeMs) - 1 ? 1.0 : 0.0
        }
        if timeMs < geo.line.words[index].startMs {
            return geo.line.style.wordAnimation == .fadeIn ? dimmedWordOpacity : 0.0
        }
        return 1.0
    }

    /// The line closest to this time: the box stays on it through the pause that follows.
    private static func nearestLineIndex(_ lines: [Line], at timeMs: Double) -> Int {
        var lo = 0
        var hi = lines.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if lines[mid].startMs <= timeMs {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        guard lo > 0 else { return 0 }
        let previous = lines[lo - 1]
        guard previous.endMs < timeMs, lo < lines.count else { return lo - 1 }
        return timeMs - previous.endMs < lines[lo].startMs - timeMs ? lo - 1 : lo
    }

    // MARK: Spring

    private struct SpringValue {
        var value: Double
        var velocity = 0.0

        /// Stops at the target instead of overshooting, so words and boxes land cleanly.
        mutating func step(toward target: Double, dt: Double) {
            let before = value - target
            guard abs(before) > 0.0001 || abs(velocity) > 0.0001 else {
                value = target
                velocity = 0.0
                return
            }
            let force = -CaptionLineLayout.springStiffness * before - CaptionLineLayout.springDamping * velocity
            velocity += force / CaptionLineLayout.springMass * dt
            value += velocity * dt
            if before * (value - target) < 0.0 {
                value = target
                velocity = 0.0
            }
        }
    }

    fileprivate static let springStiffness = 425.0
    fileprivate static let springDamping = 12.0
    fileprivate static let springMass = 1.5
    private static let stepSeconds = 1.0 / 240.0
    /// A spring from rest has landed well within this time, so older events cannot affect the frame.
    private static let settleWindowMs = 500.0
    /// Lines further than this from the playhead are invisible.
    private static let drawnLineWindowMs = 700.0

    // MARK: Frames

    static func frames(in config: CaptionsConfig, at timeMs: Double, stageSize: CGSize) -> [TrackFrame] {
        linesByTrack(in: config).compactMap { frame(lines: $0.lines, at: timeMs, stageSize: stageSize) }
    }

    private static func frame(lines: [Line], at timeMs: Double, stageSize: CGSize) -> TrackFrame? {
        guard !lines.isEmpty else { return nil }

        // Outside every block nothing is drawn: a caption shows only while the playhead is on its block.
        guard lines.contains(where: { $0.startMs <= timeMs && timeMs <= $0.endMs }) else { return nil }
        let nearby = lines.indices.filter {
            lines[$0].startMs - drawnLineWindowMs <= timeMs && lines[$0].endMs + drawnLineWindowMs >= timeMs
        }
        guard !nearby.isEmpty else { return nil }

        var geometries: [Int: LineGeometry] = [:]
        func geometry(_ index: Int) -> LineGeometry {
            if let hit = geometries[index] { return hit }
            let made = LineGeometry(line: lines[index], stageSize: stageSize)
            geometries[index] = made
            return made
        }

        // Aligned to an absolute grid so a frame does not depend on how playback reached it.
        let stepMs = stepSeconds * 1000.0
        let startStep = floor((timeMs - settleWindowMs) / stepMs)
        let steps = max(0, Int(ceil(timeMs / stepMs) - startStep))
        let startMs = startStep * stepMs

        func boxTargets(at t: Double) -> [Double] {
            let index = nearestLineIndex(lines, at: t)
            let geo = geometry(index)
            let content = targetContentRect(geo, at: t)
            let opacity: Double = progress(t, geo.line.startMs, geo.line.fadeOutStartMs) == 0 ? 1.0 : 0.0
            return [content.minX, content.minY, content.width, content.height, opacity]
        }

        // Words are stored per nearby line: x, y and opacity, in that order.
        var wordKeys: [(line: Int, word: Int)] = []
        for index in nearby {
            for wordIndex in lines[index].words.indices {
                wordKeys.append((index, wordIndex))
            }
        }

        func wordTargets(at t: Double) -> [Double] {
            let origin = targetContentRect(geometry(nearestLineIndex(lines, at: t)), at: t).origin
            var result: [Double] = []
            result.reserveCapacity(wordKeys.count * 3)
            for key in wordKeys {
                let geo = geometry(key.line)
                result.append(origin.x + targetWordOffset(geo, index: key.word, at: t))
                result.append(origin.y)
                result.append(targetWordOpacity(geo, index: key.word, at: t))
            }
            return result
        }

        var boxState = boxTargets(at: startMs).map { SpringValue(value: $0) }
        var wordState = wordTargets(at: startMs).map { SpringValue(value: $0) }

        for step in 0..<steps {
            let t = startMs + Double(step + 1) * stepMs
            let boxTarget = boxTargets(at: t)
            for i in boxState.indices {
                boxState[i].step(toward: boxTarget[i], dt: stepSeconds)
            }
            let wordTarget = wordTargets(at: t)
            for i in wordState.indices {
                wordState[i].step(toward: wordTarget[i], dt: stepSeconds)
            }
        }

        let activeGeo = geometry(nearestLineIndex(lines, at: timeMs))
        let fontSize = activeGeo.fontSize
        let padX = fontSize * boxPaddingXRatio
        let padY = fontSize * boxPaddingYRatio
        let boxRect = CGRect(
            x: boxState[0].value - padX,
            y: boxState[1].value - padY,
            width: boxState[2].value + padX * 2.0,
            height: boxState[3].value + padY * 2.0
        )

        var words: [DrawnWord] = []
        for (i, key) in wordKeys.enumerated() {
            let opacity = wordState[i * 3 + 2].value
            guard opacity > 0.002 else { continue }
            let geo = geometry(key.line)
            let word = lines[key.line].words[key.word]
            let size = geo.sizes[key.word]
            words.append(DrawnWord(
                text: word.text,
                rect: CGRect(
                    x: wordState[i * 3].value,
                    y: wordState[i * 3 + 1].value + (geo.height - size.height) * 0.5,
                    width: size.width,
                    height: size.height
                ),
                opacity: min(1.0, opacity),
                isSpokenNow: timeMs >= word.startMs && timeMs <= word.endMs + 120.0,
                isDimmedAtRest: geo.line.style.wordAnimation == .fadeIn
                    && geo.line.style.wordsReveal == .lineByLine
                    && timeMs < word.startMs
            ))
        }

        let boxOpacity = max(0.0, min(1.0, boxState[4].value))
        guard boxOpacity > 0.002 || !words.isEmpty else { return nil }
        return TrackFrame(blockId: activeGeo.line.blockId, style: activeGeo.line.style, fontSize: fontSize, boxRect: boxRect, boxOpacity: boxOpacity, words: words)
    }
}
