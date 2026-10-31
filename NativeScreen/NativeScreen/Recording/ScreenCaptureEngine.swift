import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import CoreImage

/// Keeps the selected hardware camera session warm across HUD Preview -> Countdown -> Active Recording
/// so starting a recording NEVER restarts the camera ISP (eliminating the black/dark auto-exposure ramp-up flash
/// both when clicking Record and in the first frames of `webcam.mp4`!).
public final class WarmCameraCaptureController: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    public static let shared = WarmCameraCaptureController()

    private let cameraQueue = DispatchQueue(label: "com.nativescreen.camera.warmSession", qos: .userInteractive)
    private let stateLock = NSLock()

    private var session: AVCaptureSession?
    private var activeDevice: AVCaptureDevice?
    private var activeDeviceID: String?
    private var activeMaxResolution: CameraMaxResolutionOption = .p1080

    private var _activeDimensions: CMVideoDimensions = CMVideoDimensions(width: 1920, height: 1080)
    private var _activeFps: Int = 30
    private var _sessionStartUptime: TimeInterval = 0
    private var _deliveredFrameCount: Int = 0
    private var _onPreviewSurface: (@Sendable (IOSurfaceRef) -> Void)?
    private var _onRecordingSampleBuffer: (@Sendable (CMSampleBuffer) -> Void)?

    public var activeDimensions: CMVideoDimensions {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _activeDimensions
    }

    public var activeFps: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _activeFps
    }

    public var isCameraAdjustingOrCold: Bool {
        stateLock.lock()
        let elapsed = ProcessInfo.processInfo.systemUptime - _sessionStartUptime
        let frames = _deliveredFrameCount
        let dev = activeDevice
        stateLock.unlock()
        if frames < 12 && elapsed < 0.65 {
            return true
        }
        if elapsed < 0.75, let dev = dev, dev.isAdjustingExposure {
            return true
        }
        return false
    }

    public func setPreviewSurfaceHandler(_ handler: (@Sendable (IOSurfaceRef) -> Void)?) {
        stateLock.lock()
        _onPreviewSurface = handler
        stateLock.unlock()
    }

    public func setRecordingSampleBufferHandler(_ handler: (@Sendable (CMSampleBuffer) -> Void)?) {
        stateLock.lock()
        _onRecordingSampleBuffer = handler
        stateLock.unlock()
    }

    /// Ensures the camera `AVCaptureSession` is running for `deviceID` and `maxResolution`.
    /// If already running with the same parameters, this is a complete no-op so the camera ISP never resets!
    public func ensureWarmSession(
        deviceID: String,
        maxResolution: CameraMaxResolutionOption,
        completion: (@Sendable (CMVideoDimensions, Int) -> Void)? = nil
    ) {
        cameraQueue.async { [weak self] in
            guard let self = self else { return }
            if let existing = self.session,
               existing.isRunning,
               self.activeDeviceID == deviceID,
               self.activeMaxResolution == maxResolution {
                let dims = self.activeDimensions
                let fps = self.activeFps
                completion?(dims, fps)
                return
            }

            if let existing = self.session {
                existing.stopRunning()
                self.session = nil
                self.activeDevice = nil
                self.activeDeviceID = nil
            }

            guard let camDevice = AVCaptureDevice(uniqueID: deviceID) ?? AVCaptureDevice.default(for: .video),
                  let camInput = try? AVCaptureDeviceInput(device: camDevice) else {
                completion?(CMVideoDimensions(width: 1920, height: 1080), 30)
                return
            }

            let newSession = AVCaptureSession()
            newSession.beginConfiguration()
            switch maxResolution {
            case .p720:
                if newSession.canSetSessionPreset(.hd1280x720) { newSession.sessionPreset = .hd1280x720 }
            case .p1080:
                if newSession.canSetSessionPreset(.hd1920x1080) { newSession.sessionPreset = .hd1920x1080 }
            case .p4k:
                if newSession.canSetSessionPreset(.hd4K3840x2160) {
                    newSession.sessionPreset = .hd4K3840x2160
                } else if newSession.canSetSessionPreset(.hd1920x1080) {
                    newSession.sessionPreset = .hd1920x1080
                }
            }

            if newSession.canAddInput(camInput) {
                newSession.addInput(camInput)
            }

            let vOutput = AVCaptureVideoDataOutput()
            vOutput.alwaysDiscardsLateVideoFrames = true
            vOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
            ]
            vOutput.setSampleBufferDelegate(self, queue: self.cameraQueue)
            if newSession.canAddOutput(vOutput) {
                newSession.addOutput(vOutput)
            }
            newSession.commitConfiguration()

            // Configure format AFTER `commitConfiguration` so `AVCaptureSession` preset application never clobbers it
            let maxDimH: Int32 = (maxResolution == .p720) ? 720 : ((maxResolution == .p4k) ? 2160 : 1080)
            let configuredFps = ScreenCaptureEngine.configureHighestFrameRateFormat(on: camDevice, maxHeight: maxDimH)
            let dims = CMVideoFormatDescriptionGetDimensions(camDevice.activeFormat.formatDescription)
            let resolvedDims = (dims.width > 0 && dims.height > 0)
                ? dims
                : CMVideoDimensions(width: (maxDimH * 16) / 9, height: maxDimH)

            self.stateLock.lock()
            self._activeDimensions = resolvedDims
            self._activeFps = configuredFps
            self._sessionStartUptime = ProcessInfo.processInfo.systemUptime
            self._deliveredFrameCount = 0
            self.stateLock.unlock()

            self.session = newSession
            self.activeDevice = camDevice
            self.activeDeviceID = deviceID
            self.activeMaxResolution = maxResolution

            newSession.startRunning()
            completion?(resolvedDims, configuredFps)
        }
    }

    public func stopSession() {
        cameraQueue.async { [weak self] in
            guard let self = self else { return }
            if let existing = self.session {
                existing.stopRunning()
                self.session = nil
                self.activeDevice = nil
                self.activeDeviceID = nil
            }
        }
    }

    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }

        stateLock.lock()
        _deliveredFrameCount += 1
        let previewHandler = _onPreviewSurface
        let recordingHandler = _onRecordingSampleBuffer
        stateLock.unlock()

        if let previewHandler = previewHandler,
           let pb = CMSampleBufferGetImageBuffer(sampleBuffer),
           let surface = CVPixelBufferGetIOSurface(pb)?.takeUnretainedValue() {
            previewHandler(surface)
        }

        recordingHandler?(sampleBuffer)
    }
}

