import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo

/// Native macOS Screen & Audio Capture Engine powered by `ScreenCaptureKit` + `AVAssetWriter` (VideoToolbox hardware encoding).
/// Excludes the system cursor (`showsCursor = false`) and NativeScreen's own HUD windows from the captured video stream.
public final class ScreenCaptureEngine: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var systemAudioInput: AVAssetWriterInput?

    private let videoQueue = DispatchQueue(label: "com.nativescreen.capture.video", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "com.nativescreen.capture.audio", qos: .userInteractive)

    private var isWritingSessionStarted = false
    private var firstSampleTime: CMTime = .invalid
    private var lastSampleTime: CMTime = .zero
    private var isPausedInternal: Bool = false
    private var pauseStartSourcePTS: CMTime = .invalid
    private var accumulatedPausedTime: CMTime = .zero

    public private(set) var recordedDurationMs: Double = 0.0

    public func setPaused(_ paused: Bool) {
        videoQueue.async {
            guard self.isPausedInternal != paused else { return }
            self.isPausedInternal = paused
            if paused {
                self.pauseStartSourcePTS = .invalid
            }
        }
    }

    public func startCapture(
        filter: SCContentFilter,
        pixelWidth: Int,
        pixelHeight: Int,
        sourceRect: CGRect?,
        captureSystemAudio: Bool,
        outputVideoURL: URL
    ) async throws {
        let config = SCStreamConfiguration()
        // VideoToolbox H.264/HEVC requires even dimensions
        let evenWidth = max(2, pixelWidth & ~1)
        let evenHeight = max(2, pixelHeight & ~1)
        config.width = evenWidth
        config.height = evenHeight
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false // Crucial: exclude hardware cursor so we render smooth spring cursor in post!
        config.queueDepth = 6
        if let rect = sourceRect {
            config.sourceRect = rect
        }
        config.capturesAudio = captureSystemAudio
        config.excludesCurrentProcessAudio = true

        // Setup AVAssetWriter (Hardware H.264 / VideoToolbox)
        try? FileManager.default.removeItem(at: outputVideoURL)
        let writer = try AVAssetWriter(outputURL: outputVideoURL, fileType: .mp4)

        let videoCompressionProps: [String: Any] = [
            AVVideoAverageBitRateKey: max(8_000_000, evenWidth * evenHeight * 4),
            AVVideoMaxKeyFrameIntervalKey: 60,
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
        ]
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: evenWidth,
            AVVideoHeightKey: evenHeight,
            AVVideoCompressionPropertiesKey: videoCompressionProps
        ]

        let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        vInput.expectsMediaDataInRealTime = true
        if writer.canAdd(vInput) {
            writer.add(vInput)
        }
        self.videoInput = vInput

        if captureSystemAudio {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192_000
            ]
            let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            aInput.expectsMediaDataInRealTime = true
            if writer.canAdd(aInput) {
                writer.add(aInput)
            }
            self.systemAudioInput = aInput
        }

        guard writer.startWriting() else {
            throw writer.error ?? NSError(domain: "NativeScreenCapture", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to start AVAssetWriter"])
        }

        self.assetWriter = writer
        self.isWritingSessionStarted = false
        self.firstSampleTime = .invalid
        self.lastSampleTime = .zero
        self.isPausedInternal = false
        self.pauseStartSourcePTS = .invalid
        self.accumulatedPausedTime = .zero

        let scStream = SCStream(filter: filter, configuration: config, delegate: self)
        try scStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        if captureSystemAudio {
            try scStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        }

        self.stream = scStream
        try await scStream.startCapture()
    }

    public func stopCapture() async {
        if let activeStream = stream {
            try? await activeStream.stopCapture()
            stream = nil
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            videoQueue.async {
                guard let writer = self.assetWriter else {
                    continuation.resume()
                    return
                }
                if self.firstSampleTime.isValid && self.lastSampleTime.isValid {
                    let delta = CMTimeSubtract(self.lastSampleTime, self.firstSampleTime)
                    self.recordedDurationMs = max(500.0, CMTimeGetSeconds(delta) * 1000.0)
                }
                self.videoInput?.markAsFinished()
                self.systemAudioInput?.markAsFinished()
                if writer.status == .writing {
                    writer.finishWriting {
                        self.assetWriter = nil
                        continuation.resume()
                    }
                } else {
                    self.assetWriter = nil
                    continuation.resume()
                }
            }
        }
    }

    // MARK: - SCStreamOutput

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard CMSampleBufferDataIsReady(sampleBuffer),
              let writer = assetWriter,
              writer.status == .writing else {
            return
        }

        switch outputType {
        case .screen:
            guard let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let attachments = attachmentsArray.first,
                  let statusRawValue = attachments[.status] as? Int,
                  let status = SCFrameStatus(rawValue: statusRawValue),
                  status == .complete,
                  CMSampleBufferGetImageBuffer(sampleBuffer) != nil else {
                return
            }

            let rawPTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            if isPausedInternal {
                if !pauseStartSourcePTS.isValid {
                    pauseStartSourcePTS = rawPTS
                }
                return
            } else if pauseStartSourcePTS.isValid {
                let pauseDelta = CMTimeSubtract(rawPTS, pauseStartSourcePTS)
                if pauseDelta.isValid && CMTimeGetSeconds(pauseDelta) > 0 {
                    accumulatedPausedTime = CMTimeAdd(accumulatedPausedTime, pauseDelta)
                }
                pauseStartSourcePTS = .invalid
            }

            let adjustedBuffer = Self.adjustSampleBufferTime(sampleBuffer, bySubtracting: accumulatedPausedTime) ?? sampleBuffer
            let pts = CMSampleBufferGetPresentationTimeStamp(adjustedBuffer)

            if !isWritingSessionStarted {
                writer.startSession(atSourceTime: pts)
                isWritingSessionStarted = true
                firstSampleTime = pts
            }
            lastSampleTime = pts

            if let vInput = videoInput, vInput.isReadyForMoreMediaData {
                vInput.append(adjustedBuffer)
            }

        case .audio:
            guard isWritingSessionStarted,
                  !isPausedInternal,
                  let aInput = systemAudioInput,
                  aInput.isReadyForMoreMediaData else {
                return
            }
            let adjustedAudio = Self.adjustSampleBufferTime(sampleBuffer, bySubtracting: accumulatedPausedTime) ?? sampleBuffer
            aInput.append(adjustedAudio)

        case .microphone:
            break

        @unknown default:
            break
        }
    }

    private static func adjustSampleBufferTime(_ sampleBuffer: CMSampleBuffer, bySubtracting offset: CMTime) -> CMSampleBuffer? {
        guard offset.isValid, CMTimeGetSeconds(offset) > 0.0001 else {
            return sampleBuffer
        }
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        guard count > 0 else { return sampleBuffer }

        var timingInfo = [CMSampleTimingInfo](
            repeating: CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .invalid, decodeTimeStamp: .invalid),
            count: count
        )
        CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: count, arrayToFill: &timingInfo, entriesNeededOut: &count)

        for i in 0..<count {
            if timingInfo[i].presentationTimeStamp.isValid {
                timingInfo[i].presentationTimeStamp = CMTimeSubtract(timingInfo[i].presentationTimeStamp, offset)
            }
            if timingInfo[i].decodeTimeStamp.isValid {
                timingInfo[i].decodeTimeStamp = CMTimeSubtract(timingInfo[i].decodeTimeStamp, offset)
            }
        }

        var adjustedBuffer: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: count,
            sampleTimingArray: &timingInfo,
            sampleBufferOut: &adjustedBuffer
        )
        return adjustedBuffer
    }
}
