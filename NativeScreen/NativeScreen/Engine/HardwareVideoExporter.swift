import Foundation
import AVFoundation
import CoreImage
import CoreVideo

/// Hardware-accelerated MP4 / HEVC exporter using the exact same `MetalFrameCompositor` pipeline as the Preview Canvas.
/// Zero FFmpeg required — runs directly on Apple Silicon `VideoToolbox` Media Engine.
public final class HardwareVideoExporter {
    public enum ExportCodec: String, CaseIterable, Identifiable {
        case h264 = "H.264 (MP4)"
        case hevc = "HEVC / H.265 (MP4)"

        public var id: String { rawValue }
    }

    public enum ExportResolution: String, CaseIterable, Identifiable {
        case hd1080p = "1080p Full HD"
        case qhd2k = "1440p 2K"
        case uhd4k = "2160p 4K"

        public var id: String { rawValue }

        public var baseHeight: Double {
            switch self {
            case .hd1080p: return 1080
            case .qhd2k: return 1440
            case .uhd4k: return 2160
            }
        }
    }

    @MainActor
    public static func exportProject(
        session: ProjectSession,
        outputURL: URL,
        codec: ExportCodec = .h264,
        resolution: ExportResolution = .qhd2k,
        fps: Int = 60,
        onProgress: @escaping @MainActor (Double) -> Void
    ) async throws {
        guard let compositor = MetalFrameCompositor() else {
            throw NSError(domain: "NativeScreenExport", code: -1, userInfo: [NSLocalizedDescriptionKey: "Metal GPU device unavailable."])
        }

        let sourceW = Double(session.metadata.captureTarget.pixelSize.width)
        let sourceH = Double(session.metadata.captureTarget.pixelSize.height)
        let aspect = session.document.canvas.effectiveAspectRatio(sourceWidth: sourceW, sourceHeight: sourceH)

        let targetH = Int(resolution.baseHeight) & ~1
        let targetW = max(2, Int(Double(targetH) * aspect) & ~1)
        let outputSize = CGSize(width: targetW, height: targetH)

        try? FileManager.default.removeItem(at: outputURL)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)

        let avCodec: AVVideoCodecType = (codec == .hevc) ? .hevc : .h264
        let bitrate = max(12_000_000, targetW * targetH * 5)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: avCodec,
            AVVideoWidthKey: targetW,
            AVVideoHeightKey: targetH,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoMaxKeyFrameIntervalKey: fps * 2
            ]
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
            throw NSError(domain: "NativeScreenExport", code: -2, userInfo: [NSLocalizedDescriptionKey: "Cannot configure video writer input."])
        }
        writer.add(writerInput)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let totalDurationMs = session.timeMapper.totalTimelineDurationMs
        let frameStepMs = 1000.0 / Double(fps)
        let totalFrames = max(1, Int(ceil(totalDurationMs / frameStepMs)))

        // Optional source video frame generator if a real recorded file exists
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

        for frameIdx in 0..<totalFrames {
            while !writerInput.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(2))
            }

            let timelineMs = Double(frameIdx) * frameStepMs
            let sourceMs = session.timeMapper.sourceTime(forTimelineMs: timelineMs).sourceMs

            var sourceCIImage: CIImage?
            if let gen = imageGenerator {
                let cmTime = CMTime(seconds: sourceMs / 1000.0, preferredTimescale: 600)
                if let cgImg = try? gen.copyCGImage(at: cmTime, actualTime: nil) {
                    sourceCIImage = CIImage(cgImage: cgImg)
                }
            }

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

            if frameIdx % 5 == 0 || frameIdx == totalFrames - 1 {
                onProgress(Double(frameIdx + 1) / Double(totalFrames))
                await Task.yield()
            }
        }

        writerInput.markAsFinished()
        await writer.finishWriting()
        onProgress(1.0)
    }
}
