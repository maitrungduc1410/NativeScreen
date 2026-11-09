import Foundation
import CoreGraphics

/// Where the screen recording and the camera sit on the canvas for one frame (CoreImage coordinates, bottom-left origin).
/// Every field is continuous so two layouts can be blended: timeline transitions blend them over time (identical in
/// preview and export), and the live preview springs between them when a setting is edited.
struct StageLayout: Equatable {
    var screenRect: CGRect
    var camera: CameraPlacement

    struct CameraPlacement: Equatable {
        var rect: CGRect
        var cornerRadius: CGFloat
        var opacity: CGFloat
        var shadowOpacity: CGFloat
        var borderOpacity: CGFloat
        /// Person cutout instead of a rectangular frame (discrete: switches halfway through a transition).
        var isCutout: Bool
        /// Styling of the camera image itself (grade, crop, mirror, delay...); not blended.
        var config: CameraConfig
    }

    /// The discrete settings that, when they change along the timeline, start a transition.
    struct Key: Equatable {
        var config: CameraConfig
        var isFullscreenCamera: Bool
        var isCameraVisible: Bool
    }

    static func blend(_ a: StageLayout, _ b: StageLayout, _ t: CGFloat) -> StageLayout {
        StageLayout(
            screenRect: lerp(a.screenRect, b.screenRect, t),
            camera: CameraPlacement(
                rect: lerp(a.camera.rect, b.camera.rect, t),
                cornerRadius: lerp(a.camera.cornerRadius, b.camera.cornerRadius, t),
                opacity: lerp(a.camera.opacity, b.camera.opacity, t),
                shadowOpacity: lerp(a.camera.shadowOpacity, b.camera.shadowOpacity, t),
                borderOpacity: lerp(a.camera.borderOpacity, b.camera.borderOpacity, t),
                isCutout: t < 0.5 ? a.camera.isCutout : b.camera.isCutout,
                config: b.camera.config
            )
        )
    }

    /// Ease-in-out (smoothstep) used for timeline transitions.
    static func ease(_ t: CGFloat) -> CGFloat {
        let x = min(1.0, max(0.0, t))
        return x * x * (3.0 - 2.0 * x)
    }

    private static func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat {
        a + (b - a) * t
    }

    private static func lerp(_ a: CGRect, _ b: CGRect, _ t: CGFloat) -> CGRect {
        CGRect(
            x: lerp(a.minX, b.minX, t),
            y: lerp(a.minY, b.minY, t),
            width: lerp(a.width, b.width, t),
            height: lerp(a.height, b.height, t)
        )
    }
}

/// A set of independent damped springs (SwiftUI-like `response` / `dampingFraction`) that chase target values.
/// Used only by the live preview, so edits glide into place instead of jumping.
struct SpringVector {
    private(set) var values: [Double]
    private var velocities: [Double]

    init(_ values: [Double]) {
        self.values = values
        self.velocities = Array(repeating: 0.0, count: values.count)
    }

    var isAtRest: Bool {
        velocities.allSatisfy { abs($0) < 0.5 }
    }

    mutating func snap(to target: [Double]) {
        values = target
        velocities = Array(repeating: 0.0, count: target.count)
    }

    /// Advances toward `target` by `dt` seconds. Returns `true` while still moving.
    @discardableResult
    mutating func step(toward target: [Double], dt: Double, response: Double = 0.25, dampingFraction: Double = 0.82) -> Bool {
        guard target.count == values.count else {
            snap(to: target)
            return false
        }
        let omega = 2.0 * .pi / response
        let stiffness = omega * omega
        let damping = 2.0 * dampingFraction * omega
        // Semi-implicit Euler in small substeps stays stable at 60–120 Hz frame times.
        let substeps = max(1, Int(ceil(dt / (1.0 / 240.0))))
        let h = dt / Double(substeps)
        var moving = false
        for i in values.indices {
            var x = values[i]
            var v = velocities[i]
            for _ in 0..<substeps {
                let a = -stiffness * (x - target[i]) - damping * v
                v += a * h
                x += v * h
            }
            let scale = max(1.0, abs(target[i]))
            if abs(x - target[i]) < 0.05 * max(1.0, scale * 0.001) && abs(v) < 0.5 {
                x = target[i]
                v = 0.0
            } else {
                moving = true
            }
            values[i] = x
            velocities[i] = v
        }
        return moving
    }
}

extension StageLayout {
    /// Continuous fields packed for `SpringVector`.
    var animatableValues: [Double] {
        [
            screenRect.minX, screenRect.minY, screenRect.width, screenRect.height,
            camera.rect.minX, camera.rect.minY, camera.rect.width, camera.rect.height,
            camera.cornerRadius, camera.opacity * 1000.0, camera.shadowOpacity * 1000.0, camera.borderOpacity * 1000.0
        ].map(Double.init)
    }

    /// `self` with its continuous fields replaced by `values` (opacities were scaled ×1000 so they settle with pixels).
    func applying(_ v: [Double]) -> StageLayout {
        guard v.count == 12 else { return self }
        var out = self
        out.screenRect = CGRect(x: v[0], y: v[1], width: max(1, v[2]), height: max(1, v[3]))
        out.camera.rect = CGRect(x: v[4], y: v[5], width: max(1, v[6]), height: max(1, v[7]))
        out.camera.cornerRadius = max(0, CGFloat(v[8]))
        out.camera.opacity = min(1, max(0, CGFloat(v[9] / 1000.0)))
        out.camera.shadowOpacity = min(1, max(0, CGFloat(v[10] / 1000.0)))
        out.camera.borderOpacity = min(1, max(0, CGFloat(v[11] / 1000.0)))
        return out
    }
}
