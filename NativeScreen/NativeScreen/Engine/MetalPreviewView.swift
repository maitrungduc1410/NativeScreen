import Foundation
import SwiftUI
import MetalKit
import AVFoundation
import CoreImage

/// Zero-Idle-CPU `MTKView` wrapper for SwiftUI.
/// - Animatable `canvasAspect` allows the preview canvas to morph smoothly with a 120Hz spring when changing aspect ratios!
/// - Explicitly observes `session.renderRevision` and `session.isPlaying` so slider drags update at 120Hz with zero lag.
public struct MetalPreviewView: NSViewRepresentable, Animatable {
    public var session: ProjectSession
    public var canvasAspect: Double
    public var renderRevision: UInt64
    public var isPlaying: Bool

    public nonisolated var animatableData: Double {
        get { canvasAspect }
        set { canvasAspect = newValue }
    }

    public init(session: ProjectSession, canvasAspect: Double = 16.0 / 9.0) {
        self.session = session
        self.canvasAspect = canvasAspect
        self.renderRevision = session.renderRevision
        self.isPlaying = session.isPlaying
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(session: session)
    }

    public func makeNSView(context: Context) -> MTKView {
        let mtkView = MTKView()
        if let compositor = context.coordinator.compositor {
            mtkView.device = compositor.device
        }
        mtkView.delegate = context.coordinator
        mtkView.framebufferOnly = false
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.clearColor = MTLClearColor(red: 0.05, green: 0.05, blue: 0.07, alpha: 1.0)
        mtkView.preferredFramesPerSecond = 120

        mtkView.isPaused = !session.isPlaying
        mtkView.enableSetNeedsDisplay = !session.isPlaying

        context.coordinator.attach(mtkView: mtkView)
        return mtkView
    }

    public func updateNSView(_ mtkView: MTKView, context: Context) {
        context.coordinator.updateSession(session, canvasAspect: canvasAspect, mtkView: mtkView)
    }

    @MainActor
    public final class Coordinator: NSObject, MTKViewDelegate {
        var session: ProjectSession
        let compositor = MetalFrameCompositor()
        weak var mtkView: MTKView?

        private var lastRenderedRevision: UInt64 = .max
        private var lastCanvasAspect: Double = -1.0
        private var lastFrameTickUptime: TimeInterval = 0

        // Video frame decoder for recorded `.mp4` / `.m3u8` + synchronized Microphone `.m4a`, Voiceover & Background Audio players
        private var player: AVPlayer?
        private var micPlayer: AVPlayer?
        private var loadedMicURL: URL?
        private var bgMusicPlayer: AVAudioPlayer?
        private var loadedBgMusicURL: URL?
        private var voiceoverPlayersByID: [String: AVPlayer] = [:]
        private var videoOutput: AVPlayerItemVideoOutput?
        private var playerItemStatusObserver: NSKeyValueObservation?
        private var loadedVideoURL: URL?
        private var lastDecodedFrame: CIImage?
        private var lastSeekedSourceMs: Double = -1.0
        private var isDecoderSeeking: Bool = false
        private var pendingSeekSourceMs: Double? = nil

        // Recorded camera (`webcam.mp4`), decoded here so the compositor draws the camera bubble into the same Metal frame
        // as the screen (identical to export, and never a frame out of sync like a separate SwiftUI layer).
        private var webcamPlayer: AVPlayer?
        private var webcamOutput: AVPlayerItemVideoOutput?
        private var webcamStatusObserver: NSKeyValueObservation?
        private var loadedWebcamURL: URL?
        private var lastWebcamFrame: CIImage?
        private var lastWebcamSeekedMs: Double = -1.0
        private var isWebcamSeeking: Bool = false
        private var pendingWebcamSeekMs: Double?

        /// Where each playing player's timebase was anchored at the last start / re-sync: item time `itemMs` at host time
        /// `hostSec`, advancing at `rate`. This IS the player's clock, known exactly from the first frame after Play.
        /// Asking AVPlayer instead is not free: `itemTime(forHostTime:)` stays invalid until the first decoded frame,
        /// and `currentTime` blocks the main thread ~30ms on the first call after `setRate(_:time:atHostTime:)`.
        private struct PlayerClockAnchor {
            let hostSec: Double
            let itemMs: Double
            let rate: Double

