import Foundation
import AppKit
import CoreGraphics
import CoreImage

/// High-DPI Vector Cursor Theme Catalog & Sprite Rasterizer.
/// Includes the full collection of cursor styles (macOS Tahoe, macOS Classic, Touch Circle,
/// White Bold Arrow, Neo Sharp, Retro Pixel, Minimal Dart, Outline Arrow, plus dynamic Pointing Hand & I-Beam shapes).
public struct CursorThemePreset: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let subtitle: String
    public let hotspot01: Point01 // Normalized hotspot within sprite (top-left origin)

    public static let allThemes: [CursorThemePreset] = [
        CursorThemePreset(
            id: "macos-tahoe",
            name: "macOS Tahoe",
            subtitle: "Rounded modern macOS pointer",
            hotspot01: Point01(x: 0.22, y: 0.14)
        ),
        CursorThemePreset(
            id: "macos-classic",
            name: "macOS Classic",
            subtitle: "Crisp classic Apple arrow",
            hotspot01: Point01(x: 0.22, y: 0.14)
        ),
        CursorThemePreset(
            id: "white-arrow",
            name: "White Studio",
            subtitle: "Bright white arrow with dark border",
            hotspot01: Point01(x: 0.22, y: 0.14)
        ),
        CursorThemePreset(
            id: "figma-collaborator",
            name: "Figma Dart",
            subtitle: "Sleek angled presentation dart",
            hotspot01: Point01(x: 0.20, y: 0.18)
        ),
        CursorThemePreset(
            id: "Outline-bold",
            name: "Bold Outline",
            subtitle: "High-contrast hollow arrow",
            hotspot01: Point01(x: 0.22, y: 0.14)
        ),
        CursorThemePreset(
            id: "touch-circle",
            name: "Touch Circle",
            subtitle: "Translucent iOS/iPadOS touch disc",
            hotspot01: Point01(x: 0.50, y: 0.50)
        ),
        CursorThemePreset(
            id: "touch-ring",
            name: "Spotlight Ring",
            subtitle: "Crisp ring with center dot",
            hotspot01: Point01(x: 0.50, y: 0.50)
        ),
        CursorThemePreset(
            id: "retro-pixel",
            name: "Retro Pixel",
            subtitle: "Classic 1984 pixel art pointer",
            hotspot01: Point01(x: 0.22, y: 0.14)
        )
    ]

    public static func theme(withId id: String) -> CursorThemePreset {
        if id == "macos-default" {
            return allThemes[0]
        }
        return allThemes.first(where: { $0.id == id }) ?? allThemes[0]
    }
}

public final class CursorSpriteProvider {
    public static let shared = CursorSpriteProvider()

    private var ciCache: [String: CIImage] = [:]
    private var nsImageCache: [String: NSImage] = [:]
    private let lock = NSLock()

    private init() {}

    public func ciCursorImage(themeId: String, cursorType: String) -> (image: CIImage, hotspot01: Point01) {
        let effectiveTheme = (themeId == "macos-default") ? "macos-tahoe" : themeId
        let cacheKey = "\(effectiveTheme)__\(cursorType)"

        lock.lock()
        if let cached = ciCache[cacheKey] {
            lock.unlock()
            return (cached, hotspot(forTheme: effectiveTheme, cursorType: cursorType))
        }
        lock.unlock()

        let rendered = renderHighResCursorCGImage(themeId: effectiveTheme, cursorType: cursorType, pixelSize: 256)
        let ciImg = CIImage(cgImage: rendered)

        lock.lock()
        ciCache[cacheKey] = ciImg
        lock.unlock()

        return (ciImg, hotspot(forTheme: effectiveTheme, cursorType: cursorType))
    }

    public func previewNSImage(themeId: String, cursorType: String = "arrow") -> NSImage {
        let effectiveTheme = (themeId == "macos-default") ? "macos-tahoe" : themeId
        let cacheKey = "preview_\(effectiveTheme)__\(cursorType)"

        lock.lock()
        if let cached = nsImageCache[cacheKey] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let cgImg = renderHighResCursorCGImage(themeId: effectiveTheme, cursorType: cursorType, pixelSize: 128)
        let nsImg = NSImage(cgImage: cgImg, size: NSSize(width: 64, height: 64))

        lock.lock()
        nsImageCache[cacheKey] = nsImg
        lock.unlock()
        return nsImg
    }

