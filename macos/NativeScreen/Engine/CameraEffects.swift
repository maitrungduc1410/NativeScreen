import CoreGraphics
import CoreImage
import Foundation

/// Sticker artwork and how each one sits on a face, from `Stickers.bundle/stickers.json`.
nonisolated struct CameraSticker: Identifiable, Decodable, Sendable {
    let id: String
    let name: String
    let file: String
    /// `eyes`, `nose` or `mouth`.
    let anchor: String
    /// Sizes and offsets are in face units (about the distance between the eyes).
    let width: Double
    let height: Double?
    let offsetX: Double
    let offsetY: Double
}

nonisolated enum CameraStickerCatalog {
    private struct File: Decodable { let stickers: [CameraSticker] }

    private static let bundleURL = Bundle.main.url(forResource: "Stickers", withExtension: "bundle")

    static let all: [CameraSticker] = {
        guard let url = bundleURL?.appendingPathComponent("stickers.json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data) else { return [] }
        return file.stickers
    }()

    private nonisolated(unsafe) static let images: [String: CIImage] = {
        var result: [String: CIImage] = [:]
        for sticker in all {
            if let url = imageURL(for: sticker), let image = CIImage(contentsOf: url) { result[sticker.id] = image }
        }
        return result
    }()

    static func sticker(id: String) -> CameraSticker? { all.first { $0.id == id } }
    static func image(id: String) -> CIImage? { images[id] }
    static func imageURL(for sticker: CameraSticker) -> URL? { bundleURL?.appendingPathComponent(sticker.file) }
}

nonisolated enum CameraEffects {
    private static let eyesToMouthRatio: CGFloat = 1.2

    struct StickerPlacement {
        var center: CGPoint
        var size: CGSize
        /// Radians, clockwise on screen.
        var angle: CGFloat
    }

    /// Places a sticker on a face given in pixels, y down. The face's own axes are used, so it tilts with the head; the
    /// larger of the two face scales is used, so it does not shrink when the head turns.
    static func place(_ sticker: CameraSticker, on face: FacePoints, aspect: CGFloat) -> StickerPlacement? {
        let eyes = CGPoint(x: (face.eyeA.x + face.eyeB.x) * 0.5, y: (face.eyeA.y + face.eyeB.y) * 0.5)
        let rough = CGPoint(x: eyes.x - face.mouth.x, y: eyes.y - face.mouth.y)
        let towardsRight = CGPoint(x: -rough.y, y: rough.x)
        let eyeAToB = (face.eyeB.x - face.eyeA.x) * towardsRight.x + (face.eyeB.y - face.eyeA.y) * towardsRight.y >= 0
        let (left, right) = eyeAToB ? (face.eyeA, face.eyeB) : (face.eyeB, face.eyeA)

        let axis = CGPoint(x: right.x - left.x, y: right.y - left.y)
        let eyeDistance = hypot(axis.x, axis.y)
        guard eyeDistance >= 1.0 else { return nil }
        let ux = CGPoint(x: axis.x / eyeDistance, y: axis.y / eyeDistance)
        let uy = CGPoint(x: ux.y, y: -ux.x)
        let unit = max(eyeDistance, hypot(rough.x, rough.y) / eyesToMouthRatio)

        let anchor = sticker.anchor == "nose" ? face.nose : sticker.anchor == "mouth" ? face.mouth : eyes
        let offsetX = CGFloat(sticker.offsetX), offsetY = CGFloat(sticker.offsetY)
        let width = CGFloat(sticker.width) * unit
        return StickerPlacement(
            center: CGPoint(
                x: anchor.x + unit * (offsetX * ux.x + offsetY * uy.x),
                y: anchor.y + unit * (offsetX * ux.y + offsetY * uy.y)
            ),
            size: CGSize(width: width, height: sticker.height.map { CGFloat($0) * unit } ?? width * aspect),
            angle: atan2(ux.y, ux.x)
        )
    }

    /// Draws a sticker over `base`, whose extent starts at the origin.
    static func draw(_ sticker: CIImage, at placement: StickerPlacement, opacity: Double, over base: CIImage) -> CIImage {
        let source = sticker.extent
        guard source.width > 0, source.height > 0 else { return base }
        let transform = CGAffineTransform(translationX: -source.midX, y: -source.midY)
            .concatenating(CGAffineTransform(scaleX: placement.size.width / source.width, y: placement.size.height / source.height))
            .concatenating(CGAffineTransform(rotationAngle: -placement.angle))
            .concatenating(CGAffineTransform(
                translationX: placement.center.x,
                y: base.extent.height - placement.center.y
            ))
        var placed = sticker.transformed(by: transform)
        if opacity < 0.996 {
            placed = placed.applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: opacity)
            ])
        }
        return placed.composited(over: base).cropped(to: base.extent)
    }

    /// Maps a normalized point of the raw webcam frame into the prepared camera image (crop, then mirror), still normalized.
    static func mapped(_ point: CGPoint, crop: Rect01, isFlipped: Bool) -> CGPoint {
        let x = (point.x - CGFloat(crop.x)) / CGFloat(max(0.25, crop.width))
        let y = (point.y - CGFloat(crop.y)) / CGFloat(max(0.25, crop.height))
        return CGPoint(x: isFlipped ? 1.0 - x : x, y: y)
    }

    /// Blurs what is behind the person. The person is removed first and the hole filled from around it, so no halo of
    /// their colors surrounds them. `softMask` is 1 on the person.
    static func blurredBackground(of image: CIImage, softMask: CIImage, amount: Double) -> CIImage {
        let extent = image.extent
        let downscale: CGFloat = 0.25
        let sigma = Double(extent.height) * 0.06 * max(0.05, amount) * Double(downscale)
        func blurred(_ input: CIImage) -> CIImage {
            input.clampedToExtent()
                .transformed(by: CGAffineTransform(scaleX: downscale, y: downscale))
                .applyingGaussianBlur(sigma: sigma)
                .transformed(by: CGAffineTransform(scaleX: 1.0 / downscale, y: 1.0 / downscale))
                .cropped(to: extent)
        }

        let wideMask = softMask.clampedToExtent()
            .applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: max(2.0, extent.height * 0.008)])
            .cropped(to: extent)
        guard let withoutPerson = CIFilter(name: "CIBlendWithMask", parameters: [
            kCIInputImageKey: CIImage(color: .clear).cropped(to: extent),
            kCIInputBackgroundImageKey: image,
            kCIInputMaskImageKey: wideMask
        ])?.outputImage else { return blurred(image) }

        // Color matrix works on unpremultiplied color, so raising alpha turns the blurred, partly empty result opaque
        // without darkening it. The plain blur only shows where nothing of the background reached.
        let filled = blurred(withoutPerson)
            .applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: 8)])
            .applyingFilter("CIColorClamp")
        return filled.composited(over: blurred(image)).cropped(to: extent)
    }

    /// Scales `image` to cover `extent`, centered.
    static func filling(_ extent: CGRect, with image: CIImage) -> CIImage {
        let source = image.extent
        let scale = max(extent.width / max(1.0, source.width), extent.height / max(1.0, source.height))
        return image
            .transformed(by: CGAffineTransform(translationX: -source.minX, y: -source.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(
                translationX: extent.minX + (extent.width - source.width * scale) * 0.5,
                y: extent.minY + (extent.height - source.height * scale) * 0.5
            ))
            .cropped(to: extent)
    }
}