            func itemMs(atHostSec now: Double) -> Double {
                itemMs + (now - hostSec) * 1000.0 * rate
            }
        }
        private var playerAnchors: [ObjectIdentifier: PlayerClockAnchor] = [:]

        private var videoClockAnchor: PlayerClockAnchor? {
            player.flatMap { playerAnchors[ObjectIdentifier($0)] }
        }

        /// Current item time of a playing player, from its anchor when it has one.
        private func playbackPositionMs(of player: AVPlayer) -> Double {
            if let anchor = playerAnchors[ObjectIdentifier(player)] {
                return anchor.itemMs(atHostSec: CACurrentMediaTime())
            }
            return max(0.0, CMTimeGetSeconds(player.currentTime()) * 1000.0)
        }

        init(session: ProjectSession) {
            self.session = session
            super.init()
            setupVideoDecoderIfNeeded(for: session.videoFileURL)
            setupMicrophonePlayerIfNeeded(for: session.microphoneAudioFileURL)
            setupBackgroundMusicPlayerIfNeeded(for: session.resolvedBackgroundAudioFileURL())
            setupWebcamDecoderIfNeeded(for: session.webcamVideoFileURL)
            compositor?.realtimePersonSegmenter.onMaskUpdated = { [weak self] in
                self?.mtkView?.needsDisplay = true
            }
        }

        func attach(mtkView: MTKView) {
            self.mtkView = mtkView
            mtkView.needsDisplay = true
        }

        func updateSession(_ newSession: ProjectSession, canvasAspect: Double, mtkView: MTKView) {
            self.session = newSession
            setupVideoDecoderIfNeeded(for: newSession.videoFileURL)
            setupMicrophonePlayerIfNeeded(for: newSession.microphoneAudioFileURL)
            setupBackgroundMusicPlayerIfNeeded(for: newSession.resolvedBackgroundAudioFileURL())
            setupWebcamDecoderIfNeeded(for: newSession.webcamVideoFileURL)

            if newSession.isPlaying {
                if newSession.isPreviewingBackgroundAudio {
                    newSession.stopBackgroundAudioPreview()
                }
                if mtkView.isPaused {
                    lastFrameTickUptime = ProcessInfo.processInfo.systemUptime
                    mtkView.enableSetNeedsDisplay = false
                    mtkView.isPaused = false
                }
            } else {
                playerAnchors.removeAll()
                if let webcam = webcamPlayer, webcam.rate != 0 {
                    webcam.pause()
                }
                if let micPlayer = micPlayer, micPlayer.rate != 0 {
                    micPlayer.pause()
                }
                if let bgMusicPlayer = bgMusicPlayer, bgMusicPlayer.isPlaying {
                    bgMusicPlayer.pause()
                }
                for voPlayer in voiceoverPlayersByID.values where voPlayer.rate != 0 {
                    voPlayer.pause()
                }
                let animatingBg = (compositor?.isAnimatingBackgroundTransition ?? false) || (compositor?.isAnimatingPreviewOverlays ?? false)
                if !animatingBg && !mtkView.isPaused {
                    mtkView.isPaused = true
                    mtkView.enableSetNeedsDisplay = true
                }
                if abs(canvasAspect - lastCanvasAspect) > 0.0005 {
                    lastCanvasAspect = canvasAspect
                    mtkView.needsDisplay = true
                }
                if lastRenderedRevision != newSession.renderRevision {
                    lastRenderedRevision = newSession.renderRevision
                    let targetSourceMs = newSession.currentSourceTimeMs

                    // ONLY seek the hardware video decoder if the playhead/skim timestamp actually changed!
                    // When dragging Padding, Shadow, Rounded Corners, Background Blur, or Mask handles,
                    // `targetSourceMs` is unchanged, so we redraw immediately in <0.5ms without touching AVPlayer!
                    if abs(targetSourceMs - lastSeekedSourceMs) > 0.5 {
                        let isHoverSkim = (newSession.hoverSkimTimelineMs != nil)
                        seekDecoderCoalesced(toSourceMs: targetSourceMs, fastSkim: isHoverSkim)
                    }
                    let webcamTargetMs = webcamSourceMs(forSourceMs: targetSourceMs)
                    if abs(webcamTargetMs - lastWebcamSeekedMs) > 0.5 {
                        seekWebcamCoalesced(toMs: webcamTargetMs, fastSkim: newSession.hoverSkimTimelineMs != nil)
                    }
                    mtkView.needsDisplay = true
                }
            }
        }

