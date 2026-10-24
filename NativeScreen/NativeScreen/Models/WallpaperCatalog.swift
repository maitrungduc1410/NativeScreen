import Foundation
import AppKit
import ImageIO

/// Built-in Mesh Gradient & Color Palette presets + macOS System Wallpaper loader (`/System/Library/Desktop Pictures`).
public struct MeshPreset: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let category: String
    public let colorsHex: [String] // 4 corner colors [topLeft, topRight, bottomLeft, bottomRight]

    public static let builtIn: [MeshPreset] = [
        MeshPreset(
            id: "spring-aurora",
            name: "Spring Aurora",
            category: "Spring",
            colorsHex: ["#00D2FF", "#92FE9D", "#FF6B6B", "#FFE66D"]
        ),
        MeshPreset(
            id: "spring-blossom",
            name: "Spring Blossom",
            category: "Spring",
            colorsHex: ["#FF9A9E", "#FAD0C4", "#A18CD1", "#FBC2EB"]
        ),
        MeshPreset(
            id: "sunset-glow",
            name: "Sunset Glow",
            category: "Sunset",
            colorsHex: ["#FA709A", "#FEE140", "#F83600", "#FE8C00"]
        ),
        MeshPreset(
            id: "radiant-violet",
            name: "Radiant Violet",
            category: "Radiant",
            colorsHex: ["#4776E6", "#8E54E9", "#FF0844", "#FFB199"]
        ),
        MeshPreset(
            id: "midnight-indigo",
            name: "Midnight Indigo",
            category: "Midnight",
            colorsHex: ["#0F2027", "#203A43", "#2C5364", "#4A00E0"]
        ),
        MeshPreset(
            id: "iridescent-pearl",
            name: "Iridescent Pearl",
            category: "Iridescent",
            colorsHex: ["#8EC5FC", "#E0C3FC", "#FFDEE9", "#B5FFFC"]
        ),
        MeshPreset(
            id: "energy-cyber",
            name: "Energy Pulse",
            category: "Energy",
            colorsHex: ["#12C2E9", "#C471ED", "#F64F59", "#7F00FF"]
        ),
        MeshPreset(
            id: "glass-ocean",
            name: "Glass Ocean",
            category: "Glassmorphism",
            colorsHex: ["#2193B0", "#6DD5ED", "#1A2980", "#26D0CE"]
        )
    ]

    public static func preset(withId id: String?) -> MeshPreset {
        guard let id = id, let found = builtIn.first(where: { $0.id == id }) else {
            return builtIn[0]
        }
        return found
    }
}

public struct SystemWallpaperItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let fullImageURL: URL
    public let thumbnailURL: URL
}

public enum SystemWallpaperCatalog {
    private static var cachedItems: [SystemWallpaperItem]?
    private static var thumbnailCache: [String: NSImage] = [:]
    private static let lock = NSLock()

    /// Discovers built-in macOS wallpapers from `/System/Library/Desktop Pictures/` once and caches the list.
    public static func discoverSystemWallpapers() -> [SystemWallpaperItem] {
        lock.lock()
        if let existing = cachedItems {
            lock.unlock()
            return existing
        }
        lock.unlock()

        var items: [SystemWallpaperItem] = []
        let fm = FileManager.default
        let desktopPicturesDir = URL(fileURLWithPath: "/System/Library/Desktop Pictures", isDirectory: true)
        let thumbnailsDir = desktopPicturesDir.appendingPathComponent(".thumbnails", isDirectory: true)

        if let mainScreen = NSScreen.main,
           let currentURL = NSWorkspace.shared.desktopImageURL(for: mainScreen),
           fm.fileExists(atPath: currentURL.path) {
            items.append(
                SystemWallpaperItem(
                    id: "current-desktop",
                    name: "Current Desktop",
                    fullImageURL: currentURL,
                    thumbnailURL: currentURL
                )
            )
        }

        let allowedExtensions: Set<String> = ["heic", "jpg", "jpeg", "png"]
        if let contents = try? fm.contentsOfDirectory(
            at: desktopPicturesDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            for url in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let ext = url.pathExtension.lowercased()
                guard allowedExtensions.contains(ext) else { continue }
                let baseName = url.deletingPathExtension().lastPathComponent
                let thumbCandidate = thumbnailsDir.appendingPathComponent("\(baseName).heic")
                let thumbJPGCandidate = thumbnailsDir.appendingPathComponent("\(baseName).jpg")
                let thumbURL: URL
                if fm.fileExists(atPath: thumbCandidate.path) {
                    thumbURL = thumbCandidate
                } else if fm.fileExists(atPath: thumbJPGCandidate.path) {
                    thumbURL = thumbJPGCandidate
                } else {
                    thumbURL = url
                }

                items.append(
                    SystemWallpaperItem(
                        id: baseName,
                        name: baseName,
                        fullImageURL: url,
                        thumbnailURL: thumbURL
                    )
                )
                if items.count >= 24 { break }
            }
        }

        lock.lock()
        cachedItems = items
        lock.unlock()
        return items
    }

    /// Returns a fast in-memory cached `NSImage` thumbnail (200px max dimension) so SwiftUI `body` evaluation
    /// never touches the disk or decodes multi-megabyte `.heic` files when dragging sliders!
    public static func cachedThumbnailImage(for item: SystemWallpaperItem) -> NSImage? {
        lock.lock()
        if let hit = thumbnailCache[item.id] {
            lock.unlock()
            return hit
        }
        lock.unlock()

        guard let cgImg = downsampleCGImage(at: item.thumbnailURL, maxPixelSize: 200)
                ?? downsampleCGImage(at: item.fullImageURL, maxPixelSize: 200) else {
            return nil
        }
        let nsImg = NSImage(cgImage: cgImg, size: NSSize(width: cgImg.width, height: cgImg.height))

        lock.lock()
        thumbnailCache[item.id] = nsImg
        lock.unlock()
        return nsImg
    }

    /// Uses `ImageIO` hardware thumbnailing to decode & downsample any `.heic`/`.jpg` into an immediately-cached `CGImage`.
    public static func downsampleCGImage(at url: URL, maxPixelSize: Int) -> CGImage? {
        let sourceOptions: [CFString: Any] = [
            kCGImageSourceShouldCache: false
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary) else {
            return nil
        }
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary)
    }
}
