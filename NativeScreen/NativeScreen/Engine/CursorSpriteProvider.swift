import Foundation
import AppKit
import CoreGraphics
import CoreImage
import AVFoundation

/// Descriptor for a single cursor SVG variant inside a cursor set
/// (e.g. `pointer-1__8-5.svg` -> `id = "pointer-1"`, `kind = "pointer"`, `variantNumber = 1`, `hotspot01 = (0.08, 0.05)`).
public struct CursorVariantDescriptor: Identifiable, Equatable, Sendable {
    public let id: String          // e.g. "pointer-1", "pointer-2"
    public let setId: String       // e.g. "custom-7", "macos-tahoe"
    public let kind: String        // e.g. "pointer", "pointinghand", "ibeamstroke"
    public let variantNumber: Int  // 1, 2, 3...
    public let hotspot01: Point01
    public let fileURL: URL
}

/// High-DPI Vector Cursor Theme Catalog & Sprite Rasterizer.
/// Loads all 24 official cursor sets (`macos`, `macos-tahoe`, `touch`, `custom-1`...`custom-20`, `halloween`)
/// and all of their SVG variants & hotspots from `CursorAssets.bundle/cursors/sets/`.
public struct CursorThemePreset: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let subtitle: String
    public let hotspot01: Point01
    public let pointerVariants: [CursorVariantDescriptor]
    public let allSprites: [CursorVariantDescriptor]

    /// the display order ( & 4: `macos`, `macos-tahoe`, `touch`, `custom-7`, `custom-4`, `custom-2`, ...).
    public static let preferredOrder: [String] = [
        "macos",
        "macos-tahoe",
        "touch",
        "custom-7",
        "custom-4",
        "custom-2",
        "custom-1",
        "custom-3",
        "custom-5",
        "custom-6",
        "custom-8",
        "custom-9",
        "custom-10",
        "custom-11",
        "custom-12",
        "custom-13",
        "custom-14",
        "custom-15",
        "custom-16",
        "custom-17",
        "custom-18",
        "custom-19",
        "custom-20",
        "halloween"
    ]

    public static let allThemes: [CursorThemePreset] = loadAllBundledThemes()

    public static func theme(withId id: String) -> CursorThemePreset {
        let normalized = normalizeThemeId(id)
        return allThemes.first(where: { $0.id == normalized }) ?? allThemes.first(where: { $0.id == "macos-tahoe" }) ?? allThemes[0]
    }

    public static func normalizeThemeId(_ id: String) -> String {
        switch id {
        case "macos-default": return "macos-tahoe"
        case "macos-classic": return "macos"
        case "touch-circle", "touch-ring": return "touch"
        case "white-arrow": return "custom-4"
        case "figma-collaborator": return "custom-6"
        case "Outline-bold": return "custom-2"
        case "retro-pixel": return "custom-8"
        default: return id
        }
    }

    // MARK: - Bundle Discovery

    public static func cursorAssetsRootURL() -> URL? {
        if let bundleURL = Bundle.main.url(forResource: "CursorAssets", withExtension: "bundle") {
            return bundleURL
        }
        if let resURL = Bundle.main.resourceURL?.appendingPathComponent("CursorAssets.bundle"),
           FileManager.default.fileExists(atPath: resURL.path) {
            return resURL
        }
        return nil
    }

    private static func loadAllBundledThemes() -> [CursorThemePreset] {
        guard let root = cursorAssetsRootURL() else {
            return fallbackProceduralThemes()
        }
        let setsURL = root.appendingPathComponent("cursors/sets", isDirectory: true)
        let fm = FileManager.default
        guard let dirNames = try? fm.contentsOfDirectory(atPath: setsURL.path) else {
            return fallbackProceduralThemes()
        }

        var loadedById: [String: CursorThemePreset] = [:]
        for setId in dirNames {
            let setDir = setsURL.appendingPathComponent(setId, isDirectory: true)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: setDir.path, isDirectory: &isDir), isDir.boolValue,
                  let files = try? fm.contentsOfDirectory(atPath: setDir.path) else {
                continue
            }

            let descriptors: [CursorVariantDescriptor] = files
                .filter { $0.hasSuffix(".svg") }
                .compactMap { parseDescriptor(filename: $0, setId: setId, setDir: setDir) }
                .sorted { a, b in
                    if a.kind != b.kind {
                        if a.kind == "pointer" { return true }
                        if b.kind == "pointer" { return false }
                        return a.kind < b.kind
                    }
                    return a.variantNumber < b.variantNumber
                }

            guard !descriptors.isEmpty else { continue }
            let pointers = descriptors.filter { $0.kind == "pointer" }
            let primary = pointers.first ?? descriptors[0]

            loadedById[setId] = CursorThemePreset(
                id: setId,
                name: displayName(forSetId: setId),
                subtitle: setId,
                hotspot01: primary.hotspot01,
                pointerVariants: pointers.count >= 2 ? pointers : [],
                allSprites: descriptors
            )
        }

        guard !loadedById.isEmpty else {
            return fallbackProceduralThemes()
        }

        var ordered: [CursorThemePreset] = []
        for id in preferredOrder {
            if let preset = loadedById.removeValue(forKey: id) {
                ordered.append(preset)
            }
        }
        for (_, remaining) in loadedById.sorted(by: { $0.key < $1.key }) {
            ordered.append(remaining)
        }
        return ordered
    }

    /// Parses filenames like `pointer-1__14-6.svg` or `pointer-1__8-7.svg.svg`.
    private static func parseDescriptor(filename: String, setId: String, setDir: URL) -> CursorVariantDescriptor? {
        var base = filename
        while base.hasSuffix(".svg") {
            base = String(base.dropLast(4))
        }
        let parts = base.components(separatedBy: "__")
        guard parts.count == 2 else { return nil }

        let idPart = parts[0] // e.g. "pointer-1"
        let hotspotPart = parts[1] // e.g. "14-6"

        let idPieces = idPart.split(separator: "-")
        let kind = idPieces.first.map(String.init) ?? "pointer"
        let variantNum = idPieces.last.flatMap { Int($0) } ?? 1

        let hotspotPieces = hotspotPart.split(separator: "-")
        let hx = hotspotPieces.first.flatMap { Double($0) } ?? 14.0
        let hy = hotspotPieces.last.flatMap { Double($0) } ?? 10.0

        return CursorVariantDescriptor(
            id: idPart,
            setId: setId,
            kind: kind,
            variantNumber: variantNum,
            hotspot01: Point01(x: hx / 100.0, y: hy / 100.0),
            fileURL: setDir.appendingPathComponent(filename)
        )
    }

    private static func displayName(forSetId setId: String) -> String {
        switch setId {
        case "macos": return "macOS Classic"
        case "macos-tahoe": return "macOS Tahoe"
        case "touch": return "Touch"
        case "halloween": return "Halloween"
        default:
            if setId.hasPrefix("custom-"), let num = Int(setId.dropFirst(7)) {
                return "Style \(num)"
            }
            return setId.capitalized
        }
    }

    private static func fallbackProceduralThemes() -> [CursorThemePreset] {
        [
            CursorThemePreset(
                id: "macos-tahoe",
                name: "macOS Tahoe",
                subtitle: "Rounded modern macOS pointer",
                hotspot01: Point01(x: 0.14, y: 0.06),
                pointerVariants: [],
                allSprites: []
            ),
            CursorThemePreset(
                id: "macos",
                name: "macOS Classic",
                subtitle: "Classic macOS pointer",
                hotspot01: Point01(x: 0.34, y: 0.24),
                pointerVariants: [],
                allSprites: []
            ),
            CursorThemePreset(
                id: "touch",
                name: "Touch",
                subtitle: "Touch circle",
                hotspot01: Point01(x: 0.50, y: 0.50),
                pointerVariants: [],
                allSprites: []
            )
        ]
    }
}