        private func setupVideoDecoderIfNeeded(for url: URL) {
            guard loadedVideoURL != url else { return }
            loadedVideoURL = url
            playerAnchors.removeAll()
            lastSeekedSourceMs = -1.0
            isDecoderSeeking = false
            pendingSeekSourceMs = nil
            playerItemStatusObserver?.invalidate()
            playerItemStatusObserver = nil

            guard FileManager.default.fileExists(atPath: url.path) else {
                player = nil
                videoOutput = nil
                return
            }

            let asset = AVURLAsset(url: url)
            let item = AVPlayerItem(asset: asset)
            let pixelAttrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferMetalCompatibilityKey as String: true
            ]
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: pixelAttrs)
            item.add(output)

            let avPlayer = AVPlayer(playerItem: item)
            avPlayer.isMuted = true
            self.player = avPlayer
            self.videoOutput = output

            let initialSourceMs = session.currentSourceTimeMs

            // 1. Immediately decode the initial frame via AVAssetImageGenerator so the editor canvas
            //    shows the real recorded video frame on the very first draw (no waiting for AVPlayerItem warmup)!
            Task { @MainActor [weak self] in
                let gen = AVAssetImageGenerator(asset: asset)
                gen.appliesPreferredTrackTransform = true
                gen.requestedTimeToleranceBefore = CMTime(seconds: 0.25, preferredTimescale: 600)
                gen.requestedTimeToleranceAfter = CMTime(seconds: 0.25, preferredTimescale: 600)
                let cmTime = CMTime(seconds: initialSourceMs / 1000.0, preferredTimescale: 600)
                if let (cgImg, _) = try? await gen.image(at: cmTime),
                   let self = self, self.lastDecodedFrame == nil {
                    self.lastDecodedFrame = CIImage(cgImage: cgImg)
                    self.mtkView?.needsDisplay = true
                }
            }

