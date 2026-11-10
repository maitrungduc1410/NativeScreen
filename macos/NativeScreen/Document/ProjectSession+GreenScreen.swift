import AVFoundation
import CoreImage
import Foundation

extension ProjectSession {
    /// The camera movie: the camera layer, or the main picture of a camera-only recording.
    var cameraPictureFileURL: URL? {
        isCameraOnlyRecording ? videoFileURL : webcamVideoFileURL
    }

    /// Turns on green screen keying with the backdrop color read from the top of the camera picture at the playhead.
    /// Keeps the current color when the frame cannot be read. One undo step.
    func useGreenScreen() async {
        let color = await sampledBackdropColor(atSourceMs: currentSourceTimeMs)
        startNewUndoStep()
        mutate {
            $0.camera.backgroundRemoval = .greenScreen
            if let color { $0.camera.chromaKeyColor = color }
        }
    }

    /// The average color of the top strip of the camera picture at `sourceMs`, as `#RRGGBB`.
    func sampledBackdropColor(atSourceMs sourceMs: Double) async -> String? {
        guard let url = cameraPictureFileURL else { return nil }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 10)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 10)
        let time = CMTime(seconds: max(0.0, sourceMs / 1000.0), preferredTimescale: 600)
        guard let frame = try? await generator.image(at: time).image else { return nil }
        return ChromaKey.sampledBackdropColor(of: CIImage(cgImage: frame), context: CIContext())
    }
}
