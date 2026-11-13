import Foundation
import AVFoundation
import CoreImage
import CoreVideo
import VideoToolbox
import ImageIO
import UniformTypeIdentifiers
import AppKit

/// Hardware-accelerated Video & GIF exporter using the exact same `MetalFrameCompositor` pipeline as the Preview Canvas.
/// Supports MP4 (`H.264`, `HEVC`, or `Both`), Apple `ProRes` (`422 LT`, `422`, `422 HQ`, `4444`), and animated `GIF`,
/// with the file-size range estimator, upfront export time estimator, live ETA calculator,
/// Hybrid Parallel Hardware + Software H.264 Encoding (`VTCompressionSession`), and instant cooperative cancellation (`Stop export`).
///
/// Architecture & Performance References:
/// - `spec/06-ENGINEERING-DECISIONS-AND-OPTIMIZATIONS.md` (§1 Hybrid Parallel Video Encoding, §2 Constant-Quality Keyframe Budgeting & `ITU_R_709_2`, §3 Sequential Zero-Copy Decoding, §11 Power-Law File Size & Live ETA)
/// - `spec/platforms/macos-metal-videotoolbox.md` (§1.1–1.4 `AVAssetReaderTrackOutput`, `VTParallelCompressionWorker` 14-frame lookahead backpressure)
public final class HardwareVideoExporter {

    // MARK: - 1. Export Settings Models