            // 2. Also observe when AVPlayerItem becomes `.readyToPlay` so `AVPlayerItemVideoOutput` can copy the exact CVPixelBuffer
            playerItemStatusObserver = item.observe(\.status, options: [.initial, .new]) { [weak self] observedItem, _ in
                guard observedItem.status == .readyToPlay else { return }
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    self.lastSeekedSourceMs = -1.0
                    self.isDecoderSeeking = false
                    self.seekDecoderCoalesced(toSourceMs: self.session.currentSourceTimeMs, fastSkim: false)
                }
            }
        }

        private func webcamSourceMs(forSourceMs sourceMs: Double) -> Double {
            max(0.0, sourceMs + session.document.camera.delayAdjustmentMs)
        }

        private func setupWebcamDecoderIfNeeded(for url: URL?) {
            guard loadedWebcamURL != url else { return }
            loadedWebcamURL = url
            webcamStatusObserver?.invalidate()
            webcamStatusObserver = nil
            webcamPlayer?.pause()
            webcamPlayer = nil
            webcamOutput = nil
            lastWebcamFrame = nil
            lastWebcamSeekedMs = -1.0
            isWebcamSeeking = false
            pendingWebcamSeekMs = nil
            guard let url, FileManager.default.fileExists(atPath: url.path) else { return }

            let item = AVPlayerItem(asset: AVURLAsset(url: url))
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferMetalCompatibilityKey as String: true
            ])
            item.add(output)
            let webcam = AVPlayer(playerItem: item)
            webcam.isMuted = true
            webcamPlayer = webcam
            webcamOutput = output
            webcamStatusObserver = item.observe(\.status, options: [.initial, .new]) { [weak self] observedItem, _ in
                guard observedItem.status == .readyToPlay else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.lastWebcamSeekedMs = -1.0
                    self.isWebcamSeeking = false
                    self.seekWebcamCoalesced(toMs: self.webcamSourceMs(forSourceMs: self.session.currentSourceTimeMs), fastSkim: false)
                }
            }
        }

        private func seekWebcamCoalesced(toMs ms: Double, fastSkim: Bool) {
            guard let webcam = webcamPlayer else { return }
            if isWebcamSeeking {
                pendingWebcamSeekMs = ms
                return
            }
            isWebcamSeeking = true
            lastWebcamSeekedMs = ms
            let tolerance = fastSkim ? CMTime(seconds: 0.05, preferredTimescale: 600) : .zero
            webcam.seek(to: CMTime(seconds: ms / 1000.0, preferredTimescale: 600), toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.isWebcamSeeking = false
                    let time = CMTime(seconds: self.lastWebcamSeekedMs / 1000.0, preferredTimescale: 600)
                    if let pb = self.webcamOutput?.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) {
                        self.lastWebcamFrame = CIImage(cvPixelBuffer: pb)
                        self.mtkView?.needsDisplay = true
                    }
                    if let next = self.pendingWebcamSeekMs {
                        self.pendingWebcamSeekMs = nil
                        if abs(next - self.lastWebcamSeekedMs) > 0.5 {
                            self.seekWebcamCoalesced(toMs: next, fastSkim: self.session.hoverSkimTimelineMs != nil)
                        }
                    }
                }
            }
        }

        /// Keeps the camera player running with the screen player (anchored to the same host time) while playing,
        /// and pulls the frame for this display refresh.
        private func syncWebcamForPlayback(sourceMs: Double, rate: Float) {
            guard let webcam = webcamPlayer, let output = webcamOutput else { return }
            let targetMs = webcamSourceMs(forSourceMs: sourceMs)
            if abs(webcam.rate - rate) > 0.05 || abs(playbackPositionMs(of: webcam) - targetMs) > 180.0 {
                pendingWebcamSeekMs = nil
                startPlayerAnchoredToNow(webcam, atItemTime: CMTime(seconds: targetMs / 1000.0, preferredTimescale: 600), rate: rate)
            }
            let hostItemTime = output.itemTime(forHostTime: CACurrentMediaTime())
            let queryTime = (hostItemTime.isValid && abs(CMTimeGetSeconds(hostItemTime) * 1000.0 - targetMs) < 150.0)
                ? hostItemTime
                : CMTime(seconds: targetMs / 1000.0, preferredTimescale: 600)
            if output.hasNewPixelBuffer(forItemTime: queryTime),
               let pb = output.copyPixelBuffer(forItemTime: queryTime, itemTimeForDisplay: nil) {
                lastWebcamFrame = CIImage(cvPixelBuffer: pb)
                lastWebcamSeekedMs = targetMs
            }
        }

        private func setupMicrophonePlayerIfNeeded(for url: URL?) {
            guard loadedMicURL != url else { return }
            loadedMicURL = url
            guard let micURL = url, FileManager.default.fileExists(atPath: micURL.path) else {
                micPlayer?.pause()
                micPlayer = nil
                return
            }
            let asset = AVURLAsset(url: micURL)
            let item = AVPlayerItem(asset: asset)
            let mPlayer = AVPlayer(playerItem: item)
            mPlayer.isMuted = false
            self.micPlayer = mPlayer
        }

        private func setupBackgroundMusicPlayerIfNeeded(for url: URL?) {
            guard loadedBgMusicURL != url else { return }
            loadedBgMusicURL = url
            bgMusicPlayer?.stop()
            bgMusicPlayer = nil
            guard let bgURL = url, FileManager.default.fileExists(atPath: bgURL.path),
                  let audioPlayer = try? AVAudioPlayer(contentsOf: bgURL) else {
                return
            }
            audioPlayer.numberOfLoops = -1
            audioPlayer.prepareToPlay()
            self.bgMusicPlayer = audioPlayer
        }

        private func seekDecoderCoalesced(toSourceMs sourceMs: Double, fastSkim: Bool) {
            guard let player = player else { return }
            if isDecoderSeeking {
                pendingSeekSourceMs = sourceMs
                return
            }

            isDecoderSeeking = true
            lastSeekedSourceMs = sourceMs
            let cmTime = CMTime(seconds: sourceMs / 1000.0, preferredTimescale: 600)
            let tolerance = fastSkim ? CMTime(seconds: 0.05, preferredTimescale: 600) : .zero

            player.seek(to: cmTime, toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    self.isDecoderSeeking = false

                    let actualTime = CMTime(seconds: self.lastSeekedSourceMs / 1000.0, preferredTimescale: 600)
                    if let output = self.videoOutput,
                       let pb = output.copyPixelBuffer(forItemTime: actualTime, itemTimeForDisplay: nil) {
                        self.lastDecodedFrame = CIImage(cvPixelBuffer: pb)
                        self.mtkView?.needsDisplay = true
                    }

                    if let nextMs = self.pendingSeekSourceMs {
                        self.pendingSeekSourceMs = nil
                        if abs(nextMs - self.lastSeekedSourceMs) > 0.5 {
                            let stillSkimming = (self.session.hoverSkimTimelineMs != nil)
                            self.seekDecoderCoalesced(toSourceMs: nextMs, fastSkim: stillSkimming)
                        }
                    }
                }
            }
        }

        /// Starts `player` so that its item time is exactly `itemTime` at this host instant and advances at `rate` from here.
        /// Unlike `seek` + `rate`, the player's timebase is anchored immediately: the playhead (which follows
        /// `itemTime(forHostTime:)`) starts moving on the very first frame after Play, and decoded frames simply catch up
        /// with the timebase a few frames later. Seeking first and then playing left the whole preview frozen for
        /// ~165ms (exact seek from the previous keyframe + stall-avoidance buffering) after every Play.
        private func startPlayerAnchoredToNow(
            _ player: AVPlayer,
            atItemTime itemTime: CMTime,
            rate: Float,
            onSeekStart: (() -> Void)? = nil,
            onSeekDone: (@MainActor () -> Void)? = nil
        ) {
            playerAnchors[ObjectIdentifier(player)] = nil
            guard player.currentItem?.status == .readyToPlay else {
                // Not ready yet (just opened): fall back to a plain seek, the drift check re-anchors once it is ready.
                onSeekStart?()
                player.seek(to: itemTime, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                    Task { @MainActor in onSeekDone?() }
                }
                player.rate = rate
                return
            }
            // Required by `setRate(_:time:atHostTime:)`; the preview never wants AVPlayer to delay start for buffering.
            player.automaticallyWaitsToMinimizeStalling = false
            let hostNow = CMClockGetTime(CMClockGetHostTimeClock())
            player.setRate(rate, time: itemTime, atHostTime: hostNow)
            playerAnchors[ObjectIdentifier(player)] = PlayerClockAnchor(
                hostSec: CMTimeGetSeconds(hostNow),
                itemMs: CMTimeGetSeconds(itemTime) * 1000.0,
                rate: Double(rate)
            )
            onSeekDone?()
        }

        // MARK: - MTKViewDelegate

        nonisolated public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            Task { @MainActor in
                view.needsDisplay = true
            }
        }

        nonisolated public func draw(in view: MTKView) {
            MainActor.assumeIsolated {
                drawOnMainActor(in: view)
            }
        }

        private func drawOnMainActor(in view: MTKView) {
            guard let compositor = compositor,
                  let drawable = view.currentDrawable,
                  let commandBuffer = compositor.commandQueue.makeCommandBuffer() else {
                return
            }

            if session.isPlaying {
                let prevSourceMs = session.committedSourceTimeMs
                let now = ProcessInfo.processInfo.systemUptime
                let dtMs = max(0.0, min(50.0, (now - lastFrameTickUptime) * 1000.0)) * session.previewPlaybackRate
                lastFrameTickUptime = now

                // The video decoder is the master clock: while `AVPlayer` is running inside the current slice, the playhead
                // follows its item time, so cursor/zoom (drawn at `sourceMs`) and the decoded frame never drift apart and a
                // main-thread hitch no longer loses timeline time. The wall clock is only the fallback (no video, cut
                // boundaries, seeks), where the >180ms drift check below re-syncs the decoder.
                var nextTimelineMs = session.playheadTimelineMs + dtMs
                if let player = player, player.rate != 0, !isDecoderSeeking {
                    let clockSourceMs: Double? = {
                        if let anchor = videoClockAnchor {
                            return anchor.itemMs(atHostSec: CACurrentMediaTime())
                        }
                        guard let output = videoOutput else { return nil }
                        let hostItemTime = output.itemTime(forHostTime: CACurrentMediaTime())
                        return hostItemTime.isValid ? CMTimeGetSeconds(hostItemTime) * 1000.0 : nil
                    }()
                    if let clockSourceMs,
                       let clockTimelineMs = session.timeMapper.timelineTime(
                           forSourceMs: clockSourceMs,
                           withinSliceAtTimelineMs: session.playheadTimelineMs
                       ),
                       abs(clockTimelineMs - nextTimelineMs) < 250.0 {
                        // Never step backwards.
                        nextTimelineMs = max(session.playheadTimelineMs, clockTimelineMs)
                    }
                }
                if nextTimelineMs >= session.timeMapper.totalTimelineDurationMs && EditorViewPreferences.shared.loopPlayback {
                    // `View > Loop playback`: wrap to the start; the drift check below re-anchors every player there.
                    session.playheadTimelineMs = 0.0
                } else if nextTimelineMs >= session.timeMapper.totalTimelineDurationMs {
                    session.playheadTimelineMs = session.timeMapper.totalTimelineDurationMs
                    // Clear any leftover hover-skim timestamp when playback finishes so the preview stays settled
                    // at the final frame (`playheadTimelineMs`) until the user actively moves the mouse to skim again!
                    session.hoverSkimTimelineMs = nil
                    session.isPlaying = false
                    view.isPaused = true
                    view.enableSetNeedsDisplay = true
                    // Explicitly seek the hardware video decoder to the exact final frame so `lastDecodedFrame` settles
                    // cleanly on the last frame when playback finishes!
                    let finalSourceMs = session.currentSourceTimeMs
                    lastSeekedSourceMs = -1.0
                    seekDecoderCoalesced(toSourceMs: finalSourceMs, fastSkim: false)
                } else {
                    session.playheadTimelineMs = nextTimelineMs
                }

                let newSourceMs = session.committedSourceTimeMs
                if let soundSet = session.document.cursor.clickEffect.soundSet,
                   (session.currentActiveSlice?.speed ?? 1.0) <= 2.0,
                   newSourceMs > prevSourceMs {
                    if session.clickEvents.contains(where: { $0.type == "down" && $0.t > prevSourceMs && $0.t <= newSourceMs }) {
                        CursorClickSoundPlayer.shared.playClickSound(
                            soundSet: soundSet,
                            volume: session.document.cursor.clickEffect.soundVolume
                        )
                    }
                }
            }

            let sourceMs = session.currentSourceTimeMs
            let targetCMTime = CMTime(seconds: sourceMs / 1000.0, preferredTimescale: 600)

            if let output = videoOutput {
                let activeSlice = session.currentActiveSlice
                let sliceSpeed = activeSlice?.speed ?? 1.0
                let masterVol = session.document.audio.masterVolume
                let isMutedByVO = session.isOriginalRecordingHiddenAndMutedByVoiceover(atSourceMs: sourceMs)
                let sliceVol = (activeSlice?.muted == true || session.document.audio.muteSystemAudio) ? 0.0 : (activeSlice?.systemAudioVolume ?? 1.0)
                let effectiveVolume = Float(min(2.0, max(0.0, sliceVol * session.document.audio.systemAudioVolume * masterVol)))
                let micVol = (activeSlice?.muted == true || session.document.audio.muteMicrophone || isMutedByVO) ? 0.0 : (session.document.audio.microphoneVolume * masterVol)
                let effectiveMicVolume = Float(min(2.0, max(0.0, micVol)))
                let desiredRate = Float(session.previewPlaybackRate * sliceSpeed)
                if session.isPlaying, let player = player {
                    player.isMuted = (effectiveVolume <= 0.001)
                    player.volume = effectiveVolume

                    // Only seek AVPlayer when starting playback (`rate` changed) or jumping across a cut boundary (`drift > 180ms` while not actively seeking).
                    // Never snap `sourceMs` to `displayTime` (which is quantized at 60Hz = 16.67ms steps), because the 120Hz spring camera & cursor
                    // MUST advance at smooth 8.33ms steps (`session.currentSourceTimeMs`) to avoid 60Hz-vs-120Hz frame-doubling judder during zooms!
                    let playerCurrentMs = playbackPositionMs(of: player)
                    let driftMs = abs(playerCurrentMs - sourceMs)
                    if abs(player.rate - desiredRate) > 0.05 || (!isDecoderSeeking && driftMs > 180.0) {
                        pendingSeekSourceMs = nil // a scrub seek queued while paused must not fire after playback starts
                        startPlayerAnchoredToNow(player, atItemTime: targetCMTime, rate: desiredRate) { [weak self] in
                            self?.isDecoderSeeking = true
                        } onSeekDone: { [weak self] in
                            self?.isDecoderSeeking = false
                        }
                    }

                    syncWebcamForPlayback(sourceMs: sourceMs, rate: desiredRate)

                    // Microphone and voiceovers are anchored to the same host time as the video, so they start in sync.
                    // Synchronize `micPlayer` (`microphone.m4a`) in lockstep with `player` (`display.mp4`)!
                    if let micPlayer = micPlayer {
                        micPlayer.isMuted = (effectiveMicVolume <= 0.001)
                        micPlayer.volume = effectiveMicVolume
                        let micCurrentMs = playbackPositionMs(of: micPlayer)
                        let micDriftMs = abs(micCurrentMs - sourceMs)
                        if abs(micPlayer.rate - desiredRate) > 0.05 || micDriftMs > 180.0 {
                            startPlayerAnchoredToNow(micPlayer, atItemTime: targetCMTime, rate: desiredRate)
                        }
                    }

                    // Synchronize looping `bgMusicPlayer` (`BackgroundMusicConfig`)!
                    if let bgMusicPlayer = bgMusicPlayer {
                        let bgCfg = session.document.audio.backgroundMusic
                        let bgVol = bgCfg.muted ? Float(0.0) : Float(min(1.0, max(0.0, bgCfg.volume * masterVol * 2.5)))
                        bgMusicPlayer.volume = bgVol
                        if bgVol > 0.001 {
                            let dur = max(1.0, bgMusicPlayer.duration)
                            let targetBgSec = (session.playheadTimelineMs / 1000.0).truncatingRemainder(dividingBy: dur)
                            if !bgMusicPlayer.isPlaying {
                                bgMusicPlayer.currentTime = targetBgSec
                                bgMusicPlayer.play()
                            } else if abs(bgMusicPlayer.currentTime - targetBgSec) > 0.35 && abs(bgMusicPlayer.currentTime - targetBgSec) < dur - 0.35 {
                                bgMusicPlayer.currentTime = targetBgSec
                            }
                        } else if bgMusicPlayer.isPlaying {
                            bgMusicPlayer.pause()
                        }
                    }

                    // Synchronize any active `VoiceoverSegment`s (`voiceoverPlayersByID`)!
                    let activeVOs = session.activeVoiceovers(atSourceMs: sourceMs)
                    let activeVOIDs = Set(activeVOs.map(\.id))
                    for (voId, voPlayer) in voiceoverPlayersByID where !activeVOIDs.contains(voId) {
                        if voPlayer.rate != 0 {
                            voPlayer.pause()
                            playerAnchors[ObjectIdentifier(voPlayer)] = nil
                        }
                    }
                    for vo in activeVOs {
                        let voURL = session.packageURL.appendingPathComponent(vo.relativePath)
                        guard FileManager.default.fileExists(atPath: voURL.path) else { continue }
                        let voPlayer: AVPlayer = {
                            if let existing = voiceoverPlayersByID[vo.id] {
                                return existing
                            }
                            let p = AVPlayer(url: voURL)
                            voiceoverPlayersByID[vo.id] = p
                            return p
                        }()
                        let voOffsetSec = max(0.0, (sourceMs - vo.sourceStartMs) / 1000.0)
                        let voRate = Float(session.previewPlaybackRate * (vo.attachMode == .synchronized ? sliceSpeed : 1.0))
                        let voVol = Float(min(1.0, max(0.0, vo.volume * masterVol)))
                        voPlayer.isMuted = (voVol <= 0.001)
                        voPlayer.volume = voVol
                        let curSec = playbackPositionMs(of: voPlayer) / 1000.0
                        if abs(voPlayer.rate - voRate) > 0.05 || abs(curSec - voOffsetSec) > 0.22 {
                            startPlayerAnchoredToNow(voPlayer, atItemTime: CMTime(seconds: voOffsetSec, preferredTimescale: 600), rate: voRate)
                        }
                    }

                } else if !session.isPlaying {
                    playerAnchors.removeAll()
                    if let player = player, player.rate != 0 {
                        player.pause()
                    }
                    if let webcam = webcamPlayer, webcam.rate != 0 {
                        webcam.pause()
                    }
                    if let micPlayer = micPlayer, micPlayer.rate != 0 {
                        micPlayer.pause()
                    }
                    if let bgMusicPlayer = bgMusicPlayer, bgMusicPlayer.isPlaying {
                        bgMusicPlayer.pause()
                    }
                    for voPlayer in voiceoverPlayersByID.values where voPlayer.rate != 0 {
                        voPlayer.pause()
                    }
                }

                // Poll `output` using `output.itemTime(forHostTime: CACurrentMediaTime)` during playback
                // (or `targetCMTime` when paused/skimming) so `AVPlayerItemVideoOutput` never drops or stalls frames!
                let queryTime: CMTime = {
                    if session.isPlaying {
                        let hostItemTime = output.itemTime(forHostTime: CACurrentMediaTime())
                        if hostItemTime.isValid && abs(CMTimeGetSeconds(hostItemTime) * 1000.0 - sourceMs) < 150.0 {
                            return hostItemTime
                        }
                    }
                    return targetCMTime
                }()

                if output.hasNewPixelBuffer(forItemTime: queryTime),
                   let pixelBuffer = output.copyPixelBuffer(forItemTime: queryTime, itemTimeForDisplay: nil) {
                    lastDecodedFrame = CIImage(cvPixelBuffer: pixelBuffer)
                    lastSeekedSourceMs = sourceMs
                }
            }

            let drawableSize = view.drawableSize
            guard drawableSize.width > 4 && drawableSize.height > 4 else { return }

            // Camera, captions and keycaps are drawn here by the same pass the exporter uses (WYSIWYG).
            let finalCIImage = compositor.composeFrame(
                sourceVideoFrame: lastDecodedFrame,
                sourceTimeMs: sourceMs,
                session: session,
                outputSize: drawableSize,
                includeShortcutOverlay: true,
                webcamVideoFrame: lastWebcamFrame,
                isRealtimePreview: true
            )
            if compositor.lastShortcutHitRects01 != session.previewShortcutHitRects01 {
                session.previewShortcutHitRects01 = compositor.lastShortcutHitRects01
            }

            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
            compositor.ciContext.render(
                finalCIImage,
                to: drawable.texture,
                commandBuffer: commandBuffer,
                bounds: CGRect(origin: .zero, size: drawableSize),
                colorSpace: colorSpace
            )

            commandBuffer.present(drawable)
            commandBuffer.commit()

            if !session.isPlaying {
                if compositor.isAnimatingBackgroundTransition || compositor.isAnimatingPreviewOverlays {
                    if view.isPaused {
                        view.enableSetNeedsDisplay = false
                        view.isPaused = false
                    }
                } else if !view.isPaused {
                    view.isPaused = true
                    view.enableSetNeedsDisplay = true
                }
            }
        }
    }
}
