import CoreImage
import Foundation

/// A 3D LUT from an Adobe `.cube` file. The table applies to sRGB-encoded values, the same as the Windows `Lut3D` pass,
/// so a project grades the same on both platforms (`spec/06` ADR-31).
public struct CubeLUTFile: Sendable {
    public let dimension: Int
    /// Float32 RGBA, red changing fastest, as `CIColorCube` expects.
    public let data: Data

    nonisolated public static let maximumDimension = 128

    /// Nil when the text is not a complete 3D table.
    nonisolated public static func parse(_ text: String) -> CubeLUTFile? {
        var dimension = 0
        var values: [Float] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("TITLE") || line.hasPrefix("DOMAIN_") {
                continue
            }
            if line.hasPrefix("LUT_1D_SIZE") {
                return nil
            }
            let parts = line.split(whereSeparator: \.isWhitespace)
            if line.hasPrefix("LUT_3D_SIZE") {
                guard parts.count >= 2, let parsed = Int(parts[1]) else { return nil }
                dimension = parsed
                continue
            }
            guard parts.count >= 3,
                  let red = Float(parts[0]), let green = Float(parts[1]), let blue = Float(parts[2]) else {
                return nil
            }
            values.append(red)
            values.append(green)
            values.append(blue)
            values.append(1.0)
        }
        guard dimension >= 2, dimension <= maximumDimension,
              values.count == dimension * dimension * dimension * 4 else {
            return nil
        }
        return CubeLUTFile(dimension: dimension, data: values.withUnsafeBufferPointer { Data(buffer: $0) })
    }

    nonisolated public func apply(to input: CIImage) -> CIImage {
        // VERIFY: CIColorCubeWithColorSpace accepts the usual 33 size, and alpha survives for a cutout camera.
        input.applyingFilter("CIColorCubeWithColorSpace", parameters: [
            "inputCubeDimension": dimension,
            "inputCubeData": data,
            "inputColorSpace": CGColorSpace(name: CGColorSpace.sRGB) as Any
        ])
    }
}

/// Parsed tables by path and modification time; the compositor asks on every camera frame.
public enum CubeLUTCache {
    nonisolated private static let lock = NSLock()
    nonisolated(unsafe) private static var entries: [String: CubeLUTFile?] = [:]

    nonisolated public static func table(at url: URL) -> CubeLUTFile? {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let key = "\(url.path)|\(modified?.timeIntervalSince1970 ?? 0)"
        lock.lock()
        defer { lock.unlock() }
        if let cached = entries[key] {
            return cached
        }
        let parsed = (try? String(contentsOf: url, encoding: .utf8)).flatMap(CubeLUTFile.parse)
        entries[key] = .some(parsed)
        return parsed
    }
}
