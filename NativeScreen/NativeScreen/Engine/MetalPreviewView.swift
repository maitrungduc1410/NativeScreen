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

        // Video frame decoder for recorded `.mp4` / `.m3u8`
        private var player: AVPlayer?
        private var videoOutput: AVPlayerItemVideoOutput?
        private var loadedVideoURL: URL?
        private var lastDecodedFrame: CIImage?
        private var lastSeekedSourceMs: Double = -1.0
        private var isDecoderSeeking: Bool = false
        private var pendingSeekSourceMs: Double? = nil

        init(session: ProjectSession) {
            self.session = session
            super.init()
            setupVideoDecoderIfNeeded(for: session.videoFileURL)
        }

        func attach(mtkView: MTKView) {
            self.mtkView = mtkView
            mtkView.needsDisplay = true
        }

        func updateSession(_ newSession: ProjectSession, canvasAspect: Double, mtkView: MTKView) {
            self.session = newSession
            setupVideoDecoderIfNeeded(for: newSession.videoFileURL)

            if newSession.isPlaying {
                if mtkView.isPaused {
                    lastFrameTickUptime = ProcessInfo.processInfo.systemUptime
                    mtkView.enableSetNeedsDisplay = false
                    mtkView.isPaused = false
                }
            } else {
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
            seekDecoderCoalesced(toSourceMs: session.currentSourceTimeMs, fastSkim: false)
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
                let now = ProcessInfo.processInfo.systemUptime
                let dtMs = max(0.0, min(50.0, (now - lastFrameTickUptime) * 1000.0)) * session.previewPlaybackRate
                lastFrameTickUptime = now

                let nextTimelineMs = session.playheadTimelineMs + dtMs
                if nextTimelineMs >= session.timeMapper.totalTimelineDurationMs {
                    session.playheadTimelineMs = session.timeMapper.totalTimelineDurationMs
                    session.isPlaying = false
                    view.isPaused = true
                    view.enableSetNeedsDisplay = true
                } else {
                    session.playheadTimelineMs = nextTimelineMs
                }
            }

            let sourceMs = session.currentSourceTimeMs
            let targetCMTime = CMTime(seconds: sourceMs / 1000.0, preferredTimescale: 600)

            if let output = videoOutput {
                let activeSlice = session.currentActiveSlice
                let sliceSpeed = activeSlice?.speed ?? 1.0
                let sliceVol = (activeSlice?.muted == true) ? 0.0 : (activeSlice?.systemAudioVolume ?? 1.0)
                let effectiveVolume = Float(min(2.0, max(0.0, sliceVol * session.document.audio.systemAudioVolume)))
                let desiredRate = Float(session.previewPlaybackRate * sliceSpeed)
                if session.isPlaying, let player = player {
                    player.isMuted = (effectiveVolume <= 0.001)
                    player.volume = effectiveVolume
                    if abs(player.rate - desiredRate) > 0.05 {
                        player.seek(to: targetCMTime, toleranceBefore: .zero, toleranceAfter: .zero)
                        player.rate = desiredRate
                    }
                } else if !session.isPlaying, let player = player, player.rate != 0 {
                    player.pause()
                }

                if output.hasNewPixelBuffer(forItemTime: targetCMTime),
                   let pixelBuffer = output.copyPixelBuffer(forItemTime: targetCMTime, itemTimeForDisplay: nil) {
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
