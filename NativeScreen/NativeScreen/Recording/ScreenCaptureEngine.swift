import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo

/// Native macOS Screen & Audio Capture Engine powered by `ScreenCaptureKit` + `AVAssetWriter` (VideoToolbox hardware encoding).
/// Excludes the system cursor (`showsCursor = false`) and NativeScreen's own HUD windows from the captured video stream.
public final class ScreenCaptureEngine: NSObject, SCStreamOutput, SCStreamDelegate, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    private var stream: SCStream?
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var systemAudioInput: AVAssetWriterInput?

    // Optional Webcam + Microphone capture session & writers
    private var avCaptureSession: AVCaptureSession?
    private var webcamWriter: AVAssetWriter?
    private var webcamVideoInput: AVAssetWriterInput?
    private var isWebcamSessionStarted: Bool = false
    private var microphoneWriter: AVAssetWriter?
    private var microphoneAudioInput: AVAssetWriterInput?
    private var isMicrophoneSessionStarted: Bool = false

    private let videoQueue = DispatchQueue(label: "com.nativescreen.capture.video", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "com.nativescreen.capture.audio", qos: .userInteractive)
    private let avDeviceQueue = DispatchQueue(label: "com.nativescreen.capture.avdevices", qos: .userInteractive)

    private var isWritingSessionStarted = false
    private var firstSampleTime: CMTime = .invalid
    private var lastSampleTime: CMTime = .zero
    private var isPausedInternal: Bool = false
    private var pauseStartSourcePTS: CMTime = .invalid
    private var accumulatedPausedTime: CMTime = .zero

    public private(set) var recordedDurationMs: Double = 0.0
    public var onFirstVideoFrameArrived: ((TimeInterval) -> Void)?

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
        outputVideoURL: URL,
        cameraDeviceID: String? = nil,
        cameraMaxResolution: CameraMaxResolutionOption = .p1080,
        outputWebcamURL: URL? = nil,
        microphoneDeviceID: String? = nil,
        outputMicrophoneURL: URL? = nil
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

        if cameraDeviceID != nil || microphoneDeviceID != nil {
            setupAndStartAVCaptureDevices(
                cameraDeviceID: cameraDeviceID,
                cameraMaxResolution: cameraMaxResolution,
                outputWebcamURL: outputWebcamURL,
                microphoneDeviceID: microphoneDeviceID,
                outputMicrophoneURL: outputMicrophoneURL
            )
        }
    }

    private func setupAndStartAVCaptureDevices(
        cameraDeviceID: String?,
        cameraMaxResolution: CameraMaxResolutionOption,
        outputWebcamURL: URL?,
        microphoneDeviceID: String?,
        outputMicrophoneURL: URL?
    ) {
        let session = AVCaptureSession()
        session.beginConfiguration()
        switch cameraMaxResolution {
        case .p720:
            if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 }
        case .p1080:
            if session.canSetSessionPreset(.hd1920x1080) { session.sessionPreset = .hd1920x1080 }
        case .p4k:
            if session.canSetSessionPreset(.hd4K3840x2160) {
                session.sessionPreset = .hd4K3840x2160
            } else if session.canSetSessionPreset(.hd1920x1080) {
                session.sessionPreset = .hd1920x1080
            }
        }

        // 1. Webcam Video Input & Writer
        if let camID = cameraDeviceID,
           let webcamURL = outputWebcamURL,
           let camDevice = AVCaptureDevice(uniqueID: camID) ?? AVCaptureDevice.default(for: .video),
           let camInput = try? AVCaptureDeviceInput(device: camDevice),
           session.canAddInput(camInput) {
            session.addInput(camInput)

            let vOutput = AVCaptureVideoDataOutput()
            vOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
            ]
            vOutput.setSampleBufferDelegate(self, queue: avDeviceQueue)
            if session.canAddOutput(vOutput) {
                session.addOutput(vOutput)
            }

            try? FileManager.default.removeItem(at: webcamURL)
            if let wWriter = try? AVAssetWriter(outputURL: webcamURL, fileType: .mp4) {
                let targetH: Int = (cameraMaxResolution == .p720) ? 720 : ((cameraMaxResolution == .p4k) ? 2160 : 1080)
                let targetW: Int = (targetH * 16) / 9
                let wSettings: [String: Any] = [
                    AVVideoCodecKey: AVVideoCodecType.h264,
                    AVVideoWidthKey: targetW,
                    AVVideoHeightKey: targetH,
                    AVVideoCompressionPropertiesKey: [
                        AVVideoAverageBitRateKey: max(6_000_000, targetW * targetH * 3),
                        AVVideoMaxKeyFrameIntervalKey: 30,
                        AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
                    ]
                ]
                let wInput = AVAssetWriterInput(mediaType: .video, outputSettings: wSettings)
                wInput.expectsMediaDataInRealTime = true
                if wWriter.canAdd(wInput) {
                    wWriter.add(wInput)
                }
                if wWriter.startWriting() {
                    self.webcamWriter = wWriter
                    self.webcamVideoInput = wInput
                    self.isWebcamSessionStarted = false
                }
            }
        }

        // 2. Microphone Audio Input & Writer
        if let micID = microphoneDeviceID,
           let micURL = outputMicrophoneURL,
           let micDevice = AVCaptureDevice(uniqueID: micID) ?? AVCaptureDevice.default(for: .audio),
           let micInput = try? AVCaptureDeviceInput(device: micDevice),
           session.canAddInput(micInput) {
            session.addInput(micInput)

            let aOutput = AVCaptureAudioDataOutput()
            aOutput.setSampleBufferDelegate(self, queue: avDeviceQueue)
            if session.canAddOutput(aOutput) {
                session.addOutput(aOutput)
            }

            try? FileManager.default.removeItem(at: micURL)
            if let mWriter = try? AVAssetWriter(outputURL: micURL, fileType: .m4a) {
                let mSettings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 48_000,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderBitRateKey: 128_000
                ]
                let mInput = AVAssetWriterInput(mediaType: .audio, outputSettings: mSettings)
                mInput.expectsMediaDataInRealTime = true
                if mWriter.canAdd(mInput) {
                    mWriter.add(mInput)
                }
                if mWriter.startWriting() {
                    self.microphoneWriter = mWriter
                    self.microphoneAudioInput = mInput
                    self.isMicrophoneSessionStarted = false
                }
            }
        }

        session.commitConfiguration()
        self.avCaptureSession = session
        avDeviceQueue.async {
            session.startRunning()
        }
    }

    public func stopCapture() async {
        if let activeStream = stream {
            try? await activeStream.stopCapture()
            stream = nil
        }

        if let avSession = avCaptureSession {
            avCaptureSession = nil
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                avDeviceQueue.async {
                    avSession.stopRunning()
                    let group = DispatchGroup()
                    if let wWriter = self.webcamWriter {
                        self.webcamVideoInput?.markAsFinished()
                        if wWriter.status == .writing {
                            group.enter()
                            wWriter.finishWriting { group.leave() }
                        }
                        self.webcamWriter = nil
                        self.webcamVideoInput = nil
                    }
                    if let mWriter = self.microphoneWriter {
                        self.microphoneAudioInput?.markAsFinished()
                        if mWriter.status == .writing {
                            group.enter()
                            mWriter.finishWriting { group.leave() }
                        }
                        self.microphoneWriter = nil
                        self.microphoneAudioInput = nil
                    }
                    group.notify(queue: self.avDeviceQueue) {
                        cont.resume()
                    }
                }
            }
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
                // Anchor telemetry `t = 0.0ms` to the exact presentation timestamp of the first captured video frame!
                let frameUptimeSec = CMTimeGetSeconds(rawPTS)
                let nowUptime = ProcessInfo.processInfo.systemUptime
                let resolvedOriginSec = (frameUptimeSec > 1.0 && abs(nowUptime - frameUptimeSec) < 10.0) ? frameUptimeSec : nowUptime
                onFirstVideoFrameArrived?(resolvedOriginSec)
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

    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate & AVCaptureAudioDataOutputSampleBufferDelegate

    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard CMSampleBufferDataIsReady(sampleBuffer),
              !isPausedInternal else {
            return
        }

        let adjusted = Self.adjustSampleBufferTime(sampleBuffer, bySubtracting: accumulatedPausedTime) ?? sampleBuffer
        let pts = CMSampleBufferGetPresentationTimeStamp(adjusted)
        guard pts.isValid else { return }

        if output is AVCaptureVideoDataOutput {
            guard let wWriter = webcamWriter, wWriter.status == .writing,
                  let wInput = webcamVideoInput else { return }
            if !isWebcamSessionStarted {
                wWriter.startSession(atSourceTime: pts)
                isWebcamSessionStarted = true
            }
            if wInput.isReadyForMoreMediaData {
                wInput.append(adjusted)
            }
        } else if output is AVCaptureAudioDataOutput {
            guard let mWriter = microphoneWriter, mWriter.status == .writing,
                  let mInput = microphoneAudioInput else { return }
            if !isMicrophoneSessionStarted {
                mWriter.startSession(atSourceTime: pts)
                isMicrophoneSessionStarted = true
            }
            if mInput.isReadyForMoreMediaData {
                mInput.append(adjusted)
            }
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