    private func hotspot(forTheme themeId: String, cursorType: String) -> Point01 {
        if cursorType == "pointingHand" {
            return Point01(x: 0.38, y: 0.16)
        }
        if cursorType == "iBeam" {
            return Point01(x: 0.50, y: 0.50)
        }
        if cursorType == "crosshair" {
            return Point01(x: 0.50, y: 0.50)
        }
        return CursorThemePreset.theme(withId: themeId).hotspot01
    }

    // MARK: - High-Resolution Vector Rasterizer (256x256 Retina Sprite with Soft Drop Shadow)

    private func renderHighResCursorCGImage(themeId: String, cursorType: String, pixelSize: Int) -> CGImage {
        let size = CGSize(width: pixelSize, height: pixelSize)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil,
            width: pixelSize,
            height: pixelSize,
            bitsPerComponent: 8,
            bytesPerRow: pixelSize * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!

        // Flip to top-left origin so SVG/Quartz coordinates match naturally
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: size.width / 256.0, y: -size.height / 256.0)

        // Dynamic cursor shape override when hovering links or text inputs
        if cursorType == "iBeam" {
            drawIBeamCursor(in: ctx)
            return ctx.makeImage()!
        }
        if cursorType == "pointingHand" && themeId != "touch-circle" && themeId != "touch-ring" {
            drawPointingHandCursor(in: ctx)
            return ctx.makeImage()!
        }

        switch themeId {
        case "macos-tahoe":
            drawMacOSTahoeArrow(in: ctx, fillColor: CGColor(red: 0.05, green: 0.05, blue: 0.07, alpha: 1.0), strokeColor: .white)
        case "macos-classic":
            drawMacOSClassicArrow(in: ctx, fillColor: CGColor(red: 0.04, green: 0.04, blue: 0.05, alpha: 1.0), strokeColor: .white)
        case "white-arrow":
            drawMacOSTahoeArrow(in: ctx, fillColor: .white, strokeColor: CGColor(red: 0.08, green: 0.08, blue: 0.11, alpha: 1.0))
        case "figma-collaborator":
            drawFigmaDartCursor(in: ctx)
        case "Outline-bold":
            drawBoldOutlineArrow(in: ctx)
        case "touch-circle":
            drawTouchDiscCursor(in: ctx)
        case "touch-ring":
            drawSpotlightRingCursor(in: ctx)
        case "retro-pixel":
            drawRetroPixelArrow(in: ctx)
        default:
            drawMacOSTahoeArrow(in: ctx, fillColor: CGColor(red: 0.05, green: 0.05, blue: 0.07, alpha: 1.0), strokeColor: .white)
        }

