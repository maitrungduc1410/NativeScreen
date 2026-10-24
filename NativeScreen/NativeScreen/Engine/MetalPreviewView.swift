import Foundation
import SwiftUI
import MetalKit
import AVFoundation
import CoreImage

/// Zero-Idle-CPU `MTKView` wrapper for SwiftUI.
/// - When `session.isPlaying == false`, `mtkView.isPaused = true` and `enableSetNeedsDisplay = true` -> **0.0% CPU / 0.0% GPU**.
/// - Redraws on demand (`needsDisplay = true`) whenever the user scrubs the timeline or edits any inspector/mask property.
public struct MetalPreviewView: NSViewRepresentable {
    public var session: ProjectSession

    public init(session: ProjectSession) {
        self.session = session
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
        mtkView.preferredFramesPerSecond = 60

        // Crucial for 0.0% Idle CPU when paused:
        mtkView.isPaused = !session.isPlaying
        mtkView.enableSetNeedsDisplay = !session.isPlaying

        context.coordinator.attach(mtkView: mtkView)
        return mtkView
    }

    public func updateNSView(_ mtkView: MTKView, context: Context) {
        context.coordinator.updateSession(session, mtkView: mtkView)
    }

    @MainActor
    public final class Coordinator: NSObject, MTKViewDelegate {
        var session: ProjectSession
        let compositor = MetalFrameCompositor()
        weak var mtkView: MTKView?

        private var lastRenderedRevision: UInt64 = .max
        private var lastFrameTickUptime: TimeInterval = 0

        // Video frame decoder for recorded `.mp4` / `.m3u8`
        private var player: AVPlayer?
        private var videoOutput: AVPlayerItemVideoOutput?
        private var loadedVideoURL: URL?
        private var lastDecodedFrame: CIImage?

        init(session: ProjectSession) {
            self.session = session
            super.init()
            setupVideoDecoderIfNeeded(for: session.videoFileURL)
        }

        func attach(mtkView: MTKView) {
            self.mtkView = mtkView
            mtkView.needsDisplay = true
        }

        func updateSession(_ newSession: ProjectSession, mtkView: MTKView) {
            self.session = newSession
            setupVideoDecoderIfNeeded(for: newSession.videoFileURL)

            if newSession.isPlaying {
                if mtkView.isPaused {
                    lastFrameTickUptime = ProcessInfo.processInfo.systemUptime
                    mtkView.enableSetNeedsDisplay = false
                    mtkView.isPaused = false
                }
            } else {
                if !mtkView.isPaused {
                    mtkView.isPaused = true
                    mtkView.enableSetNeedsDisplay = true
                }
                if lastRenderedRevision != newSession.renderRevision {
                    lastRenderedRevision = newSession.renderRevision
                    seekDecoder(toSourceMs: newSession.currentSourceTimeMs)
                    mtkView.needsDisplay = true
                }
            }
        }

        private func setupVideoDecoderIfNeeded(for url: URL) {
            guard loadedVideoURL != url else { return }
            loadedVideoURL = url
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
            seekDecoder(toSourceMs: session.currentSourceTimeMs)
        }

        private func seekDecoder(toSourceMs sourceMs: Double) {
            guard let player = player else { return }
            let cmTime = CMTime(seconds: sourceMs / 1000.0, preferredTimescale: 600)
            player.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self = self, let view = self.mtkView else { return }
                    let targetTime = CMTime(seconds: self.session.currentSourceTimeMs / 1000.0, preferredTimescale: 600)
                    if let output = self.videoOutput,
                       let pb = output.copyPixelBuffer(forItemTime: targetTime, itemTimeForDisplay: nil) {
                        self.lastDecodedFrame = CIImage(cvPixelBuffer: pb)
                    }
                    view.needsDisplay = true
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

            // Advance timeline playhead if actively playing
            if session.isPlaying {
                let now = ProcessInfo.processInfo.systemUptime
                let dtMs = max(0.0, min(50.0, (now - lastFrameTickUptime) * 1000.0))
                lastFrameTickUptime = now

                let nextTimelineMs = session.playheadTimelineMs + dtMs
                if nextTimelineMs >= session.timeMapper.totalTimelineDurationMs {
                    session.playheadTimelineMs = 0.0
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
                if session.isPlaying, let player = player, player.rate == 0 {
                    player.seek(to: targetCMTime, toleranceBefore: .zero, toleranceAfter: .zero)
                    player.play()
                } else if !session.isPlaying, let player = player, player.rate != 0 {
                    player.pause()
                }

                if output.hasNewPixelBuffer(forItemTime: targetCMTime),
                   let pixelBuffer = output.copyPixelBuffer(forItemTime: targetCMTime, itemTimeForDisplay: nil) {
                    lastDecodedFrame = CIImage(cvPixelBuffer: pixelBuffer)
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
        }
    }
}
