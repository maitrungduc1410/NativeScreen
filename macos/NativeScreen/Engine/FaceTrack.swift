import AVFoundation
import CoreGraphics
import Foundation
import Vision

/// Both eyes, the nose and the mouth of a face. The eyes can come in either order.
nonisolated struct FacePoints: Sendable {
    var eyeA: CGPoint
    var eyeB: CGPoint
    var nose: CGPoint
    var mouth: CGPoint

    func mapped(_ transform: (CGPoint) -> CGPoint) -> FacePoints {
        FacePoints(eyeA: transform(eyeA), eyeB: transform(eyeB), nose: transform(nose), mouth: transform(mouth))
    }
}

/// Where the largest face is at each moment of `webcam.mp4`, scanned once and kept in `assets/face-track.json`.
/// Having the whole recording lets stickers and framing be smoothed with no lag, the same in preview and export.
nonisolated struct FaceTrack: Sendable {
    /// Each sample is `[timeMs, faceX, faceY, faceW, faceH, eyeAx, eyeAy, eyeBx, eyeBy, noseX, noseY, mouthX, mouthY]`,
    /// normalized to the webcam frame with a top-left origin. Moments with no face have no sample.
    struct Stored: Codable, Sendable {
        var version = 1
        var webcamDurationMs: Double
        var samples: [[Double]]
    }

    private static let fieldCount = 13
    /// Shorter gaps than this are bridged; after longer ones the sticker fades.
    private static let bridgeGapMs = 500.0
    private static let fadeMs = 150.0
    private static let framingStepMs = 100.0
    /// The framing target only moves once the face has left this radius, so small head movements do not move the camera.
    private static let framingDeadZone = 0.05
    private static let framingSigmaSteps = 7

    private let times: [Double]
    private let values: [[Double]]
    private let framing: [CGPoint]

    var hasFaces: Bool { !times.isEmpty }

    init(stored: Stored) {
        let usable = stored.samples.filter { $0.count == Self.fieldCount }
        times = usable.map { $0[0] }
        values = Self.smoothed(usable)
        framing = Self.framingPath(samples: usable, durationMs: stored.webcamDurationMs)
    }

    /// The face at `ms`, in normalized webcam coordinates, and how visible a sticker on it should be.
    func points(atMs ms: Double) -> (points: FacePoints, opacity: Double)? {
        guard hasFaces else { return nil }
        let next = times.firstIndex(atLeast: ms)
        if next < times.count, next > 0, times[next] - times[next - 1] <= Self.bridgeGapMs {
            let t = (ms - times[next - 1]) / max(1.0, times[next] - times[next - 1])
            return (Self.facePoints(zip(values[next - 1], values[next]).map { $0 + ($1 - $0) * t }), 1.0)
        }
        if next < times.count, times[next] == ms { return (Self.facePoints(values[next]), 1.0) }
        if next > 0, ms - times[next - 1] < Self.fadeMs {
            return (Self.facePoints(values[next - 1]), 1.0 - (ms - times[next - 1]) / Self.fadeMs)
        }
        if next < times.count, times[next] - ms < Self.fadeMs {
            return (Self.facePoints(values[next]), 1.0 - (times[next] - ms) / Self.fadeMs)
        }
        return nil
    }

    /// The slow, steady point a tracking camera should center on, in normalized webcam coordinates.
    func framingCenter(atMs ms: Double) -> CGPoint? {
        guard let last = framing.indices.last else { return nil }
        let position = max(0.0, min(Double(last), ms / Self.framingStepMs))
        let lower = Int(position)
        let upper = min(last, lower + 1)
        let t = CGFloat(position - Double(lower))
        return CGPoint(
            x: framing[lower].x + (framing[upper].x - framing[lower].x) * t,
            y: framing[lower].y + (framing[upper].y - framing[lower].y) * t
        )
    }

    private static func facePoints(_ v: [Double]) -> FacePoints {
        FacePoints(
            eyeA: CGPoint(x: v[5], y: v[6]),
            eyeB: CGPoint(x: v[7], y: v[8]),
            nose: CGPoint(x: v[9], y: v[10]),
            mouth: CGPoint(x: v[11], y: v[12])
        )
    }

    /// Centered binomial filter over each unbroken run of samples: removes landmark jitter without adding lag.
    private static func smoothed(_ samples: [[Double]]) -> [[Double]] {
        let weights = [1.0, 4.0, 6.0, 4.0, 1.0]
        var result = samples
        var runStart = 0
        for index in samples.indices {
            if index > 0, samples[index][0] - samples[index - 1][0] > bridgeGapMs { runStart = index }
            var runEnd = index
            while runEnd + 1 < samples.count, runEnd - index < 2, samples[runEnd + 1][0] - samples[runEnd][0] <= bridgeGapMs {
                runEnd += 1
            }
            for field in 1..<fieldCount {
                var sum = 0.0
                var total = 0.0
                for offset in -2...2 where index + offset >= runStart && index + offset <= runEnd {
                    sum += samples[index + offset][field] * weights[offset + 2]
                    total += weights[offset + 2]
                }
                result[index][field] = sum / total
            }
        }
        return result
    }

    private static func framingPath(samples: [[Double]], durationMs: Double) -> [CGPoint] {
        guard let first = samples.first else { return [] }
        let count = Int(durationMs / framingStepMs) + 1
        var raw: [CGPoint] = []
        raw.reserveCapacity(count)
        var cursor = 0
        func center(_ s: [Double]) -> CGPoint { CGPoint(x: s[1] + s[3] * 0.5, y: s[2] + s[4] * 0.5) }
        for step in 0..<count {
            let ms = Double(step) * framingStepMs
            while cursor + 1 < samples.count, samples[cursor + 1][0] <= ms { cursor += 1 }
            if ms <= first[0] {
                raw.append(center(first))
            } else if cursor + 1 < samples.count {
                let a = samples[cursor], b = samples[cursor + 1]
                let t = CGFloat((ms - a[0]) / max(1.0, b[0] - a[0]))
                let ca = center(a), cb = center(b)
                raw.append(CGPoint(x: ca.x + (cb.x - ca.x) * t, y: ca.y + (cb.y - ca.y) * t))
            } else {
                raw.append(center(samples[cursor]))
            }
        }

        var held = raw[0]
        let settled: [CGPoint] = raw.map { point in
            let dx = point.x - held.x, dy = point.y - held.y
            let distance = hypot(dx, dy)
            if distance > framingDeadZone {
                let move = (distance - framingDeadZone) / distance
                held = CGPoint(x: held.x + dx * move, y: held.y + dy * move)
            }
            return held
        }

        let radius = framingSigmaSteps * 3
        let kernel = (-radius...radius).map { d in exp(-Double(d * d) / Double(2 * framingSigmaSteps * framingSigmaSteps)) }
        return settled.indices.map { index in
            var x = 0.0, y = 0.0, total = 0.0
            for offset in -radius...radius where settled.indices.contains(index + offset) {
                let weight = kernel[offset + radius]
                x += Double(settled[index + offset].x) * weight
                y += Double(settled[index + offset].y) * weight
                total += weight
            }
            return CGPoint(x: x / total, y: y / total)
        }
    }
}