        return ctx.makeImage()!
    }

    // 1. macOS Tahoe Rounded Arrow (Matches the `sets/macos-tahoe/pointer-1__14-6.svg`)
    private func drawMacOSTahoeArrow(in ctx: CGContext, fillColor: CGColor, strokeColor: CGColor) {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 7), blur: 14, color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.55))

        let path = CGMutablePath()
        path.move(to: CGPoint(x: 56, y: 34))
        path.addLine(to: CGPoint(x: 186, y: 152))
        path.addQuadCurve(to: CGPoint(x: 174, y: 170), control: CGPoint(x: 194, y: 162))
        path.addLine(to: CGPoint(x: 128, y: 170))
        path.addLine(to: CGPoint(x: 156, y: 226))
        path.addQuadCurve(to: CGPoint(x: 136, y: 242), control: CGPoint(x: 160, y: 238))
        path.addQuadCurve(to: CGPoint(x: 120, y: 234), control: CGPoint(x: 126, y: 244))
        path.addLine(to: CGPoint(x: 92, y: 178))
        path.addLine(to: CGPoint(x: 62, y: 206))
        path.addQuadCurve(to: CGPoint(x: 48, y: 194), control: CGPoint(x: 50, y: 210))
        path.addLine(to: CGPoint(x: 48, y: 42))
        path.addQuadCurve(to: CGPoint(x: 56, y: 34), control: CGPoint(x: 48, y: 30))
        path.closeSubpath()

        ctx.addPath(path)
        ctx.setFillColor(strokeColor)
        ctx.setStrokeColor(strokeColor)
        ctx.setLineWidth(18)
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)
        ctx.drawPath(using: .fillStroke)
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(path)
        ctx.setFillColor(fillColor)
        ctx.fillPath()
        ctx.restoreGState()
    }

    // 2. macOS Classic Sharp Arrow
    private func drawMacOSClassicArrow(in ctx: CGContext, fillColor: CGColor, strokeColor: CGColor) {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 6), blur: 12, color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.55))

        let path = CGMutablePath()
        path.move(to: CGPoint(x: 52, y: 30))
        path.addLine(to: CGPoint(x: 184, y: 158))
        path.addLine(to: CGPoint(x: 124, y: 162))
        path.addLine(to: CGPoint(x: 156, y: 228))
        path.addLine(to: CGPoint(x: 128, y: 240))
        path.addLine(to: CGPoint(x: 96, y: 174))
        path.addLine(to: CGPoint(x: 52, y: 212))
        path.closeSubpath()

        ctx.addPath(path)
        ctx.setStrokeColor(strokeColor)
        ctx.setLineWidth(14)
        ctx.setLineJoin(.round)
        ctx.strokePath()

        ctx.addPath(path)
        ctx.setFillColor(fillColor)
        ctx.fillPath()
        ctx.restoreGState()
    }

    // 3. Figma / Modern Presentation Dart
    private func drawFigmaDartCursor(in ctx: CGContext) {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 7), blur: 14, color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.55))

        let path = CGMutablePath()
        path.move(to: CGPoint(x: 46, y: 42))
        path.addLine(to: CGPoint(x: 208, y: 108))
        path.addLine(to: CGPoint(x: 132, y: 142))
        path.addLine(to: CGPoint(x: 104, y: 218))
        path.closeSubpath()

        ctx.addPath(path)
        ctx.setStrokeColor(CGColor.white)
        ctx.setLineWidth(16)
        ctx.setLineJoin(.round)
        ctx.strokePath()

        ctx.addPath(path)
        ctx.setFillColor(CGColor(red: 0.42, green: 0.32, blue: 0.98, alpha: 1.0))
        ctx.fillPath()
        ctx.restoreGState()
    }

    // 4. Bold Outline Arrow
    private func drawBoldOutlineArrow(in ctx: CGContext) {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 6), blur: 12, color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.6))

        let path = CGMutablePath()
        path.move(to: CGPoint(x: 54, y: 34))
        path.addLine(to: CGPoint(x: 186, y: 158))
        path.addLine(to: CGPoint(x: 124, y: 164))
        path.addLine(to: CGPoint(x: 154, y: 226))
        path.addLine(to: CGPoint(x: 126, y: 238))
        path.addLine(to: CGPoint(x: 96, y: 174))
        path.addLine(to: CGPoint(x: 54, y: 210))
        path.closeSubpath()

        ctx.addPath(path)
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.18))
        ctx.fillPath()

        ctx.addPath(path)
        ctx.setStrokeColor(CGColor.white)
        ctx.setLineWidth(12)
        ctx.setLineJoin(.round)
        ctx.strokePath()
        ctx.restoreGState()
    }

    // 5. Touch Circle Disc (Matches `touch-cursor.svg`)
    private func drawTouchDiscCursor(in ctx: CGContext) {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 5), blur: 12, color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.45))

        let rect = CGRect(x: 44, y: 44, width: 168, height: 168)
        ctx.setFillColor(CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.46))
        ctx.fillEllipse(in: rect)

        ctx.setStrokeColor(CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.92))
        ctx.setLineWidth(7)
        ctx.strokeEllipse(in: rect)
        ctx.restoreGState()
    }

    // 6. Spotlight Ring Cursor
    private func drawSpotlightRingCursor(in ctx: CGContext) {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 5), blur: 12, color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.55))

        let outer = CGRect(x: 42, y: 42, width: 172, height: 172)
        ctx.setStrokeColor(CGColor(red: 0.48, green: 0.38, blue: 1.0, alpha: 0.95))
        ctx.setLineWidth(12)
        ctx.strokeEllipse(in: outer)

        let centerDot = CGRect(x: 112, y: 112, width: 32, height: 32)
        ctx.setFillColor(CGColor.white)
        ctx.fillEllipse(in: centerDot)
        ctx.restoreGState()
    }

    // 7. Retro Pixel Arrow (Matches `custom-3` pixel-art style)
    private func drawRetroPixelArrow(in ctx: CGContext) {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 6), blur: 10, color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.55))

        let path = CGMutablePath()
        path.move(to: CGPoint(x: 52, y: 32))
        path.addLine(to: CGPoint(x: 180, y: 160))
        path.addLine(to: CGPoint(x: 120, y: 160))
        path.addLine(to: CGPoint(x: 148, y: 224))
        path.addLine(to: CGPoint(x: 116, y: 236))
        path.addLine(to: CGPoint(x: 88, y: 172))
        path.addLine(to: CGPoint(x: 52, y: 208))
        path.closeSubpath()

        ctx.addPath(path)
        ctx.setFillColor(CGColor.white)
        ctx.fillPath()

        ctx.addPath(path)
        ctx.setStrokeColor(CGColor(red: 0.08, green: 0.08, blue: 0.08, alpha: 1.0))
        ctx.setLineWidth(12)
        ctx.setLineJoin(.miter)
        ctx.strokePath()
        ctx.restoreGState()
    }

    // 8. Pointing Hand Cursor (`pointingHand`)
    private func drawPointingHandCursor(in ctx: CGContext) {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 6), blur: 12, color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.55))

        let path = CGMutablePath()
        // Index finger + palm silhouette
        path.addRoundedRect(in: CGRect(x: 84, y: 28, width: 30, height: 115), cornerWidth: 14, cornerHeight: 14)
        path.addRoundedRect(in: CGRect(x: 114, y: 78, width: 28, height: 80), cornerWidth: 12, cornerHeight: 12)
        path.addRoundedRect(in: CGRect(x: 142, y: 88, width: 28, height: 75), cornerWidth: 12, cornerHeight: 12)
        path.addRoundedRect(in: CGRect(x: 170, y: 102, width: 26, height: 68), cornerWidth: 12, cornerHeight: 12)
        path.addRoundedRect(in: CGRect(x: 72, y: 112, width: 124, height: 104), cornerWidth: 42, cornerHeight: 42)

        ctx.addPath(path)
        ctx.setStrokeColor(CGColor.black)
        ctx.setLineWidth(14)
        ctx.setLineJoin(.round)
        ctx.strokePath()

        ctx.addPath(path)
        ctx.setFillColor(CGColor.white)
        ctx.fillPath()
        ctx.restoreGState()
    }

    // 9. Text Selection I-Beam Cursor (`iBeam`)
    private func drawIBeamCursor(in ctx: CGContext) {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 4), blur: 10, color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.6))

        let path = CGMutablePath()
        path.addRoundedRect(in: CGRect(x: 118, y: 40, width: 20, height: 176), cornerWidth: 8, cornerHeight: 8)
        path.addRoundedRect(in: CGRect(x: 84, y: 34, width: 88, height: 20), cornerWidth: 9, cornerHeight: 9)
        path.addRoundedRect(in: CGRect(x: 84, y: 202, width: 88, height: 20), cornerWidth: 9, cornerHeight: 9)

        ctx.addPath(path)
        ctx.setStrokeColor(CGColor.white)
        ctx.setLineWidth(10)
        ctx.strokePath()

        ctx.addPath(path)
        ctx.setFillColor(CGColor(red: 0.06, green: 0.06, blue: 0.08, alpha: 1.0))
        ctx.fillPath()
        ctx.restoreGState()
    }
}
