import AppKit
import CoreImage
import Foundation

/// Green screen keying: a person mask from the backdrop color, and spill removal, both as 64³ color cubes so CoreImage
/// runs them on the GPU and a cube is built once per setting. The per-color math is in `spec/07` §7.4; Windows builds
/// the same cubes.
nonisolated enum ChromaKey {
    struct Settings: Hashable, Sendable {
        /// Backdrop color, sRGB 0...1.
        var key: SIMD3<Double>
        var similarity: Double
        var smoothness: Double
        var spill: Double

        init(camera: CameraConfig) {
            let c = CIColor(hexString: camera.chromaKeyColor)
            key = SIMD3(Double(c.red), Double(c.green), Double(c.blue))
            similarity = min(1.0, max(0.0, camera.chromaSimilarity))
            smoothness = min(1.0, max(0.0, camera.chromaSmoothness))
            spill = min(1.0, max(0.0, camera.chromaSpill))
        }
    }

    static let cubeSize = 64

    /// BT.601 chroma of an sRGB color.
    static func chroma(_ c: SIMD3<Double>) -> SIMD2<Double> {
        SIMD2(
            -0.168736 * c.x - 0.331264 * c.y + 0.5 * c.z,
            0.5 * c.x - 0.418688 * c.y - 0.081312 * c.z
        )
    }

    /// How much of `color` is the person (1) rather than the backdrop (0).
    static func alpha(of color: SIMD3<Double>, settings s: Settings) -> Double {
        let d = chroma(color) - chroma(s.key)
        let distance = (d.x * d.x + d.y * d.y).squareRoot()
        let low = 0.02 + s.similarity * 0.30
        let high = low + 0.005 + s.smoothness * 0.20
        let t = min(1.0, max(0.0, (distance - low) / (high - low)))
        return t * t * (3.0 - 2.0 * t)
    }

    /// `color` with the backdrop's tint pulled out: the key's strongest channel is brought down toward the larger of
    /// the other two by `spill`.
    static func despilled(_ color: SIMD3<Double>, settings s: Settings) -> SIMD3<Double> {
        guard s.spill > 0.001 else { return color }
        var c = color
        let k = s.key
        if k.y >= k.x && k.y >= k.z {
            let limit = max(c.x, c.z)
            if c.y > limit { c.y -= (c.y - limit) * s.spill }
        } else if k.z >= k.x {
            let limit = max(c.x, c.y)
            if c.z > limit { c.z -= (c.z - limit) * s.spill }
        } else {
            let limit = max(c.y, c.z)
            if c.x > limit { c.x -= (c.x - limit) * s.spill }
        }
        return c
    }

    private static let lock = NSLock()
    /// The most recently used cubes, newest last. Each is 4 MB, so only a few are kept: enough for preview and export of
    /// the current setting and the one before it, not every value a dragged slider passes through.
    nonisolated(unsafe) private static var maskCubes: [(Settings, Data)] = []
    nonisolated(unsafe) private static var spillCubes: [(Settings, Data)] = []
    private static let keptCubes = 3

    private static func cube(_ settings: Settings, spill: Bool) -> Data {
        lock.lock()
        defer { lock.unlock() }
        func lookUp(_ cubes: inout [(Settings, Data)]) -> Data? {
            guard let index = cubes.firstIndex(where: { $0.0 == settings }) else { return nil }
            let hit = cubes.remove(at: index)
            cubes.append(hit)
            return hit.1
        }
        if let cached = spill ? lookUp(&spillCubes) : lookUp(&maskCubes) { return cached }
        let n = cubeSize
        var values = [Float](repeating: 0, count: n * n * n * 4)
        var i = 0
        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    let color = SIMD3(Double(r), Double(g), Double(b)) / Double(n - 1)
                    if spill {
                        let out = despilled(color, settings: settings)
                        values[i] = Float(out.x)
                        values[i + 1] = Float(out.y)
                        values[i + 2] = Float(out.z)
                    } else {
                        let a = Float(alpha(of: color, settings: settings))
                        values[i] = a
                        values[i + 1] = a
                        values[i + 2] = a
                    }
                    values[i + 3] = 1.0
                    i += 4
                }
            }
        }
        let data = values.withUnsafeBufferPointer { Data(buffer: $0) }
        if spill {
            spillCubes.append((settings, data))
            if spillCubes.count > keptCubes { spillCubes.removeFirst() }
        } else {
            maskCubes.append((settings, data))
            if maskCubes.count > keptCubes { maskCubes.removeFirst() }
        }
        return data
    }

    private static func applyCube(_ data: Data, to image: CIImage) -> CIImage {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let filter = CIFilter(name: "CIColorCubeWithColorSpace", parameters: [
                  kCIInputImageKey: image,
                  "inputCubeDimension": cubeSize,
                  "inputCubeData": data,
                  "inputColorSpace": space,
              ]),
              let output = filter.outputImage else { return image }
        return output.cropped(to: image.extent)
    }

    /// A grayscale person mask (white is the person) the size of `image`.
    static func personMask(for image: CIImage, settings: Settings) -> CIImage {
        applyCube(cube(settings, spill: false), to: image)
    }

    /// `image` with the backdrop's color spill removed.
    static func removingSpill(from image: CIImage, settings: Settings) -> CIImage {
        guard settings.spill > 0.001 else { return image }
        return applyCube(cube(settings, spill: true), to: image)
    }

    /// The average color of a strip along the top of `image` (where a backdrop usually shows), as `#RRGGBB`.
    static func sampledBackdropColor(of image: CIImage, context: CIContext) -> String? {
        let e = image.extent
        guard e.width > 4, e.height > 4 else { return nil }
        let strip = CGRect(x: e.minX, y: e.maxY - e.height * 0.12, width: e.width, height: e.height * 0.12)
        guard let average = CIFilter(name: "CIAreaAverage", parameters: [
            kCIInputImageKey: image,
            kCIInputExtentKey: CIVector(cgRect: strip),
        ])?.outputImage else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(
            average,
            toBitmap: &pixel,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
        )
        return String(format: "#%02X%02X%02X", pixel[0], pixel[1], pixel[2])
    }
}

extension NSColor {
    /// `#RRGGBB` in sRGB, or nil for colors that cannot be converted (patterns).
    var sRGBHexString: String? {
        guard let c = usingColorSpace(.sRGB) else { return nil }
        func byte(_ v: CGFloat) -> Int { Int((min(1, max(0, v)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(c.redComponent), byte(c.greenComponent), byte(c.blueComponent))
    }
}