private extension Array where Element == Double {
    /// Index of the first element that is at least `value` (the array is sorted), or `count`.
    nonisolated func firstIndex(atLeast value: Double) -> Int {
        var low = 0, high = count
        while low < high {
            let mid = (low + high) / 2
            if self[mid] < value { low = mid + 1 } else { high = mid }
        }
        return low
    }
}

nonisolated enum FaceTrackScanner {
    /// Scanning every other frame and interpolating is smooth enough and halves the time.
    private static let frameStep = 2

    /// `progress` gets the fraction done and returns `false` to stop. Returns `nil` if the video cannot be read or the scan stopped.
    static func scan(webcamURL: URL, progress: @escaping @Sendable (Double) async -> Bool) async -> FaceTrack.Stored? {
        let asset = AVURLAsset(url: webcamURL)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let duration = try? await asset.load(.duration),
              let reader = try? AVAssetReader(asset: asset) else { return nil }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }

        let durationMs = max(1.0, duration.seconds * 1000.0)
        let request = VNDetectFaceLandmarksRequest()
        var samples: [[Double]] = []
        var frameIndex = 0
        while let buffer = output.copyNextSampleBuffer() {
            defer { frameIndex += 1 }
            guard frameIndex % frameStep == 0, let pixels = CMSampleBufferGetImageBuffer(buffer) else { continue }
            let ms = buffer.presentationTimeStamp.seconds * 1000.0
            autoreleasepool {
                try? VNImageRequestHandler(cvPixelBuffer: pixels, options: [:]).perform([request])
                let largest = request.results?.max { area($0.boundingBox) < area($1.boundingBox) }
                if let sample = largest.flatMap({ sample(from: $0, atMs: ms) }) { samples.append(sample) }
            }
            if frameIndex % 30 == 0, !(await progress(min(1.0, ms / durationMs))) {
                reader.cancelReading()
                return nil
            }
        }
        guard reader.status == .completed else { return nil }
        return FaceTrack.Stored(webcamDurationMs: durationMs, samples: samples)
    }

    private static func area(_ rect: CGRect) -> CGFloat { rect.width * rect.height }

    private static func sample(from face: VNFaceObservation, atMs ms: Double) -> [Double]? {
        guard let landmarks = face.landmarks,
              let eyeA = center(landmarks.leftEye),
              let eyeB = center(landmarks.rightEye),
              let nose = center(landmarks.nose ?? landmarks.noseCrest),
              let mouth = center(landmarks.innerLips ?? landmarks.outerLips) else { return nil }
        let box = face.boundingBox
        let values: [CGFloat] = [
            box.minX, 1.0 - box.maxY, box.width, box.height,
            eyeA.x, eyeA.y, eyeB.x, eyeB.y, nose.x, nose.y, mouth.x, mouth.y
        ]
        return [(ms * 10.0).rounded() / 10.0] + values.map { (Double($0) * 10000.0).rounded() / 10000.0 }
    }

    /// Mean of a landmark region, normalized with a top-left origin.
    private static func center(_ region: VNFaceLandmarkRegion2D?) -> CGPoint? {
        guard let points = region?.pointsInImage(imageSize: CGSize(width: 1, height: 1)), !points.isEmpty else { return nil }
        let sum = points.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        return CGPoint(x: sum.x / CGFloat(points.count), y: 1.0 - sum.y / CGFloat(points.count))
    }
}