// MARK: - High-DPI Cursor Sprite Provider (Loads SVG sets + Variants into GPU-Cached CIImages & NSImages)

public final class CursorSpriteProvider {
    public static let shared = CursorSpriteProvider()

    private var ciCache: [String: (image: CIImage, hotspot01: Point01)] = [:]
    private var nsImageCache: [String: NSImage] = [:]
    private let lock = NSLock()

    private init() {}

    /// Resolves the active `CIImage` sprite and its normalized `(0..1)` hotspot for the given `CursorConfig` and `cursorType`.
    public func ciCursorImage(
        themeId: String,
        variantId: String? = nil,
        alwaysUsePointer: Bool = false,
        cursorType: String
    ) -> (image: CIImage, hotspot01: Point01) {
        let normalizedTheme = CursorThemePreset.normalizeThemeId(themeId)
        let effectiveType = alwaysUsePointer ? "arrow" : cursorType
        let cacheKey = "\(normalizedTheme)__\(variantId ?? "default")__\(effectiveType)"

        lock.lock()
        if let cached = ciCache[cacheKey] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let resolved = resolveCGImageAndHotspot(
            themeId: normalizedTheme,
            variantId: variantId,
            cursorType: effectiveType,
            pixelSize: 256,
            forInspectorPreview: false
        )
        let result = (image: CIImage(cgImage: resolved.cgImage), hotspot01: resolved.hotspot01)

        lock.lock()
        ciCache[cacheKey] = result
        lock.unlock()
        return result
    }

