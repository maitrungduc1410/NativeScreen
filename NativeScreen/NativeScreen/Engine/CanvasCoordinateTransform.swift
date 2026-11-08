import Foundation
import CoreGraphics

/// Unified coordinate transformer shared between `MetalFrameCompositor` (GPU shader pass)
/// and `InteractiveMaskCanvasOverlayView` (SwiftUI interactive handles).
/// Guarantees that source-space normalized coordinates `[0.0, 1.0]` map to the exact same pixels
/// under any Virtual Camera Zoom & Pan state.
public struct CanvasCoordinateTransform: Sendable {
    public let canvasSize: CGSize
    public let baseScreenRect: CGRect // Unzoomed screen rect in top-left canvas coordinates
    public let cropRect01: Rect01
    public let cameraCenter01: Point01
    public let cameraScale: CGFloat

    /// `screenRectBottomLeft` is `StageLayout.screenRect` for this canvas, so the handles sit on the frame the
    /// compositor draws (padding, device mockup, split screen). Source rects are in full-frame coordinates, as masks are.
    public init(
        canvasSize: CGSize,
        screenRectBottomLeft: CGRect,
        cropRect01: Rect01,
        cameraCenter01: Point01,
        cameraScale: Double
    ) {
        self.canvasSize = canvasSize
        self.cropRect01 = cropRect01
        self.cameraCenter01 = cameraCenter01
        self.cameraScale = CGFloat(max(1.0, cameraScale))
        self.baseScreenRect = CGRect(
            x: screenRectBottomLeft.minX,
            y: canvasSize.height - screenRectBottomLeft.maxY,
            width: max(1.0, screenRectBottomLeft.width),
            height: max(1.0, screenRectBottomLeft.height)
        )
    }

    /// Focus point in unzoomed top-left canvas coordinates.
    private var focusCanvasPoint: CGPoint {
        CGPoint(
            x: baseScreenRect.minX + CGFloat(cameraCenter01.x) * baseScreenRect.width,
            y: baseScreenRect.minY + CGFloat(cameraCenter01.y) * baseScreenRect.height
        )
    }

    /// Maps a source-clip normalized point `[0.0, 1.0]` (top-left origin) to top-left canvas coordinates,
    /// accounting for current Virtual Camera Zoom & Pan.
    public func canvasPoint(fromSource01 p01: Point01) -> CGPoint {
        let cropX = (p01.x - cropRect01.x) / max(0.0001, cropRect01.width)
        let cropY = (p01.y - cropRect01.y) / max(0.0001, cropRect01.height)
        let unzoomedX = baseScreenRect.minX + CGFloat(cropX) * baseScreenRect.width
        let unzoomedY = baseScreenRect.minY + CGFloat(cropY) * baseScreenRect.height
        guard cameraScale > 1.001 else {
            return CGPoint(x: unzoomedX, y: unzoomedY)
        }
        let focus = focusCanvasPoint
        let centerX = canvasSize.width * 0.5
        let centerY = canvasSize.height * 0.5
        return CGPoint(
            x: centerX + (unzoomedX - focus.x) * cameraScale,
            y: centerY + (unzoomedY - focus.y) * cameraScale
        )
    }

    /// Maps a source-clip normalized rectangle `[0.0, 1.0]` (top-left origin) to top-left canvas coordinates.
    public func canvasRect(fromSourceRect01 r01: Rect01) -> CGRect {
        let topLeft = canvasPoint(fromSource01: Point01(x: r01.x, y: r01.y))
        let bottomRight = canvasPoint(fromSource01: Point01(x: r01.x + r01.width, y: r01.y + r01.height))
        return CGRect(
            x: topLeft.x,
            y: topLeft.y,
            width: bottomRight.x - topLeft.x,
            height: bottomRight.y - topLeft.y
        )
    }

    /// Inverse mapping: converts a point on the preview canvas (top-left origin) back into source-clip normalized `[0.0, 1.0]` coordinates.
    public func sourcePoint01(fromCanvasPoint pt: CGPoint) -> Point01 {
        let unzoomedX: CGFloat
        let unzoomedY: CGFloat
        if cameraScale > 1.001 {
            let focus = focusCanvasPoint
            let centerX = canvasSize.width * 0.5
            let centerY = canvasSize.height * 0.5
            unzoomedX = focus.x + (pt.x - centerX) / cameraScale
            unzoomedY = focus.y + (pt.y - centerY) / cameraScale
        } else {
            unzoomedX = pt.x
            unzoomedY = pt.y
        }
        let sx = Double((unzoomedX - baseScreenRect.minX) / max(1.0, baseScreenRect.width))
        let sy = Double((unzoomedY - baseScreenRect.minY) / max(1.0, baseScreenRect.height))
        return Point01(x: cropRect01.x + sx * cropRect01.width, y: cropRect01.y + sy * cropRect01.height)
    }

    /// Converts a canvas drag delta `(dx, dy)` into source-clip normalized delta `(dx01, dy01)`.
    public func sourceDelta01(fromCanvasDelta delta: CGSize) -> Point01 {
        let effWidth = max(1.0, baseScreenRect.width * cameraScale)
        let effHeight = max(1.0, baseScreenRect.height * cameraScale)
        return Point01(
            x: Double(delta.width / effWidth) * cropRect01.width,
            y: Double(delta.height / effHeight) * cropRect01.height
        )
    }
}