/// Keeps the selected hardware microphone session warm while the HUD is open or recording,
/// computing real-time RMS/peak audio levels (`instantLevel01` bright bar + `trailingPeakHold01` slow-decay bar)
/// and forwarding raw audio `CMSampleBuffer`s to `ScreenCaptureEngine` during recording!
public final class WarmMicrophoneCaptureController: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    public static let shared = WarmMicrophoneCaptureController()

    private let micQueue = DispatchQueue(label: "com.nativescreen.microphone.warmSession", qos: .userInteractive)
    private let stateLock = NSLock()

    private var session: AVCaptureSession?
    private var activeDeviceID: String?

    private var _instantLevel01: Double = 0.0
    private var _trailingPeakHold01: Double = 0.0
    private var _lastPeakHoldUptime: TimeInterval = 0.0
    private var _lastUIEmitUptime: TimeInterval = 0.0

    private var _onLevelUpdate: (@Sendable (String, Double, Double) -> Void)?
    private var _onRecordingSampleBuffer: (@Sendable (CMSampleBuffer) -> Void)?

    public func setLevelUpdateHandler(_ handler: (@Sendable (String, Double, Double) -> Void)?) {
        stateLock.lock()
        _onLevelUpdate = handler
        stateLock.unlock()
    }

    public func setRecordingSampleBufferHandler(_ handler: (@Sendable (CMSampleBuffer) -> Void)?) {
        stateLock.lock()
        _onRecordingSampleBuffer = handler
        stateLock.unlock()
    }

    public func ensureWarmSession(deviceID: String) {
        let authStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        if authStatus == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                guard granted else { return }
                self?.ensureWarmSession(deviceID: deviceID)
            }
            return
        }

        micQueue.async { [weak self] in
            guard let self = self else { return }
            if let existing = self.session,
               existing.isRunning,
               self.activeDeviceID == deviceID {
                return
            }

            if let existing = self.session {
                existing.stopRunning()
                self.session = nil
                self.activeDeviceID = nil
            }

            guard let micDevice = AVCaptureDevice(uniqueID: deviceID) ?? AVCaptureDevice.default(for: .audio),
                  let micInput = try? AVCaptureDeviceInput(device: micDevice) else {
                return
            }

            let newSession = AVCaptureSession()
            newSession.beginConfiguration()
            if newSession.canAddInput(micInput) {
                newSession.addInput(micInput)
            }

            let aOutput = AVCaptureAudioDataOutput()
            // Request standard 16-bit Linear PCM so both level metering and AAC `AVAssetWriter` encoding work reliably across all macOS audio devices
            aOutput.audioSettings = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
            aOutput.setSampleBufferDelegate(self, queue: self.micQueue)
            if newSession.canAddOutput(aOutput) {
                newSession.addOutput(aOutput)
            }
            newSession.commitConfiguration()

            self.stateLock.lock()
            self._instantLevel01 = 0.0
            self._trailingPeakHold01 = 0.0
            self.stateLock.unlock()

            self.session = newSession
            self.activeDeviceID = deviceID
            newSession.startRunning()
        }
    }

    public func stopSession() {
        micQueue.async { [weak self] in
            guard let self = self else { return }
            if let existing = self.session {
                existing.stopRunning()
                self.session = nil
                self.activeDeviceID = nil
            }
            self.stateLock.lock()
            self._instantLevel01 = 0.0
            self._trailingPeakHold01 = 0.0
            self.stateLock.unlock()
        }
    }

    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }

        let rawLevel01 = Self.computeNormalizedAudioLevel01(from: sampleBuffer)
        let now = ProcessInfo.processInfo.systemUptime

        stateLock.lock()
        // 1. Bright bar (`_instantLevel01`): fast attack (0.68), responsive release (0.38)
        if rawLevel01 >= _instantLevel01 {
            _instantLevel01 = _instantLevel01 * 0.32 + rawLevel01 * 0.68
        } else {
            _instantLevel01 = max(0.0, _instantLevel01 * 0.62 + rawLevel01 * 0.38)
        }

        // 2. Dimmer trailing peak-hold bar (`_trailingPeakHold01`):
        // Rises immediately with `_instantLevel01`, holds for ~90ms, then decays smoothly behind the bright bar!
        if _instantLevel01 >= _trailingPeakHold01 {
            _trailingPeakHold01 = _instantLevel01
            _lastPeakHoldUptime = now
        } else if (now - _lastPeakHoldUptime) > 0.09 {
            _trailingPeakHold01 = max(_instantLevel01, _trailingPeakHold01 * 0.86 - 0.008)
        }

        let shouldEmitUI = (now - _lastUIEmitUptime) >= 0.030
        if shouldEmitUI {
            _lastUIEmitUptime = now
        }
        let devID = activeDeviceID ?? ""
        let instantSnap = _instantLevel01
        let trailingSnap = max(_instantLevel01, _trailingPeakHold01)
        let levelHandler = shouldEmitUI ? _onLevelUpdate : nil
        let recordingHandler = _onRecordingSampleBuffer
        stateLock.unlock()

        levelHandler?(devID, instantSnap, trailingSnap)
        recordingHandler?(sampleBuffer)
    }

    private static func computeNormalizedAudioLevel01(from sampleBuffer: CMSampleBuffer) -> Double {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return 0.0 }
        let length = CMBlockBufferGetDataLength(blockBuffer)
        guard length >= 4 else { return 0.0 }

        var dataPtr: UnsafeMutablePointer<CChar>?
        var lengthAtOffset: Int = 0
        let status = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: &lengthAtOffset,
            totalLengthOut: nil,
            dataPointerOut: &dataPtr
        )
        guard status == kCMBlockBufferNoErr, let rawPtr = dataPtr, lengthAtOffset >= 4 else {
            return 0.0
        }

        let sampleCount = lengthAtOffset / MemoryLayout<Int16>.size
        guard sampleCount > 0 else { return 0.0 }
        let int16Ptr = UnsafeRawPointer(rawPtr).assumingMemoryBound(to: Int16.self)

        var sumSquares: Double = 0.0
        var peak: Double = 0.0
        let step = max(1, sampleCount / 256)
        var counted = 0
        var i = 0
        while i < sampleCount {
            let s = Double(int16Ptr[i]) / 32768.0
            let absS = abs(s)
            if absS > peak { peak = absS }
            sumSquares += s * s
            counted += 1
            i += step
        }
        guard counted > 0 else { return 0.0 }
        let rms = sqrt(sumSquares / Double(counted))
        let combined = max(rms * 1.65, peak * 0.85)
        if combined < 0.002 {
            return 0.0
        }
        // Convert to perceptual dB curve (-48 dB .. 0 dB -> 0.0 .. 1.0)
        let db = 20.0 * log10(max(0.0001, min(1.0, combined)))
        let normalized = (db + 48.0) / 48.0
        return max(0.0, min(1.0, pow(max(0.0, normalized), 1.15)))
    }
}