    public enum ExportFormat: String, CaseIterable, Identifiable, Codable {
        case mp4 = "mp4"
        case prores = "prores"
        case gif = "gif"

        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .mp4: return String(localized: "MP4")
            case .prores: return String(localized: "ProRes")
            case .gif: return String(localized: "GIF")
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
            case .studio: return String(localized: "Studio")
            case .socialMedia: return String(localized: "Social Media")
            case .web: return String(localized: "Web")
            case .webLow: return String(localized: "Web (Low)")
            }
        }

        public var descriptionText: String {
            switch self {
            case .studio:
                return String(localized: "Highest quality, best for further editing. Compression is almost impossible to notice.")
            case .socialMedia:
                return String(localized: "Good for sharing on social media, etc. Compression is noticeable when taking a good look. Keep in mind that social media server might further compress the video.")
            case .web:
                return String(localized: "Good for directly playing on websites. Compression is slightly visible, but not distracting.")
            case .webLow:
                return String(localized: "Good for sharing on the web, where quality is less important, increasing loading speed. Compression is clearly visible.")
            }
        }

        /// Target bits-per-pixel at `1920x1080 @ 60fps`:
        /// `[{ crf: 14, bitsPerPixel: 0.0816 }, { crf: 24, bitsPerPixel: 0.0221 }, { crf: 30, bitsPerPixel: 0.011 }, { crf: 42, bitsPerPixel: 0.0038 }]`)
        public var referenceBitsPerPixel: Double {
            switch self {
            case .studio: return 0.0816
            case .socialMedia: return 0.0221
            case .web: return 0.0110
            case .webLow: return 0.0038
            }
        }

        /// Constant-quality factor (`0.0 ... 1.0`) for Apple Silicon Hardware `VTCompressionSession` (`kVTCompressionPropertyKey_Quality`),
        /// calibrated to CRF levels (`14`, `24`, `30`, `42`) with full I-frame sharpness (~550–1000 KB keyframes at 4K)!
        public var vtHardwareQuality: Double {
            switch self {
            case .studio: return 0.87
            case .socialMedia: return 0.72
            case .web: return 0.58
            case .webLow: return 0.42
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
            case .h265: return String(localized: "HEVC")
            case .both: return String(localized: "Both")
            }
        }

        public var descriptionText: String {
            switch self {
            case .h264:
                return String(localized: "Great compatibility. Can play literally everywhere. Worse quality to file size ratio than HEVC.")
            case .h265:
                return String(localized: "Better quality to file size ratio than H.264. Not every player can open it.")
            case .both:
                return String(localized: "Saves both an H.264 and an HEVC file next to each other. Export may be slower, since it has to encode two files at once.")
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
            case .lt422: return String(localized: "422 LT")
            case .standard422: return "422"
            case .hq422: return String(localized: "422 HQ")
            case .p4444: return "4444"
            }
        }

        public var descriptionText: String {
            switch self {
            case .lt422:
                return String(localized: "Smaller files for editing. Some detail is lost in fine gradients.")
            case .standard422:
                return String(localized: "The standard for editing. Visually lossless for most recordings.")
            case .hq422:
                return String(localized: "Visually lossless, even for detailed screens and gradients. The usual choice for editing and archiving.")
            case .p4444:
                return String(localized: "Full color resolution, for color grading and compositing. The largest files.")
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
            case .file: return String(localized: "File")
            case .clipboard: return String(localized: "Clipboard")
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
            case .file: return String(localized: "Export to file...")
            case .clipboard: return String(localized: "Export to clipboard")
            }
        }
    }

    public struct ExportConfiguration: Equatable, Codable {
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
            let allowedFPS = format.allowedFPSModes
            if !allowedFPS.contains(fps) {
                fps = allowedFPS.first(where: { $0 <= fps }) ?? allowedFPS.first ?? 30
            }
            let enabledRes = enabledResolutionHeights
            if !enabledRes.contains(resolutionHeight) {
                resolutionHeight = enabledRes.sorted(by: >).first(where: { $0 <= resolutionHeight }) ?? enabledRes.first ?? 1080
            }
            if (target != .file || !Self.allowsCompanionFile) && mp4Codec == .both {
                mp4Codec = .h264
            }
        }

        /// `Both` writes a second `<name>-hevc.mp4` next to the chosen file. The sandboxed App Store build may only
        /// write the file the save panel granted, so it offers H.264 or HEVC alone (ADR-85).
        public static var allowsCompanionFile: Bool {
            #if APPSTORE
            return false
            #else
            return true
            #endif
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

    /// Formats a `(lowBytes, highBytes)` range into `"35–85MB"`, `"4.5–9.8MB"`, `"120–260KB"`, or `"1.2–2.4GB"`.
    public static func formatByteRange(lowBytes: Double, highBytes: Double) -> String {
        func formatUnit(_ bytes: Double) -> (amount: String, unit: String) {
            let kb = bytes / 1000.0
            if kb < 100.0 {
                return ("\(max(1, Int(round(kb))))", "KB")
            }
            if kb < 995.0 {
                let stepped = Int(round(kb / 10.0) * 10)
                return ("\(stepped)", "KB")
            }
            let mb = bytes / 1_000_000.0
            if mb < 25.0 {
                return (String(format: "%.1f", mb), "MB")
            }
            let step = mb < 100.0 ? 5.0 : 10.0
            let steppedMB = Int(round(mb / step) * step)
            if steppedMB < 1000 {
                return ("\(steppedMB)", "MB")
            }
            return (String(format: "%.1f", mb / 1000.0), "GB")
        }

        let low = formatUnit(lowBytes)
        let high = formatUnit(highBytes)
        if low.unit == high.unit {
            if low.amount == high.amount {
                return "\(high.amount)\(high.unit)"
            }
            return "\(low.amount)–\(high.amount)\(high.unit)"
        }
        return "\(low.amount)\(low.unit)–\(high.amount)\(high.unit)"
    }

    /// Upfront export duration estimation, in English. The conformance fixtures compare this exact text.
    public static func estimateExportDurationString(
        config: ExportConfiguration,
        canvasAspect: Double,
        durationMs: Double
    ) -> String {
        formatEstimatedDuration(
            seconds: estimateExportSeconds(config: config, canvasAspect: canvasAspect, durationMs: durationMs),
            localized: false
        )
    }

    /// The same estimate in the UI language, for the export panel.
    public static func localizedEstimateExportDurationString(
        config: ExportConfiguration,
        canvasAspect: Double,
        durationMs: Double
    ) -> String {
        formatEstimatedDuration(
            seconds: estimateExportSeconds(config: config, canvasAspect: canvasAspect, durationMs: durationMs),
            localized: true
        )
    }

    private static func estimateExportSeconds(
        config: ExportConfiguration,
        canvasAspect: Double,
        durationMs: Double
    ) -> Int {
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
        return seconds
    }

    /// "19 seconds", "2 minutes", "1 hour 5 minutes". The keys are shared with Windows, which reads the same catalog.
    private static func formatEstimatedDuration(seconds: Int, localized: Bool) -> String {
        func unit(_ count: Int, one: String, many: String) -> String {
            let key = count == 1 ? one : many
            let pattern = localized ? key.localizedUI : key
            return pattern.replacingOccurrences(of: "%@", with: "\(count)")
        }
        if seconds < 60 {
            return unit(seconds, one: "1 second", many: "%@ seconds")
        }
        let minutes = Int(round(Double(seconds) / 60.0))
        if minutes < 60 {
            return unit(minutes, one: "1 minute", many: "%@ minutes")
        }
        let hours = unit(minutes / 60, one: "1 hour", many: "%@ hours")
        let remMin = minutes % 60
        return remMin > 0 ? "\(hours) \(unit(remMin, one: "1 minute", many: "%@ minutes"))" : hours
    }

    // MARK: - 3. Hardware-Accelerated Sequential Decode + Hybrid Parallel Export Pipeline

    /// Ultra-fast sequential hardware video decoder powered by `AVAssetReaderTrackOutput`.
    /// Decodes directly into native `kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange` Metal-compatible `CVPixelBuffer`s (`~1.2ms` total per frame!).
    private nonisolated final class SequentialVideoFrameReader {
        private let asset: AVURLAsset
        private let videoTrack: AVAssetTrack
        private let preferredTransform: CGAffineTransform
        private var reader: AVAssetReader?
        private var trackOutput: AVAssetReaderTrackOutput?

        private var prevImage: CIImage?
        private var prevMs: Double = -1.0
        private var currImage: CIImage?
        private var currMs: Double = -1.0
        private var reachedEOF: Bool = false

        init?(url: URL) async {
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let asset = AVURLAsset(url: url)
            guard let tracks = try? await asset.load(.tracks),
                  let track = tracks.first(where: { $0.mediaType == .video }) else {
                return nil
            }
            self.asset = asset
            self.videoTrack = track
            self.preferredTransform = (try? await track.load(.preferredTransform)) ?? .identity
        }

        private func resetReader(startingAtMs startMs: Double) -> Bool {
            reader?.cancelReading()
            reader = nil
            trackOutput = nil
            prevImage = nil
            prevMs = -1.0
            currImage = nil
            currMs = -1.0
            reachedEOF = false

            guard let newReader = try? AVAssetReader(asset: asset) else { return false }
            let startSec = max(0.0, (startMs - 50.0) / 1000.0)
            let startCM = CMTime(seconds: startSec, preferredTimescale: 600)
            newReader.timeRange = CMTimeRange(start: startCM, duration: .positiveInfinity)

            // Decode directly to native 420v YUV bi-planar buffers (2.3x faster than CPU/GPU 32BGRA conversion!)
            let outputSettings: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
                kCVPixelBufferMetalCompatibilityKey as String: true
            ]
            let output = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: outputSettings)
            output.alwaysCopiesSampleData = false
            guard newReader.canAdd(output) else { return false }
            newReader.add(output)
            guard newReader.startReading() else { return false }

            self.reader = newReader
            self.trackOutput = output
            return true
        }

        private func decodeNextSample() -> (image: CIImage, ptsMs: Double)? {
            guard !reachedEOF, let output = trackOutput else { return nil }
            while let sampleBuffer = output.copyNextSampleBuffer() {
                guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { continue }
                let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                let ptsMs = pts.isNumeric ? (CMTimeGetSeconds(pts) * 1000.0) : max(0.0, currMs)
                var ciImg = CIImage(cvPixelBuffer: imageBuffer)
                if !preferredTransform.isIdentity {
                    ciImg = ciImg.transformed(by: preferredTransform)
                    let ext = ciImg.extent
                    if ext.minX != 0 || ext.minY != 0 {
                        ciImg = ciImg.transformed(by: CGAffineTransform(translationX: -ext.minX, y: -ext.minY))
                    }
                }
                return (ciImg, ptsMs)
            }
            reachedEOF = true
            return nil
        }

        func frame(atSourceMs targetMs: Double) -> CIImage? {
            if reader == nil || (currMs >= 0.0 && (targetMs < prevMs - 25.0 || targetMs - currMs > 3500.0)) {
                guard resetReader(startingAtMs: targetMs) else { return currImage ?? prevImage }
            }

            while currMs < targetMs && !reachedEOF {
                if let next = decodeNextSample() {
                    prevImage = currImage ?? next.image
                    prevMs = currMs >= 0.0 ? currMs : next.ptsMs
                    currImage = next.image
                    currMs = next.ptsMs
                } else {
                    break
                }
            }

            guard let curr = currImage else { return prevImage }

            // Hold the last frame at or before the target, like the preview (ADR-63). A capture only writes frames when
            // the screen changes, so `curr` can be seconds ahead and must not be shown early. 0.5 ms absorbs rounding.
            if currMs > targetMs + 0.5, let prev = prevImage {
                return prev
            }
            return curr
        }

        func cancel() {
            reader?.cancelReading()
            reader = nil
            trackOutput = nil
            prevImage = nil
            currImage = nil
        }
    }

    /// One `VTCompressionSession` lane of the hybrid exporter (`spec/06` ADR-01).
    /// - The Hardware Media Engine lane tops out at ~70 fps for H.264 at ~3.4K (measured), so for H.264 a second lane runs
    ///   Apple's multi-core software encoder at the same time, on a DIFFERENT GOP, which is what makes the two run truly in parallel.
    /// - Frames are handed over as in-flight `CIRenderTask`s: the GPU wait and the encode both happen on this lane's serial
    ///   `workQueue`, never on `@MainActor`, and the serial queue keeps presentation order intact for VideoToolbox.
    /// - Encoded samples are streamed to `onEncoded` (the ordered muxer) instead of being kept in memory.
    private nonisolated final class VTParallelCompressionWorker: @unchecked Sendable {
        let isHardware: Bool
        private var session: VTCompressionSession?
        private let lock = NSLock()
        private var _inFlightCount: Int = 0
        private let workQueue: DispatchQueue
        private let onEncoded: @Sendable (_ frameIndex: Int, _ sample: CMSampleBuffer?) -> Void
        /// Must exceed the 14-frame internal lookahead buffer of Apple's software H.264 `VTCompressionSession`!
        private let maxInFlightFrames: Int = 28

        init?(
            width: Int,
            height: Int,
            codecType: CMVideoCodecType,
            useHardware: Bool,
            quality: Double,
            bitrate: Int,
            fps: Int,
            label: String,
            onEncoded: @escaping @Sendable (_ frameIndex: Int, _ sample: CMSampleBuffer?) -> Void
        ) {
            self.isHardware = useHardware
            self.workQueue = DispatchQueue(label: label, qos: .userInitiated)
            self.onEncoded = onEncoded

            let spec: [String: Any] = useHardware
                ? [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true]
                : [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: false]
            let pbAttrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferMetalCompatibilityKey as String: true
            ]

            var createdSession: VTCompressionSession?
            let status = VTCompressionSessionCreate(
                allocator: nil,
                width: Int32(width),
                height: Int32(height),
                codecType: codecType,
                encoderSpecification: spec as CFDictionary,
                imageBufferAttributes: pbAttrs as CFDictionary,
                compressedDataAllocator: nil,
                outputCallback: nil,
                refcon: nil,
                compressionSessionOut: &createdSession
            )
            guard status == noErr, let s = createdSession else { return nil }
            self.session = s

            // Offline export: no realtime pacing hint (measured: same speed on the Media Engine, never slower).
            VTSessionSetProperty(s, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanFalse)
            VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
            if codecType == kCMVideoCodecType_H264 {
                VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
            }
            if useHardware {
                // Crucial: Use pure Constant-Quality (`kVTCompressionPropertyKey_Quality`) without `DataRateLimits` on the Hardware Media Engine!
                // Setting `DataRateLimits` or a tight `AverageBitRate` on VideoToolbox starves the first I-frame (~105 KB instead of ~600+ KB),
                // causing blurry text and dark macroblocking across the entire GOP!
                VTSessionSetProperty(s, key: kVTCompressionPropertyKey_Quality, value: quality as CFNumber)
            } else {
                // The software H.264 encoder rejects `kVTCompressionPropertyKey_Quality` (-12900), so it runs average-bitrate.
                // `setAverageBitRate` keeps re-targeting it to the Media Engine's measured bitrate (`matched quality`).
                VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)
            }
            VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: (fps * 2) as CFNumber)
            VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 2.0 as CFNumber)
            VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ColorPrimaries, value: kCVImageBufferColorPrimaries_ITU_R_709_2)
            VTSessionSetProperty(s, key: kVTCompressionPropertyKey_TransferFunction, value: kCVImageBufferTransferFunction_ITU_R_709_2)
            VTSessionSetProperty(s, key: kVTCompressionPropertyKey_YCbCrMatrix, value: kCVImageBufferYCbCrMatrix_ITU_R_709_2)
            VTCompressionSessionPrepareToEncodeFrames(s)
        }

        var inFlightCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return _inFlightCount
        }

        var hasCapacity: Bool {
            inFlightCount < maxInFlightFrames
        }

        func allocatePixelBuffer() -> CVPixelBuffer? {
            guard let s = session, let pool = VTCompressionSessionGetPixelBufferPool(s) else { return nil }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
            return pb
        }

        /// Encodes one throwaway frame and reports whether a sample came back. Used on a probe session only.
        func encodesFrame() -> Bool {
            guard let s = session, let buffer = allocatePixelBuffer() else { return false }
            nonisolated(unsafe) var produced = false
            let status = VTCompressionSessionEncodeFrame(
                s,
                imageBuffer: buffer,
                presentationTimeStamp: .zero,
                duration: CMTime(value: 1, timescale: 60),
                frameProperties: nil,
                infoFlagsOut: nil
            ) { encodeStatus, _, sampleBuffer in
                produced = encodeStatus == noErr && sampleBuffer != nil
            }
            guard status == noErr else { return false }
            VTCompressionSessionCompleteFrames(s, untilPresentationTimeStamp: .invalid)
            return produced
        }

        func setAverageBitRate(_ bitsPerSecond: Int) {
            workQueue.async {
                guard let s = self.session else { return }
                VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate, value: bitsPerSecond as CFNumber)
            }
        }

        private func finishOne(frameIndex: Int, sample: CMSampleBuffer?) {
            lock.lock()
            _inFlightCount = max(0, _inFlightCount - 1)
            lock.unlock()
            onEncoded(frameIndex, sample)
        }

        func submitFrame(
            renderTask: CIRenderTask?,
            pixelBuffer: CVPixelBuffer,
            frameIndex: Int,
            pts: CMTime,
            duration: CMTime,
            forceKeyframe: Bool
        ) {
            lock.lock()
            _inFlightCount += 1
            lock.unlock()

            nonisolated(unsafe) let task = renderTask
            nonisolated(unsafe) let buffer = pixelBuffer
            workQueue.async { [weak self] in
                guard let self = self else { return }
                guard let s = self.session else {
                    self.finishOne(frameIndex: frameIndex, sample: nil)
                    return
                }
                _ = try? task?.waitUntilCompleted()
                let props: CFDictionary? = forceKeyframe
                    ? [kVTEncodeFrameOptionKey_ForceKeyFrame as String: true] as CFDictionary
                    : nil
                let status = VTCompressionSessionEncodeFrame(
                    s,
                    imageBuffer: buffer,
                    presentationTimeStamp: pts,
                    duration: duration,
                    frameProperties: props,
                    infoFlagsOut: nil
                ) { [weak self] encodeStatus, _, sampleBuffer in
                    self?.finishOne(frameIndex: frameIndex, sample: encodeStatus == noErr ? sampleBuffer : nil)
                }
                if status != noErr {
                    self.finishOne(frameIndex: frameIndex, sample: nil)
                }
            }
        }

        /// Emits every frame the encoder is still holding in its lookahead buffer. Called at the end of each GOP: otherwise
        /// the software encoder keeps the GOP's last ~14 frames until it receives more input, and if this lane does not get
        /// another GOP right away (the muxer lead limit), the ordered muxer waits on those frames forever.
        func flushPendingFrames() {
            workQueue.async {
                guard let s = self.session else { return }
                VTCompressionSessionCompleteFrames(s, untilPresentationTimeStamp: .invalid)
            }
        }

        func finishAndWait() {
            workQueue.sync {
                if let s = self.session {
                    VTCompressionSessionCompleteFrames(s, untilPresentationTimeStamp: .invalid)
                    VTCompressionSessionInvalidate(s)
                    self.session = nil
                }
            }
        }

        func cancel() {
            workQueue.async {
                if let s = self.session {
                    VTCompressionSessionInvalidate(s)
                    self.session = nil
                }
                self.lock.lock()
                self._inFlightCount = 0
                self.lock.unlock()
            }
        }
    }

    /// Keeps a two-lane H.264 export to ONE sample description (`spec/06` ADR-01). The hardware and software lanes produce
    /// different SPS/PPS; written as-is they become two `avc1` sample descriptions that switch every GOP, and Chrome stops
    /// with a decode error at the first switch. Instead every sample is muxed under the first description, and every
    /// keyframe carries its own lane's SPS/PPS in-band in front of the IDR, so decoders pick up each GOP's parameter sets.
    private nonisolated enum H264InBandParameterSets {
        static func rewrite(_ sample: CMSampleBuffer, sharedDescription: CMFormatDescription) throws -> CMSampleBuffer {
            guard let own = CMSampleBufferGetFormatDescription(sample) else { return sample }
            let attachments = (CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]])?.first ?? [:]
            let isKeyframe = (attachments[kCMSampleAttachmentKey_NotSync] as? Bool) != true
            let sameDescription = CMFormatDescriptionEqual(own, otherFormatDescription: sharedDescription)
            if !isKeyframe && sameDescription { return sample }

            var payload = Data()
            if isKeyframe {
                var count = 0
                var lengthSize: Int32 = 4
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(own, parameterSetIndex: 0, parameterSetPointerOut: nil,
                    parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: &lengthSize)
                for index in 0..<count {
                    var pointer: UnsafePointer<UInt8>?
                    var size = 0
                    guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(own, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                        parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let pointer else { continue }
                    for shift in stride(from: Int(lengthSize - 1) * 8, through: 0, by: -8) { payload.append(UInt8((size >> shift) & 0xFF)) }
                    payload.append(pointer, count: size)
                }
            }
            guard let dataBuffer = CMSampleBufferGetDataBuffer(sample) else { return sample }
            let length = CMBlockBufferGetDataLength(dataBuffer)
            let prefix = payload.count
            payload.count += length
            let copied = payload.withUnsafeMutableBytes { raw in
                CMBlockBufferCopyDataBytes(dataBuffer, atOffset: 0, dataLength: length, destination: raw.baseAddress! + prefix)
            }
            guard copied == noErr else { throw rewriteError(copied) }

            var block: CMBlockBuffer?
            var status = CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: payload.count, blockAllocator: nil,
                customBlockSource: nil, offsetToData: 0, dataLength: payload.count, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
            guard status == noErr, let block else { throw rewriteError(status) }
            status = payload.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: payload.count) }
            guard status == noErr else { throw rewriteError(status) }

            var timing = CMSampleTimingInfo()
            CMSampleBufferGetSampleTimingInfo(sample, at: 0, timingInfoOut: &timing)
            var size = payload.count
            var rewritten: CMSampleBuffer?
            status = CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: sharedDescription, sampleCount: 1,
                sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &rewritten)
            guard status == noErr, let rewritten else { throw rewriteError(status) }
            if !attachments.isEmpty, let array = CMSampleBufferGetSampleAttachmentsArray(rewritten, createIfNecessary: true), CFArrayGetCount(array) > 0 {
                let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(array, 0), to: CFMutableDictionary.self)
                for (key, value) in attachments {
                    CFDictionarySetValue(dictionary, Unmanaged.passUnretained(key).toOpaque(), Unmanaged.passUnretained(value as AnyObject).toOpaque())
                }
            }
            return rewritten
        }

        private static func rewriteError(_ status: OSStatus) -> NSError {
            NSError(domain: "NativeScreenExport", code: Int(status), userInfo: [NSLocalizedDescriptionKey: String(localized: "Could not prepare an H.264 frame for the MP4 file.")])
        }
    }

    /// Puts frames coming back from both encoder lanes into presentation order and hands them to the muxer as soon
    /// as the next expected frame is available. Memory stays bounded to the GOPs currently in flight
    /// (a few MB) instead of the whole encoded video. Also tracks the Media Engine's real bitrate so the
    /// software lane can be re-targeted to it.
    private nonisolated final class OrderedEncodedSampleQueue: @unchecked Sendable {
        private let lock = NSLock()
        private var pending: [Int: CMSampleBuffer] = [:]
        private var dropped: Set<Int> = []
        private var nextIndex: Int = 0
        private var deliveredCount: Int = 0
        private var hardwareBytes: Int = 0
        private var hardwareFrames: Int = 0

        func deliver(frameIndex: Int, sample: CMSampleBuffer?, fromHardware: Bool) {
            lock.lock()
            defer { lock.unlock() }
            deliveredCount += 1
            if let sample {
                pending[frameIndex] = sample
                if fromHardware {
                    hardwareBytes += CMSampleBufferGetTotalSampleSize(sample)
                    hardwareFrames += 1
                }
            } else {
                dropped.insert(frameIndex)
            }
        }

        /// Pops the next in-order sample, skipping frames the encoder dropped. `nil` means the next frame is not encoded yet.
        func popNext() -> CMSampleBuffer? {
            lock.lock()
            defer { lock.unlock() }
            while dropped.remove(nextIndex) != nil {
                nextIndex += 1
            }
            guard let sample = pending.removeValue(forKey: nextIndex) else { return nil }
            nextIndex += 1
            return sample
        }

        /// Frames that came out of either encoder, in any order. Used for progress: the in-order count only moves when
        /// the slower lane finishes its GOP, so it advances in jumps.
        var encodedFrameCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return deliveredCount
        }

        var orderedFrameCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return nextIndex
        }

        func hardwareBitsPerFrame() -> Double? {
            lock.lock()
            defer { lock.unlock() }
            guard hardwareFrames >= 30 else { return nil }
            return Double(hardwareBytes * 8) / Double(hardwareFrames)
        }
    }

    /// Decodes the screen recording and (when present) the webcam recording side by side for one export lane, on its own
    /// serial queue so `AVAssetReader` decode and GOP-jump seeks never block the main actor.
    private nonisolated final class ExportFrameSource: @unchecked Sendable {
        struct Frames: @unchecked Sendable {
            let screen: CIImage?
            let webcam: CIImage?
        }

        private let queue = DispatchQueue(label: "com.nativescreen.export.decode", qos: .userInitiated)
        private let screenReader: SequentialVideoFrameReader?
        private let webcamReader: SequentialVideoFrameReader?
        private let webcamDelayMs: Double

        private init(screenReader: SequentialVideoFrameReader?, webcamReader: SequentialVideoFrameReader?, webcamDelayMs: Double) {
            self.screenReader = screenReader
            self.webcamReader = webcamReader
            self.webcamDelayMs = webcamDelayMs
        }

        @MainActor
        static func make(session: ProjectSession) async -> ExportFrameSource {
            let videoURL = session.videoFileURL
            let camera = session.document.camera
            let webcamURL = camera.enabled ? session.webcamVideoFileURL : nil
            let screen = await SequentialVideoFrameReader(url: videoURL)
            let webcam: SequentialVideoFrameReader? = if let webcamURL { await SequentialVideoFrameReader(url: webcamURL) } else { nil }
            return ExportFrameSource(screenReader: screen, webcamReader: webcam, webcamDelayMs: camera.delayAdjustmentMs)
        }

        func frames(atSourceMs sourceMs: Double) async -> Frames {
            await withCheckedContinuation { continuation in
                queue.async {
                    let frames = autoreleasepool {
                        Frames(
                            screen: self.screenReader?.frame(atSourceMs: sourceMs),
                            webcam: self.webcamReader?.frame(atSourceMs: max(0.0, sourceMs + self.webcamDelayMs))
                        )
                    }
                    continuation.resume(returning: frames)
                }
            }
        }

        func cancel() {
            queue.async {
                self.screenReader?.cancel()
                self.webcamReader?.cancel()
            }
        }
    }

    /// Decodes and mixes the export's audio on its own thread, a little ahead of the muxer, so the main actor only
    /// picks up finished buffers (ADR-71).
    private nonisolated final class BufferedAudioSamples: @unchecked Sendable {
        enum Next {
            case sample(CMSampleBuffer)
            case notReady
            case finished
        }

        private let condition = NSCondition()
        private var buffered: [CMSampleBuffer] = []
        private var reachedEnd = false
        private var isCancelled = false
        private static let capacity = 32

        init(output: AVAssetReaderAudioMixOutput) {
            nonisolated(unsafe) let output = output
            DispatchQueue(label: "com.nativescreen.export.audio", qos: .userInitiated).async { [self] in
                while true {
                    condition.lock()
                    while buffered.count >= Self.capacity && !isCancelled { condition.wait() }
                    let stop = isCancelled
                    condition.unlock()
                    if stop { return }

                    let sample = output.copyNextSampleBuffer()
                    condition.lock()
                    if let sample { buffered.append(sample) } else { reachedEnd = true }
                    condition.unlock()
                    if sample == nil { return }
                }
            }
        }

        func next() -> Next {
            condition.lock()
            defer { condition.unlock() }
            guard !buffered.isEmpty else { return reachedEnd ? .finished : .notReady }
            let sample = buffered.removeFirst()
            condition.signal()
            return .sample(sample)
        }

        func cancel() {
            condition.lock()
            isCancelled = true
            condition.signal()
            condition.unlock()
        }
    }

    /// Keeps long `@MainActor` export loops from starving the UI: yields to the main run loop every ~8ms of work and
    /// throttles progress callbacks to ~30 Hz.
    @MainActor
    private struct MainActorExportPacer {
        private var lastYieldUptime = ProcessInfo.processInfo.systemUptime
        private var lastProgressUptime: TimeInterval = 0

        mutating func reportProgress(_ value: Double, force: Bool = false, _ onProgress: @MainActor (Double) -> Void) {
            let now = ProcessInfo.processInfo.systemUptime
            if force || now - lastProgressUptime >= 1.0 / 30.0 {
                lastProgressUptime = now
                onProgress(value)
            }
        }

        mutating func yieldIfNeeded() async throws {
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastYieldUptime >= 0.008 {
                try await Task.sleep(for: .milliseconds(1))
                lastYieldUptime = ProcessInfo.processInfo.systemUptime
            }
        }
    }

    @MainActor
    public static func exportProject(
        session: ProjectSession,
        outputURL: URL,
        config: ExportConfiguration,
        onProgress: @escaping @MainActor (Double) -> Void
    ) async throws {
        try Task.checkCancellation()
        await session.waitForFaceTrack()

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
            try await exportProResVideoFile(
                session: session,
                outputURL: outputURL,
                avCodec: config.proResProfile.avCodecType,
                outputSize: outputSize,
                fps: config.fps,
                progressRange: (0.0, 1.0),
                onProgress: onProgress
            )

        case .mp4:
            if config.mp4Codec == .both && config.target == .file {
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
                    try await exportMP4VideoFileHybrid(
                        session: session,
                        outputURL: outputURL,
                        codecOption: .h264,
                        compression: config.compression,
                        bitrate: h264Bitrate,
                        outputSize: outputSize,
                        fps: config.fps,
                        progressRange: (0.0, 0.5),
                        onProgress: onProgress
                    )
                    try await exportMP4VideoFileHybrid(
                        session: session,
                        outputURL: hevcURL,
                        codecOption: .h265,
                        compression: config.compression,
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
                let bitrate = targetMP4VideoBitrate(
                    compression: config.compression,
                    codec: effectiveCodec,
                    widthPx: targetW,
                    heightPx: targetH,
                    fps: config.fps
                )
                try await exportMP4VideoFileHybrid(
                    session: session,
                    outputURL: outputURL,
                    codecOption: effectiveCodec,
                    compression: config.compression,
                    bitrate: bitrate,
                    outputSize: outputSize,
                    fps: config.fps,
                    progressRange: (0.0, 1.0),
                    onProgress: onProgress
                )
            }
        }
    }

    /// Hybrid Parallel MP4 Exporter (`H.264` & `HEVC`), see `spec/06` ADR-01:
    /// - H.264 runs two encoder lanes at the same time, each on its own 2-second GOP: the Hardware Media Engine lane
    ///   (~70 fps ceiling at ~3.4K, measured) and Apple's multi-core software lane. Whichever lane frees up first takes
    ///   the next GOP, so the split adapts to the machine instead of a fixed 60/40.
    /// - The software lane is continuously re-targeted to the Media Engine's measured bitrate so both halves of the
    ///   video have matched quality (no visible quality pulse every 2 seconds).
    /// - Encoded frames are re-ordered and muxed (interleaved with audio) WHILE encoding, so memory stays bounded.
    /// - The two lanes produce different SPS/PPS. The file still has one `avc1` sample description: the muxer writes every
    ///   keyframe with its own SPS/PPS in-band (`H264InBandParameterSets`), so Chrome can play it.
    /// - HEVC uses only the Hardware Media Engine lane.
    /// - If the hardware encoder cannot run at this size, one software lane does the whole export (ADR-64).
    @MainActor
    private static func exportMP4VideoFileHybrid(
        session: ProjectSession,
        outputURL: URL,
        codecOption: MP4CodecOption,
        compression: ExportCompression,
        bitrate: Int,
        outputSize: CGSize,
        fps: Int,
        progressRange: (Double, Double),
        onProgress: @escaping @MainActor (Double) -> Void
    ) async throws {
        guard let compositor = MetalFrameCompositor() else {
            throw NSError(domain: "NativeScreenExport", code: -1, userInfo: [NSLocalizedDescriptionKey: String(localized: "GPU compositor unavailable.")])
        }

        let targetW = Int(outputSize.width)
        let targetH = Int(outputSize.height)
        try? FileManager.default.removeItem(at: outputURL)

        let hwQuality = compression.vtHardwareQuality
        let cmCodec: CMVideoCodecType = (codecOption == .h265) ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264
        let ordered = OrderedEncodedSampleQueue()

        let hardwareWorks = await Task.detached(priority: .userInitiated) {
            hardwareEncoderWorks(width: targetW, height: targetH, codecType: cmCodec, quality: hwQuality, bitrate: bitrate, fps: fps)
        }.value

        let hwWorker: VTParallelCompressionWorker? = hardwareWorks ? VTParallelCompressionWorker(
            width: targetW,
            height: targetH,
            codecType: cmCodec,
            useHardware: true,
            quality: hwQuality,
            bitrate: bitrate,
            fps: fps,
            label: "com.nativescreen.export.vt.hw",
            onEncoded: { ordered.deliver(frameIndex: $0, sample: $1, fromHardware: true) }
        ) : nil

        let swWorker: VTParallelCompressionWorker? = (codecOption == .h264 || hwWorker == nil) ? VTParallelCompressionWorker(
            width: targetW,
            height: targetH,
            codecType: cmCodec,
            useHardware: false,
            quality: hwQuality,
            bitrate: bitrate,
            fps: fps,
            label: "com.nativescreen.export.vt.sw",
            onEncoded: { ordered.deliver(frameIndex: $0, sample: $1, fromHardware: false) }
        ) : nil

        guard hwWorker != nil || swWorker != nil else {
            throw NSError(domain: "NativeScreenExport", code: -2, userInfo: [NSLocalizedDescriptionKey: String(localized: "Hardware video encoder unavailable.")])
        }

        let totalDurationMs = session.timeMapper.totalTimelineDurationMs
        let frameStepMs = 1000.0 / Double(fps)
        let totalFrames = max(1, Int(ceil(totalDurationMs / frameStepMs)))
        let gopSize = max(1, fps * 2) // 2-second closed GOPs, the unit of work each lane takes
        let gopCount = (totalFrames + gopSize - 1) / gopSize
        // A lane may start at most this many GOPs ahead of the muxer, which bounds the re-order buffer.
        let maxGOPLead = 3
        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

        final class EncodeLane {
            let worker: VTParallelCompressionWorker
            let source: ExportFrameSource
            var gopIndex: Int?
            var nextFrameIndex: Int = 0
            /// Decode of `nextFrameIndex`, started one frame ahead so it overlaps GPU work and the other lane.
            var prefetch: Task<ExportFrameSource.Frames, Never>?
            /// Set when the lane finished a GOP; if it then has to idle, its encoder is flushed so no frame stays parked.
            var needsFlush = false

            init(worker: VTParallelCompressionWorker, source: ExportFrameSource) {
                self.worker = worker
                self.source = source
            }
        }

        var lanes: [EncodeLane] = []
        for worker in [hwWorker, swWorker].compactMap({ $0 }) {
            lanes.append(EncodeLane(worker: worker, source: await ExportFrameSource.make(session: session)))
        }
        let sourceMs: (Int) -> Double = { frameIdx in
            session.timeMapper.sourceTime(forTimelineMs: Double(frameIdx) * frameStepMs).sourceMs
        }
        func startPrefetch(_ lane: EncodeLane) {
            let source = lane.source
            let ms = sourceMs(lane.nextFrameIndex)
            lane.prefetch = Task { await source.frames(atSourceMs: ms) }
        }

        // Multi-Track Audio Mixdown (`display.mp4` system audio + `microphone.m4a` + `voiceovers` + `backgroundMusic`)
        let audioPipeline = await buildMultiTrackAudioReaderAndOutput(session: session)
        let audioFeed = audioPipeline.map { BufferedAudioSamples(output: $0.output) }

        // The passthrough muxer needs a format hint, so it is created when frame 0 comes out of the encoder.
        var muxWriter: AVAssetWriter?
        var muxInput: AVAssetWriterInput?
        var muxAudioInput: AVAssetWriterInput?
        var nextVideoSample: CMSampleBuffer?
        var muxDescription: CMFormatDescription?
        var pendingAudioSample: CMSampleBuffer?
        var isVideoInputFinished = false
        var isAudioDone = (audioPipeline == nil)
        var lastMuxedVideoSeconds = 0.0

        func startMuxer(formatHint: CMFormatDescription) throws {
            let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: formatHint)
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else {
                throw NSError(domain: "NativeScreenExport", code: -6, userInfo: [NSLocalizedDescriptionKey: String(localized: "Cannot configure MP4 passthrough muxer.")])
            }
            writer.add(input)
            if audioPipeline != nil {
                let aSettings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 48_000,
                    AVNumberOfChannelsKey: 2,
                    AVEncoderBitRateKey: 160_000
                ]
                let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: aSettings)
                aInput.expectsMediaDataInRealTime = false
                if writer.canAdd(aInput) {
                    writer.add(aInput)
                    muxAudioInput = aInput
                } else {
                    isAudioDone = true
                }
            }
            writer.startWriting()
            writer.startSession(atSourceTime: .zero)
            muxWriter = writer
            muxInput = input
        }

        /// Appends every in-order video sample the muxer can take, and audio up to ~1s past the muxed video
        /// (interleaving both keeps `AVAssetWriter` from stalling at `isReadyForMoreMediaData = false`).
        func drainMuxer(encodersFinished: Bool) throws {
            if nextVideoSample == nil {
                nextVideoSample = ordered.popNext()
            }
            if muxWriter == nil {
                guard let first = nextVideoSample else { return }
                guard let formatDesc = CMSampleBufferGetFormatDescription(first) else {
                    throw NSError(domain: "NativeScreenExport", code: -5, userInfo: [NSLocalizedDescriptionKey: String(localized: "No video frames were encoded.")])
                }
                try startMuxer(formatHint: formatDesc)
                muxDescription = formatDesc
            }
            guard let writer = muxWriter, let input = muxInput else { return }
            if writer.status == .failed {
                throw writer.error ?? NSError(domain: "NativeScreenExport", code: -7, userInfo: [NSLocalizedDescriptionKey: String(localized: "MP4 muxer failed.")])
            }

            while !isVideoInputFinished, input.isReadyForMoreMediaData, let encoded = nextVideoSample {
                let sample = (codecOption == .h264 && muxDescription != nil)
                    ? try H264InBandParameterSets.rewrite(encoded, sharedDescription: muxDescription!)
                    : encoded
                guard input.append(sample) else {
                    throw writer.error ?? NSError(domain: "NativeScreenExport", code: -7, userInfo: [NSLocalizedDescriptionKey: String(localized: "MP4 muxer failed.")])
                }
                lastMuxedVideoSeconds = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
                nextVideoSample = ordered.popNext()
            }
            if !isVideoInputFinished, encodersFinished, nextVideoSample == nil, ordered.orderedFrameCount >= totalFrames {
                isVideoInputFinished = true
                input.markAsFinished()
            }

            if !isAudioDone, let aInput = muxAudioInput, let audioFeed {
                audioLoop: while !isAudioDone && aInput.isReadyForMoreMediaData {
                    let aSample: CMSampleBuffer
                    if let pendingAudioSample {
                        aSample = pendingAudioSample
                    } else {
                        switch audioFeed.next() {
                        case .sample(let next):
                            aSample = next
                        case .notReady:
                            break audioLoop
                        case .finished:
                            isAudioDone = true
                            aInput.markAsFinished()
                            break audioLoop
                        }
                    }
                    let aSeconds = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(aSample))
                    // Hold audio back only while the video input could take more frames (we are just waiting on the
                    // encoders). If the writer refuses video, it is waiting for audio, so audio must keep flowing.
                    if !isVideoInputFinished && input.isReadyForMoreMediaData && aSeconds > lastMuxedVideoSeconds + 1.0 {
                        pendingAudioSample = aSample
                        break
                    }
                    pendingAudioSample = nil
                    if !aInput.append(aSample) {
                        isAudioDone = true
                        aInput.markAsFinished()
                    }
                }
            }
        }

        var pacer = MainActorExportPacer()
        func reportProgress(_ local: Double, force: Bool = false) {
            pacer.reportProgress(progressRange.0 + local * (progressRange.1 - progressRange.0), force: force, onProgress)
        }

        do {
            var nextGOP = 0
            while true {
                try Task.checkCancellation()
                var submittedFrame = false

                for lane in lanes {
                    // The software lane waits until the Media Engine has produced enough frames to measure its bitrate,
                    // so its very first GOP is already rate-matched.
                    let softwareLaneNeedsCalibration = hwWorker != nil && !lane.worker.isHardware && ordered.hardwareBitsPerFrame() == nil && nextGOP < gopCount - 1
                    if lane.gopIndex == nil, !softwareLaneNeedsCalibration, nextGOP < gopCount, nextGOP <= ordered.orderedFrameCount / gopSize + maxGOPLead {
                        lane.gopIndex = nextGOP
                        lane.nextFrameIndex = nextGOP * gopSize
                        lane.needsFlush = false
                        nextGOP += 1
                        startPrefetch(lane)
                        if !lane.worker.isHardware, let bitsPerFrame = ordered.hardwareBitsPerFrame() {
                            lane.worker.setAverageBitRate(max(600_000, Int(bitsPerFrame * Double(fps))))
                        }
                    }
                    if lane.gopIndex == nil && lane.needsFlush {
                        lane.needsFlush = false
                        lane.worker.flushPendingFrames()
                    }
                    guard let gop = lane.gopIndex, lane.worker.hasCapacity else { continue }

                    let frameIdx = lane.nextFrameIndex
                    let frameSourceMs = sourceMs(frameIdx)
                    let frames = await (lane.prefetch ?? Task { await lane.source.frames(atSourceMs: frameSourceMs) }).value
                    lane.prefetch = nil
                    try Task.checkCancellation()
                    await compositor.prepareExportFrame(webcamFrame: frames.webcam, sourceTimeMs: frameSourceMs, session: session)
                    try Task.checkCancellation()
                    autoreleasepool {
                        let composited = compositor.composeFrame(
                            sourceVideoFrame: frames.screen,
                            sourceTimeMs: frameSourceMs,
                            session: session,
                            outputSize: outputSize,
                            includeShortcutOverlay: true,
                            webcamVideoFrame: frames.webcam
                        )
                        guard let pixelBuffer = lane.worker.allocatePixelBuffer() else {
                            ordered.deliver(frameIndex: frameIdx, sample: nil, fromHardware: lane.worker.isHardware)
                            return
                        }
                        let destination = CIRenderDestination(pixelBuffer: pixelBuffer)
                        destination.colorSpace = colorSpace
                        // Async GPU render: the lane's work queue waits for it, the main actor moves on.
                        let task = try? compositor.ciContext.startTask(
                            toRender: composited,
                            from: CGRect(origin: .zero, size: outputSize),
                            to: destination,
                            at: .zero
                        )
                        lane.worker.submitFrame(
                            renderTask: task,
                            pixelBuffer: pixelBuffer,
                            frameIndex: frameIdx,
                            pts: CMTime(value: CMTimeValue(frameIdx), timescale: CMTimeScale(fps)),
                            duration: frameDuration,
                            forceKeyframe: frameIdx % gopSize == 0
                        )
                    }
                    submittedFrame = true

                    lane.nextFrameIndex += 1
                    if lane.nextFrameIndex >= min(totalFrames, (gop + 1) * gopSize) {
                        lane.gopIndex = nil
                        lane.needsFlush = true
                    } else {
                        startPrefetch(lane)
                    }
                }

                try drainMuxer(encodersFinished: false)
                reportProgress(Double(ordered.encodedFrameCount) / Double(totalFrames) * 0.98)

                if nextGOP >= gopCount && lanes.allSatisfy({ $0.gopIndex == nil }) {
                    break
                }
                if submittedFrame {
                    try await pacer.yieldIfNeeded()
                } else {
                    try await Task.sleep(for: .milliseconds(1))
                }
            }

            lanes.forEach { $0.source.cancel() }

            // Flush both encoders off the main actor. At most `maxGOPLead` GOPs are still in flight here.
            await Task.detached(priority: .userInitiated) {
                hwWorker?.finishAndWait()
                swWorker?.finishAndWait()
            }.value
            try Task.checkCancellation()

            while !isVideoInputFinished || !isAudioDone {
                try Task.checkCancellation()
                try drainMuxer(encodersFinished: true)
                if muxWriter == nil {
                    throw NSError(domain: "NativeScreenExport", code: -5, userInfo: [NSLocalizedDescriptionKey: String(localized: "No video frames were encoded.")])
                }
                if !isVideoInputFinished || !isAudioDone {
                    try await Task.sleep(for: .milliseconds(1))
                }
            }

            audioFeed?.cancel()
            audioPipeline?.reader.cancelReading()
            await muxWriter?.finishWriting()
            if let writer = muxWriter, writer.status == .failed {
                throw writer.error ?? NSError(domain: "NativeScreenExport", code: -7, userInfo: [NSLocalizedDescriptionKey: String(localized: "MP4 muxer failed.")])
            }
            reportProgress(1.0, force: true)
        } catch {
            lanes.forEach { $0.prefetch?.cancel(); $0.source.cancel() }
            hwWorker?.cancel()
            swWorker?.cancel()
            audioFeed?.cancel()
            audioPipeline?.reader.cancelReading()
            muxWriter?.cancelWriting()
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
    }

    /// Whether the hardware encoder can really encode this size. Some refuse the session, and some accept it and then
    /// fail every frame, so one frame goes through a separate session that is thrown away (its timestamp would clash).
    private nonisolated static func hardwareEncoderWorks(
        width: Int,
        height: Int,
        codecType: CMVideoCodecType,
        quality: Double,
        bitrate: Int,
        fps: Int
    ) -> Bool {
        guard let probe = VTParallelCompressionWorker(
            width: width,
            height: height,
            codecType: codecType,
            useHardware: true,
            quality: quality,
            bitrate: bitrate,
            fps: fps,
            label: "com.nativescreen.export.vt.probe",
            onEncoded: { _, _ in }
        ) else { return false }
        defer { probe.finishAndWait() }
        return probe.encodesFrame()
    }

    @MainActor
    private static func exportProResVideoFile(
        session: ProjectSession,
        outputURL: URL,
        avCodec: AVVideoCodecType,
        outputSize: CGSize,
        fps: Int,
        progressRange: (Double, Double),
        onProgress: @escaping @MainActor (Double) -> Void
    ) async throws {
        guard let compositor = MetalFrameCompositor() else {
            throw NSError(domain: "NativeScreenExport", code: -1, userInfo: [NSLocalizedDescriptionKey: String(localized: "GPU compositor unavailable.")])
        }

        let targetW = Int(outputSize.width)
        let targetH = Int(outputSize.height)

        try? FileManager.default.removeItem(at: outputURL)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: avCodec,
            AVVideoWidthKey: targetW,
            AVVideoHeightKey: targetH
        ]

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
            throw NSError(domain: "NativeScreenExport", code: -2, userInfo: [NSLocalizedDescriptionKey: String(localized: "Cannot configure ProRes video writer input.")])
        }
        writer.add(writerInput)

        let audioPipeline = await buildMultiTrackAudioReaderAndOutput(session: session)
        var proResAudioInput: AVAssetWriterInput? = nil
        if audioPipeline != nil {
            let aSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
            let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: aSettings)
            aInput.expectsMediaDataInRealTime = false
            if writer.canAdd(aInput) {
                writer.add(aInput)
                proResAudioInput = aInput
            }
        }

        func writerFailure() -> Error {
            writer.error ?? NSError(domain: "NativeScreenExport", code: -7, userInfo: [NSLocalizedDescriptionKey: String(localized: "The video file could not be written.")])
        }

        guard writer.startWriting() else { throw writerFailure() }
        writer.startSession(atSourceTime: .zero)

        let totalDurationMs = session.timeMapper.totalTimelineDurationMs
        let frameStepMs = 1000.0 / Double(fps)
        let totalFrames = max(1, Int(ceil(totalDurationMs / frameStepMs)))

        let frameSource = await ExportFrameSource.make(session: session)

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        var pacer = MainActorExportPacer()
        var isProResAudioDone = (proResAudioInput == nil || audioPipeline == nil)
        if isProResAudioDone {
            proResAudioInput?.markAsFinished()
        }
        let audioFeed = isProResAudioDone ? nil : audioPipeline.map { BufferedAudioSamples(output: $0.output) }

        func drainReadyProResAudioSamples() {
            guard !isProResAudioDone,
                  let aInput = proResAudioInput,
                  let audioFeed else { return }
            audioLoop: while !isProResAudioDone && aInput.isReadyForMoreMediaData {
                switch audioFeed.next() {
                case .sample(let aSample):
                    if !aInput.append(aSample) {
                        isProResAudioDone = true
                        aInput.markAsFinished()
                    }
                case .notReady:
                    break audioLoop
                case .finished:
                    isProResAudioDone = true
                    aInput.markAsFinished()
                }
            }
        }

        do {
            for frameIdx in 0..<totalFrames {
                try Task.checkCancellation()

                while !writerInput.isReadyForMoreMediaData {
                    try Task.checkCancellation()
                    if writer.status == .failed { throw writerFailure() }
                    drainReadyProResAudioSamples()
                    try await Task.sleep(for: .milliseconds(2))
                }

                let timelineMs = Double(frameIdx) * frameStepMs
                let sourceMs = session.timeMapper.sourceTime(forTimelineMs: timelineMs).sourceMs
                let frames = await frameSource.frames(atSourceMs: sourceMs)

                try Task.checkCancellation()
                await compositor.prepareExportFrame(webcamFrame: frames.webcam, sourceTimeMs: sourceMs, session: session)
                try Task.checkCancellation()

                let composited = autoreleasepool {
                    compositor.composeFrame(
                        sourceVideoFrame: frames.screen,
                        sourceTimeMs: sourceMs,
                        session: session,
                        outputSize: outputSize,
                        includeShortcutOverlay: true,
                        webcamVideoFrame: frames.webcam
                    )
                }

                if let pool = adaptor.pixelBufferPool {
                    var pixelBufferOut: CVPixelBuffer?
                    CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBufferOut)

                    if let pixelBufferOut {
                        nonisolated(unsafe) let pixelBuffer = pixelBufferOut
                        let context = compositor.ciContext
                        await Task.detached(priority: .userInitiated) {
                            autoreleasepool {
                                context.render(
                                    composited,
                                    to: pixelBuffer,
                                    bounds: CGRect(origin: .zero, size: outputSize),
                                    colorSpace: colorSpace
                                )
                            }
                        }.value
                        let pts = CMTime(value: CMTimeValue(frameIdx), timescale: CMTimeScale(fps))
                        guard adaptor.append(pixelBuffer, withPresentationTime: pts) else { throw writerFailure() }
                    }
                }

                drainReadyProResAudioSamples()

                let localProgress = Double(frameIdx + 1) / Double(totalFrames)
                pacer.reportProgress(progressRange.0 + localProgress * (progressRange.1 - progressRange.0), onProgress)
                try await pacer.yieldIfNeeded()
            }

            try Task.checkCancellation()
            frameSource.cancel()
            writerInput.markAsFinished()

            while !isProResAudioDone {
                try Task.checkCancellation()
                drainReadyProResAudioSamples()
                if !isProResAudioDone {
                    try await Task.sleep(for: .milliseconds(1))
                }
            }

            audioFeed?.cancel()
            audioPipeline?.reader.cancelReading()
            await writer.finishWriting()
            if writer.status != .completed { throw writerFailure() }
            onProgress(progressRange.1)
        } catch {
            frameSource.cancel()
            audioFeed?.cancel()
            audioPipeline?.reader.cancelReading()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
    }

    // MARK: - 4. Multi-Track NLE Audio Mixdown (`display.mp4` + `microphone.m4a` + `VoiceoverSegment`s + `BackgroundMusicConfig`)

    /// `setVolume(_:at:)` fades from one point to the next during export, so a change must be a constant ramp to be a step.
    private static func setConstantVolume(_ volume: Float, on params: AVMutableAudioMixInputParameters, in range: CMTimeRange) {
        params.setVolumeRamp(fromStartVolume: volume, toEndVolume: volume, timeRange: range)
    }

    @MainActor
    private static func buildMultiTrackAudioReaderAndOutput(
        session: ProjectSession
    ) async -> (reader: AVAssetReader, output: AVAssetReaderAudioMixOutput)? {
        let doc = session.document
        let masterVol = Float(max(0.0, min(2.0, doc.audio.masterVolume)))
        guard masterVol > 0.001 else { return nil }

        let composition = AVMutableComposition()
        var mixParams: [AVMutableAudioMixInputParameters] = []
        let mappedSlices = session.timeMapper.mappedSlices
        let totalTimelineSec = max(0.1, session.timeMapper.totalTimelineDurationMs / 1000.0)

        // 1. System Audio Track (`display.mp4`) across edited `ClipSlice`s
        if !doc.audio.muteSystemAudio && doc.audio.systemAudioVolume > 0.001 {
            let sysURL = session.videoFileURL
            if FileManager.default.fileExists(atPath: sysURL.path) {
                let sysAsset = AVURLAsset(url: sysURL)
                let sysAssetDurSec = max(0.0, CMTimeGetSeconds((try? await sysAsset.load(.duration)) ?? .zero))
                if sysAssetDurSec > 0.05,
                   let sysAudioTracks = try? await sysAsset.loadTracks(withMediaType: .audio),
                   let srcSysTrack = sysAudioTracks.first,
                   let compSysTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                    let params = AVMutableAudioMixInputParameters(track: compSysTrack)
                    var hasInsertedAny = false
                    for mapped in mappedSlices {
                        let slice = mapped.slice
                        let startSec = slice.sourceStartMs / 1000.0
                        let availSec = max(0.0, min(slice.sourceDurationMs / 1000.0, sysAssetDurSec - startSec))
                        guard availSec > 0.02 else { continue }
                        let sliceStartCM = CMTime(seconds: startSec, preferredTimescale: 600)
                        let sliceDurCM = CMTime(seconds: availSec, preferredTimescale: 600)
                        let destStartCM = CMTime(seconds: mapped.timelineStartMs / 1000.0, preferredTimescale: 600)
                        let destDurCM = CMTime(seconds: availSec / max(0.1, slice.speed), preferredTimescale: 600)
                        if (try? compSysTrack.insertTimeRange(CMTimeRange(start: sliceStartCM, duration: sliceDurCM), of: srcSysTrack, at: destStartCM)) != nil {
                            if abs(slice.speed - 1.0) > 0.01 {
                                compSysTrack.scaleTimeRange(CMTimeRange(start: destStartCM, duration: sliceDurCM), toDuration: destDurCM)
                            }
                            let vol = slice.muted ? Float(0.0) : Float(min(1.0, max(0.0, slice.systemAudioVolume * doc.audio.systemAudioVolume * Double(masterVol))))
                            setConstantVolume(vol, on: params, in: CMTimeRange(start: destStartCM, duration: destDurCM))
                            hasInsertedAny = true
                        }
                    }
                    if hasInsertedAny {
                        mixParams.append(params)
                    } else {
                        composition.removeTrack(compSysTrack)
                    }
                }
            }
        }

        // 2. Recorded Microphone Track (`microphone.m4a`) across edited `ClipSlice`s (respecting `VoiceoverSegment.hideRecording`)
        if !doc.audio.muteMicrophone && doc.audio.microphoneVolume > 0.001,
           let micURL = session.microphoneAudioFileURL,
           FileManager.default.fileExists(atPath: micURL.path) {
            let micAsset = AVURLAsset(url: micURL)
            let micAssetDurSec = max(0.0, CMTimeGetSeconds((try? await micAsset.load(.duration)) ?? .zero))
            if micAssetDurSec > 0.05,
               let micTracks = try? await micAsset.loadTracks(withMediaType: .audio),
               let srcMicTrack = micTracks.first,
               let compMicTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                let params = AVMutableAudioMixInputParameters(track: compMicTrack)
                var hasInsertedAny = false
                // Where a voiceover replaces the recording, the microphone stays silent, as it does in the preview.
                let hidingVoiceovers = doc.timeline.voiceovers
                    .filter { !$0.disabled && $0.hideRecording && !doc.timeline.isVoiceoverTrackHidden($0.trackIndex) }
                    .sorted { $0.sourceStartMs < $1.sourceStartMs }
                for mapped in mappedSlices {
                    let slice = mapped.slice
                    let startSec = slice.sourceStartMs / 1000.0
                    let availSec = max(0.0, min(slice.sourceDurationMs / 1000.0, micAssetDurSec - startSec))
                    guard availSec > 0.02 else { continue }
                    let sliceStartCM = CMTime(seconds: startSec, preferredTimescale: 600)
                    let sliceDurCM = CMTime(seconds: availSec, preferredTimescale: 600)
                    let destStartCM = CMTime(seconds: mapped.timelineStartMs / 1000.0, preferredTimescale: 600)
                    let destDurCM = CMTime(seconds: availSec / max(0.1, slice.speed), preferredTimescale: 600)
                    if (try? compMicTrack.insertTimeRange(CMTimeRange(start: sliceStartCM, duration: sliceDurCM), of: srcMicTrack, at: destStartCM)) != nil {
                        if abs(slice.speed - 1.0) > 0.01 {
                            compMicTrack.scaleTimeRange(CMTimeRange(start: destStartCM, duration: sliceDurCM), toDuration: destDurCM)
                        }
                        let baseVol = slice.muted ? Float(0.0) : Float(min(1.0, max(0.0, slice.microphoneVolume * doc.audio.microphoneVolume * Double(masterVol))))

                        // The parts of this slice under a hiding voiceover, merged where voiceovers overlap.
                        var mutedRanges: [(start: Double, end: Double)] = []
                        for vo in hidingVoiceovers where vo.sourceEndMs > slice.sourceStartMs && vo.sourceStartMs < slice.sourceEndMs {
                            let start = max(vo.sourceStartMs, slice.sourceStartMs)
                            let end = min(vo.sourceEndMs, slice.sourceEndMs)
                            if let last = mutedRanges.last, start <= last.end {
                                mutedRanges[mutedRanges.count - 1].end = max(last.end, end)
                            } else {
                                mutedRanges.append((start, end))
                            }
                        }
                        func setVolume(_ volume: Float, fromSourceMs start: Double, toSourceMs end: Double) {
                            guard end > start else { return }
                            func timeline(_ sourceMs: Double) -> CMTime {
                                CMTime(seconds: (mapped.timelineStartMs + (sourceMs - slice.sourceStartMs) / max(0.1, slice.speed)) / 1000.0, preferredTimescale: 600)
                            }
                            setConstantVolume(volume, on: params, in: CMTimeRange(start: timeline(start), end: timeline(end)))
                        }
                        let sourceEndMs = slice.sourceStartMs + availSec * 1000.0
                        var cursorMs = slice.sourceStartMs
                        for range in mutedRanges {
                            setVolume(baseVol, fromSourceMs: cursorMs, toSourceMs: min(range.start, sourceEndMs))
                            setVolume(0.0, fromSourceMs: range.start, toSourceMs: min(range.end, sourceEndMs))
                            cursorMs = range.end
                        }
                        setVolume(baseVol, fromSourceMs: cursorMs, toSourceMs: sourceEndMs)
                        hasInsertedAny = true
                    }
                }

                if hasInsertedAny {
                    mixParams.append(params)
                } else {
                    composition.removeTrack(compMicTrack)
                }
            }
        }

        // 3. Voiceover Segments (`doc.timeline.voiceovers`)
        for vo in doc.timeline.voiceovers where !vo.disabled && vo.volume > 0.001 && !doc.timeline.isVoiceoverTrackHidden(vo.trackIndex) {
            let voURL = session.packageURL.appendingPathComponent(vo.relativePath)
            guard FileManager.default.fileExists(atPath: voURL.path) else { continue }
            let voAsset = AVURLAsset(url: voURL)
            guard let voTracks = try? await voAsset.loadTracks(withMediaType: .audio),
                  let srcVOTrack = voTracks.first,
                  let compVOTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                continue
            }
            let assetDur = (try? await voAsset.load(.duration)) ?? CMTime(seconds: vo.durationMs / 1000.0, preferredTimescale: 600)
            let startTimelineMs = session.timeMapper.timelineTime(forSourceMs: vo.sourceStartMs) ?? vo.sourceStartMs
            let destStartCM = CMTime(seconds: max(0.0, startTimelineMs / 1000.0), preferredTimescale: 600)
            let fileOffsetSec = vo.fileOffsetMs / 1000.0
            // Bounded by the segment's own length, or the first half of a cut would play on over the second.
            let clipDurSec = min(
                vo.durationMs / 1000.0,
                CMTimeGetSeconds(assetDur) - fileOffsetSec,
                max(0.1, totalTimelineSec - CMTimeGetSeconds(destStartCM))
            )
            guard clipDurSec > 0.05 else {
                composition.removeTrack(compVOTrack)
                continue
            }
            let insertRange = CMTimeRange(
                start: CMTime(seconds: fileOffsetSec, preferredTimescale: 600),
                duration: CMTime(seconds: clipDurSec, preferredTimescale: 600)
            )
            if (try? compVOTrack.insertTimeRange(insertRange, of: srcVOTrack, at: destStartCM)) != nil {
                let params = AVMutableAudioMixInputParameters(track: compVOTrack)
                params.setVolume(Float(min(1.0, max(0.0, vo.volume * Double(masterVol)))), at: destStartCM)
                mixParams.append(params)
            } else {
                composition.removeTrack(compVOTrack)
            }
        }


        // 4. Background Audio Track (`doc.audio.backgroundMusic`, looping across `totalTimelineSec`)
        if !doc.audio.backgroundMusic.muted && doc.audio.backgroundMusic.volume > 0.001,
           let bgURL = session.resolvedBackgroundAudioFileURL(),
           FileManager.default.fileExists(atPath: bgURL.path) {
            let bgAsset = AVURLAsset(url: bgURL)
            if let bgTracks = try? await bgAsset.loadTracks(withMediaType: .audio),
               let srcBgTrack = bgTracks.first,
               let compBgTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                let assetDurCM = (try? await bgAsset.load(.duration)) ?? CMTime(seconds: 8.0, preferredTimescale: 600)
                let assetDurSec = max(0.5, CMTimeGetSeconds(assetDurCM))
                var cursorSec = 0.0
                var hasInsertedAny = false
                while cursorSec < totalTimelineSec - 0.02 {
                    let chunkSec = min(assetDurSec, totalTimelineSec - cursorSec)
                    let range = CMTimeRange(start: .zero, duration: CMTime(seconds: chunkSec, preferredTimescale: 600))
                    let destCM = CMTime(seconds: cursorSec, preferredTimescale: 600)
                    if (try? compBgTrack.insertTimeRange(range, of: srcBgTrack, at: destCM)) != nil {
                        hasInsertedAny = true
                    } else {
                        break
                    }
                    cursorSec += chunkSec
                }
                if hasInsertedAny {
                    let params = AVMutableAudioMixInputParameters(track: compBgTrack)
                    let bgVol = Float(min(1.0, max(0.0, doc.audio.backgroundMusic.volume * Double(masterVol) * 2.5)))
                    params.setVolume(bgVol, at: .zero)
                    mixParams.append(params)
                } else {
                    composition.removeTrack(compBgTrack)
                }
            }
        }

        let audioTracks = composition.tracks(withMediaType: .audio)
        guard !audioTracks.isEmpty,
              let reader = try? AVAssetReader(asset: composition) else {
            return nil
        }
        reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: totalTimelineSec, preferredTimescale: 600))

        let pcmSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let mixOutput = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: pcmSettings)
        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = mixParams
        mixOutput.audioMix = audioMix
        mixOutput.alwaysCopiesSampleData = false

        guard reader.canAdd(mixOutput) else { return nil }
        reader.add(mixOutput)
        guard reader.startReading() else { return nil }
        return (reader, mixOutput)
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
            throw NSError(domain: "NativeScreenExport", code: -1, userInfo: [NSLocalizedDescriptionKey: String(localized: "GPU compositor unavailable.")])
        }

        try? FileManager.default.removeItem(at: outputURL)

        let totalDurationMs = session.timeMapper.totalTimelineDurationMs
        let frameStepMs = 1000.0 / Double(fps)
        let totalFrames = max(1, Int(ceil(totalDurationMs / frameStepMs)))

        let writer = try StreamingGIFWriter(
            url: outputURL,
            width: Int(outputSize.width),
            height: Int(outputSize.height),
            loops: !disableLoop
        )

        // GIF delays are whole centiseconds. Rounding the running total keeps a 30 fps GIF at its real length.
        func delayCentiseconds(ofFrame index: Int) -> Int {
            func centiseconds(_ frames: Int) -> Int { Int((Double(frames) * 100.0 / Double(fps)).rounded()) }
            return centiseconds(index + 1) - centiseconds(index)
        }

        let frameSource = await ExportFrameSource.make(session: session)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        var pacer = MainActorExportPacer()

        do {
            for frameIdx in 0..<totalFrames {
                try Task.checkCancellation()

                let timelineMs = Double(frameIdx) * frameStepMs
                let sourceMs = session.timeMapper.sourceTime(forTimelineMs: timelineMs).sourceMs
                let frames = await frameSource.frames(atSourceMs: sourceMs)

                try Task.checkCancellation()
                await compositor.prepareExportFrame(webcamFrame: frames.webcam, sourceTimeMs: sourceMs, session: session)
                try Task.checkCancellation()
                let composited = autoreleasepool {
                    compositor.composeFrame(
                        sourceVideoFrame: frames.screen,
                        sourceTimeMs: sourceMs,
                        session: session,
                        outputSize: outputSize,
                        includeShortcutOverlay: true,
                        webcamVideoFrame: frames.webcam
                    )
                }
                let context = compositor.ciContext
                let delay = delayCentiseconds(ofFrame: frameIdx)
                // Rendering waits for the GPU and encoding takes a while, so neither runs on the main actor.
                try await Task.detached(priority: .userInitiated) {
                    try autoreleasepool {
                        if let cgImage = context.createCGImage(
                            composited,
                            from: CGRect(origin: .zero, size: outputSize),
                            format: .RGBA8,
                            colorSpace: colorSpace
                        ) {
                            try writer.append(cgImage, delayCentiseconds: delay)
                        }
                    }
                }.value

                pacer.reportProgress(Double(frameIdx + 1) / Double(totalFrames), onProgress)
                try await pacer.yieldIfNeeded()
            }

            try Task.checkCancellation()
            frameSource.cancel()
            try writer.finish()
            onProgress(1.0)
        } catch {
            frameSource.cancel()
            writer.abandon()
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
    }

    /// Writes an animated GIF straight to disk. `CGImageDestination` keeps every added image until it finalizes, which
    /// took 11 GB for a 12 s clip, so each frame is encoded alone and its blocks are copied into one file (ADR-68).
    private nonisolated final class StreamingGIFWriter: @unchecked Sendable {
        private let handle: FileHandle
        private let width: Int
        private let height: Int
        private var previousPixels: CFData?
        private var pendingFrame: Data?
        private var pendingTransparentIndex: UInt8?
        private var pendingDelay = 0

        private static func error(_ message: String) -> NSError {
            NSError(domain: "NativeScreenExport", code: -3, userInfo: [NSLocalizedDescriptionKey: message])
        }

        init(url: URL, width: Int, height: Int, loops: Bool) throws {
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw Self.error(String(localized: "Cannot create GIF file."))
            }
            handle = try FileHandle(forWritingTo: url)
            self.width = width
            self.height = height

            var header = Data("GIF89a".utf8)
            Self.appendUInt16(width, to: &header)
            Self.appendUInt16(height, to: &header)
            header.append(contentsOf: [0x70, 0, 0]) // no global color table: every frame carries its own palette
            if loops {
                header.append(contentsOf: [0x21, 0xFF, 0x0B])
                header.append(Data("NETSCAPE2.0".utf8))
                header.append(contentsOf: [0x03, 0x01, 0x00, 0x00, 0x00]) // 0 = forever
            }
            try handle.write(contentsOf: header)
        }

        /// Only the part that changed is stored, and a frame identical to the last one just extends its delay. Each
        /// frame is held back until the next one arrives, because its delay is written in front of its pixels.
        func append(_ image: CGImage, delayCentiseconds: Int) throws {
            let pixels = image.dataProvider?.data
            var region = CGRect(x: 0, y: 0, width: width, height: height)
            if let pixels, let previousPixels, image.width == width, image.height == height {
                if let changed = Self.changedRect(from: previousPixels, to: pixels, width: width, height: height, bytesPerRow: image.bytesPerRow) {
                    region = changed
                } else if pendingDelay + delayCentiseconds <= Int(UInt16.max) {
                    pendingDelay += delayCentiseconds
                    return
                } else {
                    region = CGRect(x: 0, y: 0, width: 1, height: 1)
                }
            }
            guard let patch = image.cropping(to: region),
                  let frame = autoreleasepool(invoking: { Self.encodedFrame(patch) }),
                  let parsed = Self.parse(frame) else {
                throw Self.error(String(localized: "Cannot encode GIF frame."))
            }
            try writePendingFrame()

            var block = Data([0x2C])
            Self.appendUInt16(Int(region.minX), to: &block)
            Self.appendUInt16(Int(region.minY), to: &block)
            Self.appendUInt16(Int(region.width), to: &block)
            Self.appendUInt16(Int(region.height), to: &block)
            block.append(0x80 | parsed.colorTableSizeBits)
            block.append(frame[parsed.colorTable])
            block.append(frame[parsed.imageData])
            pendingFrame = block
            pendingTransparentIndex = parsed.transparentIndex
            pendingDelay = delayCentiseconds
            previousPixels = pixels
        }

        func finish() throws {
            try writePendingFrame()
            try handle.write(contentsOf: Data([0x3B]))
            try handle.close()
        }

        private func writePendingFrame() throws {
            guard let pendingFrame else { return }
            var control = Data([0x21, 0xF9, 0x04, 0x04 | (pendingTransparentIndex == nil ? 0 : 1)]) // keep the previous frame
            Self.appendUInt16(pendingDelay, to: &control)
            control.append(contentsOf: [pendingTransparentIndex ?? 0, 0])
            try handle.write(contentsOf: control)
            try handle.write(contentsOf: pendingFrame)
            self.pendingFrame = nil
        }

        /// The smallest rectangle holding every pixel that differs, or `nil` when the two images are identical.
        private static func changedRect(from old: CFData, to new: CFData, width: Int, height: Int, bytesPerRow: Int) -> CGRect? {
            guard CFDataGetLength(old) == CFDataGetLength(new), CFDataGetLength(new) >= bytesPerRow * height,
                  let a = CFDataGetBytePtr(old), let b = CFDataGetBytePtr(new) else {
                return CGRect(x: 0, y: 0, width: width, height: height)
            }
            let rowBytes = width * 4
            var top = 0
            while top < height, memcmp(a + top * bytesPerRow, b + top * bytesPerRow, rowBytes) == 0 { top += 1 }
            guard top < height else { return nil }
            var bottom = height - 1
            while bottom > top, memcmp(a + bottom * bytesPerRow, b + bottom * bytesPerRow, rowBytes) == 0 { bottom -= 1 }

            var left = width
            var right = -1
            for y in top...bottom {
                let rowA = a + y * bytesPerRow
                let rowB = b + y * bytesPerRow
                guard memcmp(rowA, rowB, rowBytes) != 0 else { continue }
                var x = 0
                while x < left, memcmp(rowA + x * 4, rowB + x * 4, 4) == 0 { x += 1 }
                left = min(left, x)
                x = width - 1
                while x > right, memcmp(rowA + x * 4, rowB + x * 4, 4) == 0 { x -= 1 }
                right = max(right, x)
            }
            return CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)
        }

        func abandon() {
            try? handle.close()
        }

        private static func appendUInt16(_ value: Int, to data: inout Data) {
            data.append(UInt8(value & 0xFF))
            data.append(UInt8((value >> 8) & 0xFF))
        }

        private static func encodedFrame(_ image: CGImage) -> Data? {
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, 1, nil) else {
                return nil
            }
            CGImageDestinationAddImage(destination, image, nil)
            return CGImageDestinationFinalize(destination) ? data as Data : nil
        }

        private struct ParsedFrame {
            let colorTable: Range<Int>
            let colorTableSizeBits: UInt8
            let transparentIndex: UInt8?
            /// LZW minimum code size, sub-blocks and their terminator.
            let imageData: Range<Int>
        }

        /// Finds the palette and pixel data of a GIF holding one image. `nil` if it is not laid out as GIF requires.
        private static func parse(_ bytes: Data) -> ParsedFrame? {
            let start = bytes.startIndex
            guard bytes.count > 13 else { return nil }

            func skipSubBlocks(from index: Int) -> Int? {
                var cursor = index
                while cursor < bytes.endIndex {
                    let size = Int(bytes[cursor])
                    cursor += 1 + size
                    if size == 0 { return cursor }
                }
                return nil
            }
            func tableBytes(_ sizeBits: UInt8) -> Int { 3 << (Int(sizeBits) + 1) }

            let screenFlags = bytes[start + 10]
            var cursor = start + 13
            var globalTable: (range: Range<Int>, sizeBits: UInt8)?
            if screenFlags & 0x80 != 0 {
                let sizeBits = screenFlags & 0x07
                globalTable = (cursor..<(cursor + tableBytes(sizeBits)), sizeBits)
                cursor += tableBytes(sizeBits)
            }

            var transparentIndex: UInt8?
            while cursor < bytes.endIndex {
                switch bytes[cursor] {
                case 0x21:
                    guard cursor + 2 < bytes.endIndex else { return nil }
                    if bytes[cursor + 1] == 0xF9, cursor + 6 < bytes.endIndex, bytes[cursor + 3] & 0x01 != 0 {
                        transparentIndex = bytes[cursor + 6]
                    }
                    guard let next = skipSubBlocks(from: cursor + 2) else { return nil }
                    cursor = next
                case 0x2C:
                    guard cursor + 10 < bytes.endIndex else { return nil }
                    let flags = bytes[cursor + 9]
                    cursor += 10
                    var table = globalTable
                    if flags & 0x80 != 0 {
                        let sizeBits = flags & 0x07
                        table = (cursor..<(cursor + tableBytes(sizeBits)), sizeBits)
                        cursor += tableBytes(sizeBits)
                    }
                    guard let table, cursor < bytes.endIndex, table.range.upperBound <= bytes.endIndex,
                          let end = skipSubBlocks(from: cursor + 1), end <= bytes.endIndex else { return nil }
                    return ParsedFrame(
                        colorTable: table.range,
                        colorTableSizeBits: table.sizeBits,
                        transparentIndex: transparentIndex,
                        imageData: cursor..<end
                    )
                default:
                    return nil
                }
            }
            return nil
        }
    }
}