    /// Returns a crisp `NSImage` for the Cursor Inspector horizontal selector cards (and variant cards).
    public func previewNSImage(themeId: String, variantId: String? = nil, cursorType: String = "arrow") -> NSImage {
        let normalizedTheme = CursorThemePreset.normalizeThemeId(themeId)
        let cacheKey = "preview__\(normalizedTheme)__\(variantId ?? "default")__\(cursorType)"

        lock.lock()
        if let cached = nsImageCache[cacheKey] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let resolved = resolveCGImageAndHotspot(
            themeId: normalizedTheme,
            variantId: variantId,
            cursorType: cursorType,
            pixelSize: 128,
            forInspectorPreview: true
        )
        let nsImg = NSImage(cgImage: resolved.cgImage, size: NSSize(width: 64, height: 64))

        lock.lock()
        nsImageCache[cacheKey] = nsImg
        lock.unlock()
        return nsImg
    }

    private func mapTelemetryCursorKind(_ rawKind: String) -> String {
        switch rawKind {
        case "arrow", "pointer", "default": return "pointer"
        case "pointingHand", "pointinghand": return "pointinghand"
        case "iBeam", "ibeam", "ibeamstroke": return "ibeamstroke"
        case "crosshair", "cross": return "cross"
        case "closedHand", "closedhand": return "closedhand"
        case "openHand", "openhand": return "openhand"
        default: return "pointer"
        }
    }

    private func resolveCGImageAndHotspot(
        themeId: String,
        variantId: String?,
        cursorType: String,
        pixelSize: Int,
        forInspectorPreview: Bool
    ) -> (cgImage: CGImage, hotspot01: Point01) {
        let theme = CursorThemePreset.theme(withId: themeId)
        let mappedKind = mapTelemetryCursorKind(cursorType)

        // Find matching descriptor in the bundled SVG cursor set
        var chosenDescriptor: CursorVariantDescriptor?
        if mappedKind == "pointer" {
            if let vId = variantId,
               let match = theme.pointerVariants.first(where: { $0.id == vId }) ?? theme.allSprites.first(where: { $0.id == vId }) {
                chosenDescriptor = match
            } else {
                chosenDescriptor = theme.allSprites.first(where: { $0.kind == "pointer" }) ?? theme.allSprites.first
            }
        } else {
            chosenDescriptor = theme.allSprites.first(where: { $0.kind == mappedKind })
                ?? ( variantId.flatMap { id in theme.pointerVariants.first(where: { $0.id == id }) } )
                ?? theme.allSprites.first(where: { $0.kind == "pointer" })
                ?? theme.allSprites.first
        }

        if let desc = chosenDescriptor,
           let svgImage = NSImage(contentsOf: desc.fileURL),
           svgImage.size.width > 0, svgImage.size.height > 0 {
            // Note from NativeScreen's: `macos` classic SVGs have extra transparent margin around the sprite
            // so scales `setId === "macos"` by `1.75` around its center/hotspot!
            let extraScale: CGFloat = (theme.id == "macos") ? 1.68 : 1.0
            let cgImg = rasterizeNSImage(
                svgImage,
                pixelSize: pixelSize,
                extraScale: extraScale,
                hotspot01: desc.hotspot01,
                centerInPreviewBox: forInspectorPreview
            )
            return (cgImg, desc.hotspot01)
        }

        // Procedural fallback if bundle is unavailable
        let fallbackCG = renderFallbackProceduralCGImage(themeId: theme.id, pixelSize: pixelSize)
        return (fallbackCG, theme.hotspot01)
    }