/// Native macOS Screen & Audio Capture Engine powered by `ScreenCaptureKit` + `AVAssetWriter` (VideoToolbox hardware encoding).
/// Excludes the system cursor (`showsCursor = false`) and NativeScreen's own HUD windows from the captured video stream.
public final class ScreenCaptureEngine: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var systemAudioInput: AVAssetWriterInput?

    // Optional Webcam + Microphone capture writers
    private var webcamWriter: AVAssetWriter?
    private var webcamVideoInput: AVAssetWriterInput?
    private var webcamPixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var isWebcamSessionStarted: Bool = false
    private var webcamFirstPTS: CMTime = .invalid
    private var lastAppendedWebcamPTS: CMTime = .invalid
    private var microphoneWriter: AVAssetWriter?
    private var microphoneAudioInput: AVAssetWriterInput?
    private var isMicrophoneSessionStarted: Bool = false
    private var microphoneFirstPTS: CMTime = .invalid
    private var lastAppendedMicrophonePTS: CMTime = .invalid

    private let videoQueue = DispatchQueue(label: "com.nativescreen.capture.video", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "com.nativescreen.capture.audio", qos: .userInteractive)
    private let avDeviceQueue = DispatchQueue(label: "com.nativescreen.capture.avdevices", qos: .userInteractive)

    /// Writes a movie fragment every 2s so a crash, force-quit or power loss mid-recording leaves a playable file
    /// (everything up to the last fragment) instead of an MP4 with no `moov` atom. `finishWriting` defragments as usual.
    private static let crashSafeFragmentInterval = CMTime(seconds: 2.0, preferredTimescale: 600)

    private var isWritingSessionStarted = false
    private var firstSampleTime: CMTime = .invalid
    private var lastSampleTime: CMTime = .zero
    // Pause intervals on the host clock (the same clock as `SCStream`, `AVCaptureSession` and `systemUptime`).
    // Every writer (screen, system audio, webcam, mic) and the telemetry recorder subtract the SAME wall-clock
    // intervals, so pausing never shifts one track against another. Guarded by `pauseLock` because samples
    // arrive on three different queues.
    private struct PauseInterval {
        let start: CMTime
        var end: CMTime?
    }
    private let pauseLock = NSLock()
    private var pauseIntervals: [PauseInterval] = []

    public private(set) var recordedDurationMs: Double = 0.0
    public var onFirstVideoFrameArrived: ((TimeInterval) -> Void)?

    public var onWebcamFrameCaptured: (@Sendable (IOSurfaceRef) -> Void)?

    /// `uptimeSec` must be the same `systemUptime` passed to `TelemetryRecorder.setPaused` so both clocks drop the exact same span.
    public func setPaused(_ paused: Bool, atUptime uptimeSec: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        let hostTime = CMTime(seconds: uptimeSec, preferredTimescale: 1_000_000_000)
        pauseLock.lock()
        defer { pauseLock.unlock() }
        let isPaused = pauseIntervals.last.map { $0.end == nil } ?? false
        guard isPaused != paused else { return }
        if paused {
            pauseIntervals.append(PauseInterval(start: hostTime, end: nil))
        } else {
            pauseIntervals[pauseIntervals.count - 1].end = hostTime
        }
    }

    /// Returns `nil` when `hostPTS` falls inside a pause (drop the sample), otherwise the total paused time before it.
    private func pausedOffset(forHostPTS hostPTS: CMTime) -> CMTime? {
        pauseLock.lock()
        defer { pauseLock.unlock() }
        var offset = CMTime.zero
        for interval in pauseIntervals {
            guard CMTimeCompare(hostPTS, interval.start) >= 0 else { break }
            guard let end = interval.end, CMTimeCompare(hostPTS, end) >= 0 else { return nil }
            offset = CMTimeAdd(offset, CMTimeSubtract(end, interval.start))
        }
        return offset
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
        writer.movieFragmentInterval = Self.crashSafeFragmentInterval

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
        pauseLock.lock()
        self.pauseIntervals = []
        pauseLock.unlock()

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
        // 1. Webcam Video Input & Writer (Uses `WarmCameraCaptureController` + `AVAssetWriterInputPixelBufferAdaptor` so it is 100% immune to format description changes and ISP resets!)
        if let camID = cameraDeviceID {
            let maxDimH: Int32 = (cameraMaxResolution == .p720) ? 720 : ((cameraMaxResolution == .p4k) ? 2160 : 1080)
            WarmCameraCaptureController.shared.ensureWarmSession(
                deviceID: camID,
                maxResolution: cameraMaxResolution
            ) { [weak self] resolvedDims, configuredFps in
                guard let self = self else { return }
                self.avDeviceQueue.async {
                    if let webcamURL = outputWebcamURL {
                        try? FileManager.default.removeItem(at: webcamURL)
                        if let wWriter = try? AVAssetWriter(outputURL: webcamURL, fileType: .mp4) {
                            wWriter.movieFragmentInterval = Self.crashSafeFragmentInterval
                            let rawH: Int = resolvedDims.height > 0 ? Int(resolvedDims.height) : Int(maxDimH)
                            let rawW: Int = resolvedDims.width > 0 ? Int(resolvedDims.width) : ((rawH * 16) / 9)
                            let targetW = max(2, rawW & ~1)
                            let targetH = max(2, rawH & ~1)
                            let wSettings: [String: Any] = [
                                AVVideoCodecKey: AVVideoCodecType.h264,
                                AVVideoWidthKey: targetW,
                                AVVideoHeightKey: targetH,
                                AVVideoCompressionPropertiesKey: [
                                    AVVideoAverageBitRateKey: max(10_000_000, targetW * targetH * 5),
                                    AVVideoExpectedSourceFrameRateKey: configuredFps,
                                    AVVideoMaxKeyFrameIntervalKey: configuredFps,
                                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
                                ]
                            ]
                            let wInput = AVAssetWriterInput(mediaType: .video, outputSettings: wSettings)
                            wInput.expectsMediaDataInRealTime = true
                            let pbAttrs: [String: Any] = [
                                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                                kCVPixelBufferWidthKey as String: targetW,
                                kCVPixelBufferHeightKey as String: targetH
                            ]
                            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                                assetWriterInput: wInput,
                                sourcePixelBufferAttributes: pbAttrs
                            )
                            if wWriter.canAdd(wInput) {
                                wWriter.add(wInput)
                            }
                            if wWriter.startWriting() {
                                self.webcamWriter = wWriter
                                self.webcamVideoInput = wInput
                                self.webcamPixelBufferAdaptor = adaptor
                                self.isWebcamSessionStarted = false
                                self.webcamFirstPTS = .invalid
                                self.lastAppendedWebcamPTS = .invalid
                            }
                        }
                    }

                    WarmCameraCaptureController.shared.setRecordingSampleBufferHandler { [weak self] sampleBuffer in
                        guard let self = self else { return }
                        self.avDeviceQueue.async {
                            self.handleWebcamSampleBuffer(sampleBuffer)
                        }
                    }
                }
            }
        }

        // 2. Microphone Audio Input & Writer (Uses `WarmMicrophoneCaptureController` so HUD metering and recording share one warm audio stream!)
        if let micID = microphoneDeviceID,
           let micURL = outputMicrophoneURL {
            WarmMicrophoneCaptureController.shared.ensureWarmSession(deviceID: micID)
            avDeviceQueue.async { [weak self] in
                guard let self = self else { return }
                try? FileManager.default.removeItem(at: micURL)
                if let mWriter = try? AVAssetWriter(outputURL: micURL, fileType: .m4a) {
                    mWriter.movieFragmentInterval = Self.crashSafeFragmentInterval
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
                        self.microphoneFirstPTS = .invalid
                        self.lastAppendedMicrophonePTS = .invalid
                    }
                }

                WarmMicrophoneCaptureController.shared.setRecordingSampleBufferHandler { [weak self] sampleBuffer in
                    guard let self = self else { return }
                    self.avDeviceQueue.async {
                        self.handleMicrophoneSampleBuffer(sampleBuffer)
                    }
                }
            }
        }
    }

    public func stopCapture() async {
        if let activeStream = stream {
            try? await activeStream.stopCapture()
            stream = nil
        }

        WarmCameraCaptureController.shared.setRecordingSampleBufferHandler(nil)
        WarmMicrophoneCaptureController.shared.setRecordingSampleBufferHandler(nil)

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            avDeviceQueue.async {
                let group = DispatchGroup()
                if let wWriter = self.webcamWriter {
                    let wInput = self.webcamVideoInput
                    let wAdaptor = self.webcamPixelBufferAdaptor
                    if self.isWebcamSessionStarted && wWriter.status == .writing {
                        wInput?.markAsFinished()
                        group.enter()
                        // Crucial: Capture `wWriter`, `wInput`, `wAdaptor` strongly inside `finishWriting` so ARC never deallocates
                        // `AVAssetWriter` before the MP4 `moov` atom is flushed to disk!
                        wWriter.finishWriting {
                            _ = (wWriter, wInput, wAdaptor)
                            self.avDeviceQueue.async {
                                self.webcamWriter = nil
                                self.webcamVideoInput = nil
                                self.webcamPixelBufferAdaptor = nil
                                group.leave()
                            }
                        }
                    } else {
                        wWriter.cancelWriting()
                        self.webcamWriter = nil
                        self.webcamVideoInput = nil
                        self.webcamPixelBufferAdaptor = nil
                    }
                }
                if let mWriter = self.microphoneWriter {
                    let mInput = self.microphoneAudioInput
                    if self.isMicrophoneSessionStarted && mWriter.status == .writing {
                        mInput?.markAsFinished()
                        group.enter()
                        mWriter.finishWriting {
                            _ = (mWriter, mInput)
                            self.avDeviceQueue.async {
                                self.microphoneWriter = nil
                                self.microphoneAudioInput = nil
                                group.leave()
                            }
                        }
                    } else {
                        mWriter.cancelWriting()
                        self.microphoneWriter = nil
                        self.microphoneAudioInput = nil
                    }
                }
                group.notify(queue: self.avDeviceQueue) {
                    cont.resume()
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
            guard let pausedOffset = pausedOffset(forHostPTS: rawPTS) else { return }

            let adjustedBuffer = Self.adjustSampleBufferTime(sampleBuffer, bySubtracting: pausedOffset) ?? sampleBuffer
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
                  let aInput = systemAudioInput,
                  aInput.isReadyForMoreMediaData,
                  let pausedOffset = pausedOffset(forHostPTS: CMSampleBufferGetPresentationTimeStamp(sampleBuffer)) else {
                return
            }
            let adjustedAudio = Self.adjustSampleBufferTime(sampleBuffer, bySubtracting: pausedOffset) ?? sampleBuffer
            aInput.append(adjustedAudio)

        case .microphone:
            break

        @unknown default:
            break
        }
    }

    // MARK: - Webcam & Microphone Sample Buffer Handling

    private func handleWebcamSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard CMSampleBufferDataIsReady(sampleBuffer),
              let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        if let callback = onWebcamFrameCaptured,
           let surface = CVPixelBufferGetIOSurface(pb)?.takeUnretainedValue() {
            callback(surface)
        }

        guard let wWriter = webcamWriter, wWriter.status == .writing,
              let wInput = webcamVideoInput,
              let wAdaptor = webcamPixelBufferAdaptor else { return }

        let rawPTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard rawPTS.isValid, let pausedOffset = pausedOffset(forHostPTS: rawPTS) else { return }
        let pts = CMTimeSubtract(rawPTS, pausedOffset)

        if !isWebcamSessionStarted {
            // Guard against cold-start ISP black frames if the user started recording within milliseconds of selecting a camera
            if WarmCameraCaptureController.shared.isCameraAdjustingOrCold && Self.isFrameNearBlack(sampleBuffer) {
                return
            }
            webcamFirstPTS = pts
            wWriter.startSession(atSourceTime: .zero)
            isWebcamSessionStarted = true
        }

        var framePTS = CMTimeSubtract(pts, webcamFirstPTS)
        if !framePTS.isValid || CMTimeGetSeconds(framePTS) < 0 {
            framePTS = .zero
        }
        // Guarantee strictly monotonic presentation timestamps so `AVAssetWriter` never fails on cold-start clock jitter
        if lastAppendedWebcamPTS.isValid && CMTimeCompare(framePTS, lastAppendedWebcamPTS) <= 0 {
            framePTS = CMTimeAdd(lastAppendedWebcamPTS, CMTime(value: 1, timescale: 600))
        }

        if wInput.isReadyForMoreMediaData {
            if wAdaptor.append(pb, withPresentationTime: framePTS) {
                lastAppendedWebcamPTS = framePTS
            }
        }
    }

    private static func isFrameNearBlack(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return false }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return false }
        let width = CVPixelBufferGetWidth(pb)
        let height = CVPixelBufferGetHeight(pb)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pb)
        guard width >= 16, height >= 16, bytesPerRow >= width * 4 else { return false }

        let ptr = base.assumingMemoryBound(to: UInt8.self)
        var sumLuma: Int = 0
        var count: Int = 0
        let stepX = max(1, width / 8)
        let stepY = max(1, height / 8)
        for y in stride(from: height / 4, to: (height * 3) / 4, by: stepY) {
            let row = ptr + y * bytesPerRow
            for x in stride(from: width / 4, to: (width * 3) / 4, by: stepX) {
                let px = row + x * 4 // BGRA
                let b = Int(px[0])
                let g = Int(px[1])
                let r = Int(px[2])
                sumLuma += (r * 77 + g * 150 + b * 29) >> 8
                count += 1
            }
        }
        guard count > 0 else { return false }
        return (sumLuma / count) < 10
    }

    private func handleMicrophoneSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard CMSampleBufferDataIsReady(sampleBuffer),
              let mWriter = microphoneWriter, mWriter.status == .writing,
              let mInput = microphoneAudioInput,
              let pausedOffset = pausedOffset(forHostPTS: CMSampleBufferGetPresentationTimeStamp(sampleBuffer)) else {
            return
        }

        let adjusted = Self.adjustSampleBufferTime(sampleBuffer, bySubtracting: pausedOffset) ?? sampleBuffer
        let pts = CMSampleBufferGetPresentationTimeStamp(adjusted)
        guard pts.isValid else { return }

        if !isMicrophoneSessionStarted {
            microphoneFirstPTS = pts
            mWriter.startSession(atSourceTime: .zero)
            isMicrophoneSessionStarted = true
        }
        guard let zeroBasedBuffer = Self.adjustSampleBufferTime(adjusted, bySubtracting: microphoneFirstPTS) else { return }
        let zeroPTS = CMSampleBufferGetPresentationTimeStamp(zeroBasedBuffer)
        if lastAppendedMicrophonePTS.isValid && CMTimeCompare(zeroPTS, lastAppendedMicrophonePTS) <= 0 {
            return
        }
        if mInput.isReadyForMoreMediaData {
            if mInput.append(zeroBasedBuffer) {
                lastAppendedMicrophonePTS = zeroPTS
            }
        }
    }

    /// Selects the highest frame rate format (preferring 60fps when supported by the camera, e.g. Continuity Camera / external 60fps webcams,
    /// or locking cleanly to the highest native rate at `<= maxHeight`) without clamping `activeVideoMaxFrameDuration` (which would starve
    /// the camera ISP of exposure time in indoor/evening lighting) and without reassigning `activeFormat` when already matched!
    @discardableResult
    public static func configureHighestFrameRateFormat(on device: AVCaptureDevice, maxHeight: Int32 = 1080) -> Int {
        var bestFormat: AVCaptureDevice.Format?
        var bestRange: AVFrameRateRange?
        var bestScore: Double = -1.0

        for format in device.formats {
            let desc = format.formatDescription
            guard CMFormatDescriptionGetMediaType(desc) == kCMMediaType_Video else { continue }
            let subType = CMFormatDescriptionGetMediaSubType(desc)
            guard subType == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
               || subType == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange else { continue }

            let dims = CMVideoFormatDescriptionGetDimensions(desc)
            guard dims.width > dims.height, dims.height <= maxHeight, dims.height >= 480 else { continue }

            let aspect = Double(dims.width) / Double(max(1, dims.height))
            let is16By9Bonus = (abs(aspect - (16.0 / 9.0)) < 0.05) ? 500.0 : 0.0

            for range in format.videoSupportedFrameRateRanges {
                let maxFps = min(60.0, range.maxFrameRate)
                // Prioritize 60fps support first, then 16:9 aspect ratio and resolution closest to `maxHeight`
                let fpsWeight = (maxFps >= 59.0) ? 100_000.0 : (maxFps * 1000.0)
                let resWeight = Double(dims.height)
                let score = fpsWeight + resWeight + is16By9Bonus
                if score > bestScore {
                    bestScore = score
                    bestFormat = format
                    bestRange = range
                }
            }
        }

        guard let chosenFormat = bestFormat, let chosenRange = bestRange else {
            return 30
        }

        let targetFps = min(60.0, chosenRange.maxFrameRate)
        let minFrameDur = (targetFps >= 59.0)
            ? CMTime(value: 1, timescale: 60)
            : chosenRange.minFrameDuration

        do {
            try device.lockForConfiguration()
            // Crucial: Only assign `activeFormat` if it actually differs from the current format;
            // needlessly reassigning `activeFormat` forces the camera ISP to reset Auto-Exposure to black!
            if device.activeFormat != chosenFormat {
                device.activeFormat = chosenFormat
            }
            device.activeVideoMinFrameDuration = minFrameDur
            // Crucial: Leave `activeVideoMaxFrameDuration = .invalid` (hardware default) so the camera ISP
            // can still lengthen shutter exposure in indoor/evening light instead of underexposing to black!
            device.activeVideoMaxFrameDuration = .invalid
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                device.whiteBalanceMode = .continuousAutoWhiteBalance
            }
            device.unlockForConfiguration()
        } catch {
            // Ignore if device refuses lock
        }

        return Int(round(targetFps))
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
