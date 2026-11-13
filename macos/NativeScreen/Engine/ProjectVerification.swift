import Foundation
import AVFoundation
import CoreImage
import CoreVideo
import ImageIO
import UniformTypeIdentifiers

/// `--verify-projects <output-folder> <package>...`: opt-in checks on real recordings, never run in the editor.
/// Each package is copied first, so the originals are never touched. For every copy it measures cursor accuracy at the
/// clicks on the edited timeline, renders frames through the compositor at click moments, exports an MP4 through the
/// exporter, and times frame composition with no zoom, a screen zoom and a Loupe at 1080p and 4K.
@MainActor
enum ProjectVerification {
    static func run(packages: [URL], to root: URL) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        var reports: [[String: Any]] = []
        for original in packages {
            let name = original.deletingPathExtension().lastPathComponent
            let copy = root.appendingPathComponent(original.lastPathComponent)
            if fm.fileExists(atPath: copy.path) { try fm.removeItem(at: copy) }
            try fm.copyItem(at: original, to: copy)
            let out = root.appendingPathComponent(name, isDirectory: true)
            try? fm.removeItem(at: out)
            try fm.createDirectory(at: out, withIntermediateDirectories: true)
            fputs("project: \(name)\n", stderr)
            reports.append(try await verify(copy, out: out))
        }
        let data = try JSONSerialization.data(withJSONObject: reports, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: root.appendingPathComponent("projects-report.json"))
    }

    private static func verify(_ package: URL, out: URL) async throws -> [String: Any] {
        let session = try ProjectSession.load(from: package)
        var report: [String: Any] = ["project": package.deletingPathExtension().lastPathComponent,
                                     "timelineMs": session.timeMapper.totalTimelineDurationMs]

        // Telemetry clock: the offset found for recordings made before the first-frame epoch.
        let telemetry = package.appendingPathComponent("recording/telemetry")
        let rawCursor = JSONLinesCodec.load(CursorSampleEvent.self, from: telemetry.appendingPathComponent("cursor.jsonl"))
        let rawClicks = JSONLinesCodec.load(ClickEvent.self, from: telemetry.appendingPathComponent("clicks.jsonl"))
        let rawKeys = JSONLinesCodec.load(KeyStrokeEvent.self, from: telemetry.appendingPathComponent("keys.jsonl"))
        report["legacyOffsetMs"] = LegacyTelemetryEpoch.offsetMs(cursor: rawCursor, clicks: rawClicks, keys: rawKeys,
                                                                durationMs: session.metadata.durationMs)

        // Cursor accuracy and smoothness on the edited timeline, with the project's own settings.
        let points = MotionPointSize(session.metadata.captureTarget)
        var errors: [Double] = []
        var clickTimes: [Double] = []
        for click in session.clickEvents where click.type == "down" || click.type == "up" {
            guard let t = session.timeMapper.timelineTime(forSourceMs: click.t) else { continue }
            let tip = session.trajectorySolver.evaluate(atTimelineMs: t).cursor.position01
            errors.append(points.distance(tip, Point01(x: click.x, y: click.y)))
            if click.type == "down" { clickTimes.append(t) }
        }
        var previous = session.trajectorySolver.evaluate(atTimelineMs: 0).cursor.position01
        // A cut starts a new trajectory, so frame pairs that straddle one are not motion.
        var previousSpeed: Double? = nil, worstJump = 0.0, peakSpeed = 0.0
        let total = session.timeMapper.totalTimelineDurationMs
        let frameMs = 1000.0 / 60
        var t = frameMs
        while t < total {
            let p = session.trajectorySolver.evaluate(atTimelineMs: t).cursor.position01
            if session.trajectorySolver.isSameRun(t, t - frameMs) {
                let speed = points.distance(p, previous) / frameMs
                if let previousSpeed { worstJump = max(worstJump, abs(speed - previousSpeed)) }
                peakSpeed = max(peakSpeed, speed)
                previousSpeed = speed
            } else {
                previousSpeed = nil
            }
            previous = p; t += frameMs
        }
        report["clickCount"] = errors.count
        report["clickErrorWorstPt"] = errors.max() ?? 0
        report["clickErrorMeanPt"] = errors.isEmpty ? 0 : errors.reduce(0, +) / Double(errors.count)
        report["clicksOver1_5Pt"] = errors.filter { $0 > 1.5 }.count
        report["peakCursorSpeedPtPerMs"] = peakSpeed
        report["worstFrameSpeedChangePtPerMs"] = worstJump

        // Frames at the first clicks, through the same path as still-frame export.
        for (index, time) in clickTimes.prefix(3).enumerated() {
            session.seek(toTimelineMs: time)
            if let image = await session.renderCurrentCompositedCGImage(targetHeight: 1080) {
                try writePNG(image, to: out.appendingPathComponent("click-\(index + 1)-\(Int(time))ms.png"))
            }
        }

        // Export the whole edited movie and check what came out.
        var config = HardwareVideoExporter.ExportConfiguration()
        config.resolutionHeight = 1080
        config.normalizeForConstraints()
        let movie = out.appendingPathComponent("export.mp4")
        let exportStart = Date()
        try await HardwareVideoExporter.exportProject(session: session, outputURL: movie, config: config) { _ in }
        let asset = AVURLAsset(url: movie)
        let duration = try await asset.load(.duration).seconds * 1000
        let tracks = try await asset.loadTracks(withMediaType: .video)
        var frameCount = 0
        if let track = tracks.first {
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            reader.add(output)
            reader.startReading()
            while output.copyNextSampleBuffer() != nil { frameCount += 1 }
        }
        report["exportSeconds"] = Date().timeIntervalSince(exportStart)
        report["exportDurationMs"] = duration
        report["exportFrames"] = frameCount
        report["exportBytes"] = (try? FileManager.default.attributesOfItem(atPath: movie.path)[.size] as? NSNumber)?.intValue ?? 0

        report["composeMs"] = try await timeComposition(session, out: out)
        return report
    }

    /// Median and p95 GPU-complete time per frame, distinct decoded frames so caches behave like playback.
    private static func timeComposition(_ session: ProjectSession, out: URL) async throws -> [String: Any] {
        guard let compositor = MetalFrameCompositor() else { return [:] }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: session.videoFileURL))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let total = session.timeMapper.totalTimelineDurationMs
        let times = (0..<12).map { total * (0.1 + 0.8 * Double($0) / 11) }
        var frames: [(timeline: Double, source: Double, image: CIImage)] = []
        for time in times {
            let source = session.timeMapper.sourceTime(forTimelineMs: time).sourceMs
            if let cg = try? await generator.image(at: CMTime(value: CMTimeValue(source), timescale: 1000)).image {
                frames.append((time, source, CIImage(cgImage: cg)))
            }
        }
        guard !frames.isEmpty else { return [:] }
        let originalZooms = session.document.timeline.zooms
        let duration = session.metadata.durationMs
        let cases: [(String, [ZoomBlock])] = [
            ("none", []),
            ("screenZoom", [ZoomBlock(sourceStartMs: 0, sourceEndMs: duration, scale: 2, instantAnimation: true)]),
            ("loupe", [ZoomBlock(sourceStartMs: 0, sourceEndMs: duration, scale: 2.4, presentation: .loupe, instantAnimation: true)]),
        ]
        var result: [String: Any] = [:]
        for (name, zooms) in cases {
            session.mutate { $0.timeline.zooms = zooms; $0.timeline.isZoomTrackHidden = false }
            for (label, size) in [("1080p", CGSize(width: 1920, height: 1080)), ("4K", CGSize(width: 3840, height: 2160))] {
                var buffer: CVPixelBuffer?
                CVPixelBufferCreate(nil, Int(size.width), Int(size.height), kCVPixelFormatType_32BGRA,
                                    [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary, &buffer)
                guard let buffer else { continue }
                var samples: [Double] = []
                for round in 0..<4 {
                    for frame in frames {
                        let started = CACurrentMediaTime()
                        let image = compositor.composeFrame(sourceVideoFrame: frame.image, sourceTimeMs: frame.source,
                                                            timelineTimeMs: frame.timeline, session: session, outputSize: size,
                                                            includeShortcutOverlay: true)
                        compositor.ciContext.render(image, to: buffer)
                        if round > 0 { samples.append((CACurrentMediaTime() - started) * 1000) }
                    }
                }
                samples.sort()
                result["\(name)-\(label)"] = ["medianMs": samples[samples.count / 2],
                                              "p95Ms": samples[min(samples.count - 1, Int(Double(samples.count) * 0.95))]]
                if name == "loupe", label == "1080p", let frame = frames.first {
                    let image = compositor.composeFrame(sourceVideoFrame: frame.image, sourceTimeMs: frame.source,
                                                        timelineTimeMs: frame.timeline, session: session, outputSize: size,
                                                        includeShortcutOverlay: true)
                    if let cg = compositor.ciContext.createCGImage(image, from: CGRect(origin: .zero, size: size)) {
                        try writePNG(cg, to: out.appendingPathComponent("loupe-1080p.png"))
                    }
                }
            }
        }
        session.mutate { $0.timeline.zooms = originalZooms }
        return result
    }

    private static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}
