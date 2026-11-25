import Accelerate
import AVFoundation
import CoreVideo
import Foundation

/// Moments where moving the mouse made something under it change, as hovering does: a menu item or button taking a
/// highlight (`spec/06` ADR-108). The cursor is not in the video, so these are read from the footage around the
/// recorded cursor. The planner must have the drawn cursor where the recorded one was at each of them, or the
/// highlight shows before the cursor gets there. Scanned once per recording and kept in `assets/hover-changes.json`.
nonisolated enum HoverChangeDetector {
    struct Stored: Codable, Sendable, Equatable {
        static let currentVersion = 2
        var version = Stored.currentVersion
        var videoDurationMs: Double
        /// Recording (source) time of each change, ascending.
        var changeTimesMs: [Double]
    }

    struct Settings: Sendable {
        /// Half-size of the square compared around the cursor.
        var probeRadiusPt = 8.0
        /// The frame compared against is this much older, and two changes are at least this far apart.
        var referenceLagMs = 120.0
        /// The area must have been still for this long before the reference frame.
        var settledForMs = 150.0
        /// |dY| + |dCb| + |dCr| at or above this counts as a changed pixel.
        var pixelChangeThreshold = 10
        var coherenceTolerance01 = 0.35
        var minimumCoherenceTolerance = 6
        var minimumChangedFraction = 0.4
        var minimumCoherentFraction = 0.3
        var minimumSurroundingQuarters = 3
        var minimumQuarterCoherentFraction = 0.15
        var maximumSettledChangedFraction = 0.08
        var scrollProbeRadiusPt = 24.0
        var maximumScrollPt = 32.0
        var scrollExplainedResidual01 = 0.5
        /// The mouse must have moved this far, without a button held, within `movementWindowMs`.
        var minimumMovementPt = 3.0
        var movementWindowMs = 150.0
        /// A change this close to a click is the click's effect, not a hover.
        var clickExclusionBeforeMs = 300.0
        var clickExclusionAfterMs = 80.0
        /// Mouse movements closer than this are read as one stretch of video.
        var joinGapMs = 1000.0
        /// Scrolling is only considered with a scroll event this long before the reference frame or later.
        var scrollEventWindowMs = 300.0
        static let standard = Settings()
    }

    // MARK: - Scan

    /// `progress` gets the fraction done and returns `false` to stop. Returns `nil` if the video cannot be read or the
    /// scan stopped. Cursor and clicks are on the video clock, normalized like the telemetry files.
    static func scan(videoURL: URL, cursor: [CursorSampleEvent], clicks: [ClickEvent], pointSize: MotionPointSize,
                     settings: Settings = .standard,
                     progress: @escaping @Sendable (Double) async -> Bool) async -> Stored? {
        let asset = AVURLAsset(url: videoURL)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let duration = try? await asset.load(.duration) else { return nil }
        let durationMs = max(1, duration.seconds * 1000)
        let path = CursorPath(cursor: cursor, clicks: clicks, pointSize: pointSize)
        let spans = path.movementSpans(joinGapMs: settings.joinGapMs, tailMs: settings.movementWindowMs)
        let totalMs = max(1, spans.reduce(0) { $0 + $1.end - $1.start })
        guard let reader = try? AVAssetReader(asset: asset) else { return nil }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }

        // One pass over the whole video. Screen recordings only have a frame when the picture changed, so the frame
        // shown at a moment can be much older than the moment: the last frame before each span is kept for it.
        let historyMs = settings.referenceLagMs + settings.settledForMs
        var detector = Detector(path: path, settings: settings)
        var changes: [Double] = []
        var spanIndex = 0, doneMs = 0.0, framesInSpans = 0
        var waiting: (pixels: CVPixelBuffer, timeMs: Double)?
        while let buffer = output.copyNextSampleBuffer() {
            guard let pixels = CMSampleBufferGetImageBuffer(buffer) else { continue }
            let t = buffer.presentationTimeStamp.seconds * 1000
            while spanIndex < spans.count && t > spans[spanIndex].end {
                doneMs += spans[spanIndex].end - spans[spanIndex].start
                spanIndex += 1
                if !(await progress(min(1, doneMs / totalMs))) {
                    reader.cancelReading()
                    return nil
                }
            }
            guard spanIndex < spans.count else { break }
            let span = spans[spanIndex]
            if t < span.start - historyMs - 50 {
                waiting = (pixels, t)
                continue
            }
            if let earlier = waiting {
                waiting = nil
                if let frame = autoreleasepool(invoking: { Frame(pixels: earlier.pixels, timeMs: earlier.timeMs, pointSize: pointSize) }) {
                    detector.remember(frame)
                }
            }
            guard let frame = autoreleasepool(invoking: { Frame(pixels: pixels, timeMs: t, pointSize: pointSize) }) else { continue }
            if t >= span.start {
                if let change = detector.add(frame) { changes.append(change) }
                // Also inside a long movement, not only at the end of each one.
                framesInSpans += 1
                if framesInSpans % 15 == 0, !(await progress(min(1, (doneMs + t - span.start) / totalMs))) {
                    reader.cancelReading()
                    return nil
                }
            } else {
                detector.remember(frame)
            }
        }
        if reader.status == .failed { return nil }
        changes.sort()
        return Stored(videoDurationMs: durationMs, changeTimesMs: changes.map { ($0 * 10).rounded() / 10 })
    }

    // MARK: - Recorded cursor

    struct CursorPath: Sendable {
        /// Points.
        let ts: [Double], xs: [Double], ys: [Double]
        /// Whether each sample moved the cursor with no button held.
        let isFreeMove: [Bool]
        /// Person's clicks (down and up), ascending.
        let clickTimes: [Double]
        /// Scroll wheel events, ascending.
        let scrollTimes: [Double]

        init(cursor: [CursorSampleEvent], clicks: [ClickEvent], pointSize: MotionPointSize) {
            let sorted = cursor.sorted { $0.t < $1.t }
            ts = sorted.map(\.t)
            xs = sorted.map { $0.x * pointSize.width }
            ys = sorted.map { $0.y * pointSize.height }
            let held = CursorTelemetry.heldIntervals(clicks, endMs: sorted.last?.t ?? 0)
            var moves = [Bool](repeating: false, count: sorted.count)
            var h = 0
            for i in sorted.indices.dropFirst() {
                let t = sorted[i].t
                while h < held.count && held[h].end < t { h += 1 }
                let isHeld = h < held.count && t >= held[h].start
                moves[i] = !isHeld && (sorted[i].x != sorted[i - 1].x || sorted[i].y != sorted[i - 1].y)
            }
            isFreeMove = moves
            clickTimes = clicks.filter { $0.type == "down" || $0.type == "up" }.map(\.t).sorted()
            scrollTimes = clicks.filter { $0.type == "scroll" }.map(\.t).sorted()
        }

        /// Index of the last sample at or before `t`, or -1.
        func index(atOrBefore t: Double) -> Int {
            var lo = 0, hi = ts.count
            while lo < hi {
                let mid = (lo + hi) >> 1
                if ts[mid] <= t { lo = mid + 1 } else { hi = mid }
            }
            return lo - 1
        }

        func position(at t: Double) -> (x: Double, y: Double)? {
            let i = index(atOrBefore: t)
            guard !ts.isEmpty else { return nil }
            if i < 0 { return (xs[0], ys[0]) }
            guard i + 1 < ts.count, ts[i + 1] > ts[i] else { return (xs[i], ys[i]) }
            let f = (t - ts[i]) / (ts[i + 1] - ts[i])
            return (xs[i] + (xs[i + 1] - xs[i]) * f, ys[i] + (ys[i + 1] - ys[i]) * f)
        }

        /// How far the cursor moved with no button held in `(t - windowMs, t]`.
        func freeMovementPt(endingAt t: Double, windowMs: Double) -> Double {
            var i = index(atOrBefore: t)
            var sum = 0.0
            while i > 0 && ts[i] > t - windowMs {
                if isFreeMove[i] { sum += hypot(xs[i] - xs[i - 1], ys[i] - ys[i - 1]) }
                i -= 1
            }
            return sum
        }

        /// Stretches with free movement, joined across short gaps and extended by `tailMs`.
        func movementSpans(joinGapMs: Double, tailMs: Double) -> [(start: Double, end: Double)] {
            var spans: [(start: Double, end: Double)] = []
            for i in ts.indices where isFreeMove[i] {
                let t = ts[i]
                if let last = spans.last, t - last.end <= joinGapMs {
                    spans[spans.count - 1].end = max(last.end, t + tailMs)
                } else {
                    spans.append((t, t + tailMs))
                }
            }
            return spans
        }

        func hasClick(from a: Double, to b: Double) -> Bool { Self.contains(clickTimes, from: a, to: b) }
        func hasScroll(from a: Double, to b: Double) -> Bool { Self.contains(scrollTimes, from: a, to: b) }

        private static func contains(_ times: [Double], from a: Double, to b: Double) -> Bool {
            var lo = 0, hi = times.count
            while lo < hi {
                let mid = (lo + hi) >> 1
                if times[mid] < a { lo = mid + 1 } else { hi = mid }
            }
            return lo < times.count && times[lo] <= b
        }
    }

    // MARK: - Frames

    /// A video frame at one pixel per point (resampled with vImage), video-range `Y` and interleaved `CbCr`.
    struct Frame {
        let timeMs: Double
        let width: Int, height: Int
        let luma: [UInt8]
        let cbcr: [UInt8]

        init?(pixels: CVPixelBuffer, timeMs: Double, pointSize: MotionPointSize) {
            guard CVPixelBufferGetPlaneCount(pixels) == 2 else { return nil }
            self.timeMs = timeMs
            let w = max(1, Int(pointSize.width.rounded())), h = max(1, Int(pointSize.height.rounded()))
            width = w; height = h
            CVPixelBufferLockBaseAddress(pixels, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
            guard let yBase = CVPixelBufferGetBaseAddressOfPlane(pixels, 0),
                  let cBase = CVPixelBufferGetBaseAddressOfPlane(pixels, 1) else { return nil }
            var ySource = vImage_Buffer(data: yBase, height: vImagePixelCount(CVPixelBufferGetHeightOfPlane(pixels, 0)),
                                        width: vImagePixelCount(CVPixelBufferGetWidthOfPlane(pixels, 0)),
                                        rowBytes: CVPixelBufferGetBytesPerRowOfPlane(pixels, 0))
            var cSource = vImage_Buffer(data: cBase, height: vImagePixelCount(CVPixelBufferGetHeightOfPlane(pixels, 1)),
                                        width: vImagePixelCount(CVPixelBufferGetWidthOfPlane(pixels, 1)),
                                        rowBytes: CVPixelBufferGetBytesPerRowOfPlane(pixels, 1))
            var luma = [UInt8](repeating: 0, count: w * h)
            var cbcr = [UInt8](repeating: 128, count: w * h * 2)
            let ok = luma.withUnsafeMutableBytes { yOut -> Bool in
                cbcr.withUnsafeMutableBytes { cOut -> Bool in
                    var yDest = vImage_Buffer(data: yOut.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w)
                    var cDest = vImage_Buffer(data: cOut.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 2)
                    return vImageScale_Planar8(&ySource, &yDest, nil, vImage_Flags(kvImageNoFlags)) == kvImageNoError
                        && vImageScale_CbCr8(&cSource, &cDest, nil, vImage_Flags(kvImageNoFlags)) == kvImageNoError
                }
            }
            guard ok else { return nil }
            self.luma = luma
            self.cbcr = cbcr
        }

        @inline(__always) func index(_ x: Int, _ y: Int) -> Int {
            min(height - 1, max(0, y)) * width + min(width - 1, max(0, x))
        }
    }

    // MARK: - Detection

    struct ProbeComparison {
        var quarterCoherentFractions: [Double]
        var quarterChangedFractions: [Double]
        var changedFraction: Double
        var coherentFraction: Double
    }

    struct Detector {
        let path: CursorPath
        let settings: Settings
        private var history: [Frame] = []
        /// The frame of the last change found, while frames still compare against a reference from before it.
        private var lastChange: Frame?

        init(path: CursorPath, settings: Settings) {
            self.path = path
            self.settings = settings
        }

        mutating func remember(_ frame: Frame) {
            history.append(frame)
            // A video only has a frame when the picture changed, so the reference (the frame on screen 120 ms ago)
            // and the settled frame (on screen 150 ms before the reference) can be much older. Keep both.
            guard let reference = history.last(where: { $0.timeMs <= frame.timeMs - settings.referenceLagMs }),
                  let keep = history.lastIndex(where: { $0.timeMs <= reference.timeMs - settings.settledForMs }),
                  keep > 0 else { return }
            history.removeFirst(keep)
        }

        /// Adds a frame and returns its time if a hover change shows in it.
        mutating func add(_ frame: Frame) -> Double? {
            defer { remember(frame) }
            guard let change = change(in: frame) else { return nil }
            // Until the reference passes the last change, the same highlight still differs from it. It is a new change
            // only if the square changed again since (sweeping down a menu lights a new item every 60 to 100 ms).
            if let last = lastChange, frame.timeMs - last.timeMs < settings.referenceLagMs {
                let cursor = path.position(at: frame.timeMs) ?? (0, 0)
                guard let since = compare(last, frame, Int(cursor.x.rounded()), Int(cursor.y.rounded())),
                      since.changedFraction >= settings.minimumChangedFraction else { return nil }
            }
            lastChange = frame
            return change
        }

        func change(in frame: Frame) -> Double? {
            let s = settings
            let t = frame.timeMs
            guard path.freeMovementPt(endingAt: t, windowMs: s.movementWindowMs) >= s.minimumMovementPt,
                  !path.hasClick(from: t - s.clickExclusionBeforeMs, to: t + s.clickExclusionAfterMs),
                  let cursor = path.position(at: t),
                  let reference = history.last(where: { $0.timeMs <= t - s.referenceLagMs }),
                  let settled = history.last(where: { $0.timeMs <= reference.timeMs - s.settledForMs }) else { return nil }
            let cx = Int(cursor.x.rounded()), cy = Int(cursor.y.rounded())
            guard let probe = compare(reference, frame, cx, cy) else { return nil }
            guard probe.changedFraction >= s.minimumChangedFraction,
                  probe.coherentFraction >= s.minimumCoherentFraction,
                  probe.quarterCoherentFractions.filter({ $0 >= s.minimumQuarterCoherentFraction }).count
                    >= s.minimumSurroundingQuarters else { return nil }
            // Still before: measured where the new change is (quarters at least half coherent), so the previous menu
            // item turning on above or below the cursor does not count against the next one.
            if settled.timeMs != reference.timeMs, let before = compare(settled, reference, cx, cy) {
                let owned = (0..<4).filter { probe.quarterCoherentFractions[$0] >= 0.5 }
                let moved = owned.isEmpty ? before.changedFraction : owned.map { before.quarterChangedFractions[$0] }.max()!
                if moved > s.maximumSettledChangedFraction { return nil }
            }
            // A highlight stepping down one menu row looks like content shifted by a row, so the shift test only runs
            // when the wheel was actually scrolled.
            if path.hasScroll(from: reference.timeMs - s.scrollEventWindowMs, to: t),
               isExplainedByScrolling(from: reference, to: frame, cx, cy) { return nil }
            return t
        }

        /// How the square around the cursor changed from `a` to `b`. A highlight changes most of it, all in the same
        /// way (close to the median change), on at least three sides of the cursor.
        func compare(_ a: Frame, _ b: Frame, _ cx: Int, _ cy: Int) -> ProbeComparison? {
            let s = settings
            let r = max(2, Int(s.probeRadiusPt.rounded()))
            let xa = max(0, cx - r), xb = min(b.width - 1, cx + r)
            let ya = max(0, cy - r), yb = min(b.height - 1, cy + r)
            guard xb >= xa, yb >= ya else { return nil }
            let total = (xb - xa + 1) * (yb - ya + 1)
            var quarterTotal = [Int](repeating: 0, count: 4)
            var dYs: [Int] = [], dCbs: [Int] = [], dCrs: [Int] = [], quarters: [Int] = []
            for y in ya...yb {
                for x in xa...xb {
                    let q = (y < cy ? 0 : 2) + (x >= cx ? 1 : 0)
                    quarterTotal[q] += 1
                    let i = a.index(x, y), j = b.index(x, y)
                    let dY = Int(b.luma[j]) - Int(a.luma[i])
                    let dCb = Int(b.cbcr[2 * j]) - Int(a.cbcr[2 * i])
                    let dCr = Int(b.cbcr[2 * j + 1]) - Int(a.cbcr[2 * i + 1])
                    if abs(dY) + abs(dCb) + abs(dCr) >= s.pixelChangeThreshold {
                        dYs.append(dY); dCbs.append(dCb); dCrs.append(dCr); quarters.append(q)
                    }
                }
            }
            guard !dYs.isEmpty else {
                return ProbeComparison(quarterCoherentFractions: [0, 0, 0, 0], quarterChangedFractions: [0, 0, 0, 0],
                                       changedFraction: 0, coherentFraction: 0)
            }
            func median(_ v: [Int]) -> Int { v.sorted()[v.count / 2] }
            let mY = median(dYs), mCb = median(dCbs), mCr = median(dCrs)
            let tolerance = max(s.minimumCoherenceTolerance,
                                Int((s.coherenceTolerance01 * Double(abs(mY) + abs(mCb) + abs(mCr))).rounded()))
            var coherent = 0
            var quarterCoherent = [Int](repeating: 0, count: 4)
            for k in dYs.indices where abs(dYs[k] - mY) + abs(dCbs[k] - mCb) + abs(dCrs[k] - mCr) <= tolerance {
                coherent += 1
                quarterCoherent[quarters[k]] += 1
            }
            var quarterChanged = [Int](repeating: 0, count: 4)
            for q in quarters { quarterChanged[q] += 1 }
            func fraction(_ n: [Int], _ q: Int) -> Double { quarterTotal[q] > 0 ? Double(n[q]) / Double(quarterTotal[q]) : 0 }
            return ProbeComparison(
                quarterCoherentFractions: (0..<4).map { fraction(quarterCoherent, $0) },
                quarterChangedFractions: (0..<4).map { fraction(quarterChanged, $0) },
                changedFraction: Double(dYs.count) / Double(total),
                coherentFraction: Double(coherent) / Double(total))
        }

        /// Whether shifting `a` up, down, left or right by up to `maximumScrollPt` explains most of the difference:
        /// content moving under a still cursor, not a highlight.
        func isExplainedByScrolling(from a: Frame, to b: Frame, _ cx: Int, _ cy: Int) -> Bool {
            let s = settings
            let r = Int(s.scrollProbeRadiusPt.rounded()), maxShift = Int(s.maximumScrollPt.rounded())
            let xa = max(cx - r, maxShift), xb = min(cx + r, b.width - 1 - maxShift)
            let ya = max(cy - r, maxShift), yb = min(cy + r, b.height - 1 - maxShift)
            guard xa < xb, ya < yb else { return false }
            func residual(dx: Int, dy: Int) -> Int {
                var sum = 0
                for y in ya...yb {
                    for x in xa...xb {
                        sum += abs(Int(b.luma[b.index(x, y)]) - Int(a.luma[a.index(x - dx, y - dy)]))
                    }
                }
                return sum
            }
            let baseline = residual(dx: 0, dy: 0)
            guard baseline >= 1 else { return false }
            var best = Int.max
            for shift in -maxShift...maxShift where shift != 0 {
                best = min(best, residual(dx: 0, dy: shift), residual(dx: shift, dy: 0))
            }
            return s.scrollExplainedResidual01 * Double(baseline) > Double(best)
        }
    }
}
