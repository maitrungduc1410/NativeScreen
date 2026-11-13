import CoreGraphics
import Foundation

/// Camera-only recordings: the face keeps the picture framed when it fills the canvas and when it zooms.
extension ProjectSession {
    /// The device frame is for screen recordings; a camera-only picture never gets one, whatever a preset or patch set.
    var usesDeviceMockup: Bool {
        document.frameStyle.deviceMockup.enabled && !isCameraOnlyRecording
    }

    /// Where the face sits at `sourceMs` in the main picture after mirroring and the canvas crop (top-left, 0...1).
    /// Nil unless this is a camera-only recording with face tracking on and a face was found.
    func cameraOnlyFaceCenter01(atSourceMs sourceMs: Double) -> CGPoint? {
        guard isCameraOnlyRecording, document.camera.enableFaceTracking,
              let center = faceTrack?.framingCenter(atMs: sourceMs) else { return nil }
        // The picture is flipped unless `mirror` is on (`croppedAndMirrored`).
        let x = document.camera.mirror ? center.x : 1.0 - center.x
        let crop = document.canvas.cropRect01
        return CGPoint(
            x: (x - CGFloat(crop.x)) / max(0.01, CGFloat(crop.width)),
            y: (center.y - CGFloat(crop.y)) / max(0.01, CGFloat(crop.height))
        )
    }

    /// The zoom camera at `sourceMs`. In a camera-only recording with face tracking on, a zoom centers on the face:
    /// the center moves from the solver's toward the face as the zoom grows in, and stays where the zoomed picture
    /// still covers its frame.
    func evaluatedCamera(atSourceMs sourceMs: Double, timelineMs: Double? = nil) -> SpringTrajectorySolver.CameraFrameState {
        let time = timelineMs ?? timeMapper.timelineTime(forSourceMs: sourceMs, withinSliceAtTimelineMs: effectivePreviewTimelineMs)
            ?? timeMapper.timelineTime(forSourceMs: sourceMs) ?? 0
        var camera = trajectorySolver.evaluate(atTimelineMs: time).camera
        guard camera.scale > 1.0005,
              let face = cameraOnlyFaceCenter01(atSourceMs: sourceMs) else { return camera }
        let progress = min(1.0, (camera.scale - 1.0) / 0.25)
        let half = 0.5 / camera.scale
        let fx = min(1.0 - half, max(half, Double(face.x)))
        let fy = min(1.0 - half, max(half, Double(face.y)))
        camera.center01 = Point01(
            x: camera.center01.x + (fx - camera.center01.x) * progress,
            y: camera.center01.y + (fy - camera.center01.y) * progress
        )
        return camera
    }
}
