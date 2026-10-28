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

        // Video frame decoder for recorded `.mp4` / `.m3u8` + synchronized Microphone `.m4a` & Voiceover audio players
        private var player: AVPlayer?
        private var micPlayer: AVPlayer?
        private var loadedMicURL: URL?
        private var voiceoverPlayersByID: [String: AVPlayer] = [:]
        private var videoOutput: AVPlayerItemVideoOutput?
        private var playerItemStatusObserver: NSKeyValueObservation?
        private var loadedVideoURL: URL?
        private var lastDecodedFrame: CIImage?
        private var lastSeekedSourceMs: Double = -1.0
        private var isDecoderSeeking: Bool = false
        private var pendingSeekSourceMs: Double? = nil

        init(session: ProjectSession) {
            self.session = session
            super.init()
            setupVideoDecoderIfNeeded(for: session.videoFileURL)
            setupMicrophonePlayerIfNeeded(for: session.microphoneAudioFileURL)
        }

        func attach(mtkView: MTKView) {
            self.mtkView = mtkView
            mtkView.needsDisplay = true
        }

        func updateSession(_ newSession: ProjectSession, canvasAspect: Double, mtkView: MTKView) {
            self.session = newSession
            setupVideoDecoderIfNeeded(for: newSession.videoFileURL)
            setupMicrophonePlayerIfNeeded(for: newSession.microphoneAudioFileURL)

            if newSession.isPlaying {
                if mtkView.isPaused {
                    lastFrameTickUptime = ProcessInfo.processInfo.systemUptime
                    mtkView.enableSetNeedsDisplay = false
                    mtkView.isPaused = false
                }
            } else {
                if let micPlayer = micPlayer, micPlayer.rate != 0 {
                    micPlayer.pause()
                }
                for voPlayer in voiceoverPlayersByID.values where voPlayer.rate != 0 {
                    voPlayer.pause()
                }
                let animatingBg = compositor?.isAnimatingBackgroundTransition ?? false
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
                    mtkView.needsDisplay = true
                }
            }
        }

        private func setupVideoDecoderIfNeeded(for url: URL) {
            guard loadedVideoURL != url else { return }
            loadedVideoURL = url
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

                let nextTimelineMs = session.playheadTimelineMs + dtMs
                if nextTimelineMs >= session.timeMapper.totalTimelineDurationMs {
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

                    // Synchronize `micPlayer` (`microphone.m4a`) in lockstep with `player` (`display.mp4`)!
                    if let micPlayer = micPlayer {
                        micPlayer.isMuted = (effectiveMicVolume <= 0.001)
                        micPlayer.volume = effectiveMicVolume
                        let micCurrentMs = max(0.0, CMTimeGetSeconds(micPlayer.currentTime()) * 1000.0)
                        let micDriftMs = abs(micCurrentMs - sourceMs)
                        if abs(micPlayer.rate - desiredRate) > 0.05 || micDriftMs > 180.0 {
                            micPlayer.seek(to: targetCMTime, toleranceBefore: .zero, toleranceAfter: .zero)
                            micPlayer.rate = desiredRate
                        }
                    }

                    // Synchronize any active `VoiceoverSegment`s (`voiceoverPlayersByID`)!
                    let activeVOs = session.activeVoiceovers(atSourceMs: sourceMs)
                    let activeVOIDs = Set(activeVOs.map(\.id))
                    for (voId, voPlayer) in voiceoverPlayersByID where !activeVOIDs.contains(voId) {
                        if voPlayer.rate != 0 {
                            voPlayer.pause()
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
                        let curSec = max(0.0, CMTimeGetSeconds(voPlayer.currentTime()))
                        if abs(voPlayer.rate - voRate) > 0.05 || abs(curSec - voOffsetSec) > 0.22 {
                            voPlayer.seek(to: CMTime(seconds: voOffsetSec, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                            voPlayer.rate = voRate
                        }
                    }

                    // Only seek AVPlayer when starting playback (`rate` changed) or jumping across a cut boundary (`drift > 180ms` while not actively seeking).
                    // Never snap `sourceMs` to `displayTime` (which is quantized at 60Hz = 16.67ms steps), because the 120Hz spring camera & cursor
                    // MUST advance at smooth 8.33ms steps (`session.currentSourceTimeMs`) to avoid 60Hz-vs-120Hz frame-doubling judder during zooms!
                    let playerCurrentMs = max(0.0, CMTimeGetSeconds(player.currentTime()) * 1000.0)
                    let driftMs = abs(playerCurrentMs - sourceMs)
                    if abs(player.rate - desiredRate) > 0.05 || (!isDecoderSeeking && driftMs > 180.0) {
                        isDecoderSeeking = true
                        player.seek(to: targetCMTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                            Task { @MainActor [weak self] in
                                self?.isDecoderSeeking = false
                            }
                        }
                        player.rate = desiredRate
                    }
                } else if !session.isPlaying {
                    if let player = player, player.rate != 0 {
                        player.pause()
                    }
                    if let micPlayer = micPlayer, micPlayer.rate != 0 {
                        micPlayer.pause()
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

            let finalCIImage = compositor.composeFrame(
                sourceVideoFrame: lastDecodedFrame,
                sourceTimeMs: sourceMs,
                session: session,
                outputSize: drawableSize
            )

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
                if compositor.isAnimatingBackgroundTransition {
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
