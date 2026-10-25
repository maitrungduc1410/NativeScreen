import Foundation
import AVFoundation
import CoreImage
import CoreVideo
import ImageIO
import UniformTypeIdentifiers
import AppKit

/// Hardware-accelerated Video & GIF exporter using the exact same `MetalFrameCompositor` pipeline as the Preview Canvas.
/// Supports MP4 (`H.264`, `HEVC`, or `Both`), Apple `ProRes` (`422 LT`, `422`, `422 HQ`, `4444`), and animated `GIF`,
/// with the file-size range estimator, upfront export time estimator, live ETA calculator,
/// and instant cooperative cancellation (`Stop export`).
public final class HardwareVideoExporter {

    // MARK: - 1. Export Settings Models

    public enum ExportFormat: String, CaseIterable, Identifiable, Codable {
        case mp4 = "mp4"
        case prores = "prores"
        case gif = "gif"

        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .mp4: return "MP4"
            case .prores: return "ProRes"
            case .gif: return "GIF"
            }
        }

        public var fileExtension: String {
            switch self {
            case .mp4: return "mp4"
            case .prores: return "mov"
            case .gif: return "gif"
            }
        }

        public var allowedFPSModes: [Int] {
            switch self {
            case .mp4, .prores:
                return [60, 50, 30, 25, 24, 20, 10]
            case .gif:
                return [50, 30, 25, 20, 15, 10]
            }
        }

        public var allResolutionHeights: [Int] {
            switch self {
            case .mp4, .prores:
                return [720, 1080, 2160]
            case .gif:
                return [480, 720, 1080]
            }
        }
    }

    public enum ExportCompression: String, CaseIterable, Identifiable, Codable {
        case studio = "studio"
        case socialMedia = "social-media"
        case web = "web-high"
        case webLow = "web-low"

        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .studio: return "Studio"
            case .socialMedia: return "Social Media"
            case .web: return "Web"
            case .webLow: return "Web (Low)"
            }
        }

        public var descriptionText: String {
            switch self {
            case .studio:
                return "Highest quality, best for further editing. Compression is almost impossible to notice."
            case .socialMedia:
                return "Good for sharing on social media, etc. Compression is noticeable when taking a good look. Keep in mind that social media server might further compress the video."
            case .web:
                return "Good for directly playing on websites. Compression is slightly visible, but not distracting."
            case .webLow:
                return "Good for sharing on the web, where quality is less important, increasing loading speed. Compression is clearly visible."
            }
        }

        /// Target bits-per-pixel at `1920x1080 @ 60fps`
        public var referenceBitsPerPixel: Double {
            switch self {
            case .studio: return 0.30
            case .socialMedia: return 0.05
            case .web: return 0.0175
            case .webLow: return 0.0075
            }
        }
    }

    public enum MP4CodecOption: String, CaseIterable, Identifiable, Codable {
        case h264 = "h264"
        case h265 = "h265"
        case both = "both"

        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .h264: return "H.264"
            case .h265: return "HEVC"
            case .both: return "Both"
            }
        }

        public var descriptionText: String {
            switch self {
            case .h264:
                return "Great compatibility. Can play literally everywhere. Worse quality to file size ratio than HEVC."
            case .h265:
                return "Better quality to file size ratio than H.264. Not every player can open it."
            case .both:
                return "Saves both an H.264 and an HEVC file next to each other. Export may be slower, since it has to encode two files at once."
            }
        }
    }

    public enum ProResProfileOption: String, CaseIterable, Identifiable, Codable {
        case lt422 = "422-lt"
        case standard422 = "422"
        case hq422 = "422-hq"
        case p4444 = "4444"

        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .lt422: return "422 LT"
            case .standard422: return "422"
            case .hq422: return "422 HQ"
            case .p4444: return "4444"
            }
        }

        public var descriptionText: String {
            switch self {
            case .lt422:
                return "Smaller files for editing. Some detail is lost in fine gradients."
            case .standard422:
                return "The standard for editing. Visually lossless for most recordings."
            case .hq422:
                return "Visually lossless, even for detailed screens and gradients. The usual choice for editing and archiving."
            case .p4444:
                return "Full color resolution, for color grading and compositing. The largest files."
            }
        }

        public var avCodecType: AVVideoCodecType {
            switch self {
            case .lt422: return .proRes422LT
            case .standard422: return .proRes422
            case .hq422: return .proRes422HQ
            case .p4444: return .proRes4444
            }
        }

        /// Reference bitrate in bps at `1920x1080 @ 30fps`
        public var referenceBitrateAt1080p30: Double {
            switch self {
            case .lt422: return 102_000_000
            case .standard422: return 147_000_000
            case .hq422: return 220_000_000
            case .p4444: return 330_000_000
            }
        }
    }

    public enum ExportTarget: String, CaseIterable, Identifiable, Codable {
        case file = "file"
        case clipboard = "clipboard"

        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .file: return "File"
            case .clipboard: return "Clipboard"
            }
        }

        public var iconName: String {
            switch self {
            case .file: return "square.and.arrow.up.fill"
            case .clipboard: return "doc.on.clipboard"
            }
        }

        public var primaryButtonTitle: String {
            switch self {
            case .file: return "Export to file..."
            case .clipboard: return "Export to clipboard"
            }
        }
    }

    public struct ExportConfiguration: Equatable {
        public var format: ExportFormat = .mp4
        public var fps: Int = 60
        public var resolutionHeight: Int = 2160
        public var compression: ExportCompression = .studio
        public var mp4Codec: MP4CodecOption = .h264
        public var proResProfile: ProResProfileOption = .hq422
        public var gifHighQuality: Bool = false
        public var gifDisableLoop: Bool = false
        public var target: ExportTarget = .file

        public init() {}

        /// Resolutions enabled for the current format & compression.
        /// Note: When `Web` or `Web (Low)` compression is selected in MP4, `4K` (`2160p`) is disabled.
        public var enabledResolutionHeights: [Int] {
            let all = format.allResolutionHeights
            if format == .mp4 && (compression == .web || compression == .webLow) {
                return all.filter { $0 <= 1080 }
            }
            return all
        }

        public mutating func normalizeForConstraints() {
            // Clamp FPS to allowed list for format
            let allowedFPS = format.allowedFPSModes
            if !allowedFPS.contains(fps) {
                fps = allowedFPS.first(where: { $0 <= fps }) ?? allowedFPS.first ?? 30
            }
            // Clamp resolution height to enabled list
            let enabledRes = enabledResolutionHeights
            if !enabledRes.contains(resolutionHeight) {
                resolutionHeight = enabledRes.sorted(by: >).first(where: { $0 <= resolutionHeight }) ?? enabledRes.first ?? 1080
            }
            // If target is clipboard, `both` codec falls back to `h264`
            if target != .file && mp4Codec == .both {
                mp4Codec = .h264
            }
        }

        public static func resolutionLabel(forHeight h: Int) -> String {
            return h == 2160 ? "4K" : "\(h)p"
        }

        public func outputPixelSize(canvasAspect: Double) -> (width: Int, height: Int) {
            let safeAspect = max(0.2, canvasAspect)
            let targetH = max(2, resolutionHeight & ~1)
            let targetW = max(2, Int(round(Double(targetH) * safeAspect)) & ~1)
            return (targetW, targetH)
        }
    }

    // MARK: - 2. File Size & Export Time Estimators

    public struct SizeEstimateRange {
        public let lowBytes: Double
        public let highBytes: Double
        public let codecSuffix: String?
    }

    /// Computes the target video bitrate (in bits/sec) for `MP4` using the power-law scaling.
    public static func targetMP4VideoBitrate(
        compression: ExportCompression,
        codec: MP4CodecOption,
        widthPx: Int,
        heightPx: Int,
        fps: Int
    ) -> Int {
        let refPixels = 1920.0 * 1080.0
        let refFPS = 60.0
        let bpp = compression.referenceBitsPerPixel
        let refBitrate = bpp * refPixels * refFPS
        let pixelScale = pow(max(1.0, Double(widthPx * heightPx)) / refPixels, 0.78)
        let fpsScale = pow(max(1.0, Double(fps)) / refFPS, 0.57)
        let codecFactor = (codec == .h265) ? 0.72 : 1.0
        return max(600_000, Int(round(refBitrate * pixelScale * fpsScale * codecFactor)))
    }

    /// Estimates output file size range(s) matching `Ee` and `G`.
    public static func estimateOutputSizeString(
        config: ExportConfiguration,
        canvasAspect: Double,
        durationMs: Double,
        hasAudio: Bool = false
    ) -> String {
        let (widthPx, heightPx) = config.outputPixelSize(canvasAspect: canvasAspect)
        let durationSec = max(0.5, durationMs / 1000.0)
        let fps = Double(config.fps)

        switch config.format {
        case .mp4:
            let codecs: [MP4CodecOption] = (config.mp4Codec == .both && config.target == .file) ? [.h264, .h265] : [config.mp4Codec == .both ? .h264 : config.mp4Codec]
            let parts: [String] = codecs.map { c in
                let videoBps = Double(targetMP4VideoBitrate(
                    compression: config.compression,
                    codec: c,
                    widthPx: widthPx,
                    heightPx: heightPx,
                    fps: config.fps
                ))
                let audioBps = hasAudio ? 165_000.0 : 0.0
                let typicalBytes = ((videoBps + audioBps) / 8.0) * durationSec
                // the content spread range (`I = { low: 0.65, high: 1.5 }`)
                let low = typicalBytes * 0.65
                let high = typicalBytes * 1.50
                let formatted = formatByteRange(lowBytes: low, highBytes: high)
                if codecs.count > 1 {
                    return "\(formatted) \(c.label)"
                }
                return formatted
            }
            return parts.joined(separator: ", ")

        case .prores:
            let refPixels = 1920.0 * 1080.0
            let refFPS = 30.0
            let pixelRatio = Double(widthPx * heightPx) / refPixels
            let fpsRatio = fps / refFPS
            let videoBps = config.proResProfile.referenceBitrateAt1080p30 * pixelRatio * fpsRatio
            let audioBps = hasAudio ? Double(48_000 * 24 * 2) : 0.0
            let typicalBytes = ((videoBps + audioBps) / 8.0) * durationSec
            return formatByteRange(lowBytes: typicalBytes * 0.80, highBytes: typicalBytes * 1.10)

        case .gif:
            let refPixels = 1920.0 * 1080.0
            let qualityMult = config.gifHighQuality ? 1.8 : 1.0
            let bytesPerFrame = 75_000.0 * pow(Double(widthPx * heightPx) / refPixels, 0.80) * qualityMult
            let totalFrames = durationSec * fps
            let typicalBytes = bytesPerFrame * totalFrames
            return formatByteRange(lowBytes: typicalBytes * 0.35, highBytes: typicalBytes * 1.60)
        }
    }

    /// Formats a `(lowBytes, highBytes)` range into `"35–85MB"`, `"120–260kB"`, or `"1.2–2.4GB"`.
    public static func formatByteRange(lowBytes: Double, highBytes: Double) -> String {
        let lowMB = lowBytes / 1_000_000.0
        let highMB = highBytes / 1_000_000.0

        if highMB < 1.0 {
            let lowKB = max(1, Int(round(lowBytes / 10_000.0) * 10))
            let highKB = max(lowKB + 10, Int(round(highBytes / 10_000.0) * 10))
            return "\(lowKB)–\(highKB)kB"
        } else if highMB >= 1000.0 {
            let lowGB = lowMB / 1000.0
            let highGB = highMB / 1000.0
            return String(format: "%.1f–%.1fGB", lowGB, highGB)
        } else {
            func niceMB(_ v: Double) -> Int {
                if v < 10 { return max(1, Int(round(v))) }
                if v < 100 { return Int(round(v / 5.0) * 5) }
                return Int(round(v / 10.0) * 10)
            }
            let l = niceMB(lowMB)
            let h = max(l + 1, niceMB(highMB))
            return "\(l)–\(h)MB"
        }
    }

    /// Upfront export duration estimation.
    public static func estimateExportDurationString(
        config: ExportConfiguration,
        canvasAspect: Double,
        durationMs: Double
    ) -> String {
        let (widthPx, heightPx) = config.outputPixelSize(canvasAspect: canvasAspect)
        let durationSec = max(0.5, durationMs / 1000.0)
        let totalFrames = durationSec * Double(config.fps)
        let ratioTo4K = min(1.0, max(0.0, Double(widthPx * heightPx) / Double(3840 * 2160)))
        let encodingFPS = 60.0 - 28.5 * ratioTo4K
        var seconds = max(1, Int(round(totalFrames / encodingFPS)))
        if config.format == .gif {
            seconds = max(1, Int(round(Double(seconds) * 1.2)))
        }
        if config.format == .mp4 && config.mp4Codec == .both && config.target == .file {
            seconds = Int(round(Double(seconds) * 1.75))
        }

        if seconds < 60 {
            return seconds == 1 ? "1 second" : "\(seconds) seconds"
        }
        let minutes = Int(round(Double(seconds) / 60.0))
        if minutes < 60 {
            return minutes == 1 ? "1 minute" : "\(minutes) minutes"
        }
        let hours = minutes / 60
        let remMin = minutes % 60
        let hStr = hours == 1 ? "1 hour" : "\(hours) hours"
        let mStr = remMin == 1 ? "1 minute" : "\(remMin) minutes"
        return remMin > 0 ? "\(hStr) \(mStr)" : hStr
    }

    // MARK: - 3. Hardware-Accelerated Export Pipeline (MP4 / ProRes / GIF + Instant Cancellation)

    @MainActor
    public static func exportProject(
        session: ProjectSession,
        outputURL: URL,
        config: ExportConfiguration,
        onProgress: @escaping @MainActor (Double) -> Void
    ) async throws {
        try Task.checkCancellation()

        let sourceW = Double(session.metadata.captureTarget.pixelSize.width)
        let sourceH = Double(session.metadata.captureTarget.pixelSize.height)
        let aspect = session.document.canvas.effectiveAspectRatio(sourceWidth: sourceW, sourceHeight: sourceH)
        let (targetW, targetH) = config.outputPixelSize(canvasAspect: aspect)
        let outputSize = CGSize(width: targetW, height: targetH)

        switch config.format {
        case .gif:
            try await exportAnimatedGIF(
                session: session,
                outputURL: outputURL,
                outputSize: outputSize,
                fps: config.fps,
                disableLoop: config.gifDisableLoop,
                onProgress: onProgress
            )

        case .prores:
            try await exportVideoFile(
                session: session,
                outputURL: outputURL,
                fileType: .mov,
                avCodec: config.proResProfile.avCodecType,
                bitrate: nil,
                outputSize: outputSize,
                fps: config.fps,
                progressRange: (0.0, 1.0),
                onProgress: onProgress
            )

        case .mp4:
            if config.mp4Codec == .both && config.target == .file {
                // Save both H.264 (`name.mp4`) and HEVC (`name-hevc.mp4`) next to each other
                let h264Bitrate = targetMP4VideoBitrate(
                    compression: config.compression,
                    codec: .h264,
                    widthPx: targetW,
                    heightPx: targetH,
                    fps: config.fps
                )
                let hevcBitrate = targetMP4VideoBitrate(
                    compression: config.compression,
                    codec: .h265,
                    widthPx: targetW,
                    heightPx: targetH,
                    fps: config.fps
                )
                let baseName = outputURL.deletingPathExtension().lastPathComponent
                let hevcURL = outputURL.deletingLastPathComponent().appendingPathComponent("\(baseName)-hevc.mp4")

                do {
                    try await exportVideoFile(
                        session: session,
                        outputURL: outputURL,
                        fileType: .mp4,
                        avCodec: .h264,
                        bitrate: h264Bitrate,
                        outputSize: outputSize,
                        fps: config.fps,
                        progressRange: (0.0, 0.5),
                        onProgress: onProgress
                    )
                    try await exportVideoFile(
                        session: session,
                        outputURL: hevcURL,
                        fileType: .mp4,
                        avCodec: .hevc,
                        bitrate: hevcBitrate,
                        outputSize: outputSize,
                        fps: config.fps,
                        progressRange: (0.5, 1.0),
                        onProgress: onProgress
                    )
                } catch {
                    try? FileManager.default.removeItem(at: outputURL)
                    try? FileManager.default.removeItem(at: hevcURL)
                    throw error
                }
            } else {
                let effectiveCodec: MP4CodecOption = (config.mp4Codec == .h265) ? .h265 : .h264
                let avCodec: AVVideoCodecType = (effectiveCodec == .h265) ? .hevc : .h264
                let bitrate = targetMP4VideoBitrate(
                    compression: config.compression,
                    codec: effectiveCodec,
                    widthPx: targetW,
                    heightPx: targetH,
                    fps: config.fps
                )
                try await exportVideoFile(
                    session: session,
                    outputURL: outputURL,
                    fileType: .mp4,
                    avCodec: avCodec,
                    bitrate: bitrate,
                    outputSize: outputSize,
                    fps: config.fps,
                    progressRange: (0.0, 1.0),
                    onProgress: onProgress
                )
            }
        }
    }

    @MainActor
    private static func exportVideoFile(
        session: ProjectSession,
        outputURL: URL,
        fileType: AVFileType,
        avCodec: AVVideoCodecType,
        bitrate: Int?,
        outputSize: CGSize,
        fps: Int,
        progressRange: (Double, Double),
        onProgress: @escaping @MainActor (Double) -> Void
    ) async throws {
        guard let compositor = MetalFrameCompositor() else {
            throw NSError(domain: "NativeScreenExport", code: -1, userInfo: [NSLocalizedDescriptionKey: "GPU compositor unavailable."])
        }

        let targetW = Int(outputSize.width)
        let targetH = Int(outputSize.height)

        try? FileManager.default.removeItem(at: outputURL)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: fileType)

        var videoSettings: [String: Any] = [
            AVVideoCodecKey: avCodec,
            AVVideoWidthKey: targetW,
            AVVideoHeightKey: targetH
        ]
        if let bitrate {
            videoSettings[AVVideoCompressionPropertiesKey] = [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoMaxKeyFrameIntervalKey: fps * 2
            ]
        }

        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        writerInput.expectsMediaDataInRealTime = false

        let pixelBufferAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: targetW,
            kCVPixelBufferHeightKey as String: targetH,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: pixelBufferAttrs
        )

        guard writer.canAdd(writerInput) else {
            throw NSError(domain: "NativeScreenExport", code: -2, userInfo: [NSLocalizedDescriptionKey: "Cannot configure video writer input."])
        }
        writer.add(writerInput)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let totalDurationMs = session.timeMapper.totalTimelineDurationMs
        let frameStepMs = 1000.0 / Double(fps)
        let totalFrames = max(1, Int(ceil(totalDurationMs / frameStepMs)))

        let videoURL = session.videoFileURL
        var imageGenerator: AVAssetImageGenerator?
        if FileManager.default.fileExists(atPath: videoURL.path) {
            let asset = AVURLAsset(url: videoURL)
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.requestedTimeToleranceBefore = .zero
            gen.requestedTimeToleranceAfter = .zero
            imageGenerator = gen
        }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

        do {
            for frameIdx in 0..<totalFrames {
                try Task.checkCancellation()

                while !writerInput.isReadyForMoreMediaData {
                    try Task.checkCancellation()
                    try await Task.sleep(for: .milliseconds(2))
                }

                let timelineMs = Double(frameIdx) * frameStepMs
                let sourceMs = session.timeMapper.sourceTime(forTimelineMs: timelineMs).sourceMs

                var sourceCIImage: CIImage?
                if let gen = imageGenerator {
                    let cmTime = CMTime(seconds: sourceMs / 1000.0, preferredTimescale: 600)
                    if let (cgImg, _) = try? await gen.image(at: cmTime) {
                        sourceCIImage = CIImage(cgImage: cgImg)
                    }
                }

                try Task.checkCancellation()

                let composited = compositor.composeFrame(
                    sourceVideoFrame: sourceCIImage,
                    sourceTimeMs: sourceMs,
                    session: session,
                    outputSize: outputSize
                )

                guard let pool = adaptor.pixelBufferPool else { continue }
                var pixelBufferOut: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBufferOut)

                if let pixelBuffer = pixelBufferOut {
                    compositor.ciContext.render(
                        composited,
                        to: pixelBuffer,
                        bounds: CGRect(origin: .zero, size: outputSize),
                        colorSpace: colorSpace
                    )
                    let pts = CMTime(value: CMTimeValue(frameIdx), timescale: CMTimeScale(fps))
                    adaptor.append(pixelBuffer, withPresentationTime: pts)
                }

                let localProgress = Double(frameIdx + 1) / Double(totalFrames)
                let mappedProgress = progressRange.0 + localProgress * (progressRange.1 - progressRange.0)
                onProgress(mappedProgress)
                await Task.yield()
            }

            try Task.checkCancellation()
            writerInput.markAsFinished()
            await writer.finishWriting()
            onProgress(progressRange.1)
        } catch {
            imageGenerator?.cancelAllCGImageGeneration()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
    }

    @MainActor
    private static func exportAnimatedGIF(
        session: ProjectSession,
        outputURL: URL,
        outputSize: CGSize,
        fps: Int,
        disableLoop: Bool,
        onProgress: @escaping @MainActor (Double) -> Void
    ) async throws {
        guard let compositor = MetalFrameCompositor() else {
            throw NSError(domain: "NativeScreenExport", code: -1, userInfo: [NSLocalizedDescriptionKey: "GPU compositor unavailable."])
        }

        try? FileManager.default.removeItem(at: outputURL)

        let totalDurationMs = session.timeMapper.totalTimelineDurationMs
        let frameStepMs = 1000.0 / Double(fps)
        let totalFrames = max(1, Int(ceil(totalDurationMs / frameStepMs)))

        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL,
            UTType.gif.identifier as CFString,
            totalFrames,
            nil
        ) else {
            throw NSError(domain: "NativeScreenExport", code: -3, userInfo: [NSLocalizedDescriptionKey: "Cannot create GIF destination."])
        }

        let fileProperties: [String: Any] = [
            kCGImagePropertyGIFDictionary as String: [
                kCGImagePropertyGIFLoopCount as String: disableLoop ? 1 : 0
            ]
        ]
        CGImageDestinationSetProperties(destination, fileProperties as CFDictionary)

        let frameDelay = 1.0 / Double(fps)
        let frameProperties: [String: Any] = [
            kCGImagePropertyGIFDictionary as String: [
                kCGImagePropertyGIFUnclampedDelayTime as String: frameDelay,
                kCGImagePropertyGIFDelayTime as String: frameDelay
            ]
        ]

        let videoURL = session.videoFileURL
        var imageGenerator: AVAssetImageGenerator?
        if FileManager.default.fileExists(atPath: videoURL.path) {
            let asset = AVURLAsset(url: videoURL)
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.requestedTimeToleranceBefore = .zero
            gen.requestedTimeToleranceAfter = .zero
            imageGenerator = gen
        }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

        do {
            for frameIdx in 0..<totalFrames {
                try Task.checkCancellation()

                let timelineMs = Double(frameIdx) * frameStepMs
                let sourceMs = session.timeMapper.sourceTime(forTimelineMs: timelineMs).sourceMs

                var sourceCIImage: CIImage?
                if let gen = imageGenerator {
                    let cmTime = CMTime(seconds: sourceMs / 1000.0, preferredTimescale: 600)
                    if let (cgImg, _) = try? await gen.image(at: cmTime) {
                        sourceCIImage = CIImage(cgImage: cgImg)
                    }
                }

                try Task.checkCancellation()

                let composited = compositor.composeFrame(
                    sourceVideoFrame: sourceCIImage,
                    sourceTimeMs: sourceMs,
                    session: session,
                    outputSize: outputSize
                )

                if let cgImage = compositor.ciContext.createCGImage(
                    composited,
                    from: CGRect(origin: .zero, size: outputSize),
                    format: .RGBA8,
                    colorSpace: colorSpace
                ) {
                    CGImageDestinationAddImage(destination, cgImage, frameProperties as CFDictionary)
                }

                onProgress(Double(frameIdx + 1) / Double(totalFrames))
                await Task.yield()
            }

            try Task.checkCancellation()
            if !CGImageDestinationFinalize(destination) {
                throw NSError(domain: "NativeScreenExport", code: -4, userInfo: [NSLocalizedDescriptionKey: "Failed to finalize GIF file."])
            }
            onProgress(1.0)
        } catch {
            imageGenerator?.cancelAllCGImageGeneration()
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
    }
}