    private func rasterizeNSImage(
        _ nsImage: NSImage,
        pixelSize: Int,
        extraScale: CGFloat,
        hotspot01: Point01,
        centerInPreviewBox: Bool
    ) -> CGImage {
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

        NSGraphicsContext.saveGraphicsState()
        let graphicsContext = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.current = graphicsContext

        let srcW = max(1.0, nsImage.size.width)
        let srcH = max(1.0, nsImage.size.height)
        let fitScale = min(size.width / srcW, size.height / srcH) * extraScale
        let drawW = srcW * fitScale
        let drawH = srcH * fitScale

        let drawRect: NSRect
        if centerInPreviewBox {
            drawRect = NSRect(
                x: (size.width - drawW) * 0.5,
                y: (size.height - drawH) * 0.5,
                width: drawW,
                height: drawH
            )
        } else {
            // Keep the hotspot at its exact normalized coordinate `(hotspot01.x, 1.0 - hotspot01.y)` when `extraScale != 1`!
            let anchorX = size.width * CGFloat(hotspot01.x)
            let anchorY = size.height * CGFloat(1.0 - hotspot01.y)
            drawRect = NSRect(
                x: anchorX - drawW * CGFloat(hotspot01.x),
                y: anchorY - drawH * CGFloat(1.0 - hotspot01.y),
                width: drawW,
                height: drawH
            )
        }

        nsImage.draw(
            in: drawRect,
            from: .zero,
            operation: .sourceOver,
            fraction: 1.0,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )

        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()!
    }

    private func renderFallbackProceduralCGImage(themeId: String, pixelSize: Int) -> CGImage {
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
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: size.width / 256.0, y: -size.height / 256.0)

        let path = CGMutablePath()
        path.move(to: CGPoint(x: 56, y: 34))
        path.addLine(to: CGPoint(x: 186, y: 152))
        path.addLine(to: CGPoint(x: 128, y: 170))
        path.addLine(to: CGPoint(x: 156, y: 226))
        path.addLine(to: CGPoint(x: 120, y: 234))
        path.addLine(to: CGPoint(x: 92, y: 178))
        path.addLine(to: CGPoint(x: 48, y: 206))
        path.closeSubpath()

        ctx.addPath(path)
        ctx.setStrokeColor(CGColor.white)
        ctx.setLineWidth(16)
        ctx.setLineJoin(.round)
        ctx.strokePath()
        ctx.addPath(path)
        ctx.setFillColor(CGColor(red: 0.05, green: 0.05, blue: 0.07, alpha: 1.0))
        ctx.fillPath()
        return ctx.makeImage()!
    }
}

// MARK: - Click Sound Effect Player (`Magic Mouse™` & `MX Master™` from `CursorAssets.bundle/sounds/clicks/`)

@MainActor
public final class CursorClickSoundPlayer {
    public static let shared = CursorClickSoundPlayer()

    private var activePlayers: [AVAudioPlayer] = []

    private init() {}

    public func playClickSound(soundSet: String?, kind: String = "click", volume: Double = 0.5) {
        guard let rawSet = soundSet, !rawSet.isEmpty else { return }
        let folderName: String
        switch rawSet {
        case "apple-magic-mouse", "magic-mouse":
            folderName = "apple-magic-mouse"
        case "logitech-mx-master", "mx-master":
            folderName = "logitech-mx-master"
        default:
            return
        }

        guard let root = CursorThemePreset.cursorAssetsRootURL() else { return }
        let wavURL = root
            .appendingPathComponent("sounds/clicks/\(folderName)/\(kind).wav")
        guard FileManager.default.fileExists(atPath: wavURL.path) else { return }

        do {
            let player = try AVAudioPlayer(contentsOf: wavURL)
            player.volume = Float(max(0.0, min(1.0, volume)))
            player.prepareToPlay()
            player.play()
            activePlayers.removeAll { !$0.isPlaying }
            activePlayers.append(player)
        } catch {
            // Ignore audio device errors
        }
    }
}
